import { and, asc, eq } from "drizzle-orm";
import type { Db } from "../db/client.js";
import { dateOptions, listings, listingSources, priceSnapshots, tripListings, trips } from "../db/schema.js";
import { extractBlocks, profileFromBlocks } from "./blocks.js";
import type { Extractor } from "./extract.js";
import { UnsafeUrlError, type PageFetcher } from "./fetch.js";
import { emptyProfile, fillPercent, mergeProfiles, type Profile } from "./profile.js";
import { analyzeLink, embeddedTarget, nightsBetween, urlForStay, type LinkInfo } from "./url.js";

export interface ImportDeps {
  db: Db;
  fetcher: PageFetcher;
  extractor: Extractor;
}

export interface StartedImport {
  candidateId: string;
  listingId: string;
  sourceId: string;
  link: LinkInfo;
  /** True when the listing was already known and is reused. */
  duplicate: boolean;
}

/** Resolve app short links to the advert they point at. */
export async function resolveLink(raw: string, fetcher: PageFetcher): Promise<LinkInfo> {
  let info = analyzeLink(raw);
  if (!info.isShortLink) return info;
  const embedded = embeddedTarget(new URL(raw.trim()));
  if (embedded) return analyzeLink(embedded);
  const page = await fetcher(raw.trim());
  // The last hop that is a real web page is the advert; later hops may lead to an app store.
  for (const candidate of [page.finalUrl, ...page.redirects.toReversed()]) {
    info = analyzeLink(candidate);
    if (!info.isShortLink && info.platform !== "other") return info;
  }
  return analyzeLink(page.finalUrl);
}

function seedProfile(link: LinkInfo): Profile {
  const profile = emptyProfile(link.kind);
  const s = link.stay;
  profile.price.startDate = s.startDate;
  profile.price.endDate = link.priceHint?.endDate ?? s.endDate;
  profile.price.nights = link.priceHint?.nights ?? s.nights;
  profile.price.persons = s.adults !== null ? s.adults + (s.children ?? 0) : null;
  if (link.priceHint) {
    profile.price.totalEur = link.priceHint.totalEur;
    profile.price.kind = "total";
    profile.uncertain.push("price.totalEur");
    if (link.priceHint.nonRefundable) profile.cancellation = "Laut Link ein nicht erstattbarer Tarif.";
  }
  profile.warnings = [...link.warnings];
  return profile;
}

/**
 * Register a shared link in a trip. Returns at once; reading the page happens
 * in `processImport`, so the candidate is visible to everyone immediately.
 */
export async function startImport(deps: ImportDeps, input: { tripId: string; userId: string; url: string }): Promise<StartedImport> {
  const link = await resolveLink(input.url, deps.fetcher);
  const { db } = deps;

  const [existing] = await db
    .select()
    .from(listingSources)
    .where(and(eq(listingSources.platform, link.platform), eq(listingSources.externalId, link.externalId)))
    .limit(1);

  let listingId: string;
  let sourceId: string;
  if (existing) {
    listingId = existing.listingId;
    sourceId = existing.id;
  } else {
    const profile = seedProfile(link);
    const [listing] = await db
      .insert(listings)
      .values({ kind: link.kind, profile, fillPercent: fillPercent(profile) })
      .returning({ id: listings.id });
    listingId = listing!.id;
    const [source] = await db
      .insert(listingSources)
      .values({ listingId, platform: link.platform, externalId: link.externalId, url: input.url.trim(), canonicalUrl: link.canonicalUrl, provenance: { stay: "Link" } })
      .returning({ id: listingSources.id });
    sourceId = source!.id;
    if (link.priceHint) {
      // The link alone already carries a price; keep it even if the page turns out to be blocked.
      await db.insert(priceSnapshots).values({
        listingSourceId: sourceId,
        startDate: profile.price.startDate,
        endDate: profile.price.endDate,
        nights: profile.price.nights,
        persons: profile.price.persons,
        totalCents: Math.round(link.priceHint.totalEur * 100),
        kind: "total",
        capture: "import",
        capturedBy: input.userId,
      });
    }
  }

  const [already] = await db
    .select({ id: tripListings.id })
    .from(tripListings)
    .where(and(eq(tripListings.tripId, input.tripId), eq(tripListings.listingId, listingId)))
    .limit(1);
  if (already) return { candidateId: already.id, listingId, sourceId, link, duplicate: true };

  const [candidate] = await db
    .insert(tripListings)
    .values({ tripId: input.tripId, listingId, addedBy: input.userId, importStatus: "pending" })
    .returning({ id: tripListings.id });
  return { candidateId: candidate!.id, listingId, sourceId, link, duplicate: false };
}

async function tripStay(db: Db, tripId: string) {
  const [trip] = await db.select().from(trips).where(eq(trips.id, tripId)).limit(1);
  const [option] = await db.select().from(dateOptions).where(eq(dateOptions.tripId, tripId)).orderBy(asc(dateOptions.startDate)).limit(1);
  return {
    startDate: option?.startDate ?? null,
    endDate: option?.endDate ?? null,
    adults: trip?.adults ?? null,
    children: trip?.children ?? null,
  };
}

