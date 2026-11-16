import { randomUUID } from "node:crypto";
import { mkdir, readFile, unlink, writeFile } from "node:fs/promises";
import path from "node:path";
import { and, asc, desc, eq, inArray } from "drizzle-orm";
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import type { AppContext } from "../app.js";
import { bookingKinds, bookingPayments, bookings, documents, listings, tripListings, trips } from "../db/schema.js";
import { HttpError, notFound, parseBody, requireMember, userId, uuidParam } from "../http.js";
import { logActivity } from "./trips.js";

const isoDate = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "Datum im Format JJJJ-MM-TT");
const localTime = z.string().regex(/^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2})?$/, "Datum oder Datum mit Uhrzeit, zum Beispiel 2027-05-15T16:00");
const cents = z.number().int().min(0).max(100_000_000);

const bookingFields = {
  kind: z.enum(bookingKinds),
  title: z.string().trim().min(1).max(160),
  provider: z.string().trim().max(120).nullish(),
  reference: z.string().trim().max(120).nullish(),
  candidateId: z.string().uuid().nullish(),
  status: z.enum(["planned", "booked", "cancelled"]),
  startsAt: localTime.nullish(),
  endsAt: localTime.nullish(),
  place: z.string().trim().max(300).nullish(),
  totalCents: cents.nullish(),
  depositCents: cents.nullish(),
  depositReturnedOn: isoDate.nullish(),
  freeCancellationUntil: isoDate.nullish(),
  bookedByParty: z.string().uuid().nullish(),
  notes: z.string().max(5000).nullish(),
};
const paymentFields = {
  label: z.string().trim().min(1).max(80),
  amountCents: cents,
  dueOn: isoDate.nullish(),
  paidOn: isoDate.nullish(),
  paidByParty: z.string().uuid().nullish(),
  refundable: z.boolean(),
};

const MAX_FILE_BYTES = 20 * 1024 * 1024;
const FILE_TYPES = ["application/pdf", "image/jpeg", "image/png", "image/heic", "image/heif", "image/webp", "text/plain"];

