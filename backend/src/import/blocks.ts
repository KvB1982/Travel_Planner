import { parse } from "node-html-parser";
import { amenityKeys, emptyProfile, type ListingKind, type Profile } from "./profile.js";

/** The machine-readable parts of a listing page, plus its visible text. */
export interface PageBlocks {
  title: string | null;
  og: Record<string, string>;
  jsonLd: Record<string, unknown>[];
  /** Platform state objects such as __NEXT_DATA__, already pruned. */
  state: Record<string, unknown>;
  text: string;
}

const DROP_KEYS = /^(images?|photos?|pictures?|media|gallery|reviews?|breadcrumbs?|seo|translations?|i18n|tracking|analytics|footer|header|navigation|menu)$/i;

/** Shrink a state object to what describes the property: no image lists, no review bodies, no giant arrays. */
export function prune(value: unknown, depth = 0): unknown {
  if (value === null || value === undefined) return undefined;
  if (typeof value === "string") {
    if (/^https?:\/\/\S+\.(jpe?g|png|webp|avif|gif|svg)(\?\S*)?$/i.test(value)) return undefined;
    return value.length > 600 ? `${value.slice(0, 600)}…` : value;
  }
  if (typeof value !== "object") return value;
  if (depth > 12) return undefined;
  if (Array.isArray(value)) {
    const items = value.slice(0, 40).map((v) => prune(v, depth + 1)).filter((v) => v !== undefined);
    return items.length ? items : undefined;
  }
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(value)) {
    if (DROP_KEYS.test(k)) continue;
    const p = prune(v, depth + 1);
    if (p !== undefined) out[k] = p;
  }
  return Object.keys(out).length ? out : undefined;
}

function safeJson(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}

function flattenJsonLd(node: unknown, out: Record<string, unknown>[]): void {
  if (Array.isArray(node)) node.forEach((n) => flattenJsonLd(n, out));
  else if (node && typeof node === "object") {
    const obj = node as Record<string, unknown>;
    if (Array.isArray(obj["@graph"])) flattenJsonLd(obj["@graph"], out);
    else out.push(obj);
  }
}

export function extractBlocks(html: string): PageBlocks {
  const root = parse(html, { comment: false, blockTextElements: { script: true, style: true, noscript: false } });

  const og: Record<string, string> = {};
  for (const meta of root.querySelectorAll("meta")) {
    const key = meta.getAttribute("property") ?? meta.getAttribute("name");
    const content = meta.getAttribute("content");
    if (key && content && /^(og:|twitter:|description$)/.test(key) && !(key in og)) og[key] = content;
  }

  const jsonLd: Record<string, unknown>[] = [];
  const state: Record<string, unknown> = {};
  for (const script of root.querySelectorAll("script")) {
    const type = script.getAttribute("type") ?? "";
    const id = script.getAttribute("id") ?? "";
    if (type === "application/ld+json") {
      flattenJsonLd(safeJson(script.rawText), jsonLd);
    } else if (id === "__NEXT_DATA__") {
      const data = safeJson(script.rawText) as { props?: { pageProps?: unknown } } | undefined;
      const pruned = prune(data?.props?.pageProps);
      if (pruned) state.nextData = pruned;
    } else if (id === "js-hotel-data" || (type === "application/json" && /hotel|listing|property|offer/i.test(id))) {
      const pruned = prune(safeJson(script.rawText));
      if (pruned) state[id] = pruned;
    }
  }

  root.querySelectorAll("script,style,noscript,svg,template,iframe").forEach((n) => n.remove());
  const text = root.structuredText.replace(/[ \t]+/g, " ").replace(/\n\s*\n+/g, "\n").trim();

  return { title: root.querySelector("title")?.text.trim() || null, og, jsonLd, state, text };
}

const LODGING_TYPES = /VacationRental|LodgingBusiness|Hotel|Resort|House|Apartment|Accommodation|BedAndBreakfast|Campground|Product/i;

function typeOf(node: Record<string, unknown>): string {
  const t = node["@type"];
  return Array.isArray(t) ? t.join(" ") : String(t ?? "");
}

const num = (v: unknown): number | null => {
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v === "string" && v.trim() !== "" && Number.isFinite(Number(v.replace(",", ".")))) return Number(v.replace(",", "."));
  if (v && typeof v === "object" && "value" in v) return num((v as { value: unknown }).value);
  return null;
};
const str = (v: unknown): string | null => (typeof v === "string" && v.trim() ? v.trim() : null);
const obj = (v: unknown): Record<string, unknown> => (v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : {});

