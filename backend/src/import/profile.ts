import { z } from "zod";

/**
 * The standardised listing profile ("Steckbrief"). Every offer, whatever the
 * platform, is translated into this shape. A value of null means "not known";
 * nothing is ever guessed.
 */

const nstr = z.string().nullable().default(null);
const nnum = z.number().nullable().default(null);
const nbool = z.boolean().nullable().default(null);

export const listingKinds = ["vacation_home", "hotel", "package"] as const;
export type ListingKind = (typeof listingKinds)[number];

export const amenityKeys = [
  "pool",
  "poolHeated",
  "airConditioning",
  "wifi",
  "dishwasher",
  "washingMachine",
  "grill",
  "fireplace",
  "sauna",
  "hotTub",
  "parking",
  "evCharger",
  "seaView",
  "cot",
  "highChair",
  "fenced",
  "petsAllowed",
] as const;

const amenities = z
  .object(Object.fromEntries(amenityKeys.map((k) => [k, nbool])) as Record<(typeof amenityKeys)[number], typeof nbool>)
  .default({});

export const profileSchema = z.object({
  kind: z.enum(listingKinds).default("vacation_home"),
  title: nstr,
  objectType: nstr,
  place: nstr,
  region: nstr,
  country: nstr,
  lat: nnum,
  lon: nnum,

  maxGuests: nnum,
  bedrooms: nnum,
  beds: nnum,
  /** Sleeping places counted separately from beds: a sofa bed is a place, not a bedroom bed. */
  sleepingPlaces: nnum,
  bedDetails: z.array(z.object({ room: z.string(), beds: z.string() })).default([]),
  bathrooms: nnum,
  livingAreaSqm: nnum,
  plotSqm: nnum,
  yearBuilt: nnum,

  amenities,
  poolType: nstr,
  otherAmenities: z.array(z.string()).default([]),

  distances: z
    .object({
      beachM: nnum,
      seaM: nnum,
      townM: nnum,
      shopM: nnum,
      restaurantM: nnum,
      airportKm: nnum,
    })
    .default({}),

  rating: z.object({ value: nnum, scale: nnum, count: nnum }).default({}),

  rules: z
    .object({
      checkInFrom: nstr,
      checkOutUntil: nstr,
      minNights: nnum,
      arrivalDays: nstr,
      smoking: nstr,
    })
    .default({}),

  price: z
    .object({
      startDate: nstr,
      endDate: nstr,
      nights: nnum,
      persons: nnum,
      totalEur: nnum,
      kind: z.enum(["total", "from", "range"]).nullable().default(null),
      rangeMaxEur: nnum,
      included: z.array(z.string()).default([]),
      extraCosts: z.array(z.object({ item: z.string(), amountEur: z.number().nullable(), note: nstr })).default([]),
      depositEur: nnum,
    })
    .default({}),

  cancellation: nstr,

  /** Only filled for hotels and package holidays. */
  packageTrip: z
    .object({
      hotelStars: nnum,
      board: nstr,
      roomType: nstr,
      departureAirport: nstr,
      durationDays: nnum,
      transferIncluded: nbool,
      tourOperator: nstr,
    })
    .default({}),

  photoCount: nnum,
  coverImageUrl: nstr,
  summary: nstr,
  highlights: z.array(z.string()).default([]),
  warnings: z.array(z.string()).default([]),

  /** Dotted field paths whose value was derived from free text or is otherwise unsure. */
  uncertain: z.array(z.string()).default([]),
});

export type Profile = z.infer<typeof profileSchema>;

export function emptyProfile(kind: ListingKind = "vacation_home"): Profile {
  return profileSchema.parse({ kind });
}

/** Fields that make sense for a given kind, used for the fill percentage. */
function relevantPaths(kind: ListingKind): string[] {
  const common = [
    "title",
    "objectType",
    "place",
    "region",
    "country",
    "lat",
    "lon",
    "distances.beachM",
    "distances.townM",
    "distances.airportKm",
    "rating.value",
    "rating.count",
    "price.startDate",
    "price.endDate",
    "price.persons",
    "price.totalEur",
    "cancellation",
    "photoCount",
    "coverImageUrl",
    "summary",
    "amenities.pool",
    "amenities.airConditioning",
    "amenities.wifi",
    "amenities.parking",
  ];
  if (kind === "vacation_home") {
    return [
      ...common,
      "maxGuests",
      "bedrooms",
      "beds",
      "sleepingPlaces",
      "bathrooms",
      "livingAreaSqm",
      "amenities.dishwasher",
      "amenities.washingMachine",
      "amenities.grill",
      "amenities.seaView",
      "amenities.cot",
      "amenities.petsAllowed",
      "distances.shopM",
      "distances.restaurantM",
      "rules.checkInFrom",
      "rules.checkOutUntil",
      "price.depositEur",
    ];
  }
  return [
    ...common,
    "packageTrip.hotelStars",
    "packageTrip.board",
    "packageTrip.roomType",
    ...(kind === "package"
      ? ["packageTrip.departureAirport", "packageTrip.durationDays", "packageTrip.transferIncluded", "packageTrip.tourOperator"]
      : []),
  ];
}

export function getPath(obj: unknown, path: string): unknown {
  return path.split(".").reduce<unknown>((o, k) => (o && typeof o === "object" ? (o as Record<string, unknown>)[k] : undefined), obj);
}

export function fillPercent(profile: Profile): number {
  const paths = relevantPaths(profile.kind);
  const filled = paths.filter((p) => {
    const v = getPath(profile, p);
    return v !== null && v !== undefined && v !== "";
  }).length;
  return Math.round((filled / paths.length) * 100);
}

/**
 * Merge profiles: later sources only fill gaps or override when they are the
 * more trustworthy source (`override`). Arrays are replaced when non-empty.
 */
export function mergeProfiles(base: Profile, incoming: Partial<Profile>, override = false): Profile {
  const merge = (a: unknown, b: unknown): unknown => {
    if (b === null || b === undefined) return a;
    if (Array.isArray(b)) return b.length > 0 && (override || !Array.isArray(a) || a.length === 0) ? b : a;
    if (typeof b === "object") {
      const out: Record<string, unknown> = { ...((a as Record<string, unknown>) ?? {}) };
      for (const [k, v] of Object.entries(b as Record<string, unknown>)) out[k] = merge(out[k], v);
      return out;
    }
    if (a === null || a === undefined || a === "") return b;
    return override ? b : a;
  };
  const merged = merge(base, incoming) as Profile;
  merged.uncertain = [...new Set([...(base.uncertain ?? []), ...(incoming.uncertain ?? [])])];
  return profileSchema.parse(merged);
}
