import { and, asc, desc, eq, inArray, sql } from "drizzle-orm";
import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { z } from "zod";
import type { AppContext } from "../app.js";
import { aiUsage, comments, dateOptions, listings, listingSources, priceSnapshots, sourceSuggestions, tripCriteria, tripListings, tripMembers, tripRankings, trips, users, votes } from "../db/schema.js";
import { fillPercent, mergeProfiles, profileSchema } from "../import/profile.js";
import { chooseStay, inWindow, processImport, resolveLink, settleSource, startImport, tripStay } from "../import/pipeline.js";
import { advertsOwn, coverOf, photoKey } from "../import/blocks.js";
import { analyzeLink, carriesStay, nightsBetween, urlForStay, urlForWindow } from "../import/url.js";
import { compare } from "../compare.js";
import { judge, MEASURABLE } from "../criteria.js";
import { HttpError, parseBody, requireCandidate, requireMember, userId, uuidParam } from "../http.js";
import { logActivity } from "./trips.js";

// Rendered pages of the comparison portals run to well over six megabytes before the app trims them.
const MAX_PAGE_BYTES = 12 * 1024 * 1024;

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
    items: items.map((r) => ({ ...r, platform: r.platform ?? platform })),
  };
}

/**
 * Whether asking the server is pointless for prices and availability: the platform refused it before,
 * or it is one of those that put the price for a stay into the page only in the visitor's browser.
 */
const RENDERED_PRICES = new Set(["airbnb", "vrbo", "casamundo", "check24", "novasol"]);
function onlyTheDeviceSeesPrices(source: { platform: string; fetchNote: string | null }): boolean {
  return source.fetchNote === "blocked" || source.fetchNote === "device" || RENDERED_PRICES.has(source.platform);
}

/** The advert's hints with the trip's choice to hide them; hidden ones stay retrievable. */
/**
 * A hint that the price is for fewer people than travel. Right for a house; beside the point where the trip
 * counts households and the price is one household's: there the list says so itself and reckons the group's.
 */
export const aboutHeadcount = (hint: string) =>
  /preis/i.test(hint) &&
  /\d+\s*(Erwachsene|Personen|Kinder|Gäste|Reisende)/i.test(hint) &&
  // A hint that says something else as well stays: a "from" price, other dates, a price by the head, missing children's prices.
  !/ab[- ]?preis|\bab \d|zeitraum|termin|datum|nächte|(pro|je) person|p\.\s?p\.|doppelzimmer|unklar|fehl|zwei preise|verschiedene preise|nur für die/i.test(hint);
const hintsFor = (warnings: string[], basis: "group" | "household") => (basis === "household" ? warnings.filter((w) => !aboutHeadcount(w)) : warnings);

function warningsFor(listing: typeof listings.$inferSelect | undefined, hidden: string[], basis: "group" | "household" = "group") {
  return hintsFor(listing?.profile.warnings ?? [], basis).map((text) => ({ text, hidden: hidden.includes(text) }));
}

