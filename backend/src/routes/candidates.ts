import { and, asc, desc, eq, inArray } from "drizzle-orm";
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import type { AppContext } from "../app.js";
import { comments, dateOptions, listings, listingSources, priceSnapshots, tripListings, users, votes } from "../db/schema.js";
import { fillPercent, mergeProfiles, profileSchema } from "../import/profile.js";
import { processImport, startImport } from "../import/pipeline.js";
import { analyzeLink } from "../import/url.js";
import { compare } from "../compare.js";
import { HttpError, parseBody, requireCandidate, requireMember, userId, uuidParam } from "../http.js";
import { logActivity } from "./trips.js";

const MAX_PAGE_BYTES = 6 * 1024 * 1024;

function tally(rows: { verdict: "yes" | "maybe" | "no"; veto: boolean }[]) {
  return {
    yes: rows.filter((v) => v.verdict === "yes").length,
    maybe: rows.filter((v) => v.verdict === "maybe").length,
    no: rows.filter((v) => v.verdict === "no").length,
    vetoes: rows.filter((v) => v.veto).length,
  };
}

/** Deep partial of the profile for manual edits: every field optional, null allowed to clear a value. */
const profilePatch = z.record(z.string(), z.unknown());

function reviewsFor(listing: typeof listings.$inferSelect | undefined, platform: string | null) {
  const p = listing?.profile;
  const items = [...(p?.reviews ?? [])];
  const iso = /^\d{4}-\d{2}-\d{2}$/;
  if (items.length && items.every((r) => r.date && iso.test(r.date))) items.sort((a, b) => b.date!.localeCompare(a.date!));
  const s = p?.reviewSummary;
  if (!items.length && !s?.summary) return null;
  return {
    summary: s?.summary ?? null,
    positives: s?.positives ?? [],
    negatives: s?.negatives ?? [],
    basedOn: s?.basedOn ?? (items.length || null),
    generatedAt: listing?.updatedAt ?? null,
    items: items.map((r) => ({ ...r, platform })),
  };
}

/** The advert's hints with the trip's choice to hide them; hidden ones stay retrievable. */
function warningsFor(listing: typeof listings.$inferSelect | undefined, hidden: string[]) {
  return (listing?.profile.warnings ?? []).map((text) => ({ text, hidden: hidden.includes(text) }));
}

