import { createHash } from "node:crypto";
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
  /** Picture addresses of the advert in page order, already cleaned of icons and duplicates. */
  photos: PagePhoto[];
  /** Single guest reviews found in the page data, newest or most prominent first as the page has them. */
  reviews: PageReview[];
  /** How many pictures the app handed over, and how many it marked as the advert's gallery. */
  captured: { total: number; marked: number };
  /** Review blocks the app collected from the opened page, as running text: name, date, stars and all. */
  capturedReviews: string[];
}

export interface PageReview {
  text: string;
  title: string | null;
  rating: number | null;
  scale: number | null;
  /** As the page gives it: an ISO date where possible, otherwise its wording ("August 2026"). */
  date: string | null;
  author: string | null;
}

const REVIEW_KEYS = /^(reviews?|reviewList|ratingList|guestReviews?|customerReviews?|userReviews?|comments|testimonials|feedbacks?|bewertungen)$/i;
const REVIEW_TEXT_KEYS = ["reviewBody", "text", "comment", "comments", "body", "content", "review", "localizedReview", "description", "message", "positive", "pros", "negative", "cons"];

const shortText = (v: unknown, max = 80): string | null => (typeof v === "string" && v.trim() && v.trim().length <= max && !/^https?:/i.test(v.trim()) ? v.trim() : null);

function reviewFrom(item: unknown): PageReview | null {
  if (!item || typeof item !== "object" || Array.isArray(item)) return null;
  const o = item as Record<string, unknown>;
  // The text is under a usual name, or else the longest piece of prose in the entry.
  const parts: string[] = [];
  for (const key of REVIEW_TEXT_KEYS) {
    const v = o[key];
    const t = typeof v === "string" ? v : v && typeof v === "object" && !Array.isArray(v) ? ((v as Record<string, unknown>).text ?? (v as Record<string, unknown>).value) : null;
    if (typeof t === "string" && t.trim().length >= 20 && /\s/.test(t) && !parts.includes(t.trim())) parts.push(t.trim());
  }
  if (!parts.length) {
    const longest = Object.values(o).filter((v): v is string => typeof v === "string" && v.trim().length >= 40 && /\s/.test(v) && !/^https?:/i.test(v)).sort((a, b) => b.length - a.length)[0];
    if (longest) parts.push(longest.trim());
  }
  if (!parts.length) return null;
  const text = parts.join("\n").replace(/<br\s*\/?>/gi, "\n").replace(/<[^>]+>/g, "").slice(0, 2000);

  const ratingNode = o.reviewRating ?? o.rating ?? o.score ?? o.stars ?? o.ratingValue ?? o.overallRating ?? o.value;
  const r = ratingNode && typeof ratingNode === "object" ? (ratingNode as Record<string, unknown>) : null;
  const rating = num(r ? (r.ratingValue ?? r.value ?? r.score ?? r.overall) : ratingNode);
  const scale = r ? num(r.bestRating ?? r.scale ?? r.max) : num(o.bestRating ?? o.maxRating ?? o.scale);

  const authorNode = o.author ?? o.reviewer ?? o.user ?? o.guest ?? o.customer;
  const a = authorNode && typeof authorNode === "object" ? (authorNode as Record<string, unknown>) : null;
  const author = shortText(a ? (a.name ?? a.firstName ?? a.displayName ?? a.nickname) : authorNode, 40) ?? shortText(o.authorName ?? o.reviewerName ?? o.firstName ?? o.name ?? o.nickname, 40);

  const rawDate = o.datePublished ?? o.date ?? o.createdAt ?? o.created ?? o.reviewDate ?? o.submissionDate ?? o.travelDate ?? o.localizedDate ?? o.time;
  let date: string | null = null;
  if (typeof rawDate === "string") date = /^\d{4}-\d{2}-\d{2}/.exec(rawDate.trim())?.[0] ?? shortText(rawDate, 40);
  else if (typeof rawDate === "number" && rawDate > 1e9) date = new Date(rawDate < 1e12 ? rawDate * 1000 : rawDate).toISOString().slice(0, 10);

  return { text, title: shortText(o.title ?? o.headline, 120), rating: rating !== null && rating >= 0 && rating <= 100 ? rating : null, scale, date, author };
}