const AMENITY_WORDS: [(typeof amenityKeys)[number], RegExp][] = [
  ["pool", /(?<!whirl)pool|schwimmbad|swimming/i],
  ["airConditioning", /klimaanlage|air.?condition/i],
  ["wifi", /wi-?fi|wlan|internet/i],
  ["dishwasher", /sp[üu]lmaschine|geschirrsp[üu]ler|dishwasher/i],
  ["washingMachine", /waschmaschine|washing machine|washer/i],
  ["grill", /grill|barbecue|bbq/i],
  ["fireplace", /kamin|fireplace/i],
  ["sauna", /sauna/i],
  ["hotTub", /whirlpool|hot tub|jacuzzi/i],
  ["parking", /parkplatz|parking|garage|stellplatz/i],
  ["evCharger", /wallbox|ladestation|ev charger/i],
  ["seaView", /meerblick|sea view|ocean view/i],
  ["cot", /kinderbett|babybett|\bcrib\b|\bcot\b/i],
  ["highChair", /hochstuhl|high ?chair/i],
];

/**
 * Everything that can be read without a language model. This is the baseline
 * when no API key is configured, and the trusted core the model output is
 * merged onto.
 */
export function profileFromBlocks(blocks: PageBlocks, kind: ListingKind): { profile: Profile; provenance: Record<string, string> } {
  const profile = emptyProfile(kind);
  const provenance: Record<string, string> = {};

  const lodging = blocks.jsonLd.filter((n) => LODGING_TYPES.test(typeOf(n)));
  const main = lodging.find((n) => !/Product/i.test(typeOf(n))) ?? lodging[0];

  if (main) {
    provenance.core = `JSON-LD ${typeOf(main)}`;
    profile.title = str(main.name);
    const geo = obj(main.geo);
    profile.lat = num(main.latitude ?? geo.latitude);
    profile.lon = num(main.longitude ?? geo.longitude);
    const address = obj(main.address);
    profile.place = str(address.addressLocality);
    profile.region = str(address.addressRegion);
    profile.country = str(address.addressCountry) ?? str(obj(address.addressCountry).name);

    const place = obj(Array.isArray(main.containsPlace) ? main.containsPlace[0] : main.containsPlace);
    profile.maxGuests = num(place.occupancy ?? main.occupancy);
    profile.bedrooms = num(place.numberOfBedrooms ?? main.numberOfBedrooms);
    profile.bathrooms = num(place.numberOfBathroomsTotal ?? main.numberOfBathroomsTotal);
    profile.livingAreaSqm = num(place.floorSize ?? main.floorSize);
    profile.rules.checkInFrom = str(main.checkinTime);
    profile.rules.checkOutUntil = str(main.checkoutTime);
    if (typeof main.petsAllowed === "boolean") profile.amenities.petsAllowed = main.petsAllowed;

    const features = [main.amenityFeature, place.amenityFeature].flat().filter(Boolean);
    const names: string[] = [];
    for (const f of features) {
      const feature = obj(f);
      const name = str(feature.name);
      if (!name || feature.value === false || feature.value === "false") continue;
      names.push(name);
    }
    for (const name of names) {
      for (const [key, re] of AMENITY_WORDS) if (re.test(name)) profile.amenities[key] = true;
    }
    profile.otherAmenities = names.slice(0, 15);

    const images = [main.image].flat().filter((i) => typeof i === "string" || (i && typeof i === "object"));
    if (images.length) {
      profile.photoCount = images.length;
      profile.coverImageUrl = str(images[0]) ?? str(obj(images[0]).url);
    }
  }

  const rated = blocks.jsonLd.find((n) => n.aggregateRating);
  if (rated) {
    const r = obj(rated.aggregateRating);
    profile.rating = { value: num(r.ratingValue), scale: num(r.bestRating), count: num(r.reviewCount ?? r.ratingCount) };
    provenance.rating = `JSON-LD ${typeOf(rated)}`;
  }

  if (!profile.title) {
    profile.title = blocks.og["og:title"] ?? blocks.title;
    if (profile.title) provenance.title = blocks.og["og:title"] ? "Open Graph" : "Seitentitel";
  }
  if (!profile.coverImageUrl && blocks.og["og:image"]) {
    profile.coverImageUrl = blocks.og["og:image"];
    provenance.coverImage = "Open Graph";
  }
  return { profile, provenance };
}

/** The compact input for the language model: structured data first, then the visible text. */
export function modelInput(blocks: PageBlocks, limits = { state: 14_000, text: 9_000 }): string {
  const cut = (s: string, n: number) => (s.length > n ? `${s.slice(0, n)}\n[gekürzt]` : s);
  const parts: string[] = [];
  if (blocks.title) parts.push(`<title>${blocks.title}</title>`);
  if (Object.keys(blocks.og).length) parts.push(`<meta>\n${JSON.stringify(blocks.og)}\n</meta>`);
  if (blocks.jsonLd.length) parts.push(`<json_ld>\n${cut(JSON.stringify(prune(blocks.jsonLd) ?? []), 6_000)}\n</json_ld>`);
  if (Object.keys(blocks.state).length) parts.push(`<page_state>\n${cut(JSON.stringify(blocks.state), limits.state)}\n</page_state>`);
  if (blocks.text) parts.push(`<visible_text>\n${cut(blocks.text, limits.text)}\n</visible_text>`);
  return parts.join("\n\n");
}
