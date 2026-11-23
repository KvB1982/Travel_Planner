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

export const tripPhases = ["framing", "research", "decision", "booking", "preparation", "travelling", "review", "archived"] as const;
export type TripPhase = (typeof tripPhases)[number];

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

export const trips = pgTable(
  "trips",
  {
  id: id(),
  /** "watchlist" is one person's own shelf for adverts that belong to no trip yet. */
  kind: text("kind").$type<"trip" | "watchlist">().notNull().default("trip"),
  title: text("title").notNull(),
  region: text("region"),
  adults: integer("adults").notNull().default(2),
  children: integer("children").notNull().default(0),
  pets: integer("pets").notNull().default(0),
  budgetTotalCents: integer("budget_total_cents"),
  status: tripStatus("status").notNull().default("planning"),
  /** What the status was before the trip went into the archive, so that it comes back as it was. */
  archivedFrom: text("archived_from").$type<"planning" | "decided" | "booked">(),
  /** Where the trip stands in its course. Finer than `status`, which older queries still read. */
  phase: text("phase").$type<TripPhase>().notNull().default("research"),
  /** The advert and the period the group settled on. Plain ids: the rows may go, the decision is history. */
  decidedCandidateId: uuid("decided_candidate_id"),
  decidedDateOptionId: uuid("decided_date_option_id"),
  decidedAt: timestamp("decided_at", { withTimezone: true }),
  /** How shared costs are split unless an expense says otherwise, and what a child counts when heads are counted. */
  splitMode: text("split_mode").$type<"equal" | "heads">().notNull().default("equal"),
  childWeight: doublePrecision("child_weight").notNull().default(1),
  voteDeadline: timestamp("vote_deadline", { withTimezone: true }),
  /**
   * When the dates are not fixed: the earliest day to arrive, the latest to leave, and how many nights it may be.
   * Any stay inside counts as one for this trip, so each advert can be looked at for the dates it is free.
   */
  flexStart: date("flex_start"),
  flexEnd: date("flex_end"),
  nightsMin: integer("nights_min"),
  nightsMax: integer("nights_max"),
  /** The group this trip belongs to; its members are members of the trip. Plain id, the table comes further down. */
  groupId: uuid("group_id"),
  createdBy: uuid("created_by")
    .notNull()
    .references(() => users.id),
  createdAt: createdAt(),
  },
  (t) => [
    // One shelf of one's own per person, and one shared shelf per group.
    uniqueIndex("trips_watchlist_owner_idx").on(t.createdBy).where(sql`${t.kind} = 'watchlist' and ${t.groupId} is null`),
    uniqueIndex("trips_watchlist_group_idx").on(t.groupId).where(sql`${t.kind} = 'watchlist'`),
  ],
);

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
  /** An invite leads to one trip or into a group, never both. */
  tripId: uuid("trip_id").references(() => trips.id, { onDelete: "cascade" }),
  groupId: uuid("group_id"),
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

/** What the group asks of an advert: must-haves and wishes, measured against the profile where possible. */
export const tripCriteria = pgTable(
  "trip_criteria",
  {
    id: id(),
    tripId: uuid("trip_id")
      .notNull()
      .references(() => trips.id, { onDelete: "cascade" }),
    key: text("key").notNull(),
    label: text("label"),
    level: text("level").$type<"must" | "wish">().notNull().default("wish"),
    target: doublePrecision("target"),
    position: integer("position").notNull().default(0),
    createdAt: createdAt(),
  },
  (t) => [index("trip_criteria_trip_idx").on(t.tripId, t.position)],
);

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
export interface SourceExtract {
  title: string | null;
  rating: Profile["rating"];
  reviews: Profile["reviews"];
  reviewSummary: Profile["reviewSummary"];
}

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
    /** What this source alone said, kept so that several sources of one advert can be put together again. */
    extract: jsonb("extract").$type<SourceExtract>(),
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
    /** Chosen for the pitch: one of the few the group decides between. */
    finalist: boolean("finalist").notNull().default(false),
    /** What somebody judged by hand against the trip's criteria, by criterion id. */
    criteriaChecks: jsonb("criteria_checks").$type<Record<string, "met" | "missed">>().notNull().default({}),
    /** Looking for the same property on other platforms: idle, running, done or failed. */
    searchStatus: text("search_status").$type<"idle" | "running" | "done" | "failed">().notNull().default("idle"),
    searchedAt: timestamp("searched_at", { withTimezone: true }),
    searchNote: text("search_note"),
    createdAt: createdAt(),
  },
  (t) => [uniqueIndex("trip_listings_trip_listing_idx").on(t.tripId, t.listingId)],
);

