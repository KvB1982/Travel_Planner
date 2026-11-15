import { sql } from "drizzle-orm";
import {
  boolean,
  date,
  doublePrecision,
  index,
  integer,
  jsonb,
  pgEnum,
  pgTable,
  primaryKey,
  text,
  timestamp,
  uniqueIndex,
  uuid,
} from "drizzle-orm/pg-core";
import type { Profile } from "../import/profile.js";

const id = () => uuid("id").primaryKey().default(sql`gen_random_uuid()`);
const createdAt = () => timestamp("created_at", { withTimezone: true }).notNull().defaultNow();

export const memberRole = pgEnum("member_role", ["organizer", "member", "guest"]);
export const tripStatus = pgEnum("trip_status", ["planning", "decided", "booked", "archived"]);
export const listingKind = pgEnum("listing_kind", ["vacation_home", "hotel", "package"]);
export const candidateStatus = pgEnum("candidate_status", ["new", "shortlist", "favorite", "rejected", "booked"]);
export const importStatus = pgEnum("import_status", ["pending", "ready", "partial", "failed"]);
export const verdict = pgEnum("verdict", ["yes", "maybe", "no"]);
export const priceKind = pgEnum("price_kind", ["total", "from", "range"]);
export const priceCapture = pgEnum("price_capture", ["manual", "import", "device", "auto"]);

export const households = pgTable("households", {
  id: id(),
  name: text("name").notNull(),
  homePlace: text("home_place"),
  federalState: text("federal_state"),
  createdAt: createdAt(),
});

export const users = pgTable("users", {
  id: id(),
  name: text("name").notNull(),
  email: text("email"),
  /** Subject from "Sign in with Apple", set once that login is wired up. */
  appleSub: text("apple_sub").unique(),
  householdId: uuid("household_id").references(() => households.id, { onDelete: "set null" }),
  createdAt: createdAt(),
});

export const sessions = pgTable(
  "sessions",
  {
    id: id(),
    userId: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    /** SHA-256 of the bearer token. The token itself is never stored. */
    tokenHash: text("token_hash").notNull().unique(),
    deviceName: text("device_name"),
    createdAt: createdAt(),
    lastUsedAt: timestamp("last_used_at", { withTimezone: true }),
    revokedAt: timestamp("revoked_at", { withTimezone: true }),
  },
  (t) => [index("sessions_user_idx").on(t.userId)],
);

export const trips = pgTable("trips", {
  id: id(),
  title: text("title").notNull(),
  region: text("region"),
  adults: integer("adults").notNull().default(2),
  children: integer("children").notNull().default(0),
  pets: integer("pets").notNull().default(0),
  budgetTotalCents: integer("budget_total_cents"),
  status: tripStatus("status").notNull().default("planning"),
  voteDeadline: timestamp("vote_deadline", { withTimezone: true }),
  createdBy: uuid("created_by")
    .notNull()
    .references(() => users.id),
  createdAt: createdAt(),
});