export function candidateRoutes(app: FastifyInstance, ctx: AppContext): void {
  const { db } = ctx;
  const importDeps = { db, fetcher: ctx.fetcher, extractor: ctx.extractor, summarizer: ctx.summarizer ?? null };

  /** Share a link into a trip. Answers at once; details are read in the background. */
  app.post("/trips/:tripId/imports", { bodyLimit: MAX_PAGE_BYTES }, async (req, reply) => {
    const uid = userId(req);
    const tripId = uuidParam((req.params as { tripId: string }).tripId);
    await requireMember(db, tripId, uid, "member");
    const body = parseBody(z.object({ url: z.string().trim().url().max(4000), html: z.string().max(MAX_PAGE_BYTES).optional() }), req.body);

    await spend(uid, "reading");
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

  /**
   * Page content captured on the device, for platforms that refuse the server. With `sourceId`
   * the page belongs to a further source of the advert, otherwise to the link it was shared with.
   */
  const isoDay = z.string().regex(/^\d{4}-\d{2}-\d{2}$/);
  /** Dates named for one look: they have to be one of the trip's periods or lie inside its window. */
  async function datesFor(tripId: string, named: { startDate?: unknown; endDate?: unknown }) {
    if (named.startDate === undefined && named.endDate === undefined) return null;
    const d = parseBody(z.object({ startDate: isoDay, endDate: isoDay }), { startDate: named.startDate, endDate: named.endDate });
    const stay = await tripStay(db, tripId, null, d);
    if (stay.dateOptionId === null && !inWindow(stay.window, d.startDate, d.endDate)) throw new HttpError(400, "outside_window", "Dieser Zeitraum liegt außerhalb dessen, was die Reise zulässt.");
    return d;
  }

  app.post("/candidates/:candidateId/capture", { bodyLimit: MAX_PAGE_BYTES }, async (req, reply) => {
    const uid = userId(req);
    const { candidate } = await requireCandidate(db, uuidParam((req.params as { candidateId: string }).candidateId), uid, "member");
    const body = parseBody(z.object({ html: z.string().min(500).max(MAX_PAGE_BYTES), sourceId: z.string().uuid().optional(), forTrip: z.boolean().optional(), dateOptionId: z.string().uuid().optional(), startDate: isoDay.optional(), endDate: isoDay.optional(), url: z.string().max(4000).optional() }), req.body);
    const dates = await datesFor(candidate.tripId, body);
    await spend(uid, "reading");
    const sources = await db.select().from(listingSources).where(eq(listingSources.listingId, candidate.listingId)).orderBy(asc(listingSources.createdAt));
    const found = body.sourceId ? sources.find((s) => s.id === body.sourceId) : sources[0];
    const source = found && (await settleSource(db, ctx.fetcher, found));
    if (!source) throw new HttpError(body.sourceId ? 404 : 409, body.sourceId ? "not_found" : "no_source", body.sourceId ? "Diese Quelle gehört nicht zum Angebot." : "Zu diesem Angebot gibt es keinen Link.");
    // The shared link keeps the dates and party; an app short link carries nothing, so its resolved form is used.
    const shared = analyzeLink(source.url);
    const link = shared.isShortLink ? analyzeLink(source.canonicalUrl) : shared;
    if (source.id === sources[0]!.id) await db.update(tripListings).set({ importStatus: "pending", importNote: null }).where(eq(tripListings.id, candidate.id));
    ctx.queue.push(() =>
      processImport(importDeps, { candidateId: candidate.id, listingId: candidate.listingId, sourceId: source.id, link, tripId: candidate.tripId, userId: uid, html: body.html, forTrip: body.forTrip, dateOptionId: body.dateOptionId, dates, openedUrl: body.url }),
    );
    return reply.code(202).send({ candidateId: candidate.id, sourceId: source.id });
  });

  /** Read the advert again from the server, for example after the import got better or to look for a new price. */
  app.post("/candidates/:candidateId/refresh", async (req, reply) => {
    const uid = userId(req);
    const { candidate } = await requireCandidate(db, uuidParam((req.params as { candidateId: string }).candidateId), uid, "member");
    const [first] = await db.select().from(listingSources).where(eq(listingSources.listingId, candidate.listingId)).orderBy(asc(listingSources.createdAt)).limit(1);
    if (!first) throw new HttpError(409, "no_source", "Zu diesem Angebot gibt es keinen Link.");
    const source = await settleSource(db, ctx.fetcher, first);
    // Platforms are asked sparingly: not again within a minute.
    if (source.lastFetchedAt && Date.now() - source.lastFetchedAt.getTime() < 60_000) throw new HttpError(429, "too_soon", "Das Angebot wurde gerade erst abgerufen. Bitte gleich noch einmal versuchen.");
    await spend(uid, "reading");
    const shared = analyzeLink(source.url);
    const link = shared.isShortLink ? analyzeLink(source.canonicalUrl) : shared;
    await db.update(tripListings).set({ importStatus: "pending", importNote: null }).where(eq(tripListings.id, candidate.id));
    ctx.queue.push(() => processImport(importDeps, { candidateId: candidate.id, listingId: candidate.listingId, sourceId: source.id, link, tripId: candidate.tripId, userId: uid }));
    return reply.code(202).send({ candidateId: candidate.id });
  });

  /** The candidates of a trip as the list shows them, each with its advert for callers that need more. */
  /** Count one use of the language model against the person's allowance for today; refuse when it is used up. */
  const spend = async (uid: string, kind: "reading" | "search") => {
    const limit = kind === "search" ? ctx.config.DAILY_SEARCHES : ctx.config.DAILY_READINGS;
    const day = new Date().toISOString().slice(0, 10);
    const [row] = await db
      .insert(aiUsage)
      .values({ userId: uid, day, kind, count: 1 })
      .onConflictDoUpdate({ target: [aiUsage.userId, aiUsage.day, aiUsage.kind], set: { count: sql`${aiUsage.count} + 1` } })
      .returning({ count: aiUsage.count });
    if ((row?.count ?? 0) > limit) throw new HttpError(429, "daily_limit", kind === "search" ? "Für heute sind die Suchen aufgebraucht. Morgen geht es weiter." : "Für heute sind die Auswertungen aufgebraucht. Morgen geht es weiter.");
  };

  const criteriaOf = async (tripId: string) =>
    (await db.select().from(tripCriteria).where(eq(tripCriteria.tripId, tripId)).orderBy(asc(tripCriteria.position), asc(tripCriteria.createdAt))).map((c) => ({ id: c.id, key: c.key, label: c.label, level: c.level, target: c.target }));

  async function loadCandidates(tripId: string, uid: string, dateOptionId?: string | null) {
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
    const sources = await db.select().from(listingSources).where(inArray(listingSources.listingId, listingIds)).orderBy(asc(listingSources.createdAt));
    const stay = await tripStay(db, tripId, dateOptionId);
    const prices = sources.length
      ? await db.select().from(priceSnapshots).where(inArray(priceSnapshots.listingSourceId, sources.map((s) => s.id))).orderBy(desc(priceSnapshots.capturedAt))
      : [];

    // A price counts for this trip when it was recorded for it and its dates are one of the trip's periods.
    // Prices typed in by hand always count: whoever enters one knows what it is for.
    // With several periods to choose from, only the one asked about counts: the chosen one, else the earliest.
    const options = await db.select().from(dateOptions).where(eq(dateOptions.tripId, tripId)).orderBy(asc(dateOptions.startDate));
    // A trip with a window of possible dates takes any stay inside it, unless one period was asked for.
    const flexible = !dateOptionId && Boolean(stay.window.flexStart && stay.window.flexEnd);
    const forThisTrip = (p: (typeof prices)[number]) =>
      p.tripId === tripId &&
      (p.capture === "manual" || !p.startDate || (options.length === 0 && !flexible) || (p.startDate === stay.startDate && p.endDate === stay.endDate) || (flexible && inWindow(stay.window, p.startDate, p.endDate)));
    const inPeriod = (p: (typeof prices)[number], o: (typeof options)[number]) => p.tripId === tripId && p.startDate === o.startDate && p.endDate === o.endDate;

    const partySize = (stay.adults ?? 0) + (stay.children ?? 0);
    // A hotel portal's pages carry pictures that are not the hotel's: views of the place, other hotels nearby.
    // No address tells them apart, but the same picture stored for two of the trip's hotels belongs to neither.
    const seenIn = new Map<string, Set<string>>();
    const portalKey = (url: string) => (/check24\./.test(url) ? (photoKey(url)?.key ?? null) : null);
    for (const { listing } of rows) {
      for (const photo of listing.profile.photos ?? []) {
        const k = portalKey(photo.url);
        if (k) seenIn.set(k, (seenIn.get(k) ?? new Set()).add(listing.id));
      }
    }
    const ownPhotos = <P extends { url: string }>(photos: P[]) =>
      advertsOwn(photos).filter((photo) => {
        const k = portalKey(photo.url);
        return !k || (seenIn.get(k)?.size ?? 0) < 2;
      });
    const loaded = rows.map(({ candidate, listing, addedByName }) => {
      const mine = allVotes.filter((v) => v.tripListingId === candidate.id);
      const own = sources.filter((s) => s.listingId === listing.id);
      const ownPrices = prices.filter((p) => own.some((s) => s.id === p.listingSourceId));
      // A price captured for this trip's dates beats one that came with the shared link.
      const priced = ownPrices.filter((x) => x.totalCents !== null);
      // A look that found nothing at all says nothing: the page may not have finished loading on the device.
      // What an earlier look for the same dates found stays, with its own date, and the empty look is named beside it.
      const seenAt = (x: (typeof prices)[number]) => x.confirmedAt ?? x.capturedAt;
      const empty = (x: (typeof prices)[number] | undefined) => x !== undefined && x.totalCents === null && x.available === null;
      const newestForTrip = ownPrices.find(forThisTrip);
      // Every stay something is known about: the trip's periods and whatever was looked at inside its window.
      // The newest look with a result speaks for each.
      const known = new Map<string, (typeof prices)[number]>();
      for (const x of ownPrices) {
        if (x.tripId !== tripId || !x.startDate || !x.endDate || empty(x)) continue;
        if (!options.some((o) => o.startDate === x.startDate && o.endDate === x.endDate) && !inWindow(stay.window, x.startDate, x.endDate)) continue;
        const key = `${x.startDate}|${x.endDate}`;
        if (!known.has(key)) known.set(key, x);
      }
      const stays = [...known.values()]
        .map((x) => {
          const nights = x.nights ?? nightsBetween(x.startDate, x.endDate);
          return { row: x, startDate: x.startDate!, endDate: x.endDate!, nights, totalCents: x.available === false ? null : x.totalCents, perNightCents: x.available !== false && x.totalCents !== null && nights ? Math.round(x.totalCents / nights) : null, available: x.available, checkedAt: seenAt(x) };
        })
        .sort((a, b) => a.startDate.localeCompare(b.startDate) || a.endDate.localeCompare(b.endDate));
      // Different lengths compare by the night. Among stays that can be booked the cheapest night wins.
      // With a wish for a length, the stay of that length leads; see `chooseStay`.
      const choice = flexible ? chooseStay(stays.filter((x) => x.perNightCents !== null), (x) => x.nights, (x) => x.perNightCents!, stay.window.nightsPreferred) : null;
      const best = choice?.stay ?? null;
      const price = best?.row ?? priced.find(forThisTrip) ?? priced[0] ?? null;
      // The latest word on whether the trip's dates can be booked, from whichever source said so last.
      // With a window: free as soon as one stay inside it is, gone only when every stay looked at is.
      const said = best?.row ?? (flexible && stays.some((x) => x.available) ? stays.filter((x) => x.available).sort((a, b) => b.checkedAt.getTime() - a.checkedAt.getTime())[0]!.row : ownPrices.find((x) => forThisTrip(x) && x.available !== null));
      const stale = !said;
      const availability = stale ? ("unknown" as const) : said.available !== false ? ("available" as const) : ("unavailable" as const);
      // The page to open for the trip's dates and party, and whether only the device gets an answer from it.
      const first = own[0];
      const shared = first ? analyzeLink(first.url) : null;
      const link = shared?.isShortLink && first ? analyzeLink(first.canonicalUrl) : shared;
      const needsDevice = first !== undefined && onlyTheDeviceSeesPrices(first);
      const p = listing.profile;
      // Whom the price is for. Houses are priced for everyone; a hotel is usually asked about for one household.
      // What the members said for this advert counts first, then the number of people the price was asked for.
      const households = stay.households && stay.households > 1 ? stay.households : 1;
      const asked = price?.persons ?? null;
      const basis: "group" | "household" =
        households === 1 ? "group" : (candidate.priceBasis ?? (asked && partySize ? (asked < partySize ? "household" : "group") : p.kind === "vacation_home" ? "group" : "household"));
      const forGroup = (cents: number | null) => (cents === null ? null : basis === "household" ? cents * households : cents);
      const forHousehold = (cents: number | null) => (cents === null ? null : basis === "household" ? cents : Math.round(cents / households));
      const entry = {
        id: candidate.id,
        status: candidate.status,
        finalist: candidate.finalist,
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
          region: p.region,
          country: listing.country,
          lat: listing.lat,
          lon: listing.lon,
          // The position is an estimate or deliberately blurred by the platform: draw an area, not a pin.
          locationApproximate: listing.lat !== null && (p.uncertain.includes("lat") || p.uncertain.includes("lon")),
          coverImageUrl: ownPhotos(listing.coverImageUrl ? [{ url: listing.coverImageUrl }] : [])[0]?.url ?? ownPhotos(p.photos ?? [])[0]?.url ?? null,
          // What can actually be shown; the page may advertise more than it gave away (profile.photoCount).
          photoCount: ownPhotos(p.photos ?? []).length || p.photoCount,
          fillPercent: listing.fillPercent,
          maxGuests: p.maxGuests,
          bedrooms: p.bedrooms,
          bathrooms: p.bathrooms,
          rating: p.rating,
          platforms: own.map((s) => s.platform),
          // Hints still shown for this trip; hidden ones are not counted.
          warningCount: hintsFor(p.warnings, basis).filter((w) => !candidate.hiddenWarnings.includes(w)).length,
        },
        price: price && { available: stale ? price.available : best ? true : said.available, totalCents: price.totalCents, rangeMaxCents: price.rangeMaxCents, kind: price.kind, nights: price.nights, persons: price.persons, startDate: price.startDate, endDate: price.endDate, forThisTrip: forThisTrip(price), capturedAt: price.capturedAt, checkedAt: seenAt(price), basis, groupTotalCents: forGroup(price.totalCents), householdTotalCents: forHousehold(price.totalCents) },
        // "group" or "household": whom `price.totalCents` and the stays' totals are for. `priceBasisSet` is what a member chose, null while the server decides.
        priceBasis: basis,
        priceBasisSet: candidate.priceBasis,
        households,
        // For the trip's dates and party. "unknown" until a reading for those dates said one or the other.
        availability,
        availabilityCheckedAt: stale ? null : seenAt(said),
        // Set when the most recent look for the trip's dates came back without price and without a word on availability.
        emptyCheckAt: empty(newestForTrip) ? seenAt(newestForTrip!) : null,
        needsDevice,
        // Whether a device has read the page yet. Until then name, pictures and facts are only what the link gave away.
        deviceRead: first?.fetchNote === "device",
        // false when the advert takes fewer guests than the trip has travellers: platforms then show a hint instead of a price.
        fitsParty: p.maxGuests === null || partySize === 0 ? null : p.maxGuests >= partySize,
        checkUrl: link ? ((flexible && options.length === 0 ? urlForWindow(link, stay.window) : null) ?? urlForStay(link, stay)) : null,
        // One page for the whole window: a single look brings every possible stay, the single stays need none of their own.
        checkWindow: Boolean(link && flexible && options.length === 0 && urlForWindow(link, stay.window)),
        // What is known for each stay looked at, by the night, so that different dates and lengths compare. `best` marks the one `price` shows.
        // Why that stay leads: "cheapest" by the night, the "preferred" length, a "cheaper_longer" one, or the "nearest" length to be had.
        bestStayReason: choice?.why ?? null,
        stays: stays.map(({ row: _r, ...x }) => ({ ...x, groupTotalCents: forGroup(x.totalCents), householdTotalCents: forHousehold(x.totalCents), best: best !== null && x.startDate === best.startDate && x.endDate === best.endDate })),
        // What is known for each of the trip's periods, so they can be set side by side.
        periods: options.map((o) => {
          const seen = ownPrices.filter((x) => inPeriod(x, o));
          const word = seen.find((x) => x.available !== null);
          const amount = seen.find((x) => x.totalCents !== null);
          const newest = seen[0];
          const told = seen.find((x) => !empty(x));
          return {
            dateOptionId: o.id,
            label: o.label,
            startDate: o.startDate,
            endDate: o.endDate,
            availability: !word ? ("unknown" as const) : word.available ? ("available" as const) : ("unavailable" as const),
            totalCents: amount?.totalCents ?? null,
            kind: amount?.kind ?? null,
            // When what is shown here was read; an empty look afterwards does not move it.
            checkedAt: told ? seenAt(told) : (newest?.capturedAt ?? null),
            emptyCheckAt: empty(newest) ? seenAt(newest!) : null,
            checkUrl: link ? urlForStay(link, { ...stay, startDate: o.startDate, endDate: o.endDate }) : null,
          };
        }),
        votes: tally(mine),
        myVote: mine.find((v) => v.userId === uid) ?? null,
      };
      return { entry, profile: p, hiddenWarnings: candidate.hiddenWarnings, checks: candidate.criteriaChecks, photos: ownPhotos(p.photos ?? []) };
    });
    const wanted = await criteriaOf(tripId);
    return loaded.map((c) => {
      const { results: _r, ...verdict } = judge(wanted, c, c.checks);
      // The light and the counts for the list; the single results come with the detail view.
      return { ...c, entry: { ...c.entry, criteria: wanted.length ? verdict : null } };
    });
  }

  /** The trip's must-haves and wishes, and what can be asked for at all. */
  app.get("/trips/:tripId/criteria", async (req) => {
    const uid = userId(req);
    const tripId = uuidParam((req.params as { tripId: string }).tripId);
    await requireMember(db, tripId, uid);
    return { criteria: await criteriaOf(tripId), measurable: MEASURABLE };
  });

  /** Replace the trip's criteria as a whole. Entries that keep their id keep the checks made by hand. */
  app.put("/trips/:tripId/criteria", async (req) => {
    const uid = userId(req);
    const tripId = uuidParam((req.params as { tripId: string }).tripId);
    await requireMember(db, tripId, uid, "member");
    const body = parseBody(
      z.object({
        criteria: z
          .array(z.object({ id: z.string().uuid().optional(), key: z.string().max(60), label: z.string().trim().min(1).max(80).nullish(), level: z.enum(["must", "wish"]), target: z.number().finite().nullish() }))
          .max(30),
      }),
      req.body,
    );
    for (const c of body.criteria) {
      const m = MEASURABLE.find((x) => x.key === c.key);
      if (!m && c.key !== "custom") throw new HttpError(400, "invalid_request", `Unbekanntes Kriterium: ${c.key}`);
      if (c.key === "custom" && !c.label) throw new HttpError(400, "invalid_request", "Ein eigenes Kriterium braucht eine Bezeichnung.");
      if (m && m.rule !== "yes" && (c.target === null || c.target === undefined)) throw new HttpError(400, "invalid_request", `${m.label} braucht einen Zielwert.`);
    }
    const before = await db.select({ id: tripCriteria.id }).from(tripCriteria).where(eq(tripCriteria.tripId, tripId));
    const kept = new Set(before.map((b) => b.id));
    await db.transaction(async (tx) => {
      await tx.delete(tripCriteria).where(eq(tripCriteria.tripId, tripId));
      if (body.criteria.length) {
        await tx.insert(tripCriteria).values(
          body.criteria.map((c, position) => ({ ...(c.id && kept.has(c.id) ? { id: c.id } : {}), tripId, key: c.key, label: c.label ?? null, level: c.level, target: c.target ?? null, position })),
        );
      }
    });
    await logActivity(ctx, tripId, uid, "criteria_changed", { count: body.criteria.length });
    return { criteria: await criteriaOf(tripId), measurable: MEASURABLE };
  });

  /**
   * Adverts in any of the person's trips that only a device can read and that no device has read yet.
   * The app works through them in the background once someone is signed in.
   */
  app.get("/me/pending-readings", async (req) => {
    const uid = userId(req);
    const rows = await db
      .select({ candidateId: tripListings.id, tripId: tripListings.tripId, listingId: tripListings.listingId, title: listings.title, createdAt: tripListings.createdAt })
      .from(tripListings)
      .innerJoin(tripMembers, and(eq(tripMembers.tripId, tripListings.tripId), eq(tripMembers.userId, uid)))
      .innerJoin(listings, eq(listings.id, tripListings.listingId))
      .where(sql`${tripListings.status} <> 'rejected'`)
      .orderBy(desc(tripListings.createdAt))
      .limit(200);
    const all = rows.length ? await db.select().from(listingSources).where(inArray(listingSources.listingId, rows.map((r) => r.listingId))).orderBy(asc(listingSources.createdAt)) : [];
    const seen = new Set<string>();
    const pending = rows.flatMap((r) => {
      const first = all.find((x) => x.listingId === r.listingId);
      // One reading serves every trip the advert is in.
      if (!first || seen.has(r.listingId) || first.fetchNote === "device" || !onlyTheDeviceSeesPrices(first)) return [];
      seen.add(r.listingId);
      return [{ candidateId: r.candidateId, tripId: r.tripId, platform: first.platform, title: r.title, url: first.canonicalUrl, addedAt: r.createdAt }];
    });
    return { pending: pending.slice(0, 50) };
  });

  app.get("/trips/:tripId/candidates", async (req) => {
    const uid = userId(req);
    const tripId = uuidParam((req.params as { tripId: string }).tripId);
    await requireMember(db, tripId, uid);
    const chosen = (req.query as { dateOptionId?: string }).dateOptionId;
    return { candidates: (await loadCandidates(tripId, uid, chosen ? uuidParam(chosen) : null)).map((c) => c.entry) };
  });

  /**
   * Check every candidate of a trip for the trip's dates and party: is it still to be had, and at what price.
   * Where the server can read the page it does so in the background. Where the platform only talks to the
   * device, the answer names the page to open; the app captures it as usual.
   */
  const checkTrip = async (req: FastifyRequest, reply: FastifyReply) => {
    const uid = userId(req);
    const tripId = uuidParam((req.params as { tripId: string }).tripId);
    await requireMember(db, tripId, uid, "member");
    // Which period to check: named in the body or the query, else the earliest.
    const named = (req.body as { dateOptionId?: unknown } | null)?.dateOptionId ?? (req.query as { dateOptionId?: string }).dateOptionId;
    const dates = await datesFor(tripId, { ...(req.query as object), ...((req.body as object | null) ?? {}) });
    const stay = await tripStay(db, tripId, named ? uuidParam(named) : null, dates);
    if (named && !dates && stay.dateOptionId !== named) throw new HttpError(404, "not_found", "Diesen Zeitraum gibt es in der Reise nicht.");
    if (!stay.startDate || !stay.endDate) throw new HttpError(409, "no_dates", "Die Reise hat noch keinen Zeitraum. Lege zuerst einen fest.");
    const rows = await db.select().from(tripListings).where(eq(tripListings.tripId, tripId));
    const only = (req.body as { candidateId?: unknown } | null)?.candidateId;
    const open = rows.filter((c) => c.status !== "rejected" && (only === undefined || c.id === only));
    const sources = open.length ? await db.select().from(listingSources).where(inArray(listingSources.listingId, open.map((c) => c.listingId))).orderBy(asc(listingSources.createdAt)) : [];

    await spend(uid, "reading");
    const checks = [];
    for (const candidate of open) {
      const found = sources.find((x) => x.listingId === candidate.listingId);
      if (!found) continue;
      const source = await settleSource(db, ctx.fetcher, found);
      const shared = analyzeLink(source.url);
      const link = shared.isShortLink ? analyzeLink(source.canonicalUrl) : shared;
      // Where one page shows every stay inside the trip's window, that page is opened instead of one per stay.
      const whole = !named && !dates && stay.dateOptionId === null ? urlForWindow(link, stay.window) : null;
      const url = whole ?? urlForStay(link, stay);
      // Read on the device before: the platform refused the server, or gave it too little to go by.
      const device = onlyTheDeviceSeesPrices(source);
      const justRead = source.lastFetchedAt !== null && Date.now() - source.lastFetchedAt.getTime() < 60_000;
      if (!device && !justRead) {
        await db.update(tripListings).set({ importStatus: "pending", importNote: null }).where(eq(tripListings.id, candidate.id));
        ctx.queue.push(() => processImport(importDeps, { candidateId: candidate.id, listingId: candidate.listingId, sourceId: source.id, link, tripId, userId: uid, dateOptionId: stay.dateOptionId, dates }));
      }
      // No link form for the trip's dates: opening the undated page on the device would cost time and tell nothing.
      const pointless = device && stay.startDate !== null && stay.endDate !== null && whole === null && !carriesStay(link, stay);
      checks.push({ candidateId: candidate.id, platform: source.platform, mode: pointless || (!device && justRead) ? ("skipped" as const) : device ? ("device" as const) : ("server" as const), needsDevice: device, checkUrl: url, window: whole !== null });
    }
    await logActivity(ctx, tripId, uid, "availability_checked", { candidates: checks.length });
    return reply.code(202).send({ dateOptionId: stay.dateOptionId, startDate: stay.startDate, endDate: stay.endDate, adults: stay.adults, children: stay.children, checks });
  };
  app.post("/trips/:tripId/check", checkTrip);
  app.post("/trips/:tripId/refresh", checkTrip);

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
    const sources = await db.select().from(listingSources).where(eq(listingSources.listingId, candidate.listingId)).orderBy(asc(listingSources.createdAt));
    const suggestions = await db.select().from(sourceSuggestions).where(eq(sourceSuggestions.tripListingId, candidate.id)).orderBy(asc(sourceSuggestions.createdAt));
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
    // Measured against the trip's must-haves and wishes, criterion by criterion.
    const wanted = await criteriaOf(candidate.tripId);
    const self = (await loadCandidates(candidate.tripId, uid)).find((c) => c.entry.id === candidate.id);
    return {
      candidate,
      role,
      criteria: self && wanted.length ? judge(wanted, self, candidate.criteriaChecks) : null,
      // The same as in the trip's list: every stay something is known about, which of them leads, and why.
      stays: self?.entry.stays ?? [],
      bestStayReason: self?.entry.bestStayReason ?? null,
      priceBasis: self?.entry.priceBasis ?? "group",
      priceBasisSet: self?.entry.priceBasisSet ?? null,
      households: self?.entry.households ?? 1,
      price: self?.entry.price ?? null,
      checkWindow: self?.entry.checkWindow ?? false,
      // Without the hints on headcount where the price is one household's; see `warnings`.
      // And without pictures that turned out not to be the advert's own.
      listing: listing && {
        ...listing,
        coverImageUrl: self ? self.entry.listing.coverImageUrl : coverOf(listing.coverImageUrl, listing.profile.photos),
        profile: {
          ...listing.profile,
          photos: self?.photos ?? advertsOwn(listing.profile.photos),
          coverImageUrl: self ? self.entry.listing.coverImageUrl : coverOf(listing.profile.coverImageUrl, listing.profile.photos),
          warnings: hintsFor(listing.profile.warnings, self?.entry.priceBasis ?? "group"),
        },
      },
      // In page order, first is the cover. Empty for adverts imported before pictures were collected.
      photos: self?.photos ?? advertsOwn(listing?.profile.photos ?? []),
      // What guests say: the model's summary and the single reviews, newest first where the page dates them.
      reviews: reviewsFor(listing, sources[0]?.platform ?? null),
      // Every hint with whether this trip hid it. `listing.profile.warnings` stays the full, unfiltered list.
      warnings: warningsFor(listing, candidate.hiddenWarnings, self?.entry.priceBasis ?? "group"),
      // First is the link the advert was shared with. `read` says whether its page has been read at all,
      // `needsDevice` that the platform refused the server and the app should capture the page.
      sources: sources.map((s, i) => ({
        id: s.id,
        platform: s.platform,
        url: s.url,
        canonicalUrl: s.canonicalUrl,
        primary: i === 0,
        read: Boolean(s.provenance.details),
        needsDevice: s.fetchNote === "blocked" && !s.provenance.details,
        title: s.extract?.title ?? null,
        rating: s.extract?.rating ?? null,
        reviewCount: s.extract?.reviews.length ?? null,
        provenance: s.provenance,
        lastFetchedAt: s.lastFetchedAt,
      })),
      // The same property elsewhere: state of the search and what it proposed.
      otherPlatforms: {
        available: Boolean(ctx.searcher),
        status: candidate.searchStatus,
        searchedAt: candidate.searchedAt,
        note: candidate.searchNote,
        suggestions: suggestions.map((g) => ({ id: g.id, url: g.url, platform: g.platform, title: g.title, reason: g.reason, confidence: g.confidence, status: g.status })),
      },
      prices,
      votes: { ...tally(voteRows), entries: voteRows },
      comments: commentRows,
    };
  });

  /** Hang a further page of the same property onto a candidate and read it. */
  async function attachSource(candidate: typeof tripListings.$inferSelect, uid: string, url: string, html?: string) {
    let link;
    try {
      link = await resolveLink(url, ctx.fetcher);
    } catch {
      throw new HttpError(422, "link_unreadable", "Der Link konnte nicht gelesen werden.");
    }
    const [existing] = await db.select().from(listingSources).where(and(eq(listingSources.platform, link.platform), eq(listingSources.externalId, link.externalId))).limit(1);
    if (existing && existing.listingId !== candidate.listingId) {
      throw new HttpError(409, "already_listed", "Dieser Link ist bereits als eigenes Angebot erfasst. Entferne es dort, um es hier als weitere Quelle zu führen.");
    }
    const source =
      existing ??
      (await db
        .insert(listingSources)
        .values({ listingId: candidate.listingId, platform: link.platform, externalId: link.externalId, url: url.trim(), canonicalUrl: link.canonicalUrl, provenance: { stay: "Link" } })
        .returning())[0]!;
    await spend(uid, "reading");
    ctx.queue.push(() => processImport(importDeps, { candidateId: candidate.id, listingId: candidate.listingId, sourceId: source.id, link, tripId: candidate.tripId, userId: uid, html }));
    if (!existing) await logActivity(ctx, candidate.tripId, uid, "source_added", { candidateId: candidate.id, platform: link.platform });
    return { sourceId: source.id, platform: link.platform, duplicate: Boolean(existing) };
  }

  /** Add the same property on another platform by its link. */
  app.post("/candidates/:candidateId/sources", { bodyLimit: MAX_PAGE_BYTES }, async (req, reply) => {
    const uid = userId(req);
    const { candidate } = await requireCandidate(db, uuidParam((req.params as { candidateId: string }).candidateId), uid, "member");
    const body = parseBody(z.object({ url: z.string().trim().url().max(4000), html: z.string().max(MAX_PAGE_BYTES).optional() }), req.body);
    const attached = await attachSource(candidate, uid, body.url, body.html);
    return reply.code(attached.duplicate ? 200 : 202).send(attached);
  });

  /**
   * Take a further source away again, for example after a wrong match. Its prices and reviews go;
   * facts it filled into the profile stay and can be corrected by hand.
   */
  app.delete("/candidates/:candidateId/sources/:sourceId", async (req, reply) => {
    const uid = userId(req);
    const params = req.params as { candidateId: string; sourceId: string };
    const { candidate } = await requireCandidate(db, uuidParam(params.candidateId), uid, "member");
    const sources = await db.select().from(listingSources).where(eq(listingSources.listingId, candidate.listingId)).orderBy(asc(listingSources.createdAt));
    const source = sources.find((s) => s.id === uuidParam(params.sourceId));
    if (!source) throw new HttpError(404, "not_found", "Diese Quelle gehört nicht zum Angebot.");
    if (source.id === sources[0]!.id) throw new HttpError(409, "primary_source", "Der Link, mit dem das Angebot geteilt wurde, lässt sich nicht entfernen. Entferne stattdessen das Angebot.");
    const [listing] = await db.select().from(listings).where(eq(listings.id, candidate.listingId)).limit(1);
    await db.transaction(async (tx) => {
      await tx.delete(priceSnapshots).where(eq(priceSnapshots.listingSourceId, source.id));
      await tx.delete(listingSources).where(eq(listingSources.id, source.id));
      if (listing) {
        const profile = structuredClone(listing.profile);
        profile.reviews = profile.reviews.filter((r) => r.platform !== source.platform);
        // The joint summary spoke for this source too; fall back to what the leading source said alone.
        if (sources[0]!.extract) profile.reviewSummary = sources[0]!.extract.reviewSummary;
        await tx.update(listings).set({ profile, updatedAt: new Date() }).where(eq(listings.id, listing.id));
      }
      await tx.update(sourceSuggestions).set({ status: "rejected" }).where(and(eq(sourceSuggestions.tripListingId, candidate.id), eq(sourceSuggestions.url, source.url)));
    });
    return reply.code(204).send();
  });

  /** Look on the web for the same property on other platforms. Results arrive as suggestions on the candidate. */
  app.post("/candidates/:candidateId/sources/search", async (req, reply) => {
    const uid = userId(req);
    const { candidate } = await requireCandidate(db, uuidParam((req.params as { candidateId: string }).candidateId), uid, "member");
    const searcher = ctx.searcher;
    if (!searcher) throw new HttpError(503, "search_unavailable", "Die Suche ist auf diesem Server nicht eingerichtet.");
    if (candidate.searchStatus === "running" && candidate.searchedAt && Date.now() - candidate.searchedAt.getTime() < 5 * 60_000) return reply.code(202).send({ candidateId: candidate.id, status: "running" });
    // Every search costs money: not again for the same advert within ten minutes.
    if (candidate.searchedAt && Date.now() - candidate.searchedAt.getTime() < 10 * 60_000) throw new HttpError(429, "too_soon", "Für dieses Angebot wurde gerade erst gesucht. Bitte in ein paar Minuten noch einmal versuchen.");
    await spend(uid, "search");
    const [listing] = await db.select().from(listings).where(eq(listings.id, candidate.listingId)).limit(1);
    const sources = await db.select().from(listingSources).where(eq(listingSources.listingId, candidate.listingId));
    await db.update(tripListings).set({ searchStatus: "running", searchedAt: new Date(), searchNote: null }).where(eq(tripListings.id, candidate.id));

    ctx.queue.push(async () => {
      try {
        const { hits, note } = await searcher({ profile: listing!.profile, known: sources.map((s) => ({ platform: s.platform, url: s.canonicalUrl })) });
        let added = 0;
        for (const hit of hits) {
          let link;
          try {
            link = analyzeLink(hit.url);
          } catch {
            continue;
          }
          // Not what is already attached, and nothing on a platform that is.
          if (sources.some((s) => s.platform === link.platform && (s.externalId === link.externalId || link.platform !== "other"))) continue;
          const inserted = await db
            .insert(sourceSuggestions)
            .values({ tripListingId: candidate.id, url: link.canonicalUrl, platform: link.platform, title: hit.title, reason: hit.reason, confidence: hit.confidence })
            .onConflictDoNothing()
            .returning({ id: sourceSuggestions.id });
          added += inserted.length;
        }
        await db
          .update(tripListings)
          .set({ searchStatus: "done", searchedAt: new Date(), searchNote: note ?? (added === 0 ? "Auf anderen Plattformen wurde nichts Neues gefunden." : null) })
          .where(eq(tripListings.id, candidate.id));
      } catch (err) {
        await db.update(tripListings).set({ searchStatus: "failed", searchedAt: new Date(), searchNote: "Die Suche ist fehlgeschlagen. Bitte später noch einmal versuchen." }).where(eq(tripListings.id, candidate.id));
        throw err;
      }
    });
    return reply.code(202).send({ candidateId: candidate.id, status: "running" });
  });

  /** Confirm or dismiss a suggestion. Confirming attaches the page as a further source and reads it. */
  app.post("/candidates/:candidateId/suggestions/:suggestionId", { bodyLimit: MAX_PAGE_BYTES }, async (req, reply) => {
    const uid = userId(req);
    const params = req.params as { candidateId: string; suggestionId: string };
    const { candidate } = await requireCandidate(db, uuidParam(params.candidateId), uid, "member");
    const body = parseBody(z.object({ decision: z.enum(["accept", "reject"]), html: z.string().max(MAX_PAGE_BYTES).optional() }), req.body);
    const [suggestion] = await db.select().from(sourceSuggestions).where(and(eq(sourceSuggestions.id, uuidParam(params.suggestionId)), eq(sourceSuggestions.tripListingId, candidate.id))).limit(1);
    if (!suggestion) throw new HttpError(404, "not_found", "Vorschlag nicht gefunden.");
    if (body.decision === "reject") {
      await db.update(sourceSuggestions).set({ status: "rejected" }).where(eq(sourceSuggestions.id, suggestion.id));
      return reply.code(200).send({ status: "rejected" });
    }
    const attached = await attachSource(candidate, uid, suggestion.url, body.html);
    await db.update(sourceSuggestions).set({ status: "accepted" }).where(eq(sourceSuggestions.id, suggestion.id));
    return reply.code(202).send({ status: "accepted", ...attached });
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

  /**
   * Move a candidate to another trip, or to and from the watchlist. The advert goes with everything that
   * describes it: notes, tags, comments, hidden hints. What the old group thought of it stays behind:
   * votes, status, and the prices and availability read for the old trip's dates.
   */
  app.post("/candidates/:candidateId/move", async (req) => {
    const uid = userId(req);
    const { candidate } = await requireCandidate(db, uuidParam((req.params as { candidateId: string }).candidateId), uid, "member");
    const body = parseBody(z.object({ tripId: z.string().uuid() }), req.body);
    if (body.tripId === candidate.tripId) return { candidateId: candidate.id, tripId: candidate.tripId };
    await requireMember(db, body.tripId, uid, "member");
    const [there] = await db.select({ id: tripListings.id }).from(tripListings).where(and(eq(tripListings.tripId, body.tripId), eq(tripListings.listingId, candidate.listingId))).limit(1);
    if (there) throw new HttpError(409, "already_in_trip", "Dieses Angebot gibt es in der Zielreise schon.");
    await db.transaction(async (tx) => {
      await tx.delete(votes).where(eq(votes.tripListingId, candidate.id));
      // Prices read for the old trip keep its mark: they do not count in the new one, and return with the advert if it moves back.
      await tx.update(tripListings).set({ tripId: body.tripId, status: "new", rejectionReason: null, criteriaChecks: {}, finalist: false }).where(eq(tripListings.id, candidate.id));
    });
    await logActivity(ctx, candidate.tripId, uid, "candidate_moved_away", { listingId: candidate.listingId });
    await logActivity(ctx, body.tripId, uid, "candidate_moved_in", { candidateId: candidate.id, listingId: candidate.listingId });
    return { candidateId: candidate.id, tripId: body.tripId };
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
          criteriaChecks: z.record(z.string().uuid(), z.enum(["met", "missed"])),
          finalist: z.boolean(),
          priceBasis: z.enum(["group", "household"]).nullable(),
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

  /** Take one's own vote back, veto included. Nothing to take back is no error. */
  app.delete("/candidates/:candidateId/vote", async (req, reply) => {
    const uid = userId(req);
    const { candidate } = await requireCandidate(db, uuidParam((req.params as { candidateId: string }).candidateId), uid);
    await db.delete(votes).where(and(eq(votes.tripListingId, candidate.id), eq(votes.userId, uid)));
    return reply.code(204).send();
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
    await spend(uid, "reading");
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
  /**
   * The pitch: the few adverts the group decides between, everyone's order of them, and where that leaves each.
   * Points follow the place in a person's order: with n finalists the first gets n, the last named 1, unnamed ones 0.
   */
  async function pitch(tripId: string, uid: string) {
    const [trip] = await db.select().from(trips).where(eq(trips.id, tripId)).limit(1);
    const all = await loadCandidates(tripId, uid, trip?.decidedDateOptionId);
    const finalists = all.filter((c) => c.entry.finalist);
    const ids = finalists.map((c) => c.entry.id);
    const members = await db
      .select({ id: users.id, name: users.name, role: tripMembers.role })
      .from(tripMembers)
      .innerJoin(users, eq(users.id, tripMembers.userId))
      .where(eq(tripMembers.tripId, tripId))
      .orderBy(asc(tripMembers.joinedAt));
    const rankings = (await db.select().from(tripRankings).where(eq(tripRankings.tripId, tripId))).map((r) => ({ ...r, order: r.order.filter((id) => ids.includes(id)) })).filter((r) => r.order.length > 0);
    const points = new Map(ids.map((id) => [id, 0]));
    const firsts = new Map(ids.map((id) => [id, 0]));
    for (const r of rankings) {
      r.order.forEach((id, place) => points.set(id, (points.get(id) ?? 0) + ids.length - place));
      firsts.set(r.order[0]!, (firsts.get(r.order[0]!) ?? 0) + 1);
    }
    const rows = finalists
      .map((c) => ({
        candidate: c.entry,
        points: points.get(c.entry.id) ?? 0,
        firstPlaces: firsts.get(c.entry.id) ?? 0,
        // What speaks for and against it, for the paper the decision rests on.
        summary: c.profile.summary,
        highlights: c.profile.highlights,
        warnings: hintsFor(c.profile.warnings, c.entry.priceBasis).filter((w) => !c.hiddenWarnings.includes(w)),
        reviewSummary: c.profile.reviewSummary.summary ? { summary: c.profile.reviewSummary.summary, positives: c.profile.reviewSummary.positives, negatives: c.profile.reviewSummary.negatives } : null,
      }))
      // Most points first; a veto puts an advert behind those without one, and first places break a tie.
      .sort((a, b) => Number(a.candidate.votes.vetoes > 0) - Number(b.candidate.votes.vetoes > 0) || b.points - a.points || b.firstPlaces - a.firstPlaces);
    return {
      phase: trip?.phase ?? "research",
      voteDeadline: trip?.voteDeadline ?? null,
      decided: trip?.decidedCandidateId ? { candidateId: trip.decidedCandidateId, dateOptionId: trip.decidedDateOptionId, at: trip.decidedAt } : null,
      maxPoints: ids.length * members.length,
      finalists: rows.map((r, i) => ({ place: i + 1, ...r })),
      rankings: rankings.map((r) => ({ userId: r.userId, name: members.find((m) => m.id === r.userId)?.name ?? null, order: r.order, updatedAt: r.updatedAt })),
      myRanking: rankings.find((r) => r.userId === uid)?.order ?? [],
      // Who has not put the finalists in an order yet, for a reminder.
      missing: ids.length ? members.filter((m) => !rankings.some((r) => r.userId === m.id)).map((m) => ({ userId: m.id, name: m.name })) : [],
    };
  }

  app.get("/trips/:tripId/pitch", async (req) => {
    const uid = userId(req);
    const tripId = uuidParam((req.params as { tripId: string }).tripId);
    await requireMember(db, tripId, uid);
    return pitch(tripId, uid);
  });

  /** Open the pitch: name the finalists, optionally a deadline. The trip moves on to the decision. */
  app.post("/trips/:tripId/pitch", async (req) => {
    const uid = userId(req);
    const tripId = uuidParam((req.params as { tripId: string }).tripId);
    await requireMember(db, tripId, uid, "organizer");
    const body = parseBody(z.object({ candidateIds: z.array(z.string().uuid()).min(2).max(8), voteDeadline: z.string().datetime().nullish() }), req.body);
    const rows = await db.select({ id: tripListings.id }).from(tripListings).where(eq(tripListings.tripId, tripId));
    if (body.candidateIds.some((id) => !rows.some((r) => r.id === id))) throw new HttpError(404, "not_found", "Mindestens ein Angebot gehört nicht zu dieser Reise.");
    await db.transaction(async (tx) => {
      await tx.update(tripListings).set({ finalist: false }).where(eq(tripListings.tripId, tripId));
      await tx.update(tripListings).set({ finalist: true }).where(inArray(tripListings.id, body.candidateIds));
      await tx.update(trips).set({ phase: "decision", ...(body.voteDeadline !== undefined ? { voteDeadline: body.voteDeadline ? new Date(body.voteDeadline) : null } : {}) }).where(eq(trips.id, tripId));
    });
    await logActivity(ctx, tripId, uid, "pitch_opened", { finalists: body.candidateIds.length });
    return pitch(tripId, uid);
  });

  /** One person's order of the finalists, best first. It may leave some out. Guests rank too. */
  app.put("/trips/:tripId/ranking", async (req) => {
    const uid = userId(req);
    const tripId = uuidParam((req.params as { tripId: string }).tripId);
    await requireMember(db, tripId, uid);
    const body = parseBody(z.object({ order: z.array(z.string().uuid()).max(8) }), req.body);
    const finalists = await db.select({ id: tripListings.id }).from(tripListings).where(and(eq(tripListings.tripId, tripId), eq(tripListings.finalist, true)));
    if (new Set(body.order).size !== body.order.length || body.order.some((id) => !finalists.some((f) => f.id === id))) {
      throw new HttpError(400, "invalid_request", "Die Rangfolge darf nur Finalisten enthalten, jeden höchstens einmal.");
    }
    await db
      .insert(tripRankings)
      .values({ tripId, userId: uid, order: body.order })
      .onConflictDoUpdate({ target: [tripRankings.tripId, tripRankings.userId], set: { order: body.order, updatedAt: new Date() } });
    await logActivity(ctx, tripId, uid, "ranking_set", {});
    return pitch(tripId, uid);
  });

  /** Record what the group settled on. The trip moves on to the booking; nothing else is thrown away. */
  app.post("/trips/:tripId/decision", async (req) => {
    const uid = userId(req);
    const tripId = uuidParam((req.params as { tripId: string }).tripId);
    await requireMember(db, tripId, uid, "organizer");
    const body = parseBody(z.object({ candidateId: z.string().uuid(), dateOptionId: z.string().uuid().nullish() }), req.body);
    const [winner] = await db.select().from(tripListings).where(and(eq(tripListings.id, body.candidateId), eq(tripListings.tripId, tripId))).limit(1);
    if (!winner) throw new HttpError(404, "not_found", "Dieses Angebot gehört nicht zu dieser Reise.");
    const stay = await tripStay(db, tripId, body.dateOptionId);
    if (body.dateOptionId && stay.dateOptionId !== body.dateOptionId) throw new HttpError(404, "not_found", "Diesen Zeitraum gibt es in der Reise nicht.");
    await db.transaction(async (tx) => {
      await tx.update(trips).set({ phase: "booking", status: "decided", decidedCandidateId: winner.id, decidedDateOptionId: stay.dateOptionId, decidedAt: new Date() }).where(eq(trips.id, tripId));
      await tx.update(tripListings).set({ status: "favorite", finalist: true }).where(eq(tripListings.id, winner.id));
    });
    await logActivity(ctx, tripId, uid, "decision_made", { candidateId: winner.id });
    return pitch(tripId, uid);
  });

  /** Take the decision back, for example when the house is gone after all. The trip returns to the pitch. */
  app.delete("/trips/:tripId/decision", async (req) => {
    const uid = userId(req);
    const tripId = uuidParam((req.params as { tripId: string }).tripId);
    await requireMember(db, tripId, uid, "organizer");
    await db.update(trips).set({ phase: "decision", status: "planning", decidedCandidateId: null, decidedDateOptionId: null, decidedAt: null }).where(eq(trips.id, tripId));
    await logActivity(ctx, tripId, uid, "decision_withdrawn", {});
    return pitch(tripId, uid);
  });
}
