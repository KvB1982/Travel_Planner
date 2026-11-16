import { z } from "zod";
import { germanCountry } from "./country.js";

/**
 * The standardised listing profile ("Steckbrief"). Every offer, whatever the
 * platform, is translated into this shape. A value of null means "not known";
 * nothing is ever guessed.
 */

// Models answer a text field with a list or a yes/no now and then; that is no reason to lose the field.
const nstr = z
  .preprocess((v) => {
    if (Array.isArray(v) && v.every((x) => typeof x === "string" || typeof x === "number")) return v.length ? v.join(", ") : null;
    if (typeof v === "number") return String(v);
    return v;
  }, z.string().nullable())
  .default(null);
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
  .prefault({});

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
  // Models tend to write a line per room ("Schlafzimmer 1: 1 Doppelbett") instead of an object; both are taken.
  bedDetails: z
    .array(
      z.preprocess((v) => {
        if (typeof v === "string") {
          const i = v.indexOf(":");
          return i > 0 ? { room: v.slice(0, i).trim(), beds: v.slice(i + 1).trim() } : { room: "", beds: v.trim() };
        }
        if (v && typeof v === "object" && !Array.isArray(v)) {
          const o = v as Record<string, unknown>;
          const text = (x: unknown) => (Array.isArray(x) ? x.join(", ") : typeof x === "string" || typeof x === "number" ? String(x) : "");
          return { room: text(o.room ?? o.name ?? o.title ?? o.raum ?? o.zimmer), beds: text(o.beds ?? o.bed ?? o.description ?? o.betten ?? o.subtitle) };
        }
        return v;
      }, z.object({ room: z.string(), beds: z.string().min(1) })),
    )
    .default([]),
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
    .prefault({}),

  rating: z.object({ value: nnum, scale: nnum, count: nnum }).prefault({}),

  rules: z
    .object({
      checkInFrom: nstr,
      checkOutUntil: nstr,
      minNights: nnum,
      arrivalDays: nstr,
      // Models like to answer this one with yes or no.
      smoking: z.preprocess((v) => (v === true ? "erlaubt" : v === false ? "nicht erlaubt" : v), z.string().nullable()).default(null),
    })
    .prefault({}),

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
      extraCosts: z
        .array(
          // Models vary the shape of these entries; none of that should cost the group a cost item.
          z.preprocess((v) => {
            if (typeof v === "string") return { item: v, amountEur: null, note: null };
            if (!v || typeof v !== "object" || Array.isArray(v)) return v;
            const o = v as Record<string, unknown>;
            const item = o.item ?? o.name ?? o.label ?? o.title ?? o.description ?? o.position;
            const rawAmount = o.amountEur ?? o.amount ?? o.priceEur ?? o.price ?? o.eur ?? null;
            const parsed = typeof rawAmount === "string" ? Number(rawAmount.replace(/[^0-9,.-]/g, "").replace(/\.(?=\d{3}(\D|$))/g, "").replace(",", ".")) : rawAmount;
            const amountEur = typeof parsed === "number" && Number.isFinite(parsed) && !(typeof rawAmount === "string" && !/\d/.test(rawAmount)) ? parsed : null;
            const note = typeof o.note === "string" ? o.note : typeof rawAmount === "string" && amountEur === null ? rawAmount : null;
            return { item: typeof item === "string" ? item : item === undefined || item === null ? item : String(item), amountEur, note };
          }, z.object({ item: z.string(), amountEur: z.number().nullable(), note: nstr })),
        )
        .default([]),
      depositEur: nnum,
      /** Whether the page offered the stay for these dates and this party: true, false, or null when it did not say. */
      available: nbool,
    })
    .prefault({}),

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
    .prefault({}),

  photoCount: nnum,
  coverImageUrl: nstr,
  /** The advert's own pictures in page order, first is the cover. Read from page data, never by the model. */
  photos: z
    .array(
      z.object({
        id: z.string(),
        /** Full quality original. */
        url: z.string(),
        /** A smaller rendition where the platform's image service offers one. */
        thumbUrl: nstr.default(null),
        width: nnum.default(null),
        height: nnum.default(null),
        caption: nstr.default(null),
      }),
    )
    .max(120)
    .default([]),
  /** Single guest reviews as the page gave them. Read from page data, never written by the model. */
  reviews: z
    .array(
      z.object({
        id: z.string(),
        text: z.string(),
        title: nstr.default(null),
        rating: nnum.default(null),
        scale: nnum.default(null),
        date: nstr.default(null),
        author: nstr.default(null),
        /** Where the review was read. Empty on adverts read before several sources were possible. */
        platform: nstr.default(null),
      }),
    )
    .max(400)
    .default([]),
  /** What the reviews say, taken together. Written by the model from the reviews it was shown. */
  reviewSummary: z
    .object({
      summary: nstr.default(null),
      positives: z.array(z.string()).default([]),
      negatives: z.array(z.string()).default([]),
      /** How many single reviews the summary rests on. */
      basedOn: nnum.default(null),
    })
    .prefault({}),
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
  merged.country = germanCountry(merged.country);
  merged.uncertain = [...new Set([...(base.uncertain ?? []), ...(incoming.uncertain ?? [])])];
  return profileSchema.parse(merged);
}
