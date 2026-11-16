import { describe, expect, it } from "vitest";
import { profileSchema } from "../src/import/profile.js";
import { germanCountry, positionFitsCountry } from "../src/import/country.js";
import { reviewsFromBlocks } from "../src/import/extract.js";
import { digestState, extractBlocks, findKey, inlineState, modelInput, profileFromBlocks, prune } from "../src/import/blocks.js";
import { claudeExtractor, combine, parseLenient } from "../src/import/extract.js";
import { assertPublicUrl, looksBlocked, UnsafeUrlError } from "../src/import/fetch.js";
import { emptyProfile, fillPercent, mergeProfiles } from "../src/import/profile.js";
import { analyzeLink } from "../src/import/url.js";
import { fixture } from "./helpers.js";

describe("extractBlocks", () => {
  const blocks = extractBlocks(fixture("novasol.html"));

  it("collects metadata, JSON-LD and page state", () => {
    expect(blocks.og["og:title"]).toMatch(/XYZ123/);
    expect(blocks.jsonLd.map((n) => n["@type"])).toEqual(["VacationRental", "FAQPage"]);
    expect(JSON.stringify(blocks.state)).toContain("Schlafsofa");
  });

  it("drops image lists and SEO noise from the page state", () => {
    const state = JSON.stringify(blocks.state);
    expect(state).not.toContain("images.example.test");
    expect(state).not.toContain("ignored");
  });

  it("keeps visible text and leaves scripts and styles out", () => {
    expect(blocks.text).toContain("7 Nächte ab 2.646 €");
    expect(blocks.text).not.toMatch(/dataLayer|color:red/);
  });

  it("builds a compact model input", () => {
    const input = modelInput(blocks);
    expect(input).toContain("<json_ld>");
    expect(input).toContain("<visible_text>");
    expect(input.length).toBeLessThan(5000);
  });
});

describe("profileFromBlocks", () => {
  it("fills the profile from structured data alone", () => {
    const { profile, provenance } = profileFromBlocks(extractBlocks(fixture("novasol.html")), "vacation_home");
    expect(profile).toMatchObject({
      title: "Ferienhaus Musterort (XYZ123)",
      place: "Musterort",
      country: "HR",
      lat: 42.96,
      maxGuests: 8,
      bedrooms: 3,
      bathrooms: 3,
      livingAreaSqm: 120,
      photoCount: 3,
      rules: { checkInFrom: "16:00", checkOutUntil: "10:00" },
    });
    expect(profile.amenities).toMatchObject({ pool: true, airConditioning: true, wifi: true, dishwasher: true, petsAllowed: false });
    // "Sauna: false" in the source must not become "has a sauna".
    expect(profile.amenities.sauna).toBeNull();
    expect(provenance.core).toBe("JSON-LD VacationRental");
  });

  it("falls back to the page title when nothing structured exists", () => {
    const { profile } = profileFromBlocks(extractBlocks("<html><head><title>Haus am See</title></head><body>Text</body></html>"), "vacation_home");
    expect(profile.title).toBe("Haus am See");
    expect(profile.bedrooms).toBeNull();
  });
});

