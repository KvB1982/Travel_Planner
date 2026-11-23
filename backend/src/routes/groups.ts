import { and, asc, eq, inArray, ne, sql } from "drizzle-orm";
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { hashToken, newToken } from "../auth/tokens.js";
import type { AppContext } from "../app.js";
import type { Db } from "../db/client.js";
import { groupMembers, groups, invites, tripMembers, trips, users } from "../db/schema.js";
import { forbidden, HttpError, notFound, parseBody, userId, uuidParam } from "../http.js";

type Tx = Parameters<Parameters<Db["transaction"]>[0]>[0];

/** Joining a group means joining every trip it has. Whoever is in a trip already keeps the role held there. */
export async function joinGroup(tx: Db | Tx, groupId: string, uid: string, role: "admin" | "member" = "member"): Promise<void> {
  await tx.insert(groupMembers).values({ groupId, userId: uid, role }).onConflictDoNothing();
  const theirs = await tx.select({ id: trips.id }).from(trips).where(eq(trips.groupId, groupId));
  if (theirs.length) await tx.insert(tripMembers).values(theirs.map((t) => ({ tripId: t.id, userId: uid, role: "member" as const }))).onConflictDoNothing();
}

/** A trip put into a group opens to everyone in it. */
export async function openTripToGroup(tx: Db | Tx, tripId: string, groupId: string): Promise<void> {
  const people = await tx.select({ userId: groupMembers.userId }).from(groupMembers).where(eq(groupMembers.groupId, groupId));
  if (people.length) await tx.insert(tripMembers).values(people.map((p) => ({ tripId, userId: p.userId, role: "member" as const }))).onConflictDoNothing();
}

/** Every group has one shelf for adverts that belong to no trip yet. All its members see and tend it. */
export async function ensureGroupShelf(tx: Db | Tx, groupId: string, uid: string): Promise<void> {
  const [t] = await tx.insert(trips).values({ kind: "watchlist", title: "Merkliste", groupId, createdBy: uid }).onConflictDoNothing().returning({ id: trips.id });
  if (t) await openTripToGroup(tx, t.id, groupId);
}

/** The group a new trip goes into when nothing is said: the only one the person is in. */
export async function onlyGroupOf(db: Db, uid: string): Promise<string | null> {
  const mine = await db.select({ groupId: groupMembers.groupId }).from(groupMembers).where(eq(groupMembers.userId, uid)).limit(2);
  return mine.length === 1 ? mine[0]!.groupId : null;
}

export async function requireGroupMember(db: Db, groupId: string, uid: string, admin = false) {
  const [m] = await db.select({ role: groupMembers.role }).from(groupMembers).where(and(eq(groupMembers.groupId, groupId), eq(groupMembers.userId, uid))).limit(1);
  if (!m) throw notFound("Gruppe nicht gefunden.");
  if (admin && m.role !== "admin") throw forbidden();
  return m.role;
}

