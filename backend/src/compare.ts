import { amenityKeys, type Profile } from "./import/profile.js";

/** What the comparison needs of a candidate: its list entry and its full profile. */
export interface Comparable {
  entry: {
    id: string;
    listing: { title: string | null };
    price: { totalCents: number | null; kind: string; nights: number | null; persons: number | null; forThisTrip: boolean } | null;
    votes: { yes: number; maybe: number; no: number; vetoes: number };
  };
  profile: Profile;
  hiddenWarnings: string[];
}

type Value = number | boolean | string | null;
type Better = "higher" | "lower" | "true" | null;

interface Criterion {
  key: string;
  label: string;
  group: "price" | "space" | "rating" | "location" | "amenities" | "rules" | "votes";
  /** How the app should print a value. */
  format: "eur" | "number" | "sqm" | "meters" | "km" | "rating" | "boolean" | "text";
  better: Better;
  value: (c: Comparable) => Value;
}

const AMENITY_LABELS: Record<(typeof amenityKeys)[number], string> = {
  pool: "Pool",
  poolHeated: "Pool beheizt",
  airConditioning: "Klimaanlage",
  wifi: "WLAN",
  dishwasher: "Spülmaschine",
  washingMachine: "Waschmaschine",
  grill: "Grill",
  fireplace: "Kamin",
  sauna: "Sauna",
  hotTub: "Whirlpool",
  parking: "Parkplatz",
  evCharger: "Wallbox",
  seaView: "Meerblick",
  cot: "Babybett",
  highChair: "Hochstuhl",
  fenced: "Eingezäunt",
  petsAllowed: "Haustiere erlaubt",
};

/** Only a price for this trip's dates and party can be set against another. */
const tripPrice = (c: Comparable) => {
  const p = c.entry.price;
  return p && p.forThisTrip && p.kind === "total" && p.totalCents !== null ? { ...p, totalCents: p.totalCents } : null;
};
const round = (n: number) => Math.round(n * 100) / 100;