describe("what real pages taught us", () => {
  const ld = (node: unknown) => `<script type="application/ld+json">${JSON.stringify(node)}</script>`;

  it("does not mistake the portal for the hotel", () => {
    const html = `<html><head><title>Hotel Sol y Mar, Mallorca | Portal</title>
      ${ld({ "@type": "Product", name: "Portal Pauschalreisen", aggregateRating: { ratingValue: 5, bestRating: 5, reviewCount: 56718 } })}
      </head><body>Hotel</body></html>`;
    const { profile } = profileFromBlocks(extractBlocks(html), "package");
    expect(profile.title).toBe("Hotel Sol y Mar, Mallorca | Portal");
    expect(profile.rating.value).toBeNull();
  });

  it("accepts a product that the page is titled after", () => {
    const html = `<html><head><title>Casa Azul in Tavira</title>
      ${ld({ "@type": "Product", name: "Casa Azul", aggregateRating: { ratingValue: 4.8, bestRating: 5, reviewCount: 12 } })}
      </head><body>Haus</body></html>`;
    const { profile } = profileFromBlocks(extractBlocks(html), "vacation_home");
    expect(profile.title).toBe("Casa Azul");
    expect(profile.rating).toEqual({ value: 4.8, scale: 5, count: 12 });
  });

  it("ignores ratings that belong to something else on the page", () => {
    const html = `<html><head>${ld([{ "@type": "VacationRental", name: "Haus" }, { "@type": "Organization", name: "Portal", aggregateRating: { ratingValue: 4.9 } }])}</head><body>x</body></html>`;
    expect(profileFromBlocks(extractBlocks(html), "vacation_home").profile.rating.value).toBeNull();
  });

  it("reads rooms from the advert's headline and trusts the visible guest count over JSON-LD", () => {
    const html = `<html><head>
      <meta property="og:title" content="Villa in Calonge · ★4,95 · 4 Schlafzimmer · 4 Betten · 4,5 Badezimmer">
      ${ld({ "@type": "VacationRental", name: "Villa mit Pool", containsPlace: { occupancy: { "@type": "QuantitativeValue", value: 4 } } })}
      <script id="data-deferred-state-0" type="application/json">${JSON.stringify({ niobe: [["x", { data: { listing: { personCapacity: 8 } } }]] })}</script>
      </head><body>Villa</body></html>`;
    const { profile, provenance } = profileFromBlocks(extractBlocks(html), "vacation_home");
    expect(profile).toMatchObject({ maxGuests: 8, bedrooms: 4, beds: 4, bathrooms: 4.5 });
    expect(profile.uncertain).toContain("maxGuests");
    expect(profile.warnings[0]).toMatch(/8 Gäste.*4/);
    expect(provenance.maxGuests).toBe("Angabe auf der Seite");
  });

  it("does not read a guest count into a hotel from its description", () => {
    const html = `<html><head><meta name="description" content="Zimmer für 2 Personen"><title>Hotel</title></head><body>x</body></html>`;
    expect(profileFromBlocks(extractBlocks(html), "hotel").profile.maxGuests).toBeNull();
  });

  it("does not take a portal's home page title and picture for the advert", () => {
    const html = `<html><head><title>Ferienhäuser online buchen – Portal</title>
      <meta property="og:title" content="Ferienhäuser online buchen – Portal"><meta property="og:image" content="https://portal.example.test/collage.jpg">
      <meta property="og:url" content="https://www.portal.example.test/"></head><body>Villa Sonnenschein, 4 Schlafzimmer</body></html>`;
    const blocks = extractBlocks(html);
    const { profile } = profileFromBlocks(blocks, "vacation_home");
    expect(profile.title).toBeNull();
    expect(profile.coverImageUrl).toBeNull();
    expect(modelInput(blocks)).not.toContain("online buchen");
    expect(modelInput(blocks)).toContain("Villa Sonnenschein");
    // A page that names its own address keeps its metadata.
    const own = extractBlocks(html.replace('test/"', 'test/rental/abc"'));
    expect(profileFromBlocks(own, "vacation_home").profile.title).toMatch(/online buchen/);
  });

  it("collects the advert's gallery, one address per picture, without icons or other adverts", () => {
    const pic = (n: number) => ({ id: n, baseUrl: `https://a0.muscache.com/im/pictures/p${n}.jpeg`, thumb: `https://a0.muscache.com/im/pictures/p${n}.jpeg?im_w=240`, accessibilityLabel: `Bild ${n}` });
    const state = { listing: { photos: [1, 2, 3, 4, 5].map(pic), host: { images: ["https://a0.muscache.com/im/users/avatar.jpg"] } }, similar: [{ images: ["https://a0.muscache.com/im/pictures/other.jpeg"] }] };
    const html = `<html><head><script id="data-deferred-state-0" type="application/json">${JSON.stringify(state)}</script></head>
      <body><img src="https://cdn.example.test/logo.png"><p>Villa</p></body></html>`;
    const blocks = extractBlocks(html);
    expect(blocks.photos.map((p) => p.url)).toEqual([1, 2, 3, 4, 5].map((n) => `https://a0.muscache.com/im/pictures/p${n}.jpeg`));
    expect(blocks.photos[0]!.caption).toBe("Bild 1");
    const { profile } = profileFromBlocks(blocks, "vacation_home");
    expect(profile.photoCount).toBe(5);
    expect(profile.coverImageUrl).toBe("https://a0.muscache.com/im/pictures/p1.jpeg");
    expect(profile.photos[0]).toMatchObject({ thumbUrl: "https://a0.muscache.com/im/pictures/p1.jpeg?im_w=720", caption: "Bild 1" });
    // The model's input stays free of picture lists.
    expect(modelInput(blocks)).not.toContain("muscache");
  });

  it("falls back to the pictures in a page rendered on the device", () => {
    const img = (n: number) => `<img srcset="https://img.example.test/h${n}_400.jpg 400w, https://img.example.test/h${n}_1600.jpg 1600w" alt="Zimmer ${n}">`;
    const html = `<html><body><img src="https://img.example.test/icon-pool.png" width="24">${[1, 2, 3, 4].map(img).join("")}<img src="/relative.jpg"><img src="https://bat.bing.com/action/0?ti=1&evt=pageLoad"><img src="https://stats.example.test/t?u=1"></body></html>`;
    const { photos } = extractBlocks(html);
    expect(photos.map((p) => p.url)).toEqual([1, 2, 3, 4].map((n) => `https://img.example.test/h${n}_1600.jpg`));
    expect(photos[1]!.caption).toBe("Zimmer 2");
  });

  it("hands a huge page state to the model as readable lines instead of its first slice", () => {
    const filler = Array.from({ length: 400 }, (_, i) => ({ __typename: "LoggingContext", loggingId: `evt_${i}_${"x".repeat(40)}`, icon: "SYSTEM_CHECK", sectionId: `SECTION_${i}` }));
    const state = { niobe: { filler, sections: [{ title: "Schlafbereiche", items: [{ title: "Schlafzimmer 1", subtitle: "1 Doppelbett" }] }, { amenities: [{ title: "Geschirrspüler", available: true }, { title: "Geschirrspüler" }] }, { bedroomCount: 4, personCapacity: 8, layoutWidth: 1200 }] } };
    const html = `<html><head><script id="data-deferred-state-0" type="application/json">${JSON.stringify(state)}</script></head><body>Villa</body></html>`;
    const blocks = extractBlocks(html);
    const input = modelInput(blocks, { state: 1000, digest: 30_000, text: 14_000 });
    expect(input).toContain("subtitle: 1 Doppelbett");
    expect(input).toContain("bedroomCount: 4");
    expect(input).not.toMatch(/evt_|SYSTEM_CHECK|layoutWidth|LoggingContext/);
    // Each text once, and a budget that is kept.
    expect(input.match(/Geschirrspüler/g)).toHaveLength(1);
    expect(digestState({ a: Array.from({ length: 500 }, (_, i) => `Satz Nummer ${i} mit etwas Text`) }, 2000)).toMatch(/\[gekürzt\]$/);
  });

  it("takes the pictures the app saw load, each once and in its largest size", () => {
    const c = "https://cdn.hometogo.net";
    const html = `<html><body><img src="${c}/medium/e_v5/aaa.jpg"><p>Villa</p>
      <div id="tp-captured-images" hidden><img src="${c}/medium/e_v5/aaa.jpg"><img src="${c}/large/e_v5/aaa.jpg"><img src="${c}/large/e_v5/bbb.jpg"><img src="${c}/medium/v1/ccc.jpg"><img src="https://bat.bing.com/action/0?ti=1"><img src="${c}/thumb/v1/ccc.jpg"></div></body></html>`;
    const blocks = extractBlocks(html);
    expect(blocks.photos.map((p) => p.url)).toEqual([`${c}/large/e_v5/aaa.jpg`, `${c}/large/e_v5/bbb.jpg`, `${c}/medium/v1/ccc.jpg`]);
    expect(profileFromBlocks(blocks, "vacation_home").profile.photos[0]!.thumbUrl).toBe(`${c}/medium/e_v5/aaa.jpg`);
  });

  it("keeps other adverts' pictures out when the page itself says which ones belong", () => {
    const m = "https://a0.muscache.com/im/pictures";
    const ld = { "@type": "VacationRental", name: "Haus", image: [1, 2, 3].map((n) => `${m}/own${n}.jpeg?im_w=480`) };
    const shown = [`${m}/own2.jpeg?im_w=320`, `${m}/similar1.jpeg?im_w=320`, `${m}/similar2.jpeg?im_w=320`, `${m}/similar3.jpeg?im_w=320`, `${m}/similar4.jpeg?im_w=320`];
    const html = (attr: string) => `<html><head><script type="application/ld+json">${JSON.stringify(ld)}</script></head><body>Haus
      <div id="tp-captured-images" hidden>${shown.map((u, i) => `<img src="${u}"${i > 0 ? attr : ""}>`).join("")}</div></body></html>`;
    expect(extractBlocks(html("")).photos.map((p) => p.url)).toEqual([`${m}/own1.jpeg?im_w=480`, `${m}/own2.jpeg`, `${m}/own3.jpeg?im_w=480`]);
    // Marked by the app as the gallery: then the device is believed.
    expect(extractBlocks(html(' data-gallery="1"')).photos.map((p) => p.url).slice(0, 4)).toEqual([1, 2, 3, 4].map((n) => `${m}/similar${n}.jpeg`));
  });

  it("collects single reviews and shows them to the model in their own block", () => {
    const ld = { "@type": "VacationRental", name: "Haus", review: [{ "@type": "Review", reviewBody: "Sehr schönes Haus mit tollem Pool, wir kommen wieder.", reviewRating: { ratingValue: 5, bestRating: 5 }, author: { name: "Anna" }, datePublished: "2026-08-14T10:00:00Z" }] };
    const state = { hotel: { ratingList: [{ comment: "Das Buffet war gut, aber die Liegen kosten extra.", score: 8.5, firstName: "Jörg", date: 1755129600 }, { comment: "Sehr schönes Haus mit tollem Pool, wir kommen wieder." }, { score: 9 }], other: { reviews: [{ text: "Bewertung eines ganz anderen Angebots in der Nähe." }] } } };
    const html = `<html><head><script type="application/ld+json">${JSON.stringify(ld)}</script><script id="js-hotel-data" type="application/json">${JSON.stringify(state)}</script></head><body>Haus</body></html>`;
    const blocks = extractBlocks(html);
    expect(blocks.reviews).toEqual([
      { text: "Sehr schönes Haus mit tollem Pool, wir kommen wieder.", title: null, rating: 5, scale: 5, date: "2026-08-14", author: "Anna" },
      { text: "Das Buffet war gut, aber die Liegen kosten extra.", title: null, rating: 8.5, scale: null, date: "2025-08-14", author: "Jörg" },
    ]);
    const { profile } = profileFromBlocks(blocks, "hotel");
    expect(profile.reviews[0]).toMatchObject({ id: expect.stringMatching(/^[0-9a-f]{16}$/), author: "Anna" });
    const input = modelInput(blocks);
    expect(input).toContain('<reviews count="2">');
    expect(input).toContain("[8.5] (2025-08-14) Das Buffet war gut");
    // The reviews reach the model once, not a second time inside the page state.
    expect(input.match(/Liegen kosten extra/g)).toHaveLength(1);
    // The model's summary is kept, the reviews themselves come from the page.
    const combined = combine(profile, { ...emptyProfile("hotel"), reviews: [], reviewSummary: { summary: "Gäste loben den Pool.", positives: ["Pool", "a", "b", "c", "d"], negatives: [], basedOn: 2 } });
    expect(combined.reviews).toHaveLength(2);
    expect(combined.reviewSummary).toMatchObject({ summary: "Gäste loben den Pool.", basedOn: 2 });
    expect(combined.reviewSummary.positives).toHaveLength(4);
  });

  it("finds state that a page assigns in an inline script", () => {
    const inner = JSON.stringify({ "Property:1": { headline: 'Haus "Düne"', note: "it's", sleeps: 8 } });
    const literal = JSON.stringify(inner).replace(/'/g, "\\'").replace("ü", "\\xfc");
    const html = `<html><body><script>window.__APOLLO_STATE__ = JSON.parse(${literal});window.__OTHER__ = JSON.parse("{\\"a\\":[1]}");</script>
      <script>window.__PLUGIN_STATE__ = {"view":{"city":"Zingst"}};</script><p>Text</p></body></html>`;
    const { state } = extractBlocks(html);
    expect(state.__APOLLO_STATE__).toEqual({ "Property:1": { headline: 'Haus "Düne"', note: "it's", sleeps: 8 } });
    expect(state.__OTHER__).toEqual({ a: [1] });
    expect(findKey(state, "city")).toBe("Zingst");
    expect(inlineState("var a = 1;")).toEqual([]);
  });
});

describe("prune", () => {
  it("caps long arrays and long strings", () => {
    const pruned = prune({ list: Array.from({ length: 100 }, (_, i) => i), text: "x".repeat(2000) }) as { list: number[]; text: string };
    expect(pruned.list).toHaveLength(40);
    expect(pruned.text.length).toBeLessThan(1600);
  });
});

describe("profiles", () => {
  it("counts how complete a profile is", () => {
    expect(fillPercent(emptyProfile())).toBe(0);
    const { profile } = profileFromBlocks(extractBlocks(fixture("novasol.html")), "vacation_home");
    expect(fillPercent(profile)).toBeGreaterThan(30);
    expect(fillPercent(profile)).toBeLessThan(80);
  });

  it("fills gaps without overwriting, unless told to", () => {
    const base = { ...emptyProfile(), title: "Alt", bedrooms: 3 };
    expect(mergeProfiles(base, { title: "Neu", bathrooms: 2 })).toMatchObject({ title: "Alt", bedrooms: 3, bathrooms: 2 });
    expect(mergeProfiles(base, { title: "Neu" }, true).title).toBe("Neu");
  });
});

describe("claudeExtractor", () => {
  const blocks = extractBlocks(fixture("novasol.html"));
  const link = analyzeLink("https://www.novasol.de/ferienhaeuser/XYZ123");
  const { profile: baseline } = profileFromBlocks(blocks, "vacation_home");
  const stub = (response: unknown) => ({ messages: { create: async () => response } }) as never;

  it("merges the model's reading onto the structured baseline", async () => {
    const answer = { ...emptyProfile(), kind: "hotel", sleepingPlaces: 8, lat: 1, summary: "Villa am Meer.", price: { totalEur: 2646, kind: "from", nights: 7 }, uncertain: ["sleepingPlaces"], warnings: ["a", "b", "c", "d", "e"] };
    const extract = claudeExtractor({ apiKey: "x", model: "m", client: stub({ stop_reason: "end_turn", content: [{ type: "thinking", thinking: "" }, { type: "text", text: `\`\`\`json\n${JSON.stringify(answer)}\n\`\`\`` }] }) });
    const { profile, note } = await extract({ blocks, link, baseline });
    expect(note).toBeNull();
    expect(profile).toMatchObject({ kind: "vacation_home", bedrooms: 3, sleepingPlaces: 8, summary: "Villa am Meer.", lat: 42.96 });
    expect(profile.price).toMatchObject({ totalEur: 2646, kind: "from" });
    expect(profile.uncertain).toEqual(["sleepingPlaces"]);
    expect(profile.warnings).toHaveLength(4);
  });

  it("keeps the baseline when the model declines or answers with something unusable", async () => {
    for (const response of [{ stop_reason: "refusal", content: [] }, { stop_reason: "end_turn", content: [{ type: "text", text: "Das kann ich nicht." }] }, { stop_reason: "max_tokens", content: [{ type: "text", text: "{" }] }]) {
      const { profile, note } = await claudeExtractor({ apiKey: "x", model: "m", client: stub(response) })({ blocks, link, baseline });
      expect(profile).toEqual(baseline);
      expect(note).toMatch(/strukturierte Daten/);
    }
  });

  it("sorts collected reviews in calls of their own, and keeps them even when the reading is cut off", async () => {
    const captured = Array.from({ length: 45 }, (_, i) => `Gast ${i}\nAugust 2026\nEin wirklich schöner Aufenthalt Nummer ${i}, gerne wieder.`);
    const calls: string[] = [];
    const client = {
      messages: {
        create: async (params: { system: string; messages: { content: string }[] }) => {
          const sorting = params.system.includes('"items"');
          calls.push(sorting ? "sort" : "read");
          if (!sorting) return { stop_reason: "max_tokens", content: [{ type: "text", text: "{" }] };
          // The second batch fails; its blocks are kept as they came.
          if (params.messages[0]!.content.includes("Nummer 20,")) return { stop_reason: "max_tokens", content: [] };
          const n = params.messages[0]!.content.split("<block").length - 1;
          return { stop_reason: "end_turn", content: [{ type: "text", text: JSON.stringify({ items: Array.from({ length: n }, (_, i) => ({ i, keep: i !== 1, author: "Gast", date: "August 2026", rating: 5, scale: 5, start: "Ein wirklich schöner Aufenthalt", end: "gerne wieder." })) }) }] };
        },
      },
    } as never;
    const { profile, note } = await claudeExtractor({ apiKey: "x", model: "m", client })({ blocks: { ...blocks, capturedReviews: captured }, link, baseline: { ...baseline, reviews: [] } });
    expect(calls.sort()).toEqual(["read", "sort", "sort", "sort", "sort", "sort"]);
    expect(note).toMatch(/abgeschnitten/);
    // 45 blocks in five batches, one in each sorted batch dropped as no review, the failed batch kept whole.
    expect(profile.reviews).toHaveLength(41);
    expect(profile.reviews[0]).toMatchObject({ author: "Gast", rating: 5, text: "Ein wirklich schöner Aufenthalt Nummer 0, gerne wieder." });
    expect(profile.reviews.find((r) => r.text.includes("Nummer 25,"))).toMatchObject({ author: null, text: expect.stringContaining("Gast 25") });
  });

  it("drops a malformed field instead of the whole answer", () => {
    const answer = { ...emptyProfile(), title: "Haus", bedrooms: "drei", maxGuests: 8, highlights: ["Pool", 7, "Meerblick"], price: { ...emptyProfile().price, totalEur: "2.646 €", nights: 7 } };
    const result = parseLenient(answer);
    expect(result?.profile).toMatchObject({ title: "Haus", bedrooms: null, maxGuests: 8, highlights: ["Pool", "Meerblick"], price: { totalEur: null, nights: 7 } });
    expect(result?.dropped.map((d) => d.split(":")[0]).sort()).toEqual(["bedrooms", "highlights.1", "price.totalEur"]);
    const beds = parseLenient({ bedDetails: ["Schlafzimmer 1: 1 Doppelbett", { name: "Wohnraum", description: "1 Schlafsofa" }, { room: "Flur" }] });
    expect(beds?.profile.bedDetails).toEqual([{ room: "Schlafzimmer 1", beds: "1 Doppelbett" }, { room: "Wohnraum", beds: "1 Schlafsofa" }]);
    // Keys the model left out, and an object where it wrote null, fall back to empty values.
    const sparse = parseLenient({ title: "Haus", amenities: { pool: true }, price: null, rating: { value: 4.5 } });
    expect(sparse?.profile).toMatchObject({ title: "Haus", bedrooms: null, amenities: { pool: true, wifi: null }, price: { totalEur: null, extraCosts: [] }, rating: { value: 4.5, count: null }, warnings: [] });
    expect(sparse?.dropped).toEqual([]);
    expect(parseLenient("kein Objekt")).toBeNull();
    expect(parseLenient([1])).toBeNull();
  });

  it("never takes coordinates or ratings from prose", () => {
    const model = { ...emptyProfile(), lat: 1, lon: 2, rating: { value: 5, scale: 5, count: 1 } };
    const withRating = { ...baseline, rating: { value: 4.9, scale: 5, count: 58 } };
    expect(combine(withRating, model)).toMatchObject({ lat: 42.96, lon: 16.7, rating: { value: 4.9, count: 58 } });
  });
});

describe("fetch safety", () => {
  it("refuses internal targets", async () => {
    for (const url of ["http://127.0.0.1/", "http://10.0.0.5/", "http://192.168.1.1/admin", "http://100.101.102.103/", "http://[::1]/", "http://localhost/", "http://server.tail1234.ts.net/", "https://user:pw@example.com/", "https://example.com:5432/", "file:///etc/passwd"]) {
      await expect(assertPublicUrl(url), url).rejects.toBeInstanceOf(UnsafeUrlError);
    }
  });

  it("recognises bot checks", () => {
    expect(looksBlocked(200, fixture("blocked.html"))).toBe(true);
    expect(looksBlocked(429, "")).toBe(true);
    expect(looksBlocked(200, fixture("novasol.html"))).toBe(false);
  });
});

describe("reviews collected on the device", () => {
  const html = `<html><head><title>Haus</title></head><body><p>${"Text der Seite. ".repeat(40)}</p>
    <div id="tp-captured-reviews" hidden>
      <div data-review>Jörg\nAugust 2026\n5 Sterne\nWunderbares Haus direkt am Meer, wir kommen wieder.\nAntwort des Gastgebers: Danke!</div>
      <div data-review>Häufige Fragen: Gibt es WLAN? Ja, im ganzen Haus.</div>
      <div data-review>kurz</div>
    </div></body></html>`;

  it("takes the blocks out of the page text and hands them to the model by number", () => {
    const blocks = extractBlocks(html);
    expect(blocks.capturedReviews).toHaveLength(2);
    expect(blocks.text).not.toContain("Wunderbares Haus");
    expect(modelInput(blocks)).toContain('<block i="0">Jörg August 2026 5 Sterne Wunderbares Haus');
  });

  it("cuts the guest's words from the block and drops what is no review", () => {
    const blocks = extractBlocks(html).capturedReviews;
    const reviews = reviewsFromBlocks(blocks, [
      { i: 0, keep: true, author: "Jörg", date: "August 2026", rating: 5, scale: 5, start: "Wunderbares Haus direkt am Meer,", end: "wir kommen wieder." },
      { i: 1, keep: false },
      { i: 7, keep: true },
    ]);
    expect(reviews).toHaveLength(1);
    expect(reviews[0]).toMatchObject({ author: "Jörg", date: "August 2026", rating: 5, scale: 5, text: "Wunderbares Haus direkt am Meer, wir kommen wieder." });
  });
});

describe("cost items in whatever shape the model chose", () => {
  it("keeps them", () => {
    const parsed = profileSchema.parse({ price: { extraCosts: ["Kurtaxe", { name: "Endreinigung", amount: "120,50 €" }, { item: "Strom", amountEur: "nach Verbrauch" }, { item: "Bettwäsche", amountEur: 15, note: "pro Person" }] } });
    expect(parsed.price.extraCosts).toEqual([
      { item: "Kurtaxe", amountEur: null, note: null },
      { item: "Endreinigung", amountEur: 120.5, note: null },
      { item: "Strom", amountEur: null, note: "nach Verbrauch" },
      { item: "Bettwäsche", amountEur: 15, note: "pro Person" },
    ]);
  });
});

describe("country names", () => {
  it("come out in one German spelling", () => {
    for (const raw of ["Croatia", "HR", "Hrvatska", "kroatien", " Croatie "]) expect(germanCountry(raw)).toBe("Kroatien");
    expect(germanCountry("Spain")).toBe("Spanien");
    expect(germanCountry("United States")).toBe("Vereinigte Staaten");
    expect(germanCountry("Türkei")).toBe("Türkei");
    expect(germanCountry("Atlantis")).toBe("Atlantis");
    expect(germanCountry(null)).toBeNull();
    expect(mergeProfiles(emptyProfile(), { country: "Italy" }).country).toBe("Italien");
  });
});

describe("positions", () => {
  it("are believed only inside the advert's own country", () => {
    expect(positionFitsCountry(45.09, 14.12, "Kroatien")).toBe(true);
    expect(positionFitsCountry(45.09, 14.12, "Croatia")).toBe(true);
    expect(positionFitsCountry(60.17, 24.8, "Kroatien")).toBe(false);
    expect(positionFitsCountry(28.1, -15.4, "Spanien")).toBe(true);
    expect(positionFitsCountry(60.17, 24.8, null)).toBe(true);
    expect(positionFitsCountry(60.17, 24.8, "Atlantis")).toBe(true);
  });
});
