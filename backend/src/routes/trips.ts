import { and, asc, desc, eq, isNull, ne, sql } from "drizzle-orm";
import { rm } from "node:fs/promises";
import path from "node:path";
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { hashToken, newToken } from "../auth/tokens.js";
import type { AppContext } from "../app.js";
import { activityEvents, dateOptions, documents, groupMembers, groups, invites, tripListings, tripMembers, tripPhases, trips, users, type TripPhase } from "../db/schema.js";
import { HttpError, notFound, parseBody, requireMember, userId, uuidParam } from "../http.js";
import { ensureGroupShelf, onlyGroupOf, openTripToGroup, requireGroupMember } from "./groups.js";

const isoDate = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "Datum im Format JJJJ-MM-TT");
const dateOption = z
  .object({ label: z.string().trim().max(80).optional(), startDate: isoDate, endDate: isoDate })
  .refine((d) => d.endDate > d.startDate, { message: "Die Abreise muss nach der Anreise liegen." });

const tripFields = {
  title: z.string().trim().min(1).max(120),
  region: z.string().trim().max(120).nullish(),
  adults: z.number().int().min(1).max(40),
  children: z.number().int().min(0).max(40),
  pets: z.number().int().min(0).max(10),
  budgetTotalCents: z.number().int().min(0).nullish(),
  voteDeadline: z.string().datetime().nullish(),
  flexStart: isoDate.nullish(),
  flexEnd: isoDate.nullish(),
  nightsMin: z.number().int().min(1).max(60).nullish(),
  nightsMax: z.number().int().min(1).max(60).nullish(),
};

const addDays = (day: string, n: number) => new Date(Date.parse(`${day}T00:00:00Z`) + n * 86_400_000).toISOString().slice(0, 10);

/**
 * Up to three stays worth asking every advert about when the dates are open: the middle length at the
 * start of the window, the same at its end, and the shortest stay in the middle. Each look costs the
 * device a page load, so there are few.
 */
export function stayVariants(w: { flexStart: string | null; flexEnd: string | null; nightsMin: number | null; nightsMax: number | null }): { startDate: string; endDate: string; nights: number }[] {
  if (!w.flexStart || !w.flexEnd) return [];
  const room = Math.round((Date.parse(w.flexEnd) - Date.parse(w.flexStart)) / 86_400_000);
  if (room < 1) return [];
  const min = Math.min(room, w.nightsMin ?? room);
  const max = Math.min(room, w.nightsMax ?? room);
  const mid = Math.max(min, Math.min(max, Math.round((min + max) / 2)));
  const at = (start: number, nights: number) => ({ startDate: addDays(w.flexStart!, start), endDate: addDays(w.flexStart!, start + nights), nights });
  const all = [at(0, mid), at(room - mid, mid), at(Math.floor((room - min) / 2), min)];
  return all.filter((v, i) => all.findIndex((x) => x.startDate === v.startDate && x.endDate === v.endDate) === i);
}

/** A window needs both ends in order, and a shortest stay no longer than the longest. */
function checkWindow(w: { flexStart?: string | null; flexEnd?: string | null; nightsMin?: number | null; nightsMax?: number | null }) {
  if (Boolean(w.flexStart) !== Boolean(w.flexEnd)) throw new HttpError(400, "invalid_request", "Das Zeitfenster braucht einen frühesten Anreisetag und einen spätesten Abreisetag.");
  if (w.flexStart && w.flexEnd && w.flexEnd <= w.flexStart) throw new HttpError(400, "invalid_request", "Der späteste Abreisetag muss nach dem frühesten Anreisetag liegen.");
  if (w.nightsMin && w.nightsMax && w.nightsMin > w.nightsMax) throw new HttpError(400, "invalid_request", "Die kürzeste Dauer darf nicht länger sein als die längste.");
}

/**
 * The phase the trip is in today. Arrival and departure move it on by themselves: a booked trip is
 * "travelling" from its first day and in "review" after its last.
 */
export function currentPhase(phase: TripPhase, stay: { startDate: string | null; endDate: string | null }, today = new Date().toISOString().slice(0, 10)): TripPhase {
  if ((phase === "booking" || phase === "preparation" || phase === "travelling") && stay.startDate && stay.endDate) {
    if (today > stay.endDate) return "review";
    if (today >= stay.startDate) return "travelling";
  }
  return phase;
}

export async function logActivity(ctx: AppContext, tripId: string, uid: string | null, type: string, payload: Record<string, unknown> = {}) {
  await ctx.db.insert(activityEvents).values({ tripId, userId: uid, type, payload });
}