export function bookingRoutes(app: FastifyInstance, ctx: AppContext): void {
  const { db } = ctx;
  const today = () => new Date().toISOString().slice(0, 10);

  async function overview(tripId: string) {
    const rows = await db.select().from(bookings).where(eq(bookings.tripId, tripId)).orderBy(asc(bookings.startsAt), asc(bookings.createdAt));
    const ids = rows.map((b) => b.id);
    const payments = ids.length ? await db.select().from(bookingPayments).where(inArray(bookingPayments.bookingId, ids)).orderBy(asc(bookingPayments.dueOn), asc(bookingPayments.createdAt)) : [];
    const docs = await db.select().from(documents).where(eq(documents.tripId, tripId)).orderBy(desc(documents.createdAt));
    const doc = (d: (typeof docs)[number]) => ({ id: d.id, bookingId: d.bookingId, title: d.title, kind: d.kind, contentType: d.contentType, sizeBytes: d.sizeBytes, createdAt: d.createdAt, uploadedBy: d.uploadedBy });
    const live = rows.filter((b) => b.status !== "cancelled");
    // Everything with a date somebody must not miss, soonest first.
    const deadlines = [
      ...payments
        .filter((p) => !p.paidOn && p.dueOn && live.some((b) => b.id === p.bookingId))
        .map((p) => ({ type: "payment" as const, on: p.dueOn!, bookingId: p.bookingId, paymentId: p.id, label: `${p.label}: ${rows.find((b) => b.id === p.bookingId)!.title}`, amountCents: p.amountCents })),
      ...live.filter((b) => b.freeCancellationUntil).map((b) => ({ type: "cancellation" as const, on: b.freeCancellationUntil!, bookingId: b.id, paymentId: null, label: `Kostenlos stornierbar bis: ${b.title}`, amountCents: null })),
      ...live.filter((b) => b.startsAt).map((b) => ({ type: "start" as const, on: b.startsAt!.slice(0, 10), bookingId: b.id, paymentId: null, label: b.title, amountCents: null })),
    ]
      .map((d) => ({ ...d, overdue: d.type !== "start" && d.on < today() }))
      .sort((a, b) => a.on.localeCompare(b.on));
    const sum = (list: typeof payments) => list.reduce((a, p) => a + p.amountCents, 0);
    const costs = payments.filter((p) => !p.refundable && live.some((b) => b.id === p.bookingId));
    return {
      bookings: rows.map((b) => ({ ...b, payments: payments.filter((p) => p.bookingId === b.id), documents: docs.filter((d) => d.bookingId === b.id).map(doc) })),
      // Papers that belong to the trip as a whole, not to one booking: passports, insurance cards.
      documents: docs.filter((d) => d.bookingId === null).map(doc),
      deadlines,
      totals: {
        bookedCents: live.reduce((a, b) => a + (b.totalCents ?? 0), 0),
        plannedCents: sum(costs),
        paidCents: sum(costs.filter((p) => p.paidOn)),
        openCents: sum(costs.filter((p) => !p.paidOn)),
        depositsOutCents: sum(payments.filter((p) => p.refundable && p.paidOn && live.some((b) => b.id === p.bookingId && !b.depositReturnedOn))),
      },
    };
  }

  app.get("/trips/:tripId/bookings", async (req) => {
    const uid = userId(req);
    const tripId = uuidParam((req.params as { tripId: string }).tripId);
    await requireMember(db, tripId, uid);
    return overview(tripId);
  });

  /** A confirmed booking of the house moves the trip on from booking to preparation. */
  const moveOn = async (tripId: string, b: { kind: string; status: string }) => {
    if (b.kind !== "accommodation" || b.status !== "booked") return;
    const [trip] = await db.select().from(trips).where(eq(trips.id, tripId)).limit(1);
    if (trip && (trip.phase === "booking" || trip.phase === "decision" || trip.phase === "research")) await db.update(trips).set({ phase: "preparation", status: "booked" }).where(eq(trips.id, tripId));
  };

  app.post("/trips/:tripId/bookings", async (req, reply) => {
    const uid = userId(req);
    const tripId = uuidParam((req.params as { tripId: string }).tripId);
    await requireMember(db, tripId, uid, "member");
    const body = parseBody(z.object({ ...bookingFields, kind: bookingFields.kind.default("accommodation"), status: bookingFields.status.default("planned"), title: bookingFields.title.optional() }), req.body);
    let title = body.title;
    let place = body.place ?? null;
    if (body.candidateId) {
      // Taken from the advert the group decided on, so nothing has to be typed twice.
      const [c] = await db.select({ title: listings.title, place: listings.place, country: listings.country }).from(tripListings).innerJoin(listings, eq(listings.id, tripListings.listingId)).where(and(eq(tripListings.id, body.candidateId), eq(tripListings.tripId, tripId))).limit(1);
      if (!c) throw new HttpError(404, "not_found", "Dieses Angebot gehört nicht zu dieser Reise.");
      title ??= c.title ?? undefined;
      place ??= [c.place, c.country].filter(Boolean).join(", ") || null;
    }
    if (!title) throw new HttpError(400, "invalid_request", "Die Buchung braucht eine Bezeichnung.");
    const [booking] = await db.insert(bookings).values({ ...body, tripId, title, place, createdBy: uid }).returning();
    await moveOn(tripId, booking!);
    await logActivity(ctx, tripId, uid, "booking_added", { bookingId: booking!.id, kind: booking!.kind });
    return reply.code(201).send({ booking, overview: await overview(tripId) });
  });

  const ownBooking = async (id: string, uid: string) => {
    const [b] = await db.select().from(bookings).where(eq(bookings.id, id)).limit(1);
    if (!b) throw notFound("Buchung nicht gefunden.");
    await requireMember(db, b.tripId, uid, "member").catch((e) => {
      throw e instanceof HttpError && e.statusCode === 404 ? notFound("Buchung nicht gefunden.") : e;
    });
    return b;
  };

  app.patch("/bookings/:bookingId", async (req) => {
    const uid = userId(req);
    const b = await ownBooking(uuidParam((req.params as { bookingId: string }).bookingId), uid);
    const body = parseBody(z.object(bookingFields).partial(), req.body);
    if (Object.keys(body).length === 0) throw new HttpError(400, "invalid_request", "Keine Änderung angegeben.");
    const [booking] = await db.update(bookings).set(body).where(eq(bookings.id, b.id)).returning();
    await moveOn(b.tripId, booking!);
    return { booking, overview: await overview(b.tripId) };
  });

  app.delete("/bookings/:bookingId", async (req) => {
    const uid = userId(req);
    const b = await ownBooking(uuidParam((req.params as { bookingId: string }).bookingId), uid);
    await db.delete(bookings).where(eq(bookings.id, b.id));
    await logActivity(ctx, b.tripId, uid, "booking_removed", { kind: b.kind });
    return { overview: await overview(b.tripId) };
  });

  app.post("/bookings/:bookingId/payments", async (req, reply) => {
    const uid = userId(req);
    const b = await ownBooking(uuidParam((req.params as { bookingId: string }).bookingId), uid);
    const body = parseBody(z.object({ ...paymentFields, refundable: paymentFields.refundable.default(false) }), req.body);
    const [payment] = await db.insert(bookingPayments).values({ ...body, bookingId: b.id }).returning();
    return reply.code(201).send({ payment, overview: await overview(b.tripId) });
  });

  const ownPayment = async (id: string, uid: string) => {
    const [p] = await db.select().from(bookingPayments).where(eq(bookingPayments.id, id)).limit(1);
    if (!p) throw notFound("Zahlung nicht gefunden.");
    return { payment: p, booking: await ownBooking(p.bookingId, uid) };
  };

  app.patch("/booking-payments/:paymentId", async (req) => {
    const uid = userId(req);
    const { payment: p, booking } = await ownPayment(uuidParam((req.params as { paymentId: string }).paymentId), uid);
    const body = parseBody(z.object(paymentFields).partial(), req.body);
    if (Object.keys(body).length === 0) throw new HttpError(400, "invalid_request", "Keine Änderung angegeben.");
    const [payment] = await db.update(bookingPayments).set(body).where(eq(bookingPayments.id, p.id)).returning();
    return { payment, overview: await overview(booking.tripId) };
  });

  app.delete("/booking-payments/:paymentId", async (req) => {
    const uid = userId(req);
    const { payment: p, booking } = await ownPayment(uuidParam((req.params as { paymentId: string }).paymentId), uid);
    await db.delete(bookingPayments).where(eq(bookingPayments.id, p.id));
    return { overview: await overview(booking.tripId) };
  });

  // Documents. The file travels as the request body itself, with its own content type; title and booking in the query.
  void app.register(async (scope) => {
    scope.addContentTypeParser(FILE_TYPES, { parseAs: "buffer", bodyLimit: MAX_FILE_BYTES }, (_req, body, done) => done(null, body));

    scope.post("/trips/:tripId/documents", { bodyLimit: MAX_FILE_BYTES }, async (req, reply) => {
      const uid = userId(req);
      const tripId = uuidParam((req.params as { tripId: string }).tripId);
      await requireMember(db, tripId, uid, "member");
      const query = parseBody(z.object({ title: z.string().trim().min(1).max(160), kind: z.string().trim().max(40).optional(), bookingId: z.string().uuid().optional() }), req.query);
      const type = String(req.headers["content-type"] ?? "").split(";")[0]!.trim().toLowerCase();
      if (!FILE_TYPES.includes(type) || !Buffer.isBuffer(req.body) || req.body.length === 0) throw new HttpError(415, "unsupported_file", "Möglich sind PDF, Fotos (JPEG, PNG, HEIC, WebP) und reiner Text.");
      if (query.bookingId) {
        const [b] = await db.select({ id: bookings.id }).from(bookings).where(and(eq(bookings.id, query.bookingId), eq(bookings.tripId, tripId))).limit(1);
        if (!b) throw new HttpError(404, "not_found", "Diese Buchung gehört nicht zu dieser Reise.");
      }
      // The name on disk is random; nothing a person typed ends up in a path.
      const storedName = randomUUID();
      await mkdir(ctx.config.FILES_DIR, { recursive: true });
      await writeFile(path.join(ctx.config.FILES_DIR, storedName), req.body, { mode: 0o600 });
      const [document] = await db.insert(documents).values({ tripId, bookingId: query.bookingId ?? null, title: query.title, kind: query.kind ?? null, contentType: type, sizeBytes: req.body.length, storedName, uploadedBy: uid }).returning();
      await logActivity(ctx, tripId, uid, "document_added", { documentId: document!.id });
      const { storedName: _s, ...shown } = document!;
      return reply.code(201).send({ document: shown });
    });
  });

  const ownDocument = async (id: string, uid: string, minimum: "guest" | "member") => {
    const [d] = await db.select().from(documents).where(eq(documents.id, id)).limit(1);
    if (!d) throw notFound("Dokument nicht gefunden.");
    await requireMember(db, d.tripId, uid, minimum).catch((e) => {
      throw e instanceof HttpError && e.statusCode === 404 ? notFound("Dokument nicht gefunden.") : e;
    });
    return d;
  };

  app.get("/documents/:documentId/file", async (req, reply) => {
    const uid = userId(req);
    const d = await ownDocument(uuidParam((req.params as { documentId: string }).documentId), uid, "guest");
    const data = await readFile(path.join(ctx.config.FILES_DIR, d.storedName)).catch(() => null);
    if (!data) throw notFound("Die Datei ist nicht mehr vorhanden.");
    return reply.header("content-type", d.contentType).header("cache-control", "private, no-store").header("content-disposition", `inline; filename*=UTF-8''${encodeURIComponent(d.title)}`).send(data);
  });

  app.patch("/documents/:documentId", async (req) => {
    const uid = userId(req);
    const d = await ownDocument(uuidParam((req.params as { documentId: string }).documentId), uid, "member");
    const body = parseBody(z.object({ title: z.string().trim().min(1).max(160), kind: z.string().trim().max(40).nullable(), bookingId: z.string().uuid().nullable() }).partial(), req.body);
    if (body.bookingId) {
      const [b] = await db.select({ id: bookings.id }).from(bookings).where(and(eq(bookings.id, body.bookingId), eq(bookings.tripId, d.tripId))).limit(1);
      if (!b) throw new HttpError(404, "not_found", "Diese Buchung gehört nicht zu dieser Reise.");
    }
    await db.update(documents).set(body).where(eq(documents.id, d.id));
    return { overview: await overview(d.tripId) };
  });

  app.delete("/documents/:documentId", async (req) => {
    const uid = userId(req);
    const d = await ownDocument(uuidParam((req.params as { documentId: string }).documentId), uid, "member");
    await db.delete(documents).where(eq(documents.id, d.id));
    await unlink(path.join(ctx.config.FILES_DIR, d.storedName)).catch(() => undefined);
    return { overview: await overview(d.tripId) };
  });
}