export function groupRoutes(app: FastifyInstance, ctx: AppContext): void {
  const { db } = ctx;

  async function mine(uid: string) {
    const own = await db.select({ group: groups, role: groupMembers.role }).from(groupMembers).innerJoin(groups, eq(groups.id, groupMembers.groupId)).where(eq(groupMembers.userId, uid)).orderBy(asc(groups.createdAt));
    const ids = own.map((g) => g.group.id);
    const people = ids.length
      ? await db.select({ groupId: groupMembers.groupId, id: users.id, name: users.name, role: groupMembers.role, joinedAt: groupMembers.joinedAt }).from(groupMembers).innerJoin(users, eq(users.id, groupMembers.userId)).where(inArray(groupMembers.groupId, ids)).orderBy(asc(groupMembers.joinedAt))
      : [];
    const theirs = ids.length ? await db.select({ id: trips.id, groupId: trips.groupId, title: trips.title, kind: trips.kind }).from(trips).where(inArray(trips.groupId, ids)).orderBy(asc(trips.createdAt)) : [];
    return own.map(({ group, role }) => ({
      id: group.id,
      name: group.name,
      role,
      createdAt: group.createdAt,
      members: people.filter((p) => p.groupId === group.id).map(({ groupId: _g, ...p }) => p),
      watchlistId: theirs.find((t) => t.groupId === group.id && t.kind === "watchlist")?.id ?? null,
      trips: theirs.filter((t) => t.groupId === group.id && t.kind === "trip").map(({ groupId: _g, kind: _k, ...t }) => t),
    }));
  }

  app.get("/groups", async (req) => {
    const uid = userId(req);
    // Groups from before the shared shelf existed get theirs with the first look.
    const lacking = await db.select({ groupId: groupMembers.groupId }).from(groupMembers).where(and(eq(groupMembers.userId, uid), sql`not exists (select 1 from ${trips} where ${trips.groupId} = ${groupMembers.groupId} and ${trips.kind} = 'watchlist')`));
    for (const g of lacking) await ensureGroupShelf(db, g.groupId, uid);
    return { groups: await mine(uid) };
  });

  app.post("/groups", async (req, reply) => {
    const uid = userId(req);
    const body = parseBody(z.object({ name: z.string().trim().min(1).max(80) }), req.body);
    const [group] = await db.insert(groups).values({ name: body.name, createdBy: uid }).returning();
    await joinGroup(db, group!.id, uid, "admin");
    await ensureGroupShelf(db, group!.id, uid);
    return reply.code(201).send({ groups: await mine(uid) });
  });

  app.patch("/groups/:groupId", async (req) => {
    const uid = userId(req);
    const groupId = uuidParam((req.params as { groupId: string }).groupId);
    await requireGroupMember(db, groupId, uid, true);
    const body = parseBody(z.object({ name: z.string().trim().min(1).max(80) }), req.body);
    await db.update(groups).set({ name: body.name }).where(eq(groups.id, groupId));
    return { groups: await mine(uid) };
  });

  /** A link that brings someone into the group. Shown once; only its hash is kept. */
  app.post("/groups/:groupId/invites", async (req, reply) => {
    const uid = userId(req);
    const groupId = uuidParam((req.params as { groupId: string }).groupId);
    await requireGroupMember(db, groupId, uid, true);
    const body = parseBody(z.object({ maxUses: z.number().int().min(1).max(50).default(1), expiresInDays: z.number().int().min(1).max(60).default(14) }), req.body ?? {});
    const token = newToken();
    const expiresAt = new Date(Date.now() + body.expiresInDays * 86_400_000);
    await db.insert(invites).values({ groupId, tokenHash: hashToken(token), role: "member", createdBy: uid, expiresAt, maxUses: body.maxUses });
    return reply.code(201).send({ token, url: `${ctx.config.PUBLIC_BASE_URL.replace(/\/$/, "")}/einladung/${token}`, expiresAt, maxUses: body.maxUses });
  });

  /** Links that still work, so one that went astray can be taken back. The links themselves are not kept and cannot be shown again. */
  app.get("/groups/:groupId/invites", async (req) => {
    const uid = userId(req);
    const groupId = uuidParam((req.params as { groupId: string }).groupId);
    await requireGroupMember(db, groupId, uid, true);
    const open = await db
      .select({ id: invites.id, createdAt: invites.createdAt, expiresAt: invites.expiresAt, maxUses: invites.maxUses, usedCount: invites.usedCount, createdBy: users.name })
      .from(invites)
      .innerJoin(users, eq(users.id, invites.createdBy))
      .where(and(eq(invites.groupId, groupId), sql`${invites.usedCount} < ${invites.maxUses}`, sql`${invites.expiresAt} > now()`))
      .orderBy(asc(invites.createdAt));
    return { invites: open };
  });

  app.delete("/groups/:groupId/invites/:inviteId", async (req, reply) => {
    const uid = userId(req);
    const params = req.params as { groupId: string; inviteId: string };
    const groupId = uuidParam(params.groupId);
    await requireGroupMember(db, groupId, uid, true);
    const gone = await db.delete(invites).where(and(eq(invites.id, uuidParam(params.inviteId)), eq(invites.groupId, groupId))).returning({ id: invites.id });
    if (!gone.length) throw notFound();
    return reply.code(204).send();
  });

  /** Take someone out of the group, or leave it. Trips they set up themselves stay theirs. */
  app.delete("/groups/:groupId/members/:userId", async (req) => {
    const uid = userId(req);
    const params = req.params as { groupId: string; userId: string };
    const groupId = uuidParam(params.groupId);
    const who = uuidParam(params.userId);
    const role = await requireGroupMember(db, groupId, uid);
    if (who !== uid && role !== "admin") throw forbidden();
    const [admins] = await db.select({ n: sql<number>`count(*)::int` }).from(groupMembers).where(and(eq(groupMembers.groupId, groupId), eq(groupMembers.role, "admin"), ne(groupMembers.userId, who)));
    const [others] = await db.select({ n: sql<number>`count(*)::int` }).from(groupMembers).where(and(eq(groupMembers.groupId, groupId), ne(groupMembers.userId, who)));
    if ((admins?.n ?? 0) === 0 && (others?.n ?? 0) > 0) throw new HttpError(409, "last_admin", "Die Gruppe braucht jemanden, der sie verwaltet. Gib die Verwaltung zuerst weiter.");
    await db.transaction(async (tx) => {
      const gone = await tx.delete(groupMembers).where(and(eq(groupMembers.groupId, groupId), eq(groupMembers.userId, who))).returning({ userId: groupMembers.userId });
      if (!gone.length) throw notFound();
      const theirs = await tx.select({ id: trips.id }).from(trips).where(eq(trips.groupId, groupId));
      if (theirs.length) await tx.delete(tripMembers).where(and(eq(tripMembers.userId, who), ne(tripMembers.role, "organizer"), inArray(tripMembers.tripId, theirs.map((t) => t.id))));
    });
    return { groups: await mine(uid) };
  });

  /** Hand the administration on, or share it. */
  app.patch("/groups/:groupId/members/:userId", async (req) => {
    const uid = userId(req);
    const params = req.params as { groupId: string; userId: string };
    const groupId = uuidParam(params.groupId);
    const who = uuidParam(params.userId);
    await requireGroupMember(db, groupId, uid, true);
    const body = parseBody(z.object({ role: z.enum(["admin", "member"]) }), req.body);
    if (who === uid && body.role === "member") {
      const [admins] = await db.select({ n: sql<number>`count(*)::int` }).from(groupMembers).where(and(eq(groupMembers.groupId, groupId), eq(groupMembers.role, "admin"), ne(groupMembers.userId, who)));
      if ((admins?.n ?? 0) === 0) throw new HttpError(409, "last_admin", "Die Gruppe braucht jemanden, der sie verwaltet.");
    }
    const changed = await db.update(groupMembers).set({ role: body.role }).where(and(eq(groupMembers.groupId, groupId), eq(groupMembers.userId, who))).returning({ userId: groupMembers.userId });
    if (!changed.length) throw notFound();
    return { groups: await mine(uid) };
  });
}