export function tripRoutes(app: FastifyInstance, ctx: AppContext): void {
  const { db } = ctx;

  const notTheWatchlist = async (tripId: string, message: string) => {
    const [t] = await db.select({ kind: trips.kind }).from(trips).where(eq(trips.id, tripId)).limit(1);
    if (t?.kind === "watchlist") throw new HttpError(409, "watchlist", message);
  };

  /** Two trips of one group, or two private ones of one person, cannot be told apart by the same name. */
  const nameIsFree = async (title: string, groupId: string | null, owner: string, except?: string) => {
    const [same] = await db
      .select({ id: trips.id })
      .from(trips)
      .where(and(eq(trips.kind, "trip"), sql`lower(trim(${trips.title})) = ${title.trim().toLowerCase()}`, groupId ? eq(trips.groupId, groupId) : and(isNull(trips.groupId), eq(trips.createdBy, owner)), except ? ne(trips.id, except) : undefined))
      .limit(1);
    if (same) throw new HttpError(409, "title_taken", groupId ? "In dieser Gruppe gibt es schon eine Reise mit diesem Namen, vielleicht im Archiv." : "Du hast schon eine private Reise mit diesem Namen, vielleicht im Archiv.");
  };

  app.post("/trips", async (req, reply) => {
    const uid = userId(req);
    const body = parseBody(
      z.object({ ...tripFields, adults: tripFields.adults.default(2), children: tripFields.children.default(0), pets: tripFields.pets.default(0), dateOptions: z.array(dateOption).max(10).default([]), groupId: z.string().uuid().nullable().optional() }),
      req.body,
    );
    checkWindow(body);
    // Without a word on it, a new trip goes into the person's group, when there is exactly one. null keeps it private.
    const groupId = body.groupId === undefined ? await onlyGroupOf(db, uid) : body.groupId;
    if (groupId) await requireGroupMember(db, groupId, uid);
    await nameIsFree(body.title, groupId, uid);
    const trip = await db.transaction(async (tx) => {
      const [t] = await tx
        .insert(trips)
        .values({
          title: body.title,
          region: body.region ?? null,
          adults: body.adults,
          children: body.children,
          pets: body.pets,
          budgetTotalCents: body.budgetTotalCents ?? null,
          voteDeadline: body.voteDeadline ? new Date(body.voteDeadline) : null,
          flexStart: body.flexStart ?? null,
          flexEnd: body.flexEnd ?? null,
          nightsMin: body.nightsMin ?? null,
          nightsMax: body.nightsMax ?? null,
          groupId,
          createdBy: uid,
        })
        .returning();
      await tx.insert(tripMembers).values({ tripId: t!.id, userId: uid, role: "organizer" });
      if (groupId) await openTripToGroup(tx, t!.id, groupId);
      if (body.dateOptions.length) await tx.insert(dateOptions).values(body.dateOptions.map((d) => ({ ...d, tripId: t!.id })));
      return t!;
    });
    await logActivity(ctx, trip.id, uid, "trip_created");
    return reply.code(201).send({ trip });
  });

  app.get("/trips", async (req) => {
    const uid = userId(req);
    // Everyone has a shelf of their own for adverts that belong to no trip. It appears with the first look.
    const [shelf] = await db.select({ id: trips.id }).from(trips).where(and(eq(trips.createdBy, uid), eq(trips.kind, "watchlist"), isNull(trips.groupId))).limit(1);
    if (!shelf) {
      await db.transaction(async (tx) => {
        const [t] = await tx.insert(trips).values({ kind: "watchlist", title: "Merkliste", createdBy: uid }).onConflictDoNothing().returning({ id: trips.id });
        if (t) await tx.insert(tripMembers).values({ tripId: t.id, userId: uid, role: "organizer" });
      });
    }
    // The same for each group the person is in: one shared shelf.
    const lacking = await db.select({ groupId: groupMembers.groupId }).from(groupMembers).where(and(eq(groupMembers.userId, uid), sql`not exists (select 1 from ${trips} where ${trips.groupId} = ${groupMembers.groupId} and ${trips.kind} = 'watchlist')`));
    for (const g of lacking) await ensureGroupShelf(db, g.groupId, uid);
    const rows = await db
      .select({
        trip: trips,
        role: tripMembers.role,
        candidates: sql<number>`(select count(*)::int from ${tripListings} where ${tripListings.tripId} = ${trips.id})`,
        favorites: sql<number>`(select count(*)::int from ${tripListings} where ${tripListings.tripId} = ${trips.id} and ${tripListings.status} = 'favorite')`,
      })
      .from(tripMembers)
      .innerJoin(trips, eq(trips.id, tripMembers.tripId))
      .where(eq(tripMembers.userId, uid))
      .orderBy(desc(trips.createdAt));
    const periods = await db.select().from(dateOptions).orderBy(asc(dateOptions.startDate));
    const stayOf = (t: (typeof rows)[number]["trip"]) => {
      const own = periods.filter((p) => p.tripId === t.id);
      const o = own.find((p) => p.id === t.decidedDateOptionId) ?? own[0];
      return { startDate: o?.startDate ?? null, endDate: o?.endDate ?? null };
    };
    const named = await db.select({ id: groups.id, name: groups.name }).from(groups);
    const groupName = (id: string | null) => named.find((g) => g.id === id)?.name ?? null;
    return { trips: rows.map((r) => ({ ...r.trip, groupName: groupName(r.trip.groupId), currentPhase: currentPhase(r.trip.phase, stayOf(r.trip)), role: r.role, candidateCount: r.candidates, favoriteCount: r.favorites })) };
  });

  app.get("/trips/:tripId", async (req) => {
    const uid = userId(req);
    const tripId = uuidParam((req.params as { tripId: string }).tripId);
    const role = await requireMember(db, tripId, uid);
    const [trip] = await db.select().from(trips).where(eq(trips.id, tripId)).limit(1);
    const members = await db
      .select({ id: users.id, name: users.name, role: tripMembers.role, joinedAt: tripMembers.joinedAt })
      .from(tripMembers)
      .innerJoin(users, eq(users.id, tripMembers.userId))
      .where(eq(tripMembers.tripId, tripId))
      .orderBy(asc(tripMembers.joinedAt));
    const options = await db.select().from(dateOptions).where(eq(dateOptions.tripId, tripId)).orderBy(asc(dateOptions.startDate));
    const chosen = options.find((o) => o.id === trip!.decidedDateOptionId) ?? options[0];
    const [group] = trip!.groupId ? await db.select({ name: groups.name }).from(groups).where(eq(groups.id, trip!.groupId)).limit(1) : [];
    return { trip: { ...trip!, groupName: group?.name ?? null, stayVariants: stayVariants(trip!), currentPhase: currentPhase(trip!.phase, { startDate: chosen?.startDate ?? null, endDate: chosen?.endDate ?? null }) }, role, members, dateOptions: options };
  });

  app.patch("/trips/:tripId", async (req) => {
    const uid = userId(req);
    const tripId = uuidParam((req.params as { tripId: string }).tripId);
    await requireMember(db, tripId, uid, "organizer");
    await notTheWatchlist(tripId, "Die Merkliste lässt sich nicht ändern.");
    const body = parseBody(z.object({ ...tripFields, status: z.enum(["planning", "decided", "booked", "archived"]), phase: z.enum(tripPhases), splitMode: z.enum(["equal", "heads"]), childWeight: z.number().min(0).max(1), groupId: z.string().uuid().nullable() }).partial(), req.body);
    if ("groupId" in body || body.title !== undefined) {
      const [now] = await db.select().from(trips).where(eq(trips.id, tripId)).limit(1);
      const target = "groupId" in body ? (body.groupId ?? null) : now!.groupId;
      if (body.title !== undefined ? body.title.trim().toLowerCase() !== now!.title.trim().toLowerCase() || target !== now!.groupId : target !== now!.groupId) await nameIsFree(body.title ?? now!.title, target, now!.createdBy, tripId);
    }
    if ("groupId" in body) {
      const [now] = await db.select({ groupId: trips.groupId }).from(trips).where(eq(trips.id, tripId)).limit(1);
      if (body.groupId) await requireGroupMember(db, body.groupId, uid);
      // Out of a group: those who were in the trip through it leave it. Whoever organises the trip stays, and so does the one asking.
      if (now?.groupId && now.groupId !== body.groupId) {
        await db.delete(tripMembers).where(and(eq(tripMembers.tripId, tripId), ne(tripMembers.role, "organizer"), ne(tripMembers.userId, uid), sql`${tripMembers.userId} in (select ${groupMembers.userId} from ${groupMembers} where ${groupMembers.groupId} = ${now.groupId})`));
      }
      // Into a group: everyone in it joins the trip.
      if (body.groupId) await openTripToGroup(db, tripId, body.groupId);
    }
    if (["flexStart", "flexEnd", "nightsMin", "nightsMax"].some((k) => k in body)) {
      const [now] = await db.select().from(trips).where(eq(trips.id, tripId)).limit(1);
      checkWindow({ flexStart: now!.flexStart, flexEnd: now!.flexEnd, nightsMin: now!.nightsMin, nightsMax: now!.nightsMax, ...body });
    }
    const { voteDeadline, ...rest } = body;
    if (rest.status !== undefined) {
      const [now] = await db.select({ status: trips.status, archivedFrom: trips.archivedFrom }).from(trips).where(eq(trips.id, tripId)).limit(1);
      // Into the archive: remember where the trip stood. Out of it with "planning": back to where it stood.
      if (rest.status === "archived" && now!.status !== "archived") Object.assign(rest, { archivedFrom: now!.status });
      else if (now!.status === "archived" && rest.status !== "archived") Object.assign(rest, { status: rest.status === "planning" ? (now!.archivedFrom ?? "planning") : rest.status, archivedFrom: null });
    }
    const values = { ...rest, ...(voteDeadline !== undefined ? { voteDeadline: voteDeadline ? new Date(voteDeadline) : null } : {}) };
    if (Object.keys(values).length === 0) throw new HttpError(400, "invalid_request", "Keine Änderung angegeben.");
    const [trip] = await db.update(trips).set(values).where(eq(trips.id, tripId)).returning();
    return { trip };
  });

  /**
   * Remove a trip for good, with everything in it: adverts, votes, notes, the purse, bookings, papers, lists.
   * Adverts worth keeping can be moved to another trip or a shelf first, in the same call.
   */
  app.delete("/trips/:tripId", async (req, reply) => {
    const uid = userId(req);
    const tripId = uuidParam((req.params as { tripId: string }).tripId);
    await requireMember(db, tripId, uid, "organizer");
    await notTheWatchlist(tripId, "Die Merkliste lässt sich nicht löschen.");
    const keep = (req.query as { moveCandidatesTo?: string }).moveCandidatesTo;
    if (keep) {
      const target = uuidParam(keep);
      if (target === tripId) throw new HttpError(400, "invalid_request", "Das Ziel ist die Reise selbst.");
      await requireMember(db, target, uid, "member");
      // What is there already stays as it is; the rest moves over as new.
      await db.execute(sql`update ${tripListings} set trip_id = ${target}, status = 'new', rejection_reason = null, criteria_checks = '{}'::jsonb, finalist = false where trip_id = ${tripId} and listing_id not in (select listing_id from ${tripListings} where trip_id = ${target})`);
    }
    const papers = await db.select({ storedName: documents.storedName }).from(documents).where(eq(documents.tripId, tripId));
    await db.delete(trips).where(eq(trips.id, tripId));
    for (const p of papers) await rm(path.join(ctx.config.FILES_DIR, path.basename(p.storedName)), { force: true });
    return reply.code(204).send();
  });

  app.post("/trips/:tripId/date-options", async (req, reply) => {
    const uid = userId(req);
    const tripId = uuidParam((req.params as { tripId: string }).tripId);
    await requireMember(db, tripId, uid, "member");
    await notTheWatchlist(tripId, "Die Merkliste hat keinen Zeitraum.");
    const body = parseBody(dateOption, req.body);
    const [option] = await db.insert(dateOptions).values({ ...body, tripId }).returning();
    return reply.code(201).send({ dateOption: option });
  });

  app.delete("/trips/:tripId/date-options/:optionId", async (req, reply) => {
    const uid = userId(req);
    const params = req.params as { tripId: string; optionId: string };
    const tripId = uuidParam(params.tripId);
    await requireMember(db, tripId, uid, "member");
    const deleted = await db
      .delete(dateOptions)
      .where(and(eq(dateOptions.id, uuidParam(params.optionId)), eq(dateOptions.tripId, tripId)))
      .returning({ id: dateOptions.id });
    if (!deleted.length) throw notFound();
    return reply.code(204).send();
  });

  /** Invite links. The token is shown once, here; only its hash is kept. */
  app.post("/trips/:tripId/invites", async (req, reply) => {
    const uid = userId(req);
    const tripId = uuidParam((req.params as { tripId: string }).tripId);
    await requireMember(db, tripId, uid, "organizer");
    await notTheWatchlist(tripId, "Zur Merkliste kann niemand eingeladen werden.");
    const body = parseBody(
      z.object({ role: z.enum(["member", "guest"]).default("member"), maxUses: z.number().int().min(1).max(50).default(1), expiresInDays: z.number().int().min(1).max(60).default(14) }),
      req.body,
    );
    const token = newToken();
    const expiresAt = new Date(Date.now() + body.expiresInDays * 86_400_000);
    await db.insert(invites).values({ tripId, tokenHash: hashToken(token), role: body.role, createdBy: uid, expiresAt, maxUses: body.maxUses });
    return reply.code(201).send({ token, url: `${ctx.config.PUBLIC_BASE_URL.replace(/\/$/, "")}/einladung/${token}`, role: body.role, expiresAt, maxUses: body.maxUses });
  });

  app.get("/trips/:tripId/activity", async (req) => {
    const uid = userId(req);
    const tripId = uuidParam((req.params as { tripId: string }).tripId);
    await requireMember(db, tripId, uid);
    const events = await db
      .select({ id: activityEvents.id, type: activityEvents.type, payload: activityEvents.payload, createdAt: activityEvents.createdAt, userName: users.name })
      .from(activityEvents)
      .leftJoin(users, eq(users.id, activityEvents.userId))
      .where(eq(activityEvents.tripId, tripId))
      .orderBy(desc(activityEvents.createdAt))
      .limit(100);
    return { events };
  });
}
