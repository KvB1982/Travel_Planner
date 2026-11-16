import type { ListingKind } from "./profile.js";

export type Platform = "airbnb" | "vrbo" | "novasol" | "check24" | "casamundo" | "booking" | "other";

export interface Stay {
  startDate: string | null;
  endDate: string | null;
  nights: number | null;
  adults: number | null;
  children: number | null;
  childAges: number[];
}

export interface PriceHint {
  totalEur: number;
  nights: number | null;
  endDate: string | null;
  nonRefundable: boolean;
}

export interface LinkInfo {
  platform: Platform;
  /** Stable id of the advert on its platform; for unknown sites host + path. */
  externalId: string;
  /** Link without tracking parameters. */
  canonicalUrl: string;
  kind: ListingKind;
  stay: Stay;
  /** A price found in the link parameters themselves (Casamundo). */
  priceHint: PriceHint | null;
  /** The dates in the link are a search window (earliest departure to latest return), not a stay. */
  searchWindow: boolean;
  /** App short links must be resolved before anything else can be read. */
  isShortLink: boolean;
  /** Things in the link that contradict each other or look wrong. */
  warnings: string[];
}

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;

function isoDate(v: string | null | undefined): string | null {
  if (!v) return null;
  const s = v.trim();
  if (ISO_DATE.test(s)) return s;
  // dd.mm.yyyy and mm/dd/yyyy are not guessed; only an unambiguous yyyy/mm/dd is accepted.
  const m = /^(\d{4})[/.](\d{2})[/.](\d{2})$/.exec(s);
  return m ? `${m[1]}-${m[2]}-${m[3]}` : null;
}

function int(v: string | null | undefined): number | null {
  if (v === null || v === undefined || v.trim() === "") return null;
  const n = Number(v);
  return Number.isInteger(n) && n >= 0 ? n : null;
}

export function nightsBetween(start: string | null, end: string | null): number | null {
  if (!start || !end) return null;
  const ms = Date.parse(`${end}T00:00:00Z`) - Date.parse(`${start}T00:00:00Z`);
  const n = Math.round(ms / 86_400_000);
  return n > 0 ? n : null;
}

function emptyStay(): Stay {
  return { startDate: null, endDate: null, nights: null, adults: null, children: null, childAges: [] };
}

function withNights(stay: Stay): Stay {
  return { ...stay, nights: stay.nights ?? nightsBetween(stay.startDate, stay.endDate) };
}

function hostMatches(host: string, ...names: string[]): boolean {
  return names.some((n) => host === n || host.endsWith(`.${n}`) || host.startsWith(`${n}.`) || host.includes(`.${n}.`));
}

const SHORT_LINK_HOSTS = [/\.onelink\.me$/, /^abnb\.me$/, /^t\.vrbo\.io$/, /^bit\.ly$/, /^tinyurl\.com$/, /\.app\.link$/, /\.page\.link$/];

export function isShortLinkHost(host: string): boolean {
  return SHORT_LINK_HOSTS.some((re) => re.test(host));
}

