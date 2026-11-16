import { and, asc, eq, inArray, sql } from "drizzle-orm";
import type { FastifyInstance } from "fastify";
import type { PgColumn, PgTable } from "drizzle-orm/pg-core";
import { z } from "zod";
import type { AppContext } from "../app.js";
import { activities, activityResponses, bookings, houseInfo, listings, rooms, travelLegs, tripListings, tripParties, trips, users } from "../db/schema.js";
import { HttpError, notFound, parseBody, requireMember, userId, uuidParam, type Role } from "../http.js";
import { logActivity } from "./trips.js";

const localTime = z.string().regex(/^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2})?$/, "Datum oder Datum mit Uhrzeit, zum Beispiel 2027-05-15T16:00");
const short = (n: number) => z.string().trim().max(n).nullish();

const legFields = {
  partyId: z.string().uuid().nullish(),
  direction: z.enum(["outbound", "return", "during"]),
  mode: z.enum(["car", "flight", "train", "ferry", "bus", "other"]),
  fromPlace: short(200),
  toPlace: short(200),
  departAt: localTime.nullish(),
  arriveAt: localTime.nullish(),
  stops: z.array(z.object({ place: z.string().trim().min(1).max(200), note: z.string().trim().max(300).nullable().default(null) })).max(20),
  bookingId: z.string().uuid().nullish(),
  notes: z.string().max(3000).nullish(),
  position: z.number().int().min(0).max(100_000),
};
const roomFields = {
  name: z.string().trim().min(1).max(80),
  beds: short(200),
  partyId: z.string().uuid().nullish(),
  occupants: z.array(z.string().trim().min(1).max(80)).max(20),
  notes: z.string().max(1000).nullish(),
  position: z.number().int().min(0).max(100_000),
};
const activityFields = {
  title: z.string().trim().min(1).max(160),
  place: short(300),
  url: z.string().trim().url().max(2000).nullish(),
  status: z.enum(["idea", "planned", "done", "cancelled"]),
  startsAt: localTime.nullish(),
  endsAt: localTime.nullish(),
  costCents: z.number().int().min(0).max(100_000_000).nullish(),
  costNote: short(80),
  bookingId: z.string().uuid().nullish(),
  notes: z.string().max(3000).nullish(),
};