/** Every list of reviews in a state object; the advert's own is, as a rule, the longest. */
function reviewLists(root: unknown): PageReview[][] {
  const lists: PageReview[][] = [];
  const queue: unknown[] = [root];
  for (let i = 0; i < queue.length && i < 50_000; i++) {
    const node = queue[i];
    if (!node || typeof node !== "object") continue;
    if (Array.isArray(node)) {
      queue.push(...node);
      continue;
    }
    for (const [key, value] of Object.entries(node)) {
      if (REVIEW_KEYS.test(key) && Array.isArray(value)) {
        const found = value.map(reviewFrom).filter((r): r is PageReview => r !== null);
        if (found.length) lists.push(found);
      }
      queue.push(value);
    }
  }
  return lists;
}

function cleanReviews(candidates: PageReview[], limit = 40): PageReview[] {
  const seen = new Set<string>();
  const out: PageReview[] = [];
  for (const review of candidates) {
    const key = review.text.slice(0, 120).toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(review);
    if (out.length >= limit) break;
  }
  return out;
}

/** A stable id for a review, so the app can keep its place in a list. */
export const reviewId = (review: Pick<PageReview, "text">): string => createHash("sha256").update(review.text).digest("hex").slice(0, 16);

export interface PagePhoto {
  url: string;
  caption: string | null;
  width: number | null;
  height: number | null;
}

const IMAGE_KEYS = /^(images?|photos?|pictures?|gallery|galleryImages|media|mediaItems|imageUrls?|photoUrls?|imageList|photoList)$/i;
const NOT_A_PHOTO = /bat\.bing\.|maps\.googleapis\.|maps\.gstatic\.|\/staticmap|mapbox\.com|doubleclick|google-analytics|googletagmanager|googleadservices|facebook\.com\/tr|\/collect\?|\/pixel|beacon|logo|icon|sprite|avatar|flag|badge|pixel|tracking|placeholder|blank|spacer|profile_pic|user_profile|\/users?\/|\.svg(\?|$)|\.gif(\?|$)|^data:/i;
const IMAGE_EXT = /\.(jpe?g|png|webp|avif|heic)(\?|$)/i;
/** Preferred key when one picture comes in several sizes. */
const SIZE_KEYS = ["original", "originalUrl", "full", "fullUrl", "xxl", "xl", "large", "largeUrl", "big", "url", "baseUrl", "src", "href", "contentUrl", "uri", "path", "medium"];

