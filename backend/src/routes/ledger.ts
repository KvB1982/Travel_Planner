import { and, asc, desc, eq } from "drizzle-orm";
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import type { AppContext } from "../app.js";
import { expenses, settlementPayments, tripMembers, tripParties, trips, users } from "../db/schema.js";
import { HttpError, notFound, parseBody, requireMember, userId, uuidParam } from "../http.js";
import { settle } from "../ledger.js";
import { logActivity } from "./trips.js";

const isoDate = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "Datum im Format JJJJ-MM-TT");
const expenseFields = {
  title: z.string().trim().min(1).max(120),
  amountCents: z.number().int().min(1).max(100_000_000),
  category: z.string().trim().max(40).nullish(),
  spentOn: isoDate.nullish(),
  paidBy: z.string().uuid(),
  /** Left out: the trip's own way of splitting. */
  mode: z.enum(["equal", "heads", "custom"]).nullish(),
  among: z.array(z.string().uuid()).max(30).default([]),
  weights: z.record(z.string().uuid(), z.number().min(0).max(1000)).default({}),
  note: z.string().max(500).nullish(),
};

export function ledgerRoutes(app: FastifyInstance, ctx: AppContext): void {
  const { db } = ctx;

  /** The households of a trip, in the order they were set up. */
  async function partiesOf(tripId: string) {
    const rows = await db.select().from(tripParties).where(eq(tripParties.tripId, tripId)).orderBy(asc(tripParties.position), asc(tripParties.createdAt));
    return rows.map((p) => ({ id: p.id, name: p.name, adults: p.adults, children: p.children, memberIds: p.memberIds }));
  }

  async function ledger(tripId: string, uid: string) {
    const [trip] = await db.select().from(trips).where(eq(trips.id, tripId)).limit(1);
    const parties = await partiesOf(tripId);
    const spent = await db.select().from(expenses).where(eq(expenses.tripId, tripId)).orderBy(desc(expenses.spentOn), desc(expenses.createdAt));
    const paid = await db.select().from(settlementPayments).where(eq(settlementPayments.tripId, tripId)).orderBy(asc(settlementPayments.createdAt));
    const result = settle(
      parties,
      spent.map((e) => ({ id: e.id, amountCents: e.amountCents, paidBy: e.paidBy, mode: e.mode ?? trip!.splitMode, among: e.among, weights: e.weights })),
      paid.map((p) => ({ from: p.fromParty, to: p.toParty, amountCents: p.amountCents })),
      trip!.childWeight,
    );
    return {
      splitMode: trip!.splitMode,
      childWeight: trip!.childWeight,
      // The household the person asking belongs to, so the app can say "you get 120 € back".
      myPartyId: parties.find((p) => p.memberIds.includes(uid))?.id ?? null,
      totalCents: result.totalCents,
      parties: result.parties.map((p) => ({ ...p, memberIds: parties.find((x) => x.id === p.id)!.memberIds })),
      expenses: spent.map((e) => ({ ...e, unsplit: result.unsplit.includes(e.id) })),
      payments: paid,
      // What is still to be paid to make everything even.
      transfers: result.transfers,
    };
  }

  app.get("/trips/:tripId/ledger", async (req) => {
    const uid = userId(req);
    const tripId = uuidParam((req.params as { tripId: string }).tripId);
    await requireMember(db, tripId, uid);
    return ledger(tripId, uid);
  });

  /** Set up the households as a whole. Entries that keep their id keep their expenses. */
  app.put("/trips/:tripId/parties", async (req) => {
    const uid = userId(req);
    const tripId = uuidParam((req.params as { tripId: string }).tripId);
    await requireMember(db, tripId, uid, "member");
    const body = parseBody(
      z.object({
        parties: z
          .array(z.object({ id: z.string().uuid().optional(), name: z.string().trim().min(1).max(80), adults: z.number().int().min(0).max(40).default(2), children: z.number().int().min(0).max(40).default(0), memberIds: z.array(z.string().uuid()).max(40).default([]) }))
          .max(30),
      }),
      req.body,
    );
    const members = await db.select({ id: tripMembers.userId }).from(tripMembers).where(eq(tripMembers.tripId, tripId));
    const named = body.parties.flatMap((p) => p.memberIds);
    if (new Set(named).size !== named.length || named.some((id) => !members.some((m) => m.id === id))) {
      throw new HttpError(400, "invalid_request", "Jede Person gehört zu höchstens einem Haushalt und muss Mitglied der Reise sein.");
    }
    const before = await db.select({ id: tripParties.id }).from(tripParties).where(eq(tripParties.tripId, tripId));
    const kept = new Set(before.map((b) => b.id));
    await db.transaction(async (tx) => {
      await tx.delete(tripParties).where(eq(tripParties.tripId, tripId));
      if (body.parties.length) {
        await tx.insert(tripParties).values(body.parties.map((p, position) => ({ ...(p.id && kept.has(p.id) ? { id: p.id } : {}), tripId, name: p.name, adults: p.adults, children: p.children, memberIds: p.memberIds, position })));
      }
    });
    await logActivity(ctx, tripId, uid, "parties_changed", { count: body.parties.length });
    return { ledger: await ledger(tripId, uid) };
  });

  /** Suggest households from the members: one each, named after the person. A starting point to edit. */
  app.post("/trips/:tripId/parties/suggest", async (req) => {
    const uid = userId(req);
    const tripId = uuidParam((req.params as { tripId: string }).tripId);
    await requireMember(db, tripId, uid, "member");
    if ((await partiesOf(tripId)).length) throw new HttpError(409, "already_set_up", "Die Haushalte sind schon eingerichtet.");
    const members = await db.select({ id: users.id, name: users.name }).from(tripMembers).innerJoin(users, eq(users.id, tripMembers.userId)).where(eq(tripMembers.tripId, tripId)).orderBy(asc(tripMembers.joinedAt));
    await db.insert(tripParties).values(members.map((m, position) => ({ tripId, name: m.name, adults: 1, children: 0, memberIds: [m.id], position })));
    return { ledger: await ledger(tripId, uid) };
  });

  const checkExpense = async (tripId: string, e: { paidBy?: string | undefined; among?: string[] | undefined; weights?: Record<string, number> | undefined }) => {
    const ids = (await partiesOf(tripId)).map((p) => p.id);
    if (ids.length === 0) throw new HttpError(409, "no_parties", "Lege zuerst die Haushalte der Reise an.");
    const named = [...(e.paidBy ? [e.paidBy] : []), ...(e.among ?? []), ...Object.keys(e.weights ?? {})];
    if (named.some((id) => !ids.includes(id))) throw new HttpError(400, "invalid_request", "Ein genannter Haushalt gehört nicht zu dieser Reise.");
  };

  /** Guests may note what they paid, too: on the road everyone pays for something. */
  app.post("/trips/:tripId/expenses", async (req, reply) => {
    const uid = userId(req);
    const tripId = uuidParam((req.params as { tripId: string }).tripId);
    await requireMember(db, tripId, uid);
    const body = parseBody(z.object(expenseFields), req.body);
    await checkExpense(tripId, body);
    if (body.mode === "custom" && !Object.values(body.weights).some((w) => w > 0)) throw new HttpError(400, "invalid_request", "Eine eigene Aufteilung braucht mindestens einen Anteil.");
    const [expense] = await db
      .insert(expenses)
      .values({ tripId, title: body.title, amountCents: body.amountCents, category: body.category ?? null, spentOn: body.spentOn ?? new Date().toISOString().slice(0, 10), paidBy: body.paidBy, mode: body.mode ?? null, among: body.among, weights: body.weights, note: body.note ?? null, createdBy: uid })
      .returning();
    await logActivity(ctx, tripId, uid, "expense_added", { expenseId: expense!.id, amountCents: body.amountCents });
    return reply.code(201).send({ expense, ledger: await ledger(tripId, uid) });
  });

  const ownExpense = async (id: string, uid: string) => {
    const [e] = await db.select().from(expenses).where(eq(expenses.id, id)).limit(1);
    if (!e) throw notFound("Ausgabe nicht gefunden.");
    const role = await requireMember(db, e.tripId, uid).catch(() => {
      throw notFound("Ausgabe nicht gefunden.");
    });
    // Guests change only what they entered themselves.
    if (role === "guest" && e.createdBy !== uid) throw new HttpError(403, "forbidden", "Dafür fehlt die Berechtigung.");
    return e;
  };

  app.patch("/expenses/:expenseId", async (req) => {
    const uid = userId(req);
    const e = await ownExpense(uuidParam((req.params as { expenseId: string }).expenseId), uid);
    const body = parseBody(z.object({ ...expenseFields, among: expenseFields.among.optional(), weights: expenseFields.weights.optional() }).partial(), req.body);
    if (Object.keys(body).length === 0) throw new HttpError(400, "invalid_request", "Keine Änderung angegeben.");
    await checkExpense(e.tripId, body);
    const [expense] = await db.update(expenses).set(body).where(eq(expenses.id, e.id)).returning();
    return { expense, ledger: await ledger(e.tripId, uid) };
  });

  app.delete("/expenses/:expenseId", async (req) => {
    const uid = userId(req);
    const e = await ownExpense(uuidParam((req.params as { expenseId: string }).expenseId), uid);
    await db.delete(expenses).where(eq(expenses.id, e.id));
    await logActivity(ctx, e.tripId, uid, "expense_removed", { amountCents: e.amountCents });
    return { ledger: await ledger(e.tripId, uid) };
  });

  /** Note that money has changed hands, usually one of the suggested transfers. */
  app.post("/trips/:tripId/payments", async (req, reply) => {
    const uid = userId(req);
    const tripId = uuidParam((req.params as { tripId: string }).tripId);
    await requireMember(db, tripId, uid, "member");
    const body = parseBody(z.object({ fromParty: z.string().uuid(), toParty: z.string().uuid(), amountCents: z.number().int().min(1).max(100_000_000) }), req.body);
    const ids = (await partiesOf(tripId)).map((p) => p.id);
    if (body.fromParty === body.toParty || !ids.includes(body.fromParty) || !ids.includes(body.toParty)) throw new HttpError(400, "invalid_request", "Zahlung nur zwischen zwei Haushalten dieser Reise.");
    const [payment] = await db.insert(settlementPayments).values({ tripId, ...body, createdBy: uid }).returning();
    await logActivity(ctx, tripId, uid, "payment_noted", { amountCents: body.amountCents });
    return reply.code(201).send({ payment, ledger: await ledger(tripId, uid) });
  });

  app.delete("/trips/:tripId/payments/:paymentId", async (req) => {
    const uid = userId(req);
    const params = req.params as { tripId: string; paymentId: string };
    const tripId = uuidParam(params.tripId);
    await requireMember(db, tripId, uid, "member");
    const gone = await db.delete(settlementPayments).where(and(eq(settlementPayments.id, uuidParam(params.paymentId)), eq(settlementPayments.tripId, tripId))).returning({ id: settlementPayments.id });
    if (!gone.length) throw notFound();
    return { ledger: await ledger(tripId, uid) };
  });
}