/**
 * Read the page and fill the profile. `html` is page content captured on the
 * user's device; without it the server fetches the page itself.
 */
export async function processImport(
  deps: ImportDeps,
  input: { candidateId: string; listingId: string; sourceId: string; link: LinkInfo; tripId: string; userId: string; html?: string },
): Promise<void> {
  const { db } = deps;
  const setCandidate = (values: { importStatus: "ready" | "partial" | "failed"; importNote: string | null }) =>
    db.update(tripListings).set(values).where(eq(tripListings.id, input.candidateId));

  try {
    const stay = await tripStay(db, input.tripId);
    const fromDevice = input.html !== undefined;
    let html = input.html ?? "";
    let priceBelongsToTrip = false;

    if (!fromDevice) {
      // Ask for the trip's dates and party, so the price on the page is the one that matters.
      const target = urlForStay(input.link, stay);
      priceBelongsToTrip = target !== input.link.canonicalUrl;
      const page = await deps.fetcher(target);
      await db.update(listingSources).set({ lastFetchedAt: new Date(), fetchNote: page.blocked ? "blocked" : `http ${page.status}` }).where(eq(listingSources.id, input.sourceId));
      if (page.blocked || page.status >= 400 || page.html.length < 500) {
        await setCandidate({
          importStatus: "partial",
          importNote: "Die Plattform lässt den Abruf vom Server nicht zu. Öffne das Angebot in der App, dann werden die Details auf deinem Gerät ausgelesen.",
        });
        return;
      }
      html = page.html;
    }

    const blocks = extractBlocks(html);
    const { profile: baseline, provenance } = profileFromBlocks(blocks, input.link.kind);
    const { profile: extracted, note } = await deps.extractor({ blocks, link: input.link, baseline });

    const [current] = await db.select().from(listings).where(eq(listings.id, input.listingId)).limit(1);
    // What was read from the page replaces what was only seeded from the link.
    const profile = mergeProfiles(current?.profile ?? emptyProfile(input.link.kind), extracted, true);
    profile.price.nights ??= nightsBetween(profile.price.startDate, profile.price.endDate);
    // Hints from the link itself (one guest only, contradictory dates) stay visible next to what the page showed.
    profile.warnings = [...new Set([...(current?.profile.warnings ?? []), ...extracted.warnings])].slice(0, 6);

    await db
      .update(listings)
      .set({
        profile,
        title: profile.title,
        place: profile.place,
        country: profile.country,
        lat: profile.lat,
        lon: profile.lon,
        coverImageUrl: profile.coverImageUrl,
        fillPercent: fillPercent(profile),
        updatedAt: new Date(),
      })
      .where(eq(listings.id, input.listingId));
    await db
      .update(listingSources)
      .set({ provenance: { ...provenance, stay: "Link", details: fromDevice ? "Auf dem Gerät ausgelesen" : "Abruf vom Server" } })
      .where(eq(listingSources.id, input.sourceId));

    if (profile.price.totalEur !== null) {
      await db.insert(priceSnapshots).values({
        listingSourceId: input.sourceId,
        tripId: fromDevice || priceBelongsToTrip ? input.tripId : null,
        startDate: profile.price.startDate,
        endDate: profile.price.endDate,
        nights: profile.price.nights,
        persons: profile.price.persons,
        totalCents: Math.round(profile.price.totalEur * 100),
        rangeMaxCents: profile.price.rangeMaxEur !== null ? Math.round(profile.price.rangeMaxEur * 100) : null,
        kind: profile.price.kind ?? "total",
        breakdown: profile.price.extraCosts.map((c) => ({ item: c.item, amountCents: c.amountEur !== null ? Math.round(c.amountEur * 100) : null })),
        capture: fromDevice ? "device" : "import",
        capturedBy: input.userId,
      });
    }

    await setCandidate({ importStatus: note ? "partial" : "ready", importNote: note });
  } catch (err) {
    const note =
      err instanceof UnsafeUrlError
        ? "Dieser Link kann nicht abgerufen werden."
        : "Beim Auslesen ist ein Fehler aufgetreten. Die Angaben lassen sich von Hand ergänzen.";
    await setCandidate({ importStatus: "failed", importNote: note });
    if (!(err instanceof UnsafeUrlError)) throw err;
  }
}

/** Runs imports in the background and lets tests wait for them. */
export class ImportQueue {
  private running = new Set<Promise<void>>();
  constructor(private onError: (err: unknown) => void) {}

  push(job: () => Promise<void>): void {
    const p = job()
      .catch(this.onError)
      .finally(() => this.running.delete(p));
    this.running.add(p);
  }

  async idle(): Promise<void> {
    while (this.running.size) await Promise.all(this.running);
  }
}