const httpUrl = (v: unknown): string | null => {
  if (typeof v !== "string") return null;
  const s = v.trim().replace(/^\/\//, "https://");
  return /^https?:\/\/[^\s"'<>]+$/i.test(s) && s.length < 1500 ? s : null;
};

/** One picture out of a list entry, which is either an address or an object describing it in several sizes. */
function photoFrom(item: unknown): PagePhoto | null {
  const direct = httpUrl(item);
  if (direct) return { url: direct, caption: null, width: null, height: null };
  if (!item || typeof item !== "object" || Array.isArray(item)) return null;
  const o = item as Record<string, unknown>;
  let url: string | null = null;
  for (const key of SIZE_KEYS) if ((url = httpUrl(o[key]))) break;
  if (!url) {
    // Unknown shape: the first address anywhere inside, one or two levels down.
    for (const v of Object.values(o)) {
      url = httpUrl(v) ?? (v && typeof v === "object" ? (Object.values(v).map(httpUrl).find(Boolean) ?? null) : null);
      if (url && (IMAGE_EXT.test(url) || /im(a)?ge?s?|photo|media|cdn/i.test(url))) break;
      url = null;
    }
  }
  if (!url) return null;
  const text = (v: unknown) => (typeof v === "string" && v.trim() && v.length < 200 && !httpUrl(v) ? v.trim() : null);
  const size = (v: unknown) => (typeof v === "number" && v > 0 ? v : null);
  return { url, caption: text(o.caption) ?? text(o.title) ?? text(o.alt) ?? text(o.accessibilityLabel) ?? text(o.description), width: size(o.width), height: size(o.height) };
}

/** Every list of pictures in a state object. The advert's own gallery is, as a rule, the longest one. */
function photoLists(root: unknown): PagePhoto[][] {
  const lists: PagePhoto[][] = [];
  const queue: unknown[] = [root];
  for (let i = 0; i < queue.length && i < 50_000; i++) {
    const node = queue[i];
    if (!node || typeof node !== "object") continue;
    if (Array.isArray(node)) {
      queue.push(...node);
      continue;
    }
    for (const [key, value] of Object.entries(node)) {
      if (IMAGE_KEYS.test(key) && Array.isArray(value)) {
        const found = value.map(photoFrom).filter((p): p is PagePhoto => p !== null);
        if (found.length) lists.push(found);
      }
      queue.push(value);
    }
  }
  return lists;
}

const SIZE_WORDS = ["thumb", "thumbnail", "tiny", "xsmall", "small", "medium", "large", "xlarge", "xxlarge", "original", "full"];
const SIZE_SEGMENT = new RegExp(`/(${SIZE_WORDS.join("|")})(?=/)`, "i");

/** The same picture in two sizes shares this key; `rank` says which of them is the larger. */
function photoKey(url: string): { key: string; rank: number } | null {
  let u: URL;
  try {
    u = new URL(url);
  } catch {
    return null;
  }
  const word = SIZE_SEGMENT.exec(u.pathname)?.[1]?.toLowerCase();
  const width = Number(u.searchParams.get("im_w") ?? u.searchParams.get("w") ?? u.searchParams.get("width") ?? /[_-](\d{3,4})x\d{3,4}(?=\.)/.exec(u.pathname)?.[1] ?? 0);
  const path = u.pathname.replace(SIZE_SEGMENT, "").replace(/[_-]\d{3,4}x\d{3,4}(?=\.)/, "");
  // Without any hint an address counts as the original.
  const rank = width || (word ? (SIZE_WORDS.indexOf(word) + 1) * 300 : 10_000);
  return { key: `${u.host}${path}`, rank };
}

function cleanPhotos(candidates: PagePhoto[], limit = 80): PagePhoto[] {
  const position = new Map<string, number>();
  const ranks: number[] = [];
  const out: PagePhoto[] = [];
  for (const photo of candidates) {
    if (NOT_A_PHOTO.test(photo.url)) continue;
    const k = photoKey(photo.url);
    if (!k) continue;
    const at = position.get(k.key);
    if (at !== undefined) {
      // Seen before: keep its place in the order, but the larger rendition.
      if (k.rank > ranks[at]!) {
        out[at] = { ...photo, caption: photo.caption ?? out[at]!.caption };
        ranks[at] = k.rank;
      }
      continue;
    }
    if (out.length >= limit) continue;
    position.set(k.key, out.length);
    ranks.push(k.rank);
    out.push(photo);
  }
  return out;
}

/** Mobile pages load reduced renditions; where the image service's scheme is known, ask for the original. */
export function originalOf(url: string): string {
  try {
    const u = new URL(url);
    if (/(^|\.)muscache\.com$/.test(u.hostname)) {
      u.searchParams.delete("im_w");
      u.searchParams.delete("im_q");
      return u.toString();
    }
    if (/(^|\.)(media\.vrbo\.com|trvl-media\.com)$/.test(u.hostname)) {
      for (const key of ["impolicy", "rw", "rh", "ra", "w", "h", "q"]) u.searchParams.delete(key);
      return u.toString();
    }
  } catch {
    // fall through
  }
  return url;
}

/** A stable id for a picture, so the app can cache it across imports. */
export const photoId = (url: string): string => createHash("sha256").update(url).digest("hex").slice(0, 16);

/** A smaller rendition from the platform's own image service, where its address scheme is known. */
export function thumbFor(url: string): string | null {
  try {
    const u = new URL(url);
    if (/(^|\.)muscache\.com$/.test(u.hostname)) {
      u.searchParams.set("im_w", "720");
      return u.toString();
    }
    // HomeToGo and Casamundo name the size in the first path segment.
    // Galleries often hand out the medium size only; that is its own preview.
    if (u.hostname === "cdn.hometogo.net" && u.pathname.startsWith("/medium/")) return u.toString();
    if (u.hostname === "cdn.hometogo.net" && u.pathname.startsWith("/large/")) {
      u.pathname = u.pathname.replace(/^\/large\//, "/medium/");
      return u.toString();
    }
  } catch {
    // fall through
  }
  return null;
}

// Picture lists (collected separately), single reviews, and what real pages carry as ballast:
// A/B test configuration, editorial building blocks, page chrome, monitoring.
const DROP_KEYS =
  /^(images?|photos?|pictures?|media|gallery|reviews?|ratingList|breadcrumbs?|seo|translations?|i18n|tracking|.*analytics.*|footer|header|unparsedHeader|globalHeader.*|navigation|menu|optimizely.*|contentful.*|experiment.*|hrefLang.*|appConfig|notification.*|inlineNotification.*|newsletter.*|.*datadog.*|.*performance.*|cookie.*|consent.*)$/i;

/** Shrink a state object to what describes the property: no image lists, no review bodies, no giant arrays. */
export function prune(value: unknown, depth = 0): unknown {
  if (value === null || value === undefined) return undefined;
  if (typeof value === "string") {
    if (/^https?:\/\/\S+\.(jpe?g|png|webp|avif|gif|svg)(\?\S*)?$/i.test(value)) return undefined;
    return value.length > 1500 ? `${value.slice(0, 1500)}…` : value;
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

  const canonical = root.querySelector('link[rel="canonical"]')?.getAttribute("href");
  if (canonical) og.canonical = canonical;

  const jsonLd: Record<string, unknown>[] = [];
  const state: Record<string, unknown> = {};
  /** State before pruning: pruning drops exactly the picture lists that are wanted here. */
  const rawStates: unknown[] = [];
  for (const script of root.querySelectorAll("script")) {
    const type = script.getAttribute("type") ?? "";
    const id = script.getAttribute("id") ?? "";
    if (type === "application/ld+json") {
      flattenJsonLd(safeJson(script.rawText), jsonLd);
    } else if (id === "__NEXT_DATA__") {
      const data = safeJson(script.rawText) as { props?: { pageProps?: unknown } } | undefined;
      rawStates.push(data?.props?.pageProps);
      const pruned = prune(data?.props?.pageProps);
      if (pruned) state.nextData = pruned;
    } else if (/^data-deferred-state/.test(id)) {
      // Airbnb
      const raw = safeJson(script.rawText);
      rawStates.push(raw);
      const pruned = prune(raw);
      if (pruned) state[id] = pruned;
    } else if (id === "js-hotel-data" || (type === "application/json" && /hotel|listing|property|offer/i.test(id))) {
      const raw = safeJson(script.rawText);
      rawStates.push(raw);
      const pruned = prune(raw);
      if (pruned) state[id] = pruned;
    } else if (!type || /javascript|module/i.test(type)) {
      for (const [name, value] of inlineState(script.rawText)) {
        rawStates.push(value);
        const pruned = prune(value);
        if (pruned && !(name in state)) state[name] = pruned;
      }
    }
  }

  const title = root.querySelector("title")?.text.trim() || null;
  // The app appends the large pictures it saw load, in order, in a hidden block of its own.
  const capturedBlock = root.querySelector("#tp-captured-images");
  const capturedImgs = capturedBlock?.querySelectorAll("img") ?? [];
  // If the app could tell which of them sat in the advert's own gallery, only those count.
  const marked = capturedImgs.filter((img) => img.getAttribute("data-gallery") === "1");
  const captured = (marked.length >= 3 ? marked : capturedImgs).map((img) => httpUrl(img.getAttribute("src"))).filter((u): u is string => u !== null).map(originalOf);
  const capturedIsGallery = marked.length >= 3;
  capturedBlock?.remove();
  // Reviews the app saw on the page, one element each. Taken out so they do not count as page text twice.
  const reviewBlock = root.querySelector("#tp-captured-reviews");
  const capturedReviews = [...new Set((reviewBlock?.querySelectorAll("[data-review]") ?? []).map((n) => n.text.replace(/[ \t]+/g, " ").replace(/\n\s*\n+/g, "\n").trim()))]
    .filter((t) => t.length >= 20)
    .slice(0, 150)
    .map((t) => t.slice(0, 3000));
  reviewBlock?.remove();
  const imgs = root.querySelectorAll("img");
  root.querySelectorAll("script,style,noscript,svg,template,iframe,title").forEach((n) => n.remove());
  const text = root.structuredText.replace(/[ \t]+/g, " ").replace(/\n\s*\n+/g, "\n").trim();

  // Pictures: the lodging's own JSON-LD first, then the longest gallery in the page state.
  const candidates: PagePhoto[] = [];
  for (const node of jsonLd) {
    if (!LODGING_TYPES.test(typeOf(node)) || /Product/i.test(typeOf(node))) continue;
    candidates.push(...[node.image, node.photo].flat().map(photoFrom).filter((p): p is PagePhoto => p !== null));
  }
  // Reviews: JSON-LD of the lodging, then the longest list in the page state.
  const reviewCandidates: PageReview[] = [];
  for (const node of jsonLd) {
    if (/Product/i.test(typeOf(node)) && !LODGING_TYPES.test(typeOf(node).replace(/Product/gi, ""))) continue;
    reviewCandidates.push(...[node.review, node.reviews].flat().map(reviewFrom).filter((r): r is PageReview => r !== null));
  }
  const reviewSets = rawStates.flatMap(reviewLists).sort((a, b) => b.length - a.length);
  if (reviewSets[0]) reviewCandidates.push(...reviewSets[0]);
  const reviews = cleanReviews(reviewCandidates);

  const galleries = rawStates.flatMap(photoLists).sort((a, b) => b.length - a.length);
  if (galleries[0]) candidates.push(...galleries[0]);
  let photos = cleanPhotos(candidates);
  if (captured.length) {
    const seen = cleanPhotos(captured.map((url) => ({ url, caption: null, width: null, height: null })));
    if (capturedIsGallery || photos.length < 3) {
      // Nothing better to go by: what the device displayed is the gallery. Without the app's mark this
      // may include pictures of other adverts shown on the page.
      const merged = cleanPhotos([...seen, ...photos]);
      if (merged.length >= photos.length) photos = merged;
    } else {
      // The page's own data says which pictures belong to the advert; the device only contributes
      // larger renditions of those, never the "similar adverts" it also saw.
      photos = cleanPhotos([...photos, ...seen.filter((p) => photos.some((q) => photoKey(q.url)?.key === photoKey(p.url)?.key))]);
    }
  }
  if (photos.length < 3) {
    // A page rendered on the device has its pictures in the document itself.
    const fromDom: PagePhoto[] = [];
    for (const img of imgs) {
      const srcset = (img.getAttribute("srcset") ?? img.getAttribute("data-srcset") ?? "").split(",").map((part) => part.trim().split(/\s+/));
      const largest = srcset.filter((p) => p[0]).sort((a, b) => (parseFloat(b[1] ?? "0") || 0) - (parseFloat(a[1] ?? "0") || 0))[0]?.[0];
      const url = httpUrl(largest) ?? httpUrl(img.getAttribute("src")) ?? httpUrl(img.getAttribute("data-src"));
      const width = Number(img.getAttribute("width")) || null;
      if (!url || (width !== null && width < 200)) continue;
      // Anything can sit in an img element; a picture has a picture's address.
      const { hostname, pathname } = new URL(url);
      if (url.length > 600 || !(IMAGE_EXT.test(pathname) || /img|image|photo|media|cdn|static|pictures/i.test(hostname + pathname))) continue;
      fromDom.push({ url, caption: img.getAttribute("alt")?.trim() || null, width: null, height: null });
    }
    const merged = cleanPhotos([...photos, ...fromDom]);
    if (merged.length > photos.length) photos = merged;
  }

  return { title, og, jsonLd, state, text, photos, reviews, captured: { total: capturedImgs.length, marked: marked.length }, capturedReviews };
}

/**
 * Some portals serve every page with the metadata of their home page (title,
 * preview image, og:url pointing at "/") and fill in the advert by script.
 * Such a title and image say nothing about the advert.
 */
export function hasPortalMetadata(blocks: PageBlocks): boolean {
  for (const key of ["og:url", "canonical"]) {
    const value = blocks.og[key];
    if (!value) continue;
    try {
      // Relative values resolve against a placeholder; only the path matters.
      if (new URL(value, "https://placeholder.invalid").pathname.replace(/\/+$/, "") === "") return true;
    } catch {
      // Not a URL: no evidence either way.
    }
  }
  return false;
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

  if (blocks.photos.length) {
    profile.photos = blocks.photos.map((p) => ({ id: photoId(p.url), url: p.url, thumbUrl: thumbFor(p.url), width: p.width, height: p.height, caption: p.caption }));
    profile.photoCount = Math.max(profile.photoCount ?? 0, profile.photos.length);
    profile.coverImageUrl ??= profile.photos[0]!.url;
    provenance.photos = `${profile.photos.length} Bilder aus den Seitendaten`;
  }

  if (blocks.reviews.length) {
    profile.reviews = blocks.reviews.map((r) => ({ id: reviewId(r), ...r, platform: null }));
    provenance.reviews = `${profile.reviews.length} Bewertungen aus den Seitendaten`;
  }

  const portalMeta = hasPortalMetadata(blocks);
  if (portalMeta) provenance.metadata = "Seite trägt nur die Angaben des Portals";
  if (!profile.title && !portalMeta) {
    profile.title = blocks.og["og:title"] ?? blocks.title;
    if (profile.title) provenance.title = blocks.og["og:title"] ? "Open Graph" : "Seitentitel";
  }
  if (!profile.coverImageUrl && blocks.og["og:image"] && !portalMeta) {
    profile.coverImageUrl = blocks.og["og:image"];
    provenance.coverImage = "Open Graph";
  }

  // The headline of the advert ("… · 4 Schlafzimmer · 4 Betten · 4 Badezimmer") is what visitors see,
  // and platforms keep it more reliably than their JSON-LD.
  const headline = portalMeta ? "" : [blocks.og["og:title"], blocks.og["og:description"], blocks.og["description"]].filter(Boolean).join(" · ");
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

const DIGEST_SKIP_KEYS = /^(__typename|id|ids?|.*Id|.*ID|.*Key|key|slug|token|hash|icon.*|.*Icon|color.*|.*Color|url|.*Url|.*URL|href|src|logging.*|.*Logging.*|tracking.*|analytics.*|experiment.*|locale|currency|timezone|timestamp|createdAt|updatedAt|style.*|className|testId|anchor|ctaType|screenId|sectionId|sectionComponentType|sectionContentStatus)$/;
const DIGEST_NUMBER_KEYS = /bed|bath|room|guest|capacity|person|occup|sleep|^lat|^lng|^lon|latitude|longitude|price|amount|total|fee|deposit|rating|review|score|count|size|area|sqm|star|distance|night|min|max|year|floor/i;

/**
 * Pages that render in the browser keep everything in one enormous state
 * object, most of it layout and bookkeeping. This keeps what a person would
 * read: the texts, and the numbers whose name says what they count, in page
 * order, each once.
 */
export function digestState(state: unknown, budget = 30_000): string {
  const lines: string[] = [];
  const seen = new Set<string>();
  let used = 0;
  const add = (line: string): boolean => {
    if (seen.has(line)) return true;
    seen.add(line);
    used += line.length + 1;
    if (used > budget) return false;
    lines.push(line);
    return true;
  };
  const isProse = (v: string) => {
    const t = v.trim();
    if (t.length < 2 || /^https?:\/\//i.test(t) || /^data:/i.test(t)) return false;
    // Enum names, ids, encoded blobs: no spaces and no lower-case word in sight.
    if (!/\s/.test(t) && (t.length > 30 || /^[A-Z0-9_]+$/.test(t) || /^[A-Za-z0-9+/=_-]{16,}$/.test(t))) return false;
    return /\p{L}{2}/u.test(t) || /\d/.test(t);
  };
  const walk = (node: unknown, key: string, depth: number): boolean => {
    if (node === null || node === undefined || depth > 40) return true;
    if (typeof node === "string") return isProse(node) ? add(`${key}: ${node.trim().replace(/\s+/g, " ")}`) : true;
    if (typeof node === "number" || typeof node === "boolean") return DIGEST_NUMBER_KEYS.test(key) ? add(`${key}: ${node}`) : true;
    if (Array.isArray(node)) {
      for (const item of node) if (!walk(item, key, depth + 1)) return false;
      return true;
    }
    for (const [k, v] of Object.entries(node)) {
      if (DIGEST_SKIP_KEYS.test(k)) continue;
      if (!walk(v, k, depth + 1)) return false;
    }
    return true;
  };
  const complete = walk(state, "state", 0);
  return complete ? lines.join("\n") : `${lines.join("\n")}\n[gekürzt]`;
}

/** The compact input for the language model: structured data first, then the visible text. */
export function modelInput(blocks: PageBlocks, limits = { state: 14_000, digest: 40_000, text: 14_000 }): string {
  const cut = (s: string, n: number) => (s.length > n ? `${s.slice(0, n)}\n[gekürzt]` : s);
  const parts: string[] = [];
  if (hasPortalMetadata(blocks)) {
    parts.push("<note>Titel, Beschreibung und Vorschaubild dieser Seite gehören zum Portal, nicht zum Angebot, und sind deshalb weggelassen.</note>");
  } else {
    if (blocks.title) parts.push(`<title>${blocks.title}</title>`);
    if (Object.keys(blocks.og).length) parts.push(`<meta>\n${JSON.stringify(blocks.og)}\n</meta>`);
  }
  if (blocks.jsonLd.length) parts.push(`<json_ld>\n${cut(JSON.stringify(prune(blocks.jsonLd) ?? []), 6_000)}\n</json_ld>`);
  if (Object.keys(blocks.state).length) {
    const json = JSON.stringify(blocks.state);
    // A state that fits is passed as it is; a large one as its readable digest instead of an arbitrary first slice.
    parts.push(json.length <= limits.state ? `<page_state>\n${json}\n</page_state>` : `<page_state format="Auszug: Schlüssel und Wert je Zeile, in Seitenreihenfolge">\n${digestState(blocks.state, limits.digest)}\n</page_state>`);
  }
  if (blocks.reviews.length) {
    // Enough voices for a fair picture, short enough to stay cheap.
    const lines: string[] = [];
    let used = 0;
    for (const r of blocks.reviews) {
      const line = `- ${r.rating !== null ? `[${r.rating}${r.scale ? `/${r.scale}` : ""}] ` : ""}${r.date ? `(${r.date}) ` : ""}${r.text.replace(/\s+/g, " ").slice(0, 600)}`;
      if (used + line.length > 9_000) break;
      used += line.length;
      lines.push(line);
    }
    parts.push(`<reviews count="${blocks.reviews.length}">\n${lines.join("\n")}\n</reviews>`);
  }
  if (blocks.capturedReviews.length) {
    const lines: string[] = [];
    let used = 0;
    for (const [i, text] of blocks.capturedReviews.entries()) {
      // For the summary a good part of each review is enough; the single reviews are sorted in a call of their own.
      const flat = text.replace(/\s+/g, " ");
      const line = `<block i="${i}">${flat.length > 700 ? `${flat.slice(0, 700)} […]` : flat}</block>`;
      if (used + line.length > 60_000) break;
      used += line.length;
      lines.push(line);
    }
    parts.push(`<captured_reviews count="${lines.length}">\n${lines.join("\n")}\n</captured_reviews>`);
  }
  if (blocks.text) parts.push(`<visible_text>\n${cut(blocks.text, limits.text)}\n</visible_text>`);
  return parts.join("\n\n");
}