/** A page on another platform that may show the same property. Someone has to confirm it. */
export const sourceSuggestions = pgTable(
  "source_suggestions",
  {
    id: id(),
    tripListingId: uuid("trip_listing_id")
      .notNull()
      .references(() => tripListings.id, { onDelete: "cascade" }),
    url: text("url").notNull(),
    platform: text("platform").notNull(),
    title: text("title"),
    reason: text("reason"),
    confidence: text("confidence").$type<"high" | "medium" | "low">().notNull().default("medium"),
    status: text("status").$type<"proposed" | "accepted" | "rejected">().notNull().default("proposed"),
    createdAt: createdAt(),
  },
  (t) => [uniqueIndex("source_suggestions_candidate_url_idx").on(t.tripListingId, t.url)],
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
    /** When a later reading last found the very same again. The row itself stays the first sighting. */
    confirmedAt: timestamp("confirmed_at", { withTimezone: true }),
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

/** How often a person has set the language model to work on a day, so a stolen login cannot burn through the credit. */
export const aiUsage = pgTable(
  "ai_usage",
  {
    userId: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    day: date("day").notNull(),
    kind: text("kind").$type<"reading" | "search">().notNull(),
    count: integer("count").notNull().default(0),
  },
  (t) => [primaryKey({ columns: [t.userId, t.day, t.kind] })],
);

/** One person's order of the finalists, best first. Points follow from the place in it. */
export const tripRankings = pgTable(
  "trip_rankings",
  {
    tripId: uuid("trip_id")
      .notNull()
      .references(() => trips.id, { onDelete: "cascade" }),
    userId: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    order: jsonb("order").$type<string[]>().notNull().default([]),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [primaryKey({ columns: [t.tripId, t.userId] })],
);

/** A household travelling along: the unit costs are shared between. It may include people without the app. */
export const tripParties = pgTable(
  "trip_parties",
  {
    id: id(),
    tripId: uuid("trip_id")
      .notNull()
      .references(() => trips.id, { onDelete: "cascade" }),
    name: text("name").notNull(),
    adults: integer("adults").notNull().default(2),
    children: integer("children").notNull().default(0),
    /** The members of the trip who belong to this household. */
    memberIds: jsonb("member_ids").$type<string[]>().notNull().default([]),
    position: integer("position").notNull().default(0),
    createdAt: createdAt(),
  },
  (t) => [index("trip_parties_trip_idx").on(t.tripId, t.position)],
);

export const expenses = pgTable(
  "expenses",
  {
    id: id(),
    tripId: uuid("trip_id")
      .notNull()
      .references(() => trips.id, { onDelete: "cascade" }),
    title: text("title").notNull(),
    amountCents: integer("amount_cents").notNull(),
    category: text("category"),
    spentOn: date("spent_on"),
    paidBy: uuid("paid_by").notNull(),
    mode: text("mode").$type<"equal" | "heads" | "custom">(),
    among: jsonb("among").$type<string[]>().notNull().default([]),
    weights: jsonb("weights").$type<Record<string, number>>().notNull().default({}),
    note: text("note"),
    createdBy: uuid("created_by").references(() => users.id, { onDelete: "set null" }),
    /** Given by the device, so that an entry written offline and sent twice is kept once. */
    clientId: uuid("client_id"),
    createdAt: createdAt(),
  },
  (t) => [uniqueIndex("expenses_client_idx").on(t.tripId, t.clientId), index("expenses_trip_idx").on(t.tripId, t.createdAt)],
);

/** Money that has changed hands to even things out. */
export const settlementPayments = pgTable(
  "settlement_payments",
  {
    id: id(),
    tripId: uuid("trip_id")
      .notNull()
      .references(() => trips.id, { onDelete: "cascade" }),
    fromParty: uuid("from_party").notNull(),
    toParty: uuid("to_party").notNull(),
    amountCents: integer("amount_cents").notNull(),
    createdBy: uuid("created_by").references(() => users.id, { onDelete: "set null" }),
    createdAt: createdAt(),
  },
  (t) => [index("settlement_payments_trip_idx").on(t.tripId)],
);

export const bookingKinds = ["accommodation", "flight", "car", "ferry", "train", "insurance", "activity", "other"] as const;

/** Something fixed for the trip: the house, a flight, a hire car. The app records it, it does not book. */
export const bookings = pgTable(
  "bookings",
  {
    id: id(),
    tripId: uuid("trip_id")
      .notNull()
      .references(() => trips.id, { onDelete: "cascade" }),
    kind: text("kind").$type<(typeof bookingKinds)[number]>().notNull().default("accommodation"),
    title: text("title").notNull(),
    provider: text("provider"),
    reference: text("reference"),
    /** The advert this booking came from, for the house the group decided on. */
    candidateId: uuid("candidate_id"),
    status: text("status").$type<"planned" | "booked" | "cancelled">().notNull().default("planned"),
    /** Local date and time as written on the confirmation, for example 2027-05-15T16:00. */
    startsAt: text("starts_at"),
    endsAt: text("ends_at"),
    place: text("place"),
    totalCents: integer("total_cents"),
    depositCents: integer("deposit_cents"),
    depositReturnedOn: date("deposit_returned_on"),
    freeCancellationUntil: date("free_cancellation_until"),
    bookedByParty: uuid("booked_by_party"),
    notes: text("notes"),
    createdBy: uuid("created_by").references(() => users.id, { onDelete: "set null" }),
    createdAt: createdAt(),
  },
  (t) => [index("bookings_trip_idx").on(t.tripId)],
);

/** One instalment of a booking: deposit, balance, security deposit. */
export const bookingPayments = pgTable(
  "booking_payments",
  {
    id: id(),
    bookingId: uuid("booking_id")
      .notNull()
      .references(() => bookings.id, { onDelete: "cascade" }),
    label: text("label").notNull(),
    amountCents: integer("amount_cents").notNull(),
    dueOn: date("due_on"),
    paidOn: date("paid_on"),
    paidByParty: uuid("paid_by_party"),
    /** A security deposit comes back; it is not a cost to share. */
    refundable: boolean("refundable").notNull().default(false),
    createdAt: createdAt(),
  },
  (t) => [index("booking_payments_booking_idx").on(t.bookingId)],
);

/** A confirmation, ticket or contract kept with the trip. The file itself lies in the server's file store. */
export const documents = pgTable(
  "documents",
  {
    id: id(),
    tripId: uuid("trip_id")
      .notNull()
      .references(() => trips.id, { onDelete: "cascade" }),
    bookingId: uuid("booking_id").references(() => bookings.id, { onDelete: "set null" }),
    title: text("title").notNull(),
    kind: text("kind"),
    contentType: text("content_type").notNull(),
    sizeBytes: integer("size_bytes").notNull(),
    storedName: text("stored_name").notNull(),
    uploadedBy: uuid("uploaded_by").references(() => users.id, { onDelete: "set null" }),
    createdAt: createdAt(),
  },
  (t) => [index("documents_trip_idx").on(t.tripId)],
);

/** A line on one of the trip's lists: packing, shopping, things to do. */
export const checklistItems = pgTable(
  "checklist_items",
  {
    id: id(),
    tripId: uuid("trip_id")
      .notNull()
      .references(() => trips.id, { onDelete: "cascade" }),
    list: text("list").notNull().default("packing"),
    title: text("title").notNull(),
    quantity: text("quantity"),
    /** Who takes care of it, as a member or as a household. */
    assignedTo: uuid("assigned_to"),
    assignedParty: uuid("assigned_party"),
    dueOn: date("due_on"),
    done: boolean("done").notNull().default(false),
    doneBy: uuid("done_by"),
    doneAt: timestamp("done_at", { withTimezone: true }),
    /** Only its author sees it: a personal packing list. */
    private: boolean("private").notNull().default(false),
    position: integer("position").notNull().default(0),
    createdBy: uuid("created_by").references(() => users.id, { onDelete: "set null" }),
    /** Given by the device, so that an entry written offline and sent twice is kept once. */
    clientId: uuid("client_id"),
    createdAt: createdAt(),
  },
  (t) => [uniqueIndex("checklist_items_client_idx").on(t.tripId, t.clientId), index("checklist_items_trip_idx").on(t.tripId, t.list, t.position)],
);

/** How one household gets there: a drive with stops, a flight, a train. */
export const travelLegs = pgTable(
  "travel_legs",
  {
    id: id(),
    tripId: uuid("trip_id")
      .notNull()
      .references(() => trips.id, { onDelete: "cascade" }),
    partyId: uuid("party_id"),
    direction: text("direction").$type<"outbound" | "return" | "during">().notNull().default("outbound"),
    mode: text("mode").$type<"car" | "flight" | "train" | "ferry" | "bus" | "other">().notNull().default("car"),
    fromPlace: text("from_place"),
    toPlace: text("to_place"),
    departAt: text("depart_at"),
    arriveAt: text("arrive_at"),
    /** Stops on the way: a night halfway, a charging stop, a ferry port. */
    stops: jsonb("stops").$type<{ place: string; note: string | null }[]>().notNull().default([]),
    bookingId: uuid("booking_id"),
    notes: text("notes"),
    position: integer("position").notNull().default(0),
    createdAt: createdAt(),
  },
  (t) => [index("travel_legs_trip_idx").on(t.tripId, t.position)],
);

/** Who sleeps where. */
export const rooms = pgTable(
  "rooms",
  {
    id: id(),
    tripId: uuid("trip_id")
      .notNull()
      .references(() => trips.id, { onDelete: "cascade" }),
    name: text("name").notNull(),
    beds: text("beds"),
    partyId: uuid("party_id"),
    /** Names as the group writes them; not everyone travelling has an account. */
    occupants: jsonb("occupants").$type<string[]>().notNull().default([]),
    notes: text("notes"),
    position: integer("position").notNull().default(0),
    createdAt: createdAt(),
  },
  (t) => [index("rooms_trip_idx").on(t.tripId, t.position)],
);

/** Something to do on the trip: an idea first, then a date in the calendar. */
export const activities = pgTable(
  "activities",
  {
    id: id(),
    tripId: uuid("trip_id")
      .notNull()
      .references(() => trips.id, { onDelete: "cascade" }),
    title: text("title").notNull(),
    place: text("place"),
    url: text("url"),
    status: text("status").$type<"idea" | "planned" | "done" | "cancelled">().notNull().default("idea"),
    startsAt: text("starts_at"),
    endsAt: text("ends_at"),
    costCents: integer("cost_cents"),
    /** What the cost refers to, as the group needs it: per person, per family, in total. */
    costNote: text("cost_note"),
    bookingId: uuid("booking_id"),
    notes: text("notes"),
    createdBy: uuid("created_by").references(() => users.id, { onDelete: "set null" }),
    createdAt: createdAt(),
  },
  (t) => [index("activities_trip_idx").on(t.tripId, t.startsAt)],
);

export const activityResponses = pgTable(
  "activity_responses",
  {
    activityId: uuid("activity_id")
      .notNull()
      .references(() => activities.id, { onDelete: "cascade" }),
    userId: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    answer: verdict("answer").notNull(),
    updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [primaryKey({ columns: [t.activityId, t.userId] })],
);

/** What one needs at the house: how to get in, the WLAN, who to call. One per trip. */
export const houseInfo = pgTable("house_info", {
  tripId: uuid("trip_id")
    .primaryKey()
    .references(() => trips.id, { onDelete: "cascade" }),
  address: text("address"),
  lat: doublePrecision("lat"),
  lon: doublePrecision("lon"),
  checkInFrom: text("check_in_from"),
  checkOutUntil: text("check_out_until"),
  keyInfo: text("key_info"),
  wifiName: text("wifi_name"),
  wifiPassword: text("wifi_password"),
  contactName: text("contact_name"),
  contactPhone: text("contact_phone"),
  rules: text("rules"),
  waste: text("waste"),
  emergency: text("emergency"),
  notes: text("notes"),
  updatedBy: uuid("updated_by").references(() => users.id, { onDelete: "set null" }),
  updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
});

/** People who travel together again and again. Every trip of the group is open to all of them. */
export const groups = pgTable("groups", {
  id: id(),
  name: text("name").notNull(),
  createdBy: uuid("created_by").references(() => users.id, { onDelete: "set null" }),
  createdAt: createdAt(),
});

export const groupMembers = pgTable(
  "group_members",
  {
    groupId: uuid("group_id")
      .notNull()
      .references(() => groups.id, { onDelete: "cascade" }),
    userId: uuid("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    role: text("role").$type<"admin" | "member">().notNull().default("member"),
    joinedAt: timestamp("joined_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [primaryKey({ columns: [t.groupId, t.userId] })],
);
