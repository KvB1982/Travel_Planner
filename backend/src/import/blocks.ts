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

/**
 * State that a page assigns in an inline script, as Vrbo/FeWo-direkt does:
 *   window.__APOLLO_STATE__ = JSON.parse("{\"a\":1}");   or   window.__X__ = {"a":1};
 */
export function inlineState(script: string): [string, unknown][] {
  const out: [string, unknown][] = [];
  if (!script.includes("window.__")) return out;
  for (const m of script.matchAll(/window\.(__[A-Z0-9_]+__)\s*=\s*JSON\.parse\(\s*("(?:[^"\\]|\\[\s\S])*")\s*\)/g)) {
    // The argument is a JavaScript string literal; \xNN and \' are valid there but not in JSON.
    const literal = m[2]!.replace(/\\(\\|x([0-9a-fA-F]{2})|')/g, (all, esc: string, hex?: string) => (esc === "\\" ? all : hex ? `\\u00${hex}` : "'"));
    const text = safeJson(literal);
    const value = typeof text === "string" ? safeJson(text) : undefined;
    if (value && typeof value === "object") out.push([m[1]!, value]);
  }
  if (out.length === 0) {
    const m = /^\s*window\.(__[A-Z0-9_]+__)\s*=\s*(\{[\s\S]*\})\s*;?\s*$/.exec(script);
    const value = m ? safeJson(m[2]!) : undefined;
    if (m && value && typeof value === "object") out.push([m[1]!, value]);
  }
  return out;
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
    } else if (/^data-deferred-state/.test(id)) {
      // Airbnb
      const pruned = prune(safeJson(script.rawText));
      if (pruned) state[id] = pruned;
    } else if (id === "js-hotel-data" || (type === "application/json" && /hotel|listing|property|offer/i.test(id))) {
      const pruned = prune(safeJson(script.rawText));
      if (pruned) state[id] = pruned;
    } else if (!type || /javascript|module/i.test(type)) {
      for (const [name, value] of inlineState(script.rawText)) {
        const pruned = prune(value);
        if (pruned && !(name in state)) state[name] = pruned;
      }
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

/** First value stored under `key` anywhere in a nested object, breadth first. */
export function findKey(root: unknown, key: string): unknown {
  const queue: unknown[] = [root];
  for (let i = 0; i < queue.length && i < 20_000; i++) {
    const node = queue[i];
    if (!node || typeof node !== "object") continue;
    if (!Array.isArray(node) && key in node && (node as Record<string, unknown>)[key] != null) return (node as Record<string, unknown>)[key];
    queue.push(...Object.values(node));
  }
  return undefined;
}

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
  // A "Product" often describes the portal itself ("CHECK24 Pauschalreisen", rated by 56,000 customers).
  // It only counts as the property when the page is titled after it.
  const pageTitle = `${blocks.og["og:title"] ?? ""} ${blocks.title ?? ""}`.toLowerCase();
  const siteName = (blocks.og["og:site_name"] ?? "").trim().toLowerCase();
  const namesThePage = (n: Record<string, unknown>) => {
    const name = str(n.name)?.toLowerCase();
    return Boolean(name && name !== siteName && pageTitle.includes(name));
  };
  const main = lodging.find((n) => !/Product/i.test(typeOf(n))) ?? lodging.find(namesThePage);

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

  // Only the property's own rating counts, never that of the portal or of some other node.
  const rated = main?.aggregateRating ? main : undefined;
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

  // The headline of the advert ("… · 4 Schlafzimmer · 4 Betten · 4 Badezimmer") is what visitors see,
  // and platforms keep it more reliably than their JSON-LD.
  const headline = [blocks.og["og:title"], blocks.og["og:description"], blocks.og["description"]].filter(Boolean).join(" · ");
  const count = (re: RegExp): number | null => {
    const m = re.exec(headline);
    return m ? Number(m[1]!.replace(",", ".")) : null;
  };
  const fromHeadline = {
    bedrooms: count(/(\d+)\s*(?:Schlafzimmer|bedrooms?)\b/i),
    beds: count(/(\d+)\s*(?:Betten|Bett|beds?)\b/i),
    bathrooms: count(/(\d+(?:[.,]5)?)\s*(?:Badezimmer|Bäder|Bad|bath(?:room)?s?)\b/i),
  };
  for (const [key, value] of Object.entries(fromHeadline) as [keyof typeof fromHeadline, number | null][]) {
    if (value !== null && profile[key] === null) {
      profile[key] = value;
      provenance.rooms = "Überschrift der Anzeige";
    }
  }

  const shownGuests = num(findKey(blocks.state, "personCapacity")) ?? (kind !== "vacation_home" ? null : count(/(\d+)\s*(?:Gäste|Gästen|Personen|guests)\b/i));
  if (shownGuests !== null && shownGuests > 0 && shownGuests !== profile.maxGuests) {
    if (profile.maxGuests !== null) {
      profile.warnings.push(`Die Seite nennt ${shownGuests} Gäste, ihre Maschinendaten ${profile.maxGuests}. Übernommen ist die Angabe, die Besucher sehen.`);
      profile.uncertain.push("maxGuests");
    }
    profile.maxGuests = shownGuests;
    provenance.maxGuests = "Angabe auf der Seite";
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