export function planRoutes(app: FastifyInstance, ctx: AppContext): void {
  const { db } = ctx;

  async function plan(tripId: string, uid: string) {
    const legs = await db.select().from(travelLegs).where(eq(travelLegs.tripId, tripId)).orderBy(asc(travelLegs.position), asc(travelLegs.createdAt));
    const sleeping = await db.select().from(rooms).where(eq(rooms.tripId, tripId)).orderBy(asc(rooms.position), asc(rooms.createdAt));
    // Dated ones in the order of the calendar, ideas after them.
    const things = await db.select().from(activities).where(eq(activities.tripId, tripId)).orderBy(sql`${activities.startsAt} asc nulls last`, asc(activities.createdAt));
    const ids = things.map((a) => a.id);
    const answers = ids.length
      ? await db.select({ activityId: activityResponses.activityId, userId: activityResponses.userId, name: users.name, answer: activityResponses.answer }).from(activityResponses).innerJoin(users, eq(users.id, activityResponses.userId)).where(inArray(activityResponses.activityId, ids))
      : [];
    return {
      legs,
      rooms: sleeping,
      activities: things.map((a) => {
        const own = answers.filter((r) => r.activityId === a.id);
        const count = (v: string) => own.filter((r) => r.answer === v).length;
        return { ...a, responses: own.map(({ activityId: _a, ...r }) => r), tally: { yes: count("yes"), maybe: count("maybe"), no: count("no") }, myAnswer: own.find((r) => r.userId === uid)?.answer ?? null };
      }),
    };
  }

  app.get("/trips/:tripId/plan", async (req) => {
    const uid = userId(req);
    const tripId = uuidParam((req.params as { tripId: string }).tripId);
    await requireMember(db, tripId, uid);
    return plan(tripId, uid);
  });

  /** A household or a booking named in an entry has to be one of this trip's. */
  async function ofThisTrip(tripId: string, body: Record<string, unknown>) {
    if (typeof body.partyId === "string") {
      const [p] = await db.select({ id: tripParties.id }).from(tripParties).where(and(eq(tripParties.id, body.partyId), eq(tripParties.tripId, tripId))).limit(1);
      if (!p) throw new HttpError(400, "invalid_request", "Diesen Haushalt gibt es in der Reise nicht.");
    }
    if (typeof body.bookingId === "string") {
      const [b] = await db.select({ id: bookings.id }).from(bookings).where(and(eq(bookings.id, body.bookingId), eq(bookings.tripId, tripId))).limit(1);
      if (!b) throw new HttpError(400, "invalid_request", "Diese Buchung gibt es in der Reise nicht.");
    }
  }

  /** The same three calls for every kind of entry: add to a trip, change, remove. */
  function crud<F extends z.ZodRawShape>(opts: { path: string; single: string; table: PgTable & { id: PgColumn; tripId: PgColumn }; fields: F; defaults: Record<string, unknown>; required: string[]; create: Role; event: string }) {
    const { table } = opts;
    const own = async (id: string, uid: string, minimum: Role) => {
      const [row] = (await db.select().from(table).where(eq(table.id, id)).limit(1)) as { id: string; tripId: string }[];
      if (!row) throw notFound();
      await requireMember(db, row.tripId, uid, minimum).catch((e) => {
        throw e instanceof HttpError && e.statusCode === 404 ? notFound() : e;
      });
      return row;
    };
    app.post(`/trips/:tripId/${opts.path}`, async (req, reply) => {
      const uid = userId(req);
      const tripId = uuidParam((req.params as { tripId: string }).tripId);
      await requireMember(db, tripId, uid, opts.create);
      const body = parseBody(z.object(opts.fields).partial(), req.body) as Record<string, unknown>;
      const missing = opts.required.find((k) => body[k] === undefined || body[k] === null);
      if (missing) throw new HttpError(400, "invalid_request", `Es fehlt: ${missing}`);
      await ofThisTrip(tripId, body);
      const [row] = (await db.insert(table).values({ ...opts.defaults, ...body, tripId, ...("createdBy" in table ? { createdBy: uid } : {}) } as never).returning()) as { id: string }[];
      await logActivity(ctx, tripId, uid, `${opts.event}_added`, { id: row!.id });
      return reply.code(201).send({ [opts.single]: row, plan: await plan(tripId, uid) });
    });
    app.patch(`/${opts.path}/:id`, async (req) => {
      const uid = userId(req);
      const row = await own(uuidParam((req.params as { id: string }).id), uid, "member");
      const body = parseBody(z.object(opts.fields).partial(), req.body) as Record<string, unknown>;
      if (Object.keys(body).length === 0) throw new HttpError(400, "invalid_request", "Keine Änderung angegeben.");
      await ofThisTrip(row.tripId, body);
      const [updated] = await db.update(table).set(body as never).where(eq(table.id, row.id)).returning();
      return { [opts.single]: updated, plan: await plan(row.tripId, uid) };
    });
    app.delete(`/${opts.path}/:id`, async (req) => {
      const uid = userId(req);
      const row = await own(uuidParam((req.params as { id: string }).id), uid, "member");
      await db.delete(table).where(eq(table.id, row.id));
      return { plan: await plan(row.tripId, uid) };
    });
    return own;
  }

  crud({ path: "legs", single: "leg", table: travelLegs, fields: legFields, defaults: {}, required: [], create: "member", event: "leg" });
  crud({ path: "rooms", single: "room", table: rooms, fields: roomFields, defaults: {}, required: ["name"], create: "member", event: "room" });
  // Ideas for things to do come from everyone, guests included.
  const ownActivity = crud({ path: "activities", single: "activity", table: activities, fields: activityFields, defaults: {}, required: ["title"], create: "guest", event: "activity" });

  /** Rooms as the advert the group decided on describes them, as a starting point for who sleeps where. */
  app.post("/trips/:tripId/rooms/suggest", async (req) => {
    const uid = userId(req);
    const tripId = uuidParam((req.params as { tripId: string }).tripId);
    await requireMember(db, tripId, uid, "member");
    const [existing] = await db.select({ id: rooms.id }).from(rooms).where(eq(rooms.tripId, tripId)).limit(1);
    if (existing) throw new HttpError(409, "already_set_up", "Die Zimmer sind schon angelegt.");
    const [trip] = await db.select().from(trips).where(eq(trips.id, tripId)).limit(1);
    if (!trip?.decidedCandidateId) throw new HttpError(409, "no_decision", "Dafür muss die Reise sich für ein Angebot entschieden haben.");
    const [chosen] = await db.select({ profile: listings.profile }).from(tripListings).innerJoin(listings, eq(listings.id, tripListings.listingId)).where(and(eq(tripListings.id, trip.decidedCandidateId), eq(tripListings.tripId, tripId))).limit(1);
    const described = chosen?.profile.bedDetails ?? [];
    const count = chosen?.profile.bedrooms ?? 0;
    const named = described.length ? described.map((d, i) => ({ name: d.room || `Schlafzimmer ${i + 1}`, beds: d.beds })) : Array.from({ length: count }, (_, i) => ({ name: `Schlafzimmer ${i + 1}`, beds: null }));
    if (named.length === 0) throw new HttpError(409, "nothing_known", "Der Steckbrief nennt keine Zimmer. Lege sie von Hand an.");
    await db.insert(rooms).values(named.map((r, position) => ({ tripId, name: r.name.slice(0, 80), beds: r.beds, position })));
    return { plan: await plan(tripId, uid) };
  });

  const houseFields = {
    address: short(400),
    lat: z.number().min(-90).max(90).nullish(),
    lon: z.number().min(-180).max(180).nullish(),
    checkInFrom: short(40),
    checkOutUntil: short(40),
    keyInfo: short(1000),
    wifiName: short(120),
    wifiPassword: short(200),
    contactName: short(120),
    contactPhone: short(60),
    rules: z.string().max(5000).nullish(),
    waste: z.string().max(2000).nullish(),
    emergency: z.string().max(2000).nullish(),
    notes: z.string().max(5000).nullish(),
  };

  /** The folder as the group filled it in, and beside it what the advert and the booking already say. */
  async function house(tripId: string) {
    const [row] = await db.select().from(houseInfo).where(eq(houseInfo.tripId, tripId)).limit(1);
    const [trip] = await db.select().from(trips).where(eq(trips.id, tripId)).limit(1);
    const [chosen] = trip?.decidedCandidateId
      ? await db.select({ profile: listings.profile }).from(tripListings).innerJoin(listings, eq(listings.id, tripListings.listingId)).where(and(eq(tripListings.id, trip.decidedCandidateId), eq(tripListings.tripId, tripId))).limit(1)
      : [];
    const [stay] = await db.select().from(bookings).where(and(eq(bookings.tripId, tripId), eq(bookings.kind, "accommodation"), sql`${bookings.status} <> 'cancelled'`)).orderBy(asc(bookings.startsAt)).limit(1);
    const p = chosen?.profile;
    const time = (v: string | null | undefined) => (v && v.length > 10 ? v.slice(11) : null);
    const { tripId: _t, ...own } = row ?? { tripId, ...Object.fromEntries(Object.keys(houseFields).map((k) => [k, null])), updatedBy: null, updatedAt: null };
    return {
      house: own,
      suggestions: {
        title: p?.title ?? stay?.title ?? null,
        address: stay?.place ?? ([p?.place, p?.region, p?.country].filter(Boolean).join(", ") || null),
        lat: p?.lat ?? null,
        lon: p?.lon ?? null,
        checkInFrom: time(stay?.startsAt) ?? p?.rules.checkInFrom ?? null,
        checkOutUntil: time(stay?.endsAt) ?? p?.rules.checkOutUntil ?? null,
        arrival: stay?.startsAt ?? null,
        departure: stay?.endsAt ?? null,
        bookingId: stay?.id ?? null,
        reference: stay?.reference ?? null,
      },
    };
  }

  app.get("/trips/:tripId/house", async (req) => {
    const tripId = uuidParam((req.params as { tripId: string }).tripId);
    await requireMember(db, tripId, userId(req));
    return house(tripId);
  });

  /** Only the fields that are sent change; null empties one. */
  app.put("/trips/:tripId/house", async (req) => {
    const uid = userId(req);
    const tripId = uuidParam((req.params as { tripId: string }).tripId);
    await requireMember(db, tripId, uid, "member");
    const body = parseBody(z.object(houseFields).partial(), req.body);
    if (Object.keys(body).length === 0) throw new HttpError(400, "invalid_request", "Keine Änderung angegeben.");
    const set = { ...body, updatedBy: uid, updatedAt: new Date() };
    await db.insert(houseInfo).values({ tripId, ...set }).onConflictDoUpdate({ target: houseInfo.tripId, set });
    return house(tripId);
  });

  /** One day of the trip at a glance. The app says which day it is where the group is. */
  app.get("/trips/:tripId/today", async (req) => {
    const uid = userId(req);
    const tripId = uuidParam((req.params as { tripId: string }).tripId);
    await requireMember(db, tripId, uid);
    const { date } = parseBody(z.object({ date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).default(new Date().toISOString().slice(0, 10)) }), req.query);
    const on = (v: string | null) => v !== null && v.slice(0, 10) === date;
    const spans = (from: string | null, to: string | null) => from !== null && from.slice(0, 10) <= date && (to ?? from).slice(0, 10) >= date;
    const all = await plan(tripId, uid);
    const booked = await db.select().from(bookings).where(and(eq(bookings.tripId, tripId), sql`${bookings.status} <> 'cancelled'`)).orderBy(asc(bookings.startsAt));
    const h = await house(tripId);
    return {
      date,
      arrivalDay: on(h.suggestions.arrival),
      departureDay: on(h.suggestions.departure),
      legs: all.legs.filter((l) => on(l.departAt) || on(l.arriveAt)),
      activities: all.activities.filter((a) => a.status !== "cancelled" && spans(a.startsAt, a.endsAt)),
      // Things that begin or end today: the ferry, the hire car, the house itself.
      bookings: booked.filter((b) => on(b.startsAt) || on(b.endsAt)).map((b) => ({ id: b.id, kind: b.kind, title: b.title, startsAt: b.startsAt, endsAt: b.endsAt, place: b.place, reference: b.reference, begins: on(b.startsAt), ends: on(b.endsAt) })),
      ideas: all.activities.filter((a) => a.status === "idea" && !a.startsAt).length,
      ...h,
    };
  });

  /** Say whether one comes along. Everyone answers for themselves. */
  app.put("/activities/:id/response", async (req) => {
    const uid = userId(req);
    const row = await ownActivity(uuidParam((req.params as { id: string }).id), uid, "guest");
    const body = parseBody(z.object({ answer: z.enum(["yes", "maybe", "no"]).nullable() }), req.body);
    if (body.answer === null) await db.delete(activityResponses).where(and(eq(activityResponses.activityId, row.id), eq(activityResponses.userId, uid)));
    else await db.insert(activityResponses).values({ activityId: row.id, userId: uid, answer: body.answer }).onConflictDoUpdate({ target: [activityResponses.activityId, activityResponses.userId], set: { answer: body.answer, updatedAt: new Date() } });
    return { plan: await plan(row.tripId, uid) };
  });
}