const CRITERIA: Criterion[] = [
  { key: "price.total", label: "Gesamtpreis", group: "price", format: "eur", better: "lower", value: (c) => (tripPrice(c) ? tripPrice(c)!.totalCents / 100 : null) },
  {
    key: "price.perNight",
    label: "Preis pro Nacht",
    group: "price",
    format: "eur",
    better: "lower",
    value: (c) => {
      const p = tripPrice(c);
      return p?.nights ? round(p.totalCents / 100 / p.nights) : null;
    },
  },
  {
    key: "price.perPersonNight",
    label: "Preis pro Person und Nacht",
    group: "price",
    format: "eur",
    better: "lower",
    value: (c) => {
      const p = tripPrice(c);
      return p?.nights && p.persons ? round(p.totalCents / 100 / p.nights / p.persons) : null;
    },
  },
  { key: "price.deposit", label: "Kaution", group: "price", format: "eur", better: null, value: (c) => c.profile.price.depositEur },
  { key: "cancellation", label: "Stornierung", group: "price", format: "text", better: null, value: (c) => c.profile.cancellation },
  { key: "maxGuests", label: "Gäste", group: "space", format: "number", better: "higher", value: (c) => c.profile.maxGuests },
  { key: "bedrooms", label: "Schlafzimmer", group: "space", format: "number", better: "higher", value: (c) => c.profile.bedrooms },
  { key: "beds", label: "Betten", group: "space", format: "number", better: "higher", value: (c) => c.profile.beds },
  { key: "bathrooms", label: "Bäder", group: "space", format: "number", better: "higher", value: (c) => c.profile.bathrooms },
  { key: "livingAreaSqm", label: "Wohnfläche", group: "space", format: "sqm", better: "higher", value: (c) => c.profile.livingAreaSqm },
  { key: "plotSqm", label: "Grundstück", group: "space", format: "sqm", better: "higher", value: (c) => c.profile.plotSqm },
  {
    key: "rating",
    label: "Bewertung",
    group: "rating",
    format: "rating",
    better: "higher",
    // Platforms use different scales; everything is put on a scale of ten to be comparable.
    value: (c) => {
      const r = c.profile.rating;
      return r.value !== null && r.scale ? round((r.value / r.scale) * 10) : null;
    },
  },
  { key: "rating.count", label: "Anzahl Bewertungen", group: "rating", format: "number", better: "higher", value: (c) => c.profile.rating.count },
  { key: "distances.beachM", label: "Zum Strand", group: "location", format: "meters", better: "lower", value: (c) => c.profile.distances.beachM ?? c.profile.distances.seaM },
  { key: "distances.townM", label: "Zum Ort", group: "location", format: "meters", better: "lower", value: (c) => c.profile.distances.townM },
  { key: "distances.shopM", label: "Zum Einkaufen", group: "location", format: "meters", better: "lower", value: (c) => c.profile.distances.shopM },
  { key: "distances.restaurantM", label: "Zum Restaurant", group: "location", format: "meters", better: "lower", value: (c) => c.profile.distances.restaurantM },
  { key: "distances.airportKm", label: "Zum Flughafen", group: "location", format: "km", better: "lower", value: (c) => c.profile.distances.airportKm },
  ...amenityKeys.map(
    (k): Criterion => ({ key: `amenities.${k}`, label: AMENITY_LABELS[k], group: "amenities", format: "boolean", better: "true", value: (c) => c.profile.amenities[k] }),
  ),
  { key: "poolType", label: "Art des Pools", group: "amenities", format: "text", better: null, value: (c) => c.profile.poolType },
  { key: "rules.checkInFrom", label: "Anreise ab", group: "rules", format: "text", better: null, value: (c) => c.profile.rules.checkInFrom },
  { key: "rules.checkOutUntil", label: "Abreise bis", group: "rules", format: "text", better: null, value: (c) => c.profile.rules.checkOutUntil },
  { key: "rules.arrivalDays", label: "Anreisetage", group: "rules", format: "text", better: null, value: (c) => c.profile.rules.arrivalDays },
  { key: "packageTrip.hotelStars", label: "Hotelsterne", group: "rating", format: "number", better: "higher", value: (c) => c.profile.packageTrip.hotelStars },
  { key: "packageTrip.board", label: "Verpflegung", group: "rules", format: "text", better: null, value: (c) => c.profile.packageTrip.board },
  { key: "votes.yes", label: "Ja-Stimmen", group: "votes", format: "number", better: "higher", value: (c) => c.entry.votes.yes },
  { key: "votes.no", label: "Nein-Stimmen", group: "votes", format: "number", better: "lower", value: (c) => c.entry.votes.no },
  { key: "votes.vetoes", label: "Vetos", group: "votes", format: "number", better: "lower", value: (c) => c.entry.votes.vetoes },
];

/** The candidates that are ahead in a row: only when the values differ and at least two are known. */
function ahead(values: Value[], better: Better): number[] {
  if (!better) return [];
  const known = values.map((v, i) => ({ v, i })).filter((x) => x.v !== null);
  if (known.length < 2 || known.every((x) => x.v === known[0]!.v)) return [];
  if (better === "true") return known.filter((x) => x.v === true).map((x) => x.i);
  const nums = known.filter((x): x is { v: number; i: number } => typeof x.v === "number");
  const top = better === "higher" ? Math.max(...nums.map((x) => x.v)) : Math.min(...nums.map((x) => x.v));
  return nums.filter((x) => x.v === top).map((x) => x.i);
}

export function compare(chosen: Comparable[]) {
  const criteria = CRITERIA.map((c) => {
    const values = chosen.map(c.value);
    return { key: c.key, label: c.label, group: c.group, format: c.format, better: c.better, values, best: ahead(values, c.better).map((i) => chosen[i]!.entry.id) };
  })
    // A row nobody has a value for says nothing; for amenities, neither does one where no advert has it.
    .filter((row) => row.values.some((v) => v !== null) && (row.group !== "amenities" || row.values.some((v) => v !== false && v !== null)));

  return {
    candidates: chosen.map((c) => ({
      ...c.entry,
      // How often this advert is ahead, as a first orientation. Rows are not weighted.
      bestCount: criteria.filter((row) => row.best.includes(c.entry.id)).length,
      summary: c.profile.summary,
      highlights: c.profile.highlights,
      warnings: c.profile.warnings.filter((w) => !c.hiddenWarnings.includes(w)),
      reviewSummary: c.profile.reviewSummary.summary ? { summary: c.profile.reviewSummary.summary, positives: c.profile.reviewSummary.positives, negatives: c.profile.reviewSummary.negatives } : null,
    })),
    // `values` runs parallel to `candidates`.
    criteria,
  };
}
