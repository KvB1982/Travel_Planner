import { and, eq, isNull, sql } from "drizzle-orm";
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { appleKeys, verifyAppleToken } from "../auth/apple.js";
import { hashToken, newToken, safeEqual } from "../auth/tokens.js";
import type { AppContext } from "../app.js";
import { groups, invites, sessions, tripMembers, trips, users } from "../db/schema.js";
import { joinGroup } from "./groups.js";
import { HttpError, parseBody, userId } from "../http.js";

const strictLimit = { config: { rateLimit: { max: 10, timeWindow: "1 minute" } } };

export async function createSession(ctx: AppContext, uid: string, deviceName?: string): Promise<string> {
  const token = newToken();
  await ctx.db.insert(sessions).values({ userId: uid, tokenHash: hashToken(token), deviceName: deviceName ?? null });
  return token;
}

export function authRoutes(app: FastifyInstance, ctx: AppContext): void {
  const { db } = ctx;

  /** Resolve the bearer token on every request; routes decide whether a user is required. */
  app.addHook("onRequest", async (req) => {
    req.user = null;
    const header = req.headers.authorization;
    if (!header?.startsWith("Bearer ")) return;
    const [row] = await db
      .select({ sessionId: sessions.id, id: users.id, name: users.name })
      .from(sessions)
      .innerJoin(users, eq(users.id, sessions.userId))
      .where(and(eq(sessions.tokenHash, hashToken(header.slice(7).trim())), isNull(sessions.revokedAt)))
      .limit(1);
    if (!row) return;
    req.user = row;
    await db.update(sessions).set({ lastUsedAt: new Date() }).where(eq(sessions.id, row.sessionId));
  });

  /** Creates the very first account. Works once, and only with the secret from the server configuration. */
  app.post("/auth/bootstrap", strictLimit, async (req, reply) => {
    const body = parseBody(z.object({ secret: z.string(), name: z.string().trim().min(1).max(80), deviceName: z.string().max(80).optional() }), req.body);
    if (!ctx.config.BOOTSTRAP_SECRET || !safeEqual(body.secret, ctx.config.BOOTSTRAP_SECRET)) {
      throw new HttpError(403, "forbidden", "Einrichtung nicht möglich.");
    }
    const [{ count } = { count: 0 }] = await db.select({ count: sql<number>`count(*)::int` }).from(users);
    if (count > 0) throw new HttpError(409, "already_set_up", "Es gibt bereits ein Konto. Weitere Personen kommen per Einladung dazu.");
    const [user] = await db.insert(users).values({ name: body.name }).returning();
    const token = await createSession(ctx, user!.id, body.deviceName);
    return reply.code(201).send({ token, user: { id: user!.id, name: user!.name } });
  });

  /** What an invite leads to, shown before someone joins. */
  app.get("/auth/invites/:token", strictLimit, async (req) => {
    const { token } = req.params as { token: string };
    const invite = await findInvite(ctx, token);
    const [trip] = invite.tripId ? await db.select({ title: trips.title, region: trips.region }).from(trips).where(eq(trips.id, invite.tripId)).limit(1) : [];
    const [group] = invite.groupId ? await db.select({ name: groups.name }).from(groups).where(eq(groups.id, invite.groupId)).limit(1) : [];
    return { trip: trip ?? null, group: group ?? null, role: invite.role };
  });

  const acceptBody = z.object({ name: z.string().trim().min(1).max(80).optional(), deviceName: z.string().max(80).optional() });

  /** Join a trip or a group with an invite. Signed-in users join as themselves, everyone else gets a new account. */
  async function accept(token: string, user: { id: string; name: string } | null, body: z.infer<typeof acceptBody>) {
    const result = await db.transaction(async (tx) => {
      // Counting the use first, in one statement, keeps two people from sharing a single-use invite.
      const [invite] = await tx
        .update(invites)
        .set({ usedCount: sql`${invites.usedCount} + 1` })
        .where(and(eq(invites.tokenHash, hashToken(token)), sql`${invites.usedCount} < ${invites.maxUses}`, sql`${invites.expiresAt} > now()`))
        .returning();
      if (!invite) throw new HttpError(410, "invite_invalid", "Diese Einladung ist abgelaufen oder wurde schon verwendet.");

      let uid = user?.id;
      let name = user?.name;
      if (!uid) {
        if (!body.name) throw new HttpError(400, "invalid_request", "name: erforderlich");
        const [created] = await tx.insert(users).values({ name: body.name }).returning();
        uid = created!.id;
        name = created!.name;
      }
      if (invite.groupId) await joinGroup(tx, invite.groupId, uid);
      if (invite.tripId) await tx.insert(tripMembers).values({ tripId: invite.tripId, userId: uid, role: invite.role }).onConflictDoNothing();
      return { uid, name: name!, tripId: invite.tripId, groupId: invite.groupId, role: invite.role };
    });
    const sessionToken = user ? null : await createSession(ctx, result.uid, body.deviceName);
    return { token: sessionToken, user: { id: result.uid, name: result.name }, tripId: result.tripId, groupId: result.groupId, role: result.role };
  }

  app.post("/auth/invites/:token/accept", strictLimit, async (req, reply) => {
    const { token } = req.params as { token: string };
    return reply.code(201).send(await accept(token, req.user, parseBody(acceptBody, req.body ?? {})));
  });

  /**
   * The same for someone who is signed in and was sent a link: paste the link, or just its last part.
   * The link travels in the body, so it does not show up in the log.
   */
  app.post("/invites/redeem", strictLimit, async (req, reply) => {
    userId(req);
    const body = parseBody(z.object({ link: z.string().trim().min(10).max(2000) }), req.body);
    const token = body.link.replace(/[?#].*$/, "").replace(/\/+$/, "").split("/").pop() ?? "";
    if (!/^[A-Za-z0-9_-]{20,}$/.test(token)) throw new HttpError(400, "invite_unreadable", "Das ist kein Einladungslink. Füge den ganzen Link ein, so wie du ihn bekommen hast.");
    return reply.code(201).send(await accept(token, req.user, {}));
  });

  const keys = ctx.appleKeys ?? appleKeys();
  const appleBody = z.object({ identityToken: z.string().min(20).max(8000), nonce: z.string().min(8).max(200).optional(), deviceName: z.string().max(80).optional() });
  const identityOf = async (body: z.infer<typeof appleBody>) => {
    const audiences = ctx.config.APPLE_CLIENT_IDS.split(",").map((s) => s.trim()).filter(Boolean);
    let identity;
    try {
      identity = await verifyAppleToken(body.identityToken, audiences, keys, { nonce: body.nonce });
    } catch (err) {
      app.log.error({ err }, "apple keys unavailable");
      throw new HttpError(503, "apple_unavailable", "Apple ist gerade nicht erreichbar. Bitte gleich noch einmal versuchen.");
    }
    if (!identity) throw new HttpError(401, "apple_token_invalid", "Die Anmeldung mit Apple konnte nicht bestätigt werden.");
    return identity;
  };

  /**
   * Sign in with Apple. Opens a session for the account this Apple ID is linked to.
   * New accounts still come from an invite only: an Apple ID nobody linked is turned away.
   */
  app.post("/auth/apple", strictLimit, async (req, reply) => {
    const body = parseBody(appleBody, req.body);
    const identity = await identityOf(body);
    const [user] = await db.select({ id: users.id, name: users.name }).from(users).where(eq(users.appleSub, identity.sub)).limit(1);
    if (!user) throw new HttpError(404, "apple_not_linked", "Diese Apple-ID ist mit keinem Konto verknüpft. Tritt zuerst mit einer Einladung bei und verknüpfe sie dann in den Einstellungen.");
    const token = await createSession(ctx, user.id, body.deviceName);
    return reply.code(201).send({ token, user });
  });

  /** Link the Apple ID to the account one is signed in with, so that it opens this account on any device. */
  app.put("/me/apple", strictLimit, async (req) => {
    const uid = userId(req);
    const identity = await identityOf(parseBody(appleBody, req.body));
    const [taken] = await db.select({ id: users.id }).from(users).where(eq(users.appleSub, identity.sub)).limit(1);
    if (taken && taken.id !== uid) throw new HttpError(409, "apple_in_use", "Diese Apple-ID gehört schon zu einem anderen Konto.");
    await db.update(users).set({ appleSub: identity.sub, ...(identity.email ? { email: sql`coalesce(${users.email}, ${identity.email})` } : {}) }).where(eq(users.id, uid));
    return { user: await me(uid) };
  });

  /** Take the link away again. Sessions that are open stay open. */
  app.delete("/me/apple", async (req) => {
    const uid = userId(req);
    await db.update(users).set({ appleSub: null }).where(eq(users.id, uid));
    return { user: await me(uid) };
  });

  async function me(uid: string) {
    const [user] = await db.select({ id: users.id, name: users.name, email: users.email, appleSub: users.appleSub }).from(users).where(eq(users.id, uid)).limit(1);
    const { appleSub, ...rest } = user!;
    return { ...rest, apple: appleSub !== null };
  }

  app.get("/me", async (req) => ({ user: await me(userId(req)) }));

  /** The name the others see. */
  app.patch("/me", async (req) => {
    const uid = userId(req);
    const body = parseBody(z.object({ name: z.string().trim().min(1).max(80) }), req.body);
    await db.update(users).set({ name: body.name }).where(eq(users.id, uid));
    return { user: await me(uid) };
  });

  app.post("/auth/logout", async (req, reply) => {
    userId(req);
    await db.update(sessions).set({ revokedAt: new Date() }).where(eq(sessions.id, req.user!.sessionId));
    return reply.code(204).send();
  });
}

async function findInvite(ctx: AppContext, token: string) {
  const [invite] = await ctx.db
    .select()
    .from(invites)
    .where(and(eq(invites.tokenHash, hashToken(token)), sql`${invites.usedCount} < ${invites.maxUses}`, sql`${invites.expiresAt} > now()`))
    .limit(1);
  if (!invite) throw new HttpError(410, "invite_invalid", "Diese Einladung ist abgelaufen oder wurde schon verwendet.");
  return invite;
}