export function candidateRoutes(app: FastifyInstance, ctx: AppContext): void {
  const { db } = ctx;
  const importDeps = { db, fetcher: ctx.fetcher, extractor: ctx.extractor };

  /** Share a link into a trip. Answers at once; details are read in the background. */
  app.post("/trips/:tripId/imports", { bodyLimit: MAX_PAGE_BYTES }, async (req, reply) => {
    const uid = userId(req);
    const tripId = uuidParam((req.params as { tripId: string }).tripId);
    await requireMember(db, tripId, uid, "member");
    const body = parseBody(z.object({ url: z.string().trim().url().max(4000), html: z.string().max(MAX_PAGE_BYTES).optional() }), req.body);

    let started;
    try {
      started = await startImport(importDeps, { tripId, userId: uid, url: body.url });
    } catch (err) {
      throw new HttpError(422, "link_unreadable", err instanceof Error && err.name === "UnsafeUrlError" ? "Dieser Link kann nicht abgerufen werden." : "Der Link konnte nicht gelesen werden.");
    }

    if (!started.duplicate || body.html !== undefined) {
      ctx.queue.push(() => processImport(importDeps, { ...started, tripId, userId: uid, html: body.html }));
    }
    if (!started.duplicate) await logActivity(ctx, tripId, uid, "candidate_added", { candidateId: started.candidateId, platform: started.link.platform });

    return reply.code(started.duplicate ? 200 : 202).send({
      candidateId: started.candidateId,
      duplicate: started.duplicate,
      platform: started.link.platform,
      kind: started.link.kind,
      stay: started.link.stay,
      warnings: started.link.warnings,
    });
  });

  /** Page content captured on the device, for platforms that refuse the server. */
  app.post("/candidates/:candidateId/capture", { bodyLimit: MAX_PAGE_BYTES }, async (req, reply) => {
    const uid = userId(req);
    const { candidate } = await requireCandidate(db, uuidParam((req.params as { candidateId: string }).candidateId), uid, "member");
    const body = parseBody(z.object({ html: z.string().min(500).max(MAX_PAGE_BYTES) }), req.body);
    const [source] = await db.select().from(listingSources).where(eq(listingSources.listingId, candidate.listingId)).orderBy(asc(listingSources.createdAt)).limit(1);
    if (!source) throw new HttpError(409, "no_source", "Zu diesem Angebot gibt es keinen Link.");
    // The shared link keeps the dates and party; an app short link carries nothing, so its resolved form is used.
    const shared = analyzeLink(source.url);
    const link = shared.isShortLink ? analyzeLink(source.canonicalUrl) : shared;
    await db.update(tripListings).set({ importStatus: "pending", importNote: null }).where(eq(tripListings.id, candidate.id));
    ctx.queue.push(() =>
      processImport(importDeps, { candidateId: candidate.id, listingId: candidate.listingId, sourceId: source.id, link, tripId: candidate.tripId, userId: uid, html: body.html }),
    );
    return reply.code(202).send({ candidateId: candidate.id });
  });

  /** Read the advert again from the server, for example after the import got better or to look for a new price. */
  app.post("/candidates/:candidateId/refresh", async (req, reply) => {
    const uid = userId(req);
    const { candidate } = await requireCandidate(db, uuidParam((req.params as { candidateId: string }).candidateId), uid, "member");
    const [source] = await db.select().from(listingSources).where(eq(listingSources.listingId, candidate.listingId)).orderBy(asc(listingSources.createdAt)).limit(1);
    if (!source) throw new HttpError(409, "no_source", "Zu diesem Angebot gibt es keinen Link.");
    // Platforms are asked sparingly: not again within a minute.
    if (source.lastFetchedAt && Date.now() - source.lastFetchedAt.getTime() < 60_000) throw new HttpError(429, "too_soon", "Das Angebot wurde gerade erst abgerufen. Bitte gleich noch einmal versuchen.");
    const shared = analyzeLink(source.url);
    const link = shared.isShortLink ? analyzeLink(source.canonicalUrl) : shared;
    await db.update(tripListings).set({ importStatus: "pending", importNote: null }).where(eq(tripListings.id, candidate.id));
    ctx.queue.push(() => processImport(importDeps, { candidateId: candidate.id, listingId: candidate.listingId, sourceId: source.id, link, tripId: candidate.tripId, userId: uid }));
    return reply.code(202).send({ candidateId: candidate.id });
  });

  /** The candidates of a trip as the list shows them, each with its advert for callers that need more. */
  async function loadCandidates(tripId: string, uid: string) {
    const rows = await db
      .select({ candidate: tripListings, listing: listings, addedByName: users.name })
      .from(tripListings)
      .innerJoin(listings, eq(listings.id, tripListings.listingId))
      .innerJoin(users, eq(users.id, tripListings.addedBy))
      .where(eq(tripListings.tripId, tripId))
      .orderBy(desc(tripListings.createdAt));
    if (rows.length === 0) return [];

    const candidateIds = rows.map((r) => r.candidate.id);
    const listingIds = rows.map((r) => r.listing.id);
    const allVotes = await db.select().from(votes).where(inArray(votes.tripListingId, candidateIds));
    const sources = await db.select().from(listingSources).where(inArray(listingSources.listingId, listingIds));
    const prices = sources.length
      ? await db.select().from(priceSnapshots).where(inArray(priceSnapshots.listingSourceId, sources.map((s) => s.id))).orderBy(desc(priceSnapshots.capturedAt))
      : [];

    // A price counts for this trip when it was recorded for it and its dates are one of the trip's periods.
    // Prices typed in by hand always count: whoever enters one knows what it is for.
    const options = await db.select().from(dateOptions).where(eq(dateOptions.tripId, tripId));
    const forThisTrip = (p: (typeof prices)[number]) =>
      p.tripId === tripId && (p.capture === "manual" || !p.startDate || options.length === 0 || options.some((o) => o.startDate === p.startDate && o.endDate === p.endDate));

    return rows.map(({ candidate, listing, addedByName }) => {
      const mine = allVotes.filter((v) => v.tripListingId === candidate.id);
      const own = sources.filter((s) => s.listingId === listing.id);
      const ownPrices = prices.filter((p) => own.some((s) => s.id === p.listingSourceId));
      // A price captured for this trip's dates beats one that came with the shared link.
      const price = ownPrices.find(forThisTrip) ?? ownPrices[0] ?? null;
      const p = listing.profile;
      const entry = {
        id: candidate.id,
        status: candidate.status,
        importStatus: candidate.importStatus,
        importNote: candidate.importNote,
        tags: candidate.tags,
        addedBy: addedByName,
        createdAt: candidate.createdAt,
        listing: {
          id: listing.id,
          kind: listing.kind,
          title: listing.title,
          place: listing.place,
          country: listing.country,
          lat: listing.lat,
          lon: listing.lon,
          coverImageUrl: listing.coverImageUrl,
          // What can actually be shown; the page may advertise more than it gave away (profile.photoCount).
          photoCount: p.photos?.length || p.photoCount,
          fillPercent: listing.fillPercent,
          maxGuests: p.maxGuests,
          bedrooms: p.bedrooms,
          bathrooms: p.bathrooms,
          rating: p.rating,
          platforms: own.map((s) => s.platform),
          // Hints still shown for this trip; hidden ones are not counted.
          warningCount: p.warnings.filter((w) => !candidate.hiddenWarnings.includes(w)).length,
        },
        price: price && { totalCents: price.totalCents, rangeMaxCents: price.rangeMaxCents, kind: price.kind, nights: price.nights, persons: price.persons, startDate: price.startDate, endDate: price.endDate, forThisTrip: forThisTrip(price), capturedAt: price.capturedAt },
        votes: tally(mine),
        myVote: mine.find((v) => v.userId === uid) ?? null,
      };
      return { entry, profile: p, hiddenWarnings: candidate.hiddenWarnings };
    });
  }

  app.get("/trips/:tripId/candidates", async (req) => {
    const uid = userId(req);
    const tripId = uuidParam((req.params as { tripId: string }).tripId);
    await requireMember(db, tripId, uid);
    return { candidates: (await loadCandidates(tripId, uid)).map((c) => c.entry) };
  });

  /**
   * Side by side: chosen candidates of a trip (or all that are not rejected) with one row per
   * criterion, and which of them is ahead in each. Nothing is weighed up or decided here.
   */
  app.get("/trips/:tripId/compare", async (req) => {
    const uid = userId(req);
    const tripId = uuidParam((req.params as { tripId: string }).tripId);
    await requireMember(db, tripId, uid);
    const raw = (req.query as { ids?: string }).ids;
    const ids = raw ? raw.split(",").map((v) => uuidParam(v.trim())) : null;
    const all = await loadCandidates(tripId, uid);
    const chosen = ids ? ids.map((id) => all.find((c) => c.entry.id === id)).filter((c) => c !== undefined) : all.filter((c) => c.entry.status !== "rejected");
    if (ids && chosen.length !== ids.length) throw new HttpError(404, "not_found", "Mindestens ein Angebot gehört nicht zu dieser Reise.");
    if (chosen.length > 12) throw new HttpError(400, "invalid_request", "Höchstens zwölf Angebote lassen sich nebeneinander vergleichen.");
    return compare(chosen);
  });

  app.get("/candidates/:candidateId", async (req) => {
    const uid = userId(req);
    const { candidate, role } = await requireCandidate(db, uuidParam((req.params as { candidateId: string }).candidateId), uid);
    const [listing] = await db.select().from(listings).where(eq(listings.id, candidate.listingId)).limit(1);
    const sources = await db.select().from(listingSources).where(eq(listingSources.listingId, candidate.listingId));
    const prices = sources.length
      ? await db.select().from(priceSnapshots).where(inArray(priceSnapshots.listingSourceId, sources.map((s) => s.id))).orderBy(desc(priceSnapshots.capturedAt)).limit(200)
      : [];
    const voteRows = await db
      .select({ userId: votes.userId, name: users.name, verdict: votes.verdict, veto: votes.veto, updatedAt: votes.updatedAt })
      .from(votes)
      .innerJoin(users, eq(users.id, votes.userId))
      .where(eq(votes.tripListingId, candidate.id));
    const commentRows = await db
      .select({ id: comments.id, body: comments.body, createdAt: comments.createdAt, userId: comments.userId, name: users.name })
      .from(comments)
      .innerJoin(users, eq(users.id, comments.userId))
      .where(eq(comments.tripListingId, candidate.id))
      .orderBy(asc(comments.createdAt));
    return {
      candidate,
      role,
      listing,
      // In page order, first is the cover. Empty for adverts imported before pictures were collected.
      photos: listing?.profile.photos ?? [],
      // What guests say: the model's summary and the single reviews, newest first where the page dates them.
      reviews: reviewsFor(listing, sources[0]?.platform ?? null),
      // Every hint with whether this trip hid it. `listing.profile.warnings` stays the full, unfiltered list.
      warnings: warningsFor(listing, candidate.hiddenWarnings),
      sources: sources.map((s) => ({ id: s.id, platform: s.platform, url: s.url, canonicalUrl: s.canonicalUrl, provenance: s.provenance, lastFetchedAt: s.lastFetchedAt })),
      prices,
      votes: { ...tally(voteRows), entries: voteRows },
      comments: commentRows,
    };
  });

  /**
   * Take an advert out of a trip, with its votes and comments. The advert itself and
   * its price history stay known, so sharing the link again brings it straight back.
   */
  app.delete("/candidates/:candidateId", async (req, reply) => {
    const uid = userId(req);
    const { candidate } = await requireCandidate(db, uuidParam((req.params as { candidateId: string }).candidateId), uid, "member");
    await db.transaction(async (tx) => {
      await tx.delete(votes).where(eq(votes.tripListingId, candidate.id));
      await tx.delete(comments).where(eq(comments.tripListingId, candidate.id));
      await tx.delete(priceSnapshots).where(and(eq(priceSnapshots.tripId, candidate.tripId), inArray(priceSnapshots.listingSourceId, tx.select({ id: listingSources.id }).from(listingSources).where(eq(listingSources.listingId, candidate.listingId)))));
      await tx.delete(tripListings).where(eq(tripListings.id, candidate.id));
    });
    await logActivity(ctx, candidate.tripId, uid, "candidate_removed", { listingId: candidate.listingId });
    return reply.code(204).send();
  });

  app.patch("/candidates/:candidateId", async (req) => {
    const uid = userId(req);
    const { candidate } = await requireCandidate(db, uuidParam((req.params as { candidateId: string }).candidateId), uid, "member");
    const body = parseBody(
      z
        .object({
          status: z.enum(["new", "shortlist", "favorite", "rejected", "booked"]),
          rejectionReason: z.string().trim().max(500).nullable(),
          notes: z.string().max(5000).nullable(),
          tags: z.array(z.string().trim().min(1).max(40)).max(20),
          hiddenWarnings: z.array(z.string().max(1000)).max(40),
        })
        .partial(),
      req.body,
    );
    if (Object.keys(body).length === 0) throw new HttpError(400, "invalid_request", "Keine Änderung angegeben.");
    const [updated] = await db.update(tripListings).set(body).where(eq(tripListings.id, candidate.id)).returning();
    if (body.status && body.status !== candidate.status) {
      await logActivity(ctx, candidate.tripId, uid, "candidate_status", { candidateId: candidate.id, status: body.status });
    }
    return { candidate: updated };
  });

  /** Manual correction of the profile. Edited fields are no longer marked as uncertain. */
  app.patch("/candidates/:candidateId/profile", async (req) => {
    const uid = userId(req);
    const { candidate } = await requireCandidate(db, uuidParam((req.params as { candidateId: string }).candidateId), uid, "member");
    const patch = parseBody(profilePatch, req.body);
    const [listing] = await db.select().from(listings).where(eq(listings.id, candidate.listingId)).limit(1);

    const edited: string[] = [];
    const apply = (target: Record<string, unknown>, source: Record<string, unknown>, prefix: string) => {
      for (const [k, v] of Object.entries(source)) {
        const path = prefix ? `${prefix}.${k}` : k;
        if (v && typeof v === "object" && !Array.isArray(v) && target[k] && typeof target[k] === "object" && !Array.isArray(target[k])) {
          apply(target[k] as Record<string, unknown>, v as Record<string, unknown>, path);
        } else {
          target[k] = v;
          edited.push(path);
        }
      }
    };
    const draft = structuredClone(listing!.profile) as unknown as Record<string, unknown>;
    delete patch.uncertain;
    apply(draft, patch, "");
    draft.uncertain = listing!.profile.uncertain.filter((u) => !edited.some((e) => u === e || u.startsWith(`${e}.`)));

    const parsed = profileSchema.strict().safeParse(draft);
    if (!parsed.success) {
      const issue = parsed.error.issues[0];
      throw new HttpError(400, "invalid_request", `${issue?.path.join(".") || "Steckbrief"}: ${issue?.message ?? "ungültig"}`);
    }
    const profile = mergeProfiles(parsed.data, {});
    const [updated] = await db
      .update(listings)
      .set({ profile, kind: profile.kind, title: profile.title, place: profile.place, country: profile.country, lat: profile.lat, lon: profile.lon, coverImageUrl: profile.coverImageUrl, fillPercent: fillPercent(profile), updatedAt: new Date() })
      .where(eq(listings.id, listing!.id))
      .returning();
    return { listing: updated };
  });

  app.put("/candidates/:candidateId/vote", async (req) => {
    const uid = userId(req);
    const { candidate } = await requireCandidate(db, uuidParam((req.params as { candidateId: string }).candidateId), uid);
    const body = parseBody(z.object({ verdict: z.enum(["yes", "maybe", "no"]), veto: z.boolean().default(false) }), req.body);
    const [vote] = await db
      .insert(votes)
      .values({ tripListingId: candidate.id, userId: uid, verdict: body.verdict, veto: body.veto })
      .onConflictDoUpdate({ target: [votes.tripListingId, votes.userId], set: { verdict: body.verdict, veto: body.veto, updatedAt: new Date() } })
      .returning();
    await logActivity(ctx, candidate.tripId, uid, "vote", { candidateId: candidate.id, verdict: body.verdict, veto: body.veto });
    return { vote };
  });

  app.post("/candidates/:candidateId/comments", async (req, reply) => {
    const uid = userId(req);
    const { candidate } = await requireCandidate(db, uuidParam((req.params as { candidateId: string }).candidateId), uid);
    const body = parseBody(z.object({ body: z.string().trim().min(1).max(4000) }), req.body);
    const [comment] = await db.insert(comments).values({ tripListingId: candidate.id, userId: uid, body: body.body }).returning();
    await logActivity(ctx, candidate.tripId, uid, "comment", { candidateId: candidate.id });
    return reply.code(201).send({ comment });
  });

  /** A price someone read off the page themselves. */
  app.post("/candidates/:candidateId/prices", async (req, reply) => {
    const uid = userId(req);
    const { candidate } = await requireCandidate(db, uuidParam((req.params as { candidateId: string }).candidateId), uid, "member");
    const date = z.string().regex(/^\d{4}-\d{2}-\d{2}$/);
    const body = parseBody(
      z.object({
        totalCents: z.number().int().min(0).max(100_000_000),
        startDate: date.nullish(),
        endDate: date.nullish(),
        persons: z.number().int().min(1).max(60).nullish(),
        kind: z.enum(["total", "from", "range"]).default("total"),
        rangeMaxCents: z.number().int().min(0).nullish(),
        available: z.boolean().nullish(),
        breakdown: z.array(z.object({ item: z.string().trim().min(1).max(120), amountCents: z.number().int().nullable() })).max(30).default([]),
        sourceId: z.string().uuid().optional(),
      }),
      req.body,
    );
    const sources = await db.select().from(listingSources).where(eq(listingSources.listingId, candidate.listingId)).orderBy(asc(listingSources.createdAt));
    const source = body.sourceId ? sources.find((s) => s.id === body.sourceId) : sources[0];
    if (!source) throw new HttpError(400, "invalid_request", "sourceId: unbekannt");
    const nights = body.startDate && body.endDate ? Math.round((Date.parse(body.endDate) - Date.parse(body.startDate)) / 86_400_000) : null;
    const [price] = await db
      .insert(priceSnapshots)
      .values({
        listingSourceId: source.id,
        tripId: candidate.tripId,
        startDate: body.startDate ?? null,
        endDate: body.endDate ?? null,
        nights: nights && nights > 0 ? nights : null,
        persons: body.persons ?? null,
        totalCents: body.totalCents,
        rangeMaxCents: body.rangeMaxCents ?? null,
        kind: body.kind,
        available: body.available ?? null,
        breakdown: body.breakdown,
        capture: "manual",
        capturedBy: uid,
      })
      .returning();
    return reply.code(201).send({ price });
  });
}
