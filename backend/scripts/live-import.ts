/**
 * Runs the real import pipeline against real links, without a database server:
 *   npx tsx scripts/live-import.ts <url> [<url> ...]
 *   npx tsx scripts/live-import.ts @links.txt
 * Uses the Claude API when ANTHROPIC_API_KEY is set, otherwise structured data only.
 * Each link is fetched at most twice (short-link resolution plus the page).
 */
import { PGlite } from "@electric-sql/pglite";
import { drizzle } from "drizzle-orm/pglite";
import { migrate } from "drizzle-orm/pglite/migrator";
import { eq } from "drizzle-orm";
import { migrationsFolder, type Db } from "../src/db/client.js";
import * as schema from "../src/db/schema.js";
import { baselineExtractor, claudeExtractor } from "../src/import/extract.js";
import { fetchPage, type PageFetcher } from "../src/import/fetch.js";
import { processImport, startImport } from "../src/import/pipeline.js";

import { readFileSync } from "node:fs";

// "@links.txt" reads one link per line; that avoids shells mangling "&" and "%7C".
const urls = process.argv.slice(2).flatMap((arg) =>
  arg.startsWith("@") ? readFileSync(arg.slice(1), "utf8").split(/\r?\n/).map((l) => l.trim()).filter((l) => l && !l.startsWith("#")) : [arg],
);
if (urls.length === 0) {
  console.error("Usage: npx tsx scripts/live-import.ts <url> [<url> ...]");
  process.exit(1);
}

const db = drizzle(new PGlite(), { schema }) as unknown as Db;
await migrate(db as never, { migrationsFolder });

const key = process.env.ANTHROPIC_API_KEY;
const extractor = key ? claudeExtractor({ apiKey: key, model: process.env.EXTRACTION_MODEL ?? "claude-haiku-5-5" }) : baselineExtractor;

const [user] = await db.insert(schema.users).values({ name: "Test" }).returning();
const [trip] = await db.insert(schema.trips).values({ title: "Sommer 2027", adults: 4, children: 4, createdBy: user!.id }).returning();
await db.insert(schema.dateOptions).values({ tripId: trip!.id, startDate: "2027-08-21", endDate: "2027-08-28" });

const results: Record<string, unknown>[] = [];
for (const url of urls) {
  const fetches: { url: string; status: number; blocked: boolean; bytes: number }[] = [];
  const fetcher: PageFetcher = async (u) => {
    const page = await fetchPage(u);
    fetches.push({ url: page.finalUrl.slice(0, 120), status: page.status, blocked: page.blocked, bytes: page.html.length });
    return page;
  };
  const deps = { db, fetcher, extractor };
  const started = Date.now();
  try {
    const s = await startImport(deps, { tripId: trip!.id, userId: user!.id, url });
    await processImport(deps, { ...s, tripId: trip!.id, userId: user!.id }).catch((e) => console.error("processImport:", e instanceof Error ? e.message : e));
    const [candidate] = await db.select().from(schema.tripListings).where(eq(schema.tripListings.id, s.candidateId));
    const [listing] = await db.select().from(schema.listings).where(eq(schema.listings.id, s.listingId));
    const prices = await db.select().from(schema.priceSnapshots).where(eq(schema.priceSnapshots.listingSourceId, s.sourceId));
    const p = listing!.profile;
    results.push({
      input: url.slice(0, 80),
      platform: s.link.platform,
      externalId: s.link.externalId,
      kind: s.link.kind,
      duplicate: s.duplicate,
      linkStay: s.link.stay,
      linkWarnings: s.link.warnings,
      fetches,
      importStatus: candidate!.importStatus,
      importNote: candidate!.importNote,
      fillPercent: listing!.fillPercent,
      title: p.title,
      place: [p.place, p.region, p.country].filter(Boolean).join(", "),
      coordinates: p.lat !== null ? [p.lat, p.lon] : null,
      size: { maxGuests: p.maxGuests, bedrooms: p.bedrooms, beds: p.beds, sleepingPlaces: p.sleepingPlaces, bathrooms: p.bathrooms, livingAreaSqm: p.livingAreaSqm },
      amenitiesTrue: Object.entries(p.amenities).filter(([, v]) => v === true).map(([k]) => k),
      amenitiesFalse: Object.entries(p.amenities).filter(([, v]) => v === false).map(([k]) => k),
      otherAmenities: p.otherAmenities.length,
      rating: p.rating,
      rules: p.rules,
      price: p.price,
      packageTrip: s.link.kind === "vacation_home" ? undefined : p.packageTrip,
      photoCount: p.photoCount,
      hasCoverImage: Boolean(p.coverImageUrl),
      summary: p.summary,
      highlights: p.highlights,
      warnings: p.warnings,
      uncertain: p.uncertain,
      priceSnapshots: prices.map((x) => ({ totalCents: x.totalCents, kind: x.kind, nights: x.nights, persons: x.persons, capture: x.capture, forTrip: x.tripId !== null })),
      seconds: Math.round((Date.now() - started) / 100) / 10,
    });
  } catch (e) {
    results.push({ input: url.slice(0, 80), error: e instanceof Error ? `${e.name}: ${e.message}` : String(e), fetches });
  }
}
console.log(JSON.stringify({ extractor: key ? "claude" : "baseline", results }, null, 2));
