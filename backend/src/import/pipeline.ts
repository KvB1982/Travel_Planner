import { and, asc, desc, eq } from "drizzle-orm";
import type { Db } from "../db/client.js";
import { dateOptions, listings, listingSources, priceSnapshots, tripListings, trips } from "../db/schema.js";
import { extractBlocks, profileFromBlocks } from "./blocks.js";
import { positionFitsCountry } from "./country.js";
import type { Extractor, ReviewSummarizer } from "./extract.js";
import { looksBlocked, UnsafeUrlError, type PageFetcher } from "./fetch.js";
import { emptyProfile, fillPercent, mergeProfiles, type Profile } from "./profile.js";
import { analyzeLink, embeddedTarget, nightsBetween, urlForStay, type LinkInfo } from "./url.js";

const APPROXIMATE_POSITION = new Set(["airbnb", "vrbo"]);
/** A title a security check left behind in place of the advert's own. */
const SECURITY_CHECK_TITLE = /Bot oder Mensch|Bot or human|Just a moment|Access Denied|Sicherheitsüberprüfung/i;

export interface ImportDeps {
  db: Db;
  fetcher: PageFetcher;
  extractor: Extractor;
  /** Writes one summary over the reviews of several platforms. Without it the first source's summary stays. */
  summarizer?: ReviewSummarizer | null;
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
  // A search window says when the trip may happen, not how long it lasts.
  if (!link.searchWindow) {
    profile.price.startDate = s.startDate;
    profile.price.endDate = link.priceHint?.endDate ?? s.endDate;
    profile.price.nights = link.priceHint?.nights ?? s.nights;
  }
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

/** The stay a trip asks about: the chosen period, or the earliest one when none is named. */
export async function tripStay(db: Db, tripId: string, dateOptionId?: string | null) {
  const [trip] = await db.select().from(trips).where(eq(trips.id, tripId)).limit(1);
  const all = await db.select().from(dateOptions).where(eq(dateOptions.tripId, tripId)).orderBy(asc(dateOptions.startDate));
  const option = (dateOptionId ? all.find((o) => o.id === dateOptionId) : undefined) ?? all[0];
  return {
    dateOptionId: option?.id ?? null,
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
  input: { candidateId: string; listingId: string; sourceId: string; link: LinkInfo; tripId: string; userId: string; html?: string; /** The device opened the page for the trip's own dates and party. */ forTrip?: boolean; /** Which of the trip's periods is asked about; the earliest when left out. */ dateOptionId?: string | null; /** The address the device had open, for diagnosis. */ openedUrl?: string },
): Promise<void> {
  const { db } = deps;
  const sources = await db.select().from(listingSources).where(eq(listingSources.listingId, input.listingId)).orderBy(asc(listingSources.createdAt));
  // The link an advert was shared with leads. Further sources of the same property only add to it.
  const secondary = sources.length > 0 && sources[0]!.id !== input.sourceId;
  const setCandidate = async (values: { importStatus: "ready" | "partial" | "failed"; importNote: string | null }) => {
    if (secondary) return;
    await db.update(tripListings).set(values).where(eq(tripListings.id, input.candidateId));
  };

  try {
    const stay = await tripStay(db, input.tripId, input.dateOptionId);
    const fromDevice = input.html !== undefined;
    let html = input.html ?? "";
    // The device's word only counts where a link can carry the trip's dates; otherwise it opened the undated page.
    let priceBelongsToTrip =
      fromDevice && input.forTrip === true && stay.startDate !== null && stay.endDate !== null && urlForStay(input.link, stay) !== input.link.canonicalUrl;

    if (!fromDevice) {
      // Ask for the trip's dates and party, so the price on the page is the one that matters.
      const target = urlForStay(input.link, stay);
      priceBelongsToTrip = target !== input.link.canonicalUrl;
      const page = await deps.fetcher(target);
      const refused = page.blocked || page.status >= 400 || page.html.length < 500;
      await db.update(listingSources).set({ lastFetchedAt: new Date(), fetchNote: refused ? "blocked" : `http ${page.status}` }).where(eq(listingSources.id, input.sourceId));
      if (refused) {
        await setCandidate({
          importStatus: "partial",
          importNote: "Die Plattform lässt den Abruf vom Server nicht zu. Öffne das Angebot in der App, dann werden die Details auf deinem Gerät ausgelesen.",
        });
        return;
      }
      html = page.html;
    }

    if (fromDevice && input.forTrip && input.openedUrl && stay.startDate) {
      // Whether the page was open for the trip's dates; only that, never the address itself.
      const [y, m, d] = stay.startDate.split("-");
      const dated = input.openedUrl.includes(stay.startDate) || input.openedUrl.includes(`${d}-${m}-${y}`);
      console.info(`import ${input.link.platform}/${input.link.externalId}: opened address ${dated ? "carries" : "does not carry"} the trip's arrival date`);
    }
    if (fromDevice && looksBlocked(200, html)) {
      // The platform showed the device a "bot or human?" check instead of the advert. Nothing of it is the property's.
      console.warn(`import ${input.link.platform}/${input.link.externalId}: device sent a security check page (${html.length} bytes), nothing taken over`);
      return;
    }
    const blocks = extractBlocks(html);
    // Shape of what arrived, for diagnosis; never content.
    console.info(
      `import ${input.link.platform}/${input.link.externalId}${secondary ? " (further source)" : ""}: ${fromDevice ? "device" : "server"} html ${html.length} bytes, json-ld ${blocks.jsonLd.length}, state [${Object.keys(blocks.state).join(",")}], text ${blocks.text.length}, photos ${blocks.photos.length}, reviews ${blocks.reviews.length}, captured ${blocks.captured.total} marked ${blocks.captured.marked}, review blocks ${blocks.capturedReviews.length}`,
    );
    const { profile: baseline, provenance } = profileFromBlocks(blocks, input.link.kind);
    const { profile: extracted, note } = await deps.extractor({ blocks, link: input.link, baseline, ...(priceBelongsToTrip ? { requestedFor: stay } : {}) });

    const [current] = await db.select().from(listings).where(eq(listings.id, input.listingId)).limit(1);
    const before = current?.profile ?? emptyProfile(input.link.kind);
    const readBefore = sources.find((x) => x.id === input.sourceId)?.extract != null && Boolean(before.title) && !SECURITY_CHECK_TITLE.test(before.title ?? "");
    const checkOnly = !secondary && fromDevice && priceBelongsToTrip && readBefore;
    let profile: Profile;
    // The price this source showed. For the leading source it is the profile's own.
    let price: Profile["price"];
    if (secondary) {
      // Fill gaps only. Name, text, hints, pictures and price stay those of the advert that was shared.
      const { title: _t, summary: _s, highlights: _h, warnings: _w, price: _p, reviews: _r, reviewSummary: _rs, uncertain: _u, coverImageUrl: _c, ...facts } = extracted;
      profile = mergeProfiles(before, before.photos.length ? { ...facts, photos: [] } : facts);
      price = structuredClone(extracted.price);
    } else if (checkOnly) {
      // A look at price and availability for the trip. The page may show less, or something else, than the
      // full reading did; name, text, pictures and facts stay as they are.
      profile = structuredClone(before);
      profile.price = mergeProfiles(before, extracted, true).price;
      price = profile.price;
    } else {
      // What was read from the page replaces what was only seeded from the link.
      profile = mergeProfiles(before, extracted, true);
      // How many pictures a reading brings depends on how far the gallery was opened on the device.
      // A thinner reading must not shrink what an earlier one collected.
      if (before.photos.length > profile.photos.length) {
        console.info(`import ${input.link.platform}/${input.link.externalId}: kept ${before.photos.length} earlier photos over ${profile.photos.length} new ones`);
        profile.photos = before.photos;
        profile.coverImageUrl = before.coverImageUrl ?? profile.coverImageUrl;
      }
      price = profile.price;
    }
    if (priceBelongsToTrip) {
      // Only what this very page showed is the trip's price. An amount an earlier reading or the shared
      // link left behind is for other dates and must not be carried over under the trip's.
      // A general "from" price is no price for the trip's dates.
      price.totalEur = fromDevice && extracted.price.kind === "from" ? null : extracted.price.totalEur;
      price.kind = fromDevice && extracted.price.kind === "from" ? null : extracted.price.kind;
      price.rangeMaxEur = extracted.price.rangeMaxEur;
      // The page was asked for the trip's dates and party, so whatever price it showed belongs to those,
      // not to what the sharer had selected in the link.
      price.startDate = stay.startDate;
      price.endDate = stay.endDate;
      price.nights = nightsBetween(stay.startDate, stay.endDate);
      if (stay.adults !== null) price.persons = stay.adults + (stay.children ?? 0);
    }
    if (input.link.searchWindow && !fromDevice && !priceBelongsToTrip) {
      // Whatever was read, a window of possible dates is not a stay.
      price.startDate = null;
      price.endDate = null;
      price.nights = null;
    }
    price.nights ??= nightsBetween(price.startDate, price.endDate);
    // What this reading said about availability counts, also when it said nothing: an old "booked out" must not linger.
    price.available = extracted.price.available;
    // A stay that cannot be booked has no price; whatever figure the page still showed is for other dates.
    if (price.available === false) price.totalEur = null;
    if (!secondary && !checkOnly) {
      // Hints from the link itself (one guest only, contradictory dates) stay visible next to what the page showed.
      // Not when the page was read for the trip itself: then the sharer's guest count and dates are beside the point.
      const fromLink = priceBelongsToTrip ? before.warnings.filter((w) => !input.link.warnings.includes(w)) : before.warnings;
      profile.warnings = [...new Set([...extracted.warnings, ...fromLink])].slice(0, 5);
    }

    // A position outside the advert's own country is somebody else's: the visitor's, or the server's.
    if (profile.lat !== null && profile.lon !== null && !positionFitsCountry(profile.lat, profile.lon, profile.country)) {
      console.warn(`import ${input.link.platform}/${input.link.externalId}: position dropped, it lies outside ${profile.country}`);
      profile.lat = null;
      profile.lon = null;
      profile.uncertain = profile.uncertain.filter((u) => u !== "lat" && u !== "lon");
    }
    // These platforms show the neighbourhood, not the house, until someone has booked.
    if (!secondary && profile.lat !== null && APPROXIMATE_POSITION.has(input.link.platform)) profile.uncertain = [...new Set([...profile.uncertain, "lat", "lon"])];

    // Reviews are kept per source and put together anew each time, so reading one platform again
    // never loses what another one said.
    // A reading that brought no reviews (the server sees far less of some pages than the device) must not
    // wipe the ones an earlier reading of the same source found.
    const earlier = sources.find((s) => s.id === input.sourceId)?.extract;
    const own = {
      title: checkOnly ? (earlier?.title ?? extracted.title) : extracted.title,
      rating: checkOnly ? (earlier?.rating ?? extracted.rating) : extracted.rating,
      reviews: extracted.reviews.length ? extracted.reviews : (earlier?.reviews ?? []),
      // A summary resting on fewer reviews than the one before (a quick look at the page) does not replace it.
      reviewSummary:
        extracted.reviewSummary.summary && (extracted.reviewSummary.basedOn ?? 0) >= (earlier?.reviewSummary.summary ? (earlier.reviewSummary.basedOn ?? 0) : 0)
          ? extracted.reviewSummary
          : (earlier?.reviewSummary ?? extracted.reviewSummary),
    };
    const perSource = sources.map((s, i) => {
      if (s.id === input.sourceId) return { platform: s.platform, extract: own };
      if (s.extract) return { platform: s.platform, extract: s.extract };
      // Read before sources kept their own share: what the profile holds belongs to the leading source.
      return { platform: s.platform, extract: i === 0 ? { title: before.title, rating: before.rating, reviews: before.reviews.filter((r) => !r.platform || r.platform === s.platform), reviewSummary: before.reviewSummary } : null };
    });
    profile.reviews = perSource.flatMap((s) => (s.extract?.reviews ?? []).map((r) => ({ ...r, platform: s.platform }))).slice(0, 400);
    const told = perSource.filter((s) => s.extract?.reviewSummary.summary || s.extract?.reviews.length);
    const leading = perSource[0]?.extract?.reviewSummary;
    profile.reviewSummary = leading?.summary ? leading : (told[0]?.extract?.reviewSummary ?? profile.reviewSummary);
    if (told.length > 1 && deps.summarizer) {
      const overall = await deps.summarizer(told.map((s) => ({ platform: s.platform, rating: s.extract!.rating, summary: s.extract!.reviewSummary, reviews: s.extract!.reviews }))).catch((err: unknown) => {
        console.warn(`reviews: no joint summary for ${input.link.platform}/${input.link.externalId}: ${err instanceof Error ? err.name : "error"}`);
        return null;
      });
      if (overall?.summary) profile.reviewSummary = overall;
    }

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
      .set({ extract: own, provenance: { ...provenance, stay: "Link", details: fromDevice ? "Auf dem Gerät ausgelesen" : "Abruf vom Server" }, ...(fromDevice ? { fetchNote: "device" } : {}) })
      .where(eq(listingSources.id, input.sourceId));

    // A price belongs to the trip only if it is for one of the trip's periods. A price that merely
    // came along with a shared link for other dates stays unassigned, even when the device sent the page.
    const options = await db.select().from(dateOptions).where(eq(dateOptions.tripId, input.tripId));
    const forTrip = priceBelongsToTrip || options.some((o) => o.startDate === price.startDate && o.endDate === price.endDate);
    const totalCents = price.totalEur !== null ? Math.round(price.totalEur * 100) : null;
    const [latest] = await db.select().from(priceSnapshots).where(eq(priceSnapshots.listingSourceId, input.sourceId)).orderBy(desc(priceSnapshots.capturedAt)).limit(1);
    const unchanged =
      latest !== undefined &&
      latest.totalCents === totalCents &&
      latest.startDate === price.startDate &&
      latest.endDate === price.endDate &&
      latest.kind === (price.kind ?? "total") &&
      latest.available === price.available &&
      (latest.tripId === input.tripId) === forTrip;
    // Reading the same price again is not a new observation.
    // A look for the trip that found neither price nor answer is recorded too, so the list can say that the last look came back empty.
    if ((totalCents !== null || price.available === false || priceBelongsToTrip) && !unchanged) {
      await db.insert(priceSnapshots).values({
        listingSourceId: input.sourceId,
        tripId: forTrip ? input.tripId : null,
        startDate: price.startDate,
        endDate: price.endDate,
        nights: price.nights,
        persons: price.persons,
        totalCents,
        rangeMaxCents: price.rangeMaxEur !== null ? Math.round(price.rangeMaxEur * 100) : null,
        kind: price.kind ?? "total",
        available: price.available,
        breakdown: price.extraCosts.map((c) => ({ item: c.item, amountCents: c.amountEur !== null ? Math.round(c.amountEur * 100) : null })),
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
    if (secondary) await db.update(listingSources).set({ fetchNote: "failed" }).where(eq(listingSources.id, input.sourceId));
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
