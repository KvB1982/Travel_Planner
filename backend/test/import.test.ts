import { describe, expect, it } from "vitest";
import { extractBlocks, modelInput, profileFromBlocks, prune } from "../src/import/blocks.js";
import { claudeExtractor, combine } from "../src/import/extract.js";
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

describe("prune", () => {
  it("caps long arrays and long strings", () => {
    const pruned = prune({ list: Array.from({ length: 100 }, (_, i) => i), text: "x".repeat(2000) }) as { list: number[]; text: string };
    expect(pruned.list).toHaveLength(40);
    expect(pruned.text.length).toBeLessThan(700);
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
