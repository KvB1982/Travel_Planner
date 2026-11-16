import { and, asc, desc, eq, sql } from "drizzle-orm";
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { hashToken, newToken } from "../auth/tokens.js";
import type { AppContext } from "../app.js";
import { activityEvents, dateOptions, invites, tripListings, tripMembers, tripPhases, trips, users, type TripPhase } from "../db/schema.js";
import { HttpError, notFound, parseBody, requireMember, userId, uuidParam } from "../http.js";

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
};

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

  app.post("/trips", async (req, reply) => {
    const uid = userId(req);
    const body = parseBody(
      z.object({ ...tripFields, adults: tripFields.adults.default(2), children: tripFields.children.default(0), pets: tripFields.pets.default(0), dateOptions: z.array(dateOption).max(10).default([]) }),
      req.body,
    );
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
          createdBy: uid,
        })
        .returning();
      await tx.insert(tripMembers).values({ tripId: t!.id, userId: uid, role: "organizer" });
      if (body.dateOptions.length) await tx.insert(dateOptions).values(body.dateOptions.map((d) => ({ ...d, tripId: t!.id })));
      return t!;
    });
    await logActivity(ctx, trip.id, uid, "trip_created");
    return reply.code(201).send({ trip });
  });

  app.get("/trips", async (req) => {
    const uid = userId(req);
    // Everyone has a shelf of their own for adverts that belong to no trip. It appears with the first look.
    const [shelf] = await db.select({ id: trips.id }).from(trips).where(and(eq(trips.createdBy, uid), eq(trips.kind, "watchlist"))).limit(1);
    if (!shelf) {
      await db.transaction(async (tx) => {
        const [t] = await tx.insert(trips).values({ kind: "watchlist", title: "Merkliste", createdBy: uid }).onConflictDoNothing().returning({ id: trips.id });
        if (t) await tx.insert(tripMembers).values({ tripId: t.id, userId: uid, role: "organizer" });
      });
    }
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
    return { trips: rows.map((r) => ({ ...r.trip, currentPhase: currentPhase(r.trip.phase, stayOf(r.trip)), role: r.role, candidateCount: r.candidates, favoriteCount: r.favorites })) };
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
    return { trip: { ...trip!, currentPhase: currentPhase(trip!.phase, { startDate: chosen?.startDate ?? null, endDate: chosen?.endDate ?? null }) }, role, members, dateOptions: options };
  });

  app.patch("/trips/:tripId", async (req) => {
    const uid = userId(req);
    const tripId = uuidParam((req.params as { tripId: string }).tripId);
    await requireMember(db, tripId, uid, "organizer");
    await notTheWatchlist(tripId, "Die Merkliste lässt sich nicht ändern.");
    const body = parseBody(z.object({ ...tripFields, status: z.enum(["planning", "decided", "booked", "archived"]), phase: z.enum(tripPhases) }).partial(), req.body);
    const { voteDeadline, ...rest } = body;
    const values = { ...rest, ...(voteDeadline !== undefined ? { voteDeadline: voteDeadline ? new Date(voteDeadline) : null } : {}) };
    if (Object.keys(values).length === 0) throw new HttpError(400, "invalid_request", "Keine Änderung angegeben.");
    const [trip] = await db.update(trips).set(values).where(eq(trips.id, tripId)).returning();
    return { trip };
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
