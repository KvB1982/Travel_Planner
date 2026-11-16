import { and, asc, eq, or, sql } from "drizzle-orm";
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import type { AppContext } from "../app.js";
import { checklistItems } from "../db/schema.js";
import { HttpError, notFound, parseBody, requireMember, userId, uuidParam } from "../http.js";

const isoDate = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "Datum im Format JJJJ-MM-TT");
const itemFields = {
  list: z.string().trim().min(1).max(40),
  title: z.string().trim().min(1).max(160),
  quantity: z.string().trim().max(40).nullish(),
  assignedTo: z.string().uuid().nullish(),
  assignedParty: z.string().uuid().nullish(),
  dueOn: isoDate.nullish(),
  done: z.boolean(),
  private: z.boolean(),
  position: z.number().int().min(0).max(100_000),
};

/** Starting points. Each adds its lines to a list; whatever is already on it by the same name is left alone. */
export const TEMPLATES: Record<string, { label: string; list: string; items: string[] }> = {
  basics: { label: "Grundausstattung", list: "packing", items: ["Ausweise und Reisepässe", "Krankenversicherungskarten", "Führerschein", "Ladegeräte und Kabel", "Reiseapotheke", "Sonnencreme", "Kulturbeutel", "Bargeld und Karten", "Buchungsunterlagen"] },
  beach: { label: "Strand und Pool", list: "packing", items: ["Badesachen", "Strandtücher", "Sonnenhüte", "Sonnenbrillen", "Badeschuhe", "Schnorchel und Taucherbrille", "Sonnenschirm oder Strandmuschel", "Wasserspielzeug", "Kühltasche", "After-Sun"] },
  ski: { label: "Skiurlaub", list: "packing", items: ["Skijacke und Skihose", "Skiunterwäsche", "Handschuhe", "Mütze und Schal", "Skibrille", "Helm", "Skisocken", "Sonnencreme mit hohem Schutz", "Lippenpflege", "Skipass-Unterlagen", "Schneeketten"] },
  toddler: { label: "Kleinkind", list: "packing", items: ["Windeln und Feuchttücher", "Reisebett oder Babybett klären", "Kinderwagen oder Trage", "Lieblingskuscheltier", "Schnuller und Fläschchen", "Babyfon", "Kindersitz", "Wechselkleidung griffbereit", "Kinder-Sonnenschutz", "Fieberthermometer und Kindermedizin"] },
  dog: { label: "Hund", list: "packing", items: ["EU-Heimtierausweis", "Impfnachweise", "Leine und Geschirr", "Futter und Näpfe", "Hundebett oder Decke", "Kotbeutel", "Zeckenschutz", "Wasser für die Fahrt"] },
  home: { label: "Vor der Abreise", list: "todo", items: ["Gültigkeit der Ausweise prüfen", "Auslandskrankenversicherung prüfen", "Post und Zeitung regeln", "Pflanzen und Haustiere versorgen", "Hausschlüssel hinterlegen", "Müll rausbringen", "Kühlschrank leeren", "Fenster schließen, Geräte ausstecken", "Maut und Vignetten besorgen"] },
  firstDay: { label: "Einkauf für den ersten Tag", list: "shopping", items: ["Wasser", "Kaffee und Tee", "Milch", "Brot", "Butter und Aufstrich", "Obst", "Nudeln und Soße", "Salz, Pfeffer, Öl", "Spülmittel und Schwamm", "Toilettenpapier", "Müllbeutel"] },
};