export const tripMembers = pgTable(
  "trip_members",
  {
    tripId: uuid("trip_id")
      .notNull()
      .references(() => trips.id, { onDelete: "cascade" }),
    userId: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    role: memberRole("role").notNull().default("member"),
    joinedAt: timestamp("joined_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [primaryKey({ columns: [t.tripId, t.userId] })],
);

export const invites = pgTable("invites", {
  id: id(),
  tripId: uuid("trip_id")
    .notNull()
    .references(() => trips.id, { onDelete: "cascade" }),
  tokenHash: text("token_hash").notNull().unique(),
  role: memberRole("role").notNull().default("member"),
  createdBy: uuid("created_by")
    .notNull()
    .references(() => users.id),
  expiresAt: timestamp("expires_at", { withTimezone: true }).notNull(),
  maxUses: integer("max_uses").notNull().default(1),
  usedCount: integer("used_count").notNull().default(0),
  createdAt: createdAt(),
});

export const dateOptions = pgTable(
  "date_options",
  {
    id: id(),
    tripId: uuid("trip_id")
      .notNull()
      .references(() => trips.id, { onDelete: "cascade" }),
    label: text("label"),
    startDate: date("start_date").notNull(),
    endDate: date("end_date").notNull(),
  },
  (t) => [index("date_options_trip_idx").on(t.tripId)],
);

/** The offer itself, independent of platform and of any trip. */
export const listings = pgTable("listings", {
  id: id(),
  kind: listingKind("kind").notNull().default("vacation_home"),
  title: text("title"),
  place: text("place"),
  country: text("country"),
  lat: doublePrecision("lat"),
  lon: doublePrecision("lon"),
  coverImageUrl: text("cover_image_url"),
  profile: jsonb("profile").$type<Profile>().notNull(),
  fillPercent: integer("fill_percent").notNull().default(0),
  createdAt: createdAt(),
  updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
});

/** One advert of a listing on one platform. The same house can have several. */
export const listingSources = pgTable(
  "listing_sources",
  {
    id: id(),
    listingId: uuid("listing_id")
      .notNull()
      .references(() => listings.id, { onDelete: "cascade" }),
    platform: text("platform").notNull(),
    externalId: text("external_id"),
    url: text("url").notNull(),
    canonicalUrl: text("canonical_url").notNull(),
    /** Where each group of fields came from, for transparency in the app. */
    provenance: jsonb("provenance").$type<Record<string, string>>().notNull().default({}),
    lastFetchedAt: timestamp("last_fetched_at", { withTimezone: true }),
    fetchNote: text("fetch_note"),
    createdAt: createdAt(),
  },
  (t) => [
    uniqueIndex("listing_sources_platform_external_idx").on(t.platform, t.externalId),
    index("listing_sources_listing_idx").on(t.listingId),
  ],
);

/** A listing as a candidate within one trip. */
export const tripListings = pgTable(
  "trip_listings",
  {
    id: id(),
    tripId: uuid("trip_id")
      .notNull()
      .references(() => trips.id, { onDelete: "cascade" }),
    listingId: uuid("listing_id")
      .notNull()
      .references(() => listings.id, { onDelete: "cascade" }),
    status: candidateStatus("status").notNull().default("new"),
    importStatus: importStatus("import_status").notNull().default("pending"),
    importNote: text("import_note"),
    addedBy: uuid("added_by")
      .notNull()
      .references(() => users.id),
    rejectionReason: text("rejection_reason"),
    notes: text("notes"),
    tags: jsonb("tags").$type<string[]>().notNull().default([]),
    /** Hints of the advert that this trip's members chose not to see, by their wording. */
    hiddenWarnings: jsonb("hidden_warnings").$type<string[]>().notNull().default([]),
    createdAt: createdAt(),
  },
  (t) => [uniqueIndex("trip_listings_trip_listing_idx").on(t.tripId, t.listingId)],
);

export const priceSnapshots = pgTable(
  "price_snapshots",
  {
    id: id(),
    listingSourceId: uuid("listing_source_id")
      .notNull()
      .references(() => listingSources.id, { onDelete: "cascade" }),
    tripId: uuid("trip_id").references(() => trips.id, { onDelete: "cascade" }),
    startDate: date("start_date"),
    endDate: date("end_date"),
    nights: integer("nights"),
    persons: integer("persons"),
    totalCents: integer("total_cents"),
    rangeMaxCents: integer("range_max_cents"),
    currency: text("currency").notNull().default("EUR"),
    kind: priceKind("kind").notNull().default("total"),
    breakdown: jsonb("breakdown").$type<{ item: string; amountCents: number | null }[]>().notNull().default([]),
    available: boolean("available"),
    capture: priceCapture("capture").notNull(),
    capturedBy: uuid("captured_by").references(() => users.id, { onDelete: "set null" }),
    capturedAt: timestamp("captured_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [index("price_snapshots_source_idx").on(t.listingSourceId, t.capturedAt)],
);

export const votes = pgTable(
  "votes",
  {
    tripListingId: uuid("trip_listing_id")
      .notNull()
      .references(() => tripListings.id, { onDelete: "cascade" }),
    userId: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    verdict: verdict("verdict").notNull(),
    veto: boolean("veto").notNull().default(false),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [primaryKey({ columns: [t.tripListingId, t.userId] })],
);

export const comments = pgTable(
  "comments",
  {
    id: id(),
    tripListingId: uuid("trip_listing_id")
      .notNull()
      .references(() => tripListings.id, { onDelete: "cascade" }),
    userId: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    body: text("body").notNull(),
    createdAt: createdAt(),
  },
  (t) => [index("comments_candidate_idx").on(t.tripListingId, t.createdAt)],
);

export const activityEvents = pgTable(
  "activity_events",
  {
    id: id(),
    tripId: uuid("trip_id")
      .notNull()
      .references(() => trips.id, { onDelete: "cascade" }),
    userId: uuid("user_id").references(() => users.id, { onDelete: "set null" }),
    type: text("type").notNull(),
    payload: jsonb("payload").$type<Record<string, unknown>>().notNull().default({}),
    createdAt: createdAt(),
  },
  (t) => [index("activity_trip_idx").on(t.tripId, t.createdAt)],
);