/** Some app short links carry the real target as a parameter; use it without a network call. */
export function embeddedTarget(url: URL): string | null {
  for (const key of ["deep_link_value", "af_web_dp", "af_dp", "$fallback_url", "link"]) {
    const v = url.searchParams.get(key);
    if (v && /^https?:\/\//i.test(v)) return v;
  }
  return null;
}

function analyzeAirbnb(url: URL): Partial<LinkInfo> | null {
  const m = /\/rooms\/(?:plus\/)?(\d+)/.exec(url.pathname);
  if (!m) return null;
  const p = url.searchParams;
  const stay = withNights({
    ...emptyStay(),
    startDate: isoDate(p.get("check_in")),
    endDate: isoDate(p.get("check_out")),
    adults: int(p.get("adults")),
    children: int(p.get("children")),
  });
  const warnings: string[] = [];
  if ((stay.adults ?? 0) + (stay.children ?? 0) === 1) {
    warnings.push("Der Link rechnet mit nur einem Gast. Der Preis gilt erst mit der Personenzahl der Reise.");
  }
  return { platform: "airbnb", externalId: m[1]!, canonicalUrl: `https://${url.host}/rooms/${m[1]}`, kind: "vacation_home", stay, warnings };
}

function analyzeVrbo(url: URL): Partial<LinkInfo> | null {
  // /ferienwohnung-ferienhaus/p5212122, /p5212122vb, /1234567ha
  const m = /\/p?(\d{5,})(vb|ha)?(?:\/|$)/.exec(url.pathname);
  if (!m) return null;
  const p = url.searchParams;
  const stay: Stay = {
    ...emptyStay(),
    startDate: isoDate(p.get("startDate") ?? p.get("chkin") ?? p.get("arrival")),
    endDate: isoDate(p.get("endDate") ?? p.get("chkout") ?? p.get("departure")),
    adults: int(p.get("adults")),
  };
  // rm1=a4:c17:c17:c17:c17 means 4 adults and four children with their ages.
  const rm = p.get("rm1");
  if (rm) {
    const a = /a(\d+)/.exec(rm);
    if (a) stay.adults = Number(a[1]);
    stay.childAges = [...rm.matchAll(/c(\d+)/g)].map((x) => Number(x[1]));
    stay.children = stay.childAges.length;
  }
  // children=1_5,1_8 means room 1 with children aged 5 and 8.
  const kids = p.get("children");
  if (kids && stay.children === null) {
    stay.childAges = kids
      .split(",")
      .map((c) => Number(c.split("_").pop()))
      .filter((n) => Number.isInteger(n));
    stay.children = stay.childAges.length;
  }
  const warnings: string[] = [];
  if (stay.childAges.length > 1 && stay.childAges.every((a) => a === 17)) {
    warnings.push("Die Kinderalter im Link sind pauschal mit 17 angegeben.");
  }
  const id = `p${m[1]}${m[2] ?? ""}`;
  return { platform: "vrbo", externalId: id, canonicalUrl: `https://${url.host}${url.pathname.replace(/\/$/, "")}`, kind: "vacation_home", stay: withNights(stay), warnings };
}

function analyzeNovasol(url: URL): Partial<LinkInfo> | null {
  // /ferienhaeuser/CLD520 and /ferienhaeuser/korcula-vela-luka-cld520
  const last = url.pathname.split("/").filter(Boolean).pop() ?? "";
  const m = /(?:^|-)([a-z]{1,3}\d{3,5})$/i.exec(last);
  if (!m) return null;
  const p = url.searchParams;
  const stay = withNights({
    ...emptyStay(),
    startDate: isoDate(p.get("arrival") ?? p.get("startDate")),
    endDate: isoDate(p.get("departure") ?? p.get("endDate")),
    adults: int(p.get("adults")),
    children: int(p.get("children")),
  });
  return { platform: "novasol", externalId: m[1]!.toUpperCase(), canonicalUrl: `https://${url.host}${url.pathname}`, kind: "vacation_home", stay };
}

function analyzeCheck24(url: URL): Partial<LinkInfo> | null {
  const p = url.searchParams;
  const hotelId = p.get("hotelId");
  if (!hotelId) return null;
  const isPackage = p.get("pageArea") === "package" || p.get("transportType") === "flight";
  const stay: Stay = { ...emptyStay(), startDate: isoDate(p.get("departureDate")), endDate: isoDate(p.get("returnDate")) };
  // roomAllocation=A-A-7-11: every A is an adult, numbers are children's ages; rooms are separated by commas.
  const alloc = p.get("roomAllocation");
  if (alloc) {
    const parts = alloc.split(/[-,]/).filter(Boolean);
    stay.adults = parts.filter((x) => x.toUpperCase() === "A").length;
    stay.childAges = parts.filter((x) => /^\d+$/.test(x)).map(Number);
    stay.children = stay.childAges.length;
  }
  const warnings: string[] = [];
  const days = p.get("days");
  const searchWindow = Boolean(days && days.includes("-"));
  if (days && searchWindow) {
    // The dates are a search window, not a stay.
    warnings.push(`Der Link enthält eine Spanne von ${days.replace("-", " bis ")} Tagen statt eines festen Zeitraums. Es gibt deshalb keinen einzelnen Preis.`);
  } else if (days) {
    stay.nights = int(days);
  }
  const keep = new URLSearchParams();
  for (const k of ["hotelId", "departureDate", "returnDate", "days", "roomAllocation", "transportType", "pageArea"]) {
    const v = p.get(k);
    if (v) keep.set(k, v);
  }
  return {
    platform: "check24",
    externalId: hotelId,
    canonicalUrl: `https://${url.host}${url.pathname}?${keep.toString()}`,
    kind: isPackage ? "package" : "hotel",
    stay,
    searchWindow,
    warnings,
  };
}

function analyzeCasamundo(url: URL): Partial<LinkInfo> | null {
  const m = /\/rental\/([a-z0-9]+)/i.exec(url.pathname);
  if (!m) return null;
  const p = url.searchParams;
  const warnings: string[] = [];
  const range = p.get("dateRange")?.split("~") ?? [];
  const stay: Stay = {
    ...emptyStay(),
    startDate: isoDate(range[0]) ?? isoDate(p.get("arrival")),
    endDate: isoDate(range[1]),
    adults: int(p.get("adults")),
    children: int(p.get("children")),
    childAges: p.getAll("childrenAges[]").map(Number).filter((n) => Number.isInteger(n)),
  };
  if (!stay.endDate && stay.startDate && int(p.get("duration"))) {
    const end = new Date(Date.parse(`${stay.startDate}T00:00:00Z`) + int(p.get("duration"))! * 86_400_000);
    stay.endDate = end.toISOString().slice(0, 10);
  }
  const arrival = isoDate(p.get("arrival"));
  if (arrival && range[0] && arrival !== isoDate(range[0])) {
    warnings.push("Der Link nennt zwei verschiedene Anreisetage. Verwendet wird der Zeitraum, zu dem auch der Preis gehört.");
  }
  const persons = int(p.get("persons"));
  if (persons !== null && stay.adults !== null && persons !== stay.adults + (stay.children ?? 0)) {
    warnings.push("Die Personenzahl im Link ist widersprüchlich.");
  }
  // pCon=4620|EUR|2027-08-28|7|... : total, currency, departure date, nights.
  let priceHint: PriceHint | null = null;
  const pCon = p.get("pCon")?.split("|");
  if (pCon && pCon[1] === "EUR" && Number(pCon[0]) > 0) {
    priceHint = {
      totalEur: Number(pCon[0]),
      endDate: isoDate(pCon[2]),
      nights: int(pCon[3]),
      nonRefundable: p.get("priceRate") === "nonRefund",
    };
  }
  return {
    platform: "casamundo",
    externalId: m[1]!,
    canonicalUrl: `https://${url.host}/rental/${m[1]}`,
    kind: "vacation_home",
    stay: withNights(stay),
    priceHint,
    warnings,
  };
}

function analyzeBooking(url: URL): Partial<LinkInfo> | null {
  const m = /\/hotel\/([a-z]{2})\/([^/.]+)/.exec(url.pathname);
  if (!m) return null;
  const p = url.searchParams;
  const stay = withNights({
    ...emptyStay(),
    startDate: isoDate(p.get("checkin")),
    endDate: isoDate(p.get("checkout")),
    adults: int(p.get("group_adults")),
    children: int(p.get("group_children")),
    childAges: p.getAll("age").map(Number).filter((n) => Number.isInteger(n)),
  });
  return { platform: "booking", externalId: `${m[1]}/${m[2]}`, canonicalUrl: `https://${url.host}${url.pathname}`, kind: "hotel", stay };
}

export function analyzeLink(raw: string): LinkInfo {
  const url = new URL(raw.trim());
  if (url.protocol !== "https:" && url.protocol !== "http:") throw new Error("Only http and https links are supported.");
  const host = url.hostname.toLowerCase();

  let found: Partial<LinkInfo> | null = null;
  if (hostMatches(host, "airbnb")) found = analyzeAirbnb(url);
  else if (hostMatches(host, "fewo-direkt", "vrbo", "abritel", "homeaway", "stayz", "bookabach")) found = analyzeVrbo(url);
  else if (hostMatches(host, "novasol")) found = analyzeNovasol(url);
  else if (hostMatches(host, "check24")) found = analyzeCheck24(url);
  else if (hostMatches(host, "casamundo", "hometogo")) found = analyzeCasamundo(url);
  else if (hostMatches(host, "booking")) found = analyzeBooking(url);

  const base: LinkInfo = {
    platform: "other",
    externalId: `${host}${url.pathname.replace(/\/$/, "")}`,
    canonicalUrl: `${url.protocol}//${url.host}${url.pathname}`,
    kind: "vacation_home",
    stay: emptyStay(),
    priceHint: null,
    searchWindow: false,
    isShortLink: isShortLinkHost(host),
    warnings: [],
  };
  return { ...base, ...(found ?? {}) };
}

/**
 * Rebuild a link with the dates and party of the trip, so the price read from
 * the page belongs to the trip and not to whatever the sharer had selected.
 */
export function urlForStay(info: LinkInfo, stay: Pick<Stay, "startDate" | "endDate" | "adults" | "children">): string {
  const url = new URL(info.canonicalUrl);
  const p = url.searchParams;
  if (!stay.startDate || !stay.endDate) return info.canonicalUrl;
  switch (info.platform) {
    case "airbnb":
      p.set("check_in", stay.startDate);
      p.set("check_out", stay.endDate);
      if (stay.adults !== null) p.set("adults", String(stay.adults));
      if (stay.children) p.set("children", String(stay.children));
      break;
    case "vrbo":
      p.set("startDate", stay.startDate);
      p.set("endDate", stay.endDate);
      if (stay.adults !== null) p.set("adults", String(stay.adults));
      break;
    case "booking":
      p.set("checkin", stay.startDate);
      p.set("checkout", stay.endDate);
      if (stay.adults !== null) p.set("group_adults", String(stay.adults));
      if (stay.children !== null) p.set("group_children", String(stay.children));
      break;
    case "check24": {
      // A fixed stay instead of a search window: outward and return date, and the days between them.
      const nights = nightsBetween(stay.startDate, stay.endDate);
      p.set("departureDate", stay.startDate);
      p.set("returnDate", stay.endDate);
      if (nights) p.set("days", String(nights));
      if (stay.adults !== null) {
        // The link wants every child's age. Those of the shared link serve where the number fits; otherwise a school child.
        const known = (p.get("roomAllocation") ?? "").split(/[-,]/).filter((x) => /^\d+$/.test(x));
        const children = stay.children ?? 0;
        const ages = Array.from({ length: children }, (_, i) => (known.length === children ? known[i]! : "10"));
        p.set("roomAllocation", [...Array.from({ length: stay.adults }, () => "A"), ...ages].join("-"));
      }
      break;
    }
    case "novasol": {
      // Arrival as day-month-year plus the number of nights, as the platform's own search writes it.
      const nights = nightsBetween(stay.startDate, stay.endDate);
      if (!nights) return info.canonicalUrl;
      const [y, m, d] = stay.startDate.split("-");
      p.set("start", `${d}-${m}-${y}`);
      p.set("nights", String(nights));
      if (stay.adults !== null) p.set("adult", String(stay.adults));
      if (stay.children !== null) p.set("child", String(stay.children));
      break;
    }
    case "casamundo": {
      // The page only takes the dates over when arrival, length and head count come along with the range.
      const nights = nightsBetween(stay.startDate, stay.endDate);
      p.set("dateRange", `${stay.startDate}~${stay.endDate}`);
      p.set("arrival", stay.startDate);
      if (nights) p.set("duration", String(nights));
      if (stay.adults !== null) {
        p.set("adults", String(stay.adults));
        if (stay.children) p.set("children", String(stay.children));
        p.set("persons", String(stay.adults + (stay.children ?? 0)));
      }
      break;
    }
    default:
      return info.canonicalUrl;
  }
  return url.toString();
}