export function checklistRoutes(app: FastifyInstance, ctx: AppContext): void {
  const { db } = ctx;

  /** Everything shared, plus what the person asking keeps for themselves. */
  async function lists(tripId: string, uid: string) {
    const rows = await db
      .select()
      .from(checklistItems)
      .where(and(eq(checklistItems.tripId, tripId), or(eq(checklistItems.private, false), eq(checklistItems.createdBy, uid))))
      .orderBy(asc(checklistItems.list), asc(checklistItems.position), asc(checklistItems.createdAt));
    const names = [...new Set(["packing", "shopping", "todo", ...rows.map((r) => r.list)])];
    return {
      lists: names.map((name) => {
        const items = rows.filter((r) => r.list === name);
        return { list: name, total: items.length, done: items.filter((i) => i.done).length, items };
      }),
      templates: Object.entries(TEMPLATES).map(([key, t]) => ({ key, label: t.label, list: t.list, count: t.items.length })),
    };
  }

  app.get("/trips/:tripId/checklists", async (req) => {
    const uid = userId(req);
    const tripId = uuidParam((req.params as { tripId: string }).tripId);
    await requireMember(db, tripId, uid);
    return lists(tripId, uid);
  });

  const nextPosition = async (tripId: string, list: string) => {
    const [row] = await db.select({ max: sql<number>`coalesce(max(${checklistItems.position}), -1)::int` }).from(checklistItems).where(and(eq(checklistItems.tripId, tripId), eq(checklistItems.list, list)));
    return (row?.max ?? -1) + 1;
  };

  /** Guests add and tick off, too: packing is everybody's business. */
  app.post("/trips/:tripId/checklist-items", async (req, reply) => {
    const uid = userId(req);
    const tripId = uuidParam((req.params as { tripId: string }).tripId);
    await requireMember(db, tripId, uid);
    const body = parseBody(z.object({ ...itemFields, list: itemFields.list.default("packing"), done: itemFields.done.default(false), private: itemFields.private.default(false), position: itemFields.position.optional() }), req.body);
    const [item] = await db
      .insert(checklistItems)
      .values({ ...body, tripId, position: body.position ?? (await nextPosition(tripId, body.list)), createdBy: uid, ...(body.done ? { doneBy: uid, doneAt: new Date() } : {}) })
      .returning();
    return reply.code(201).send({ item, checklists: await lists(tripId, uid) });
  });

  app.post("/trips/:tripId/checklists/template", async (req) => {
    const uid = userId(req);
    const tripId = uuidParam((req.params as { tripId: string }).tripId);
    await requireMember(db, tripId, uid, "member");
    const body = parseBody(z.object({ template: z.string(), private: z.boolean().default(false) }), req.body);
    const template = TEMPLATES[body.template];
    if (!template) throw new HttpError(400, "invalid_request", "Diese Vorlage gibt es nicht.");
    const there = (await db.select({ title: checklistItems.title }).from(checklistItems).where(and(eq(checklistItems.tripId, tripId), eq(checklistItems.list, template.list)))).map((r) => r.title.toLowerCase());
    const fresh = template.items.filter((t) => !there.includes(t.toLowerCase()));
    const start = await nextPosition(tripId, template.list);
    if (fresh.length) await db.insert(checklistItems).values(fresh.map((title, i) => ({ tripId, list: template.list, title, position: start + i, private: body.private, createdBy: uid })));
    return { added: fresh.length, checklists: await lists(tripId, uid) };
  });

  const ownItem = async (id: string, uid: string) => {
    const [item] = await db.select().from(checklistItems).where(eq(checklistItems.id, id)).limit(1);
    // A private line of somebody else does not exist for anyone but its author.
    if (!item || (item.private && item.createdBy !== uid)) throw notFound("Eintrag nicht gefunden.");
    await requireMember(db, item.tripId, uid).catch(() => {
      throw notFound("Eintrag nicht gefunden.");
    });
    return item;
  };

  app.patch("/checklist-items/:itemId", async (req) => {
    const uid = userId(req);
    const item = await ownItem(uuidParam((req.params as { itemId: string }).itemId), uid);
    const body = parseBody(z.object(itemFields).partial(), req.body);
    if (Object.keys(body).length === 0) throw new HttpError(400, "invalid_request", "Keine Änderung angegeben.");
    const ticked = body.done === undefined || body.done === item.done ? {} : body.done ? { doneBy: uid, doneAt: new Date() } : { doneBy: null, doneAt: null };
    const [updated] = await db.update(checklistItems).set({ ...body, ...ticked }).where(eq(checklistItems.id, item.id)).returning();
    return { item: updated, checklists: await lists(item.tripId, uid) };
  });

  app.delete("/checklist-items/:itemId", async (req) => {
    const uid = userId(req);
    const item = await ownItem(uuidParam((req.params as { itemId: string }).itemId), uid);
    await db.delete(checklistItems).where(eq(checklistItems.id, item.id));
    return { checklists: await lists(item.tripId, uid) };
  });
}
