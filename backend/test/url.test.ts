import { describe, expect, it } from "vitest";
import { analyzeLink, embeddedTarget, urlForStay } from "../src/import/url.js";

// The links from the feasibility test of 15.11.2026.
const AIRBNB = "https://www.airbnb.de/rooms/18726447?unique_share_id=0aadc6e1-9c6f-49a2-88a1-3cc52c53796d&viralityEntryPoint=1&s=76&check_in=2027-08-14&check_out=2027-08-28&guests=1&adults=1";
const NOVASOL = "https://www.novasol.de/ferienhaeuser/CLD520";
const NOVASOL_SLUG = "https://www.novasol.de/ferienhaeuser/korcula-vela-luka-cld520";
const CHECK24 =
  "https://urlaub.check24.de/suche/angebot?airport=BER,BRE&areaId=605&cateringList=halfboard&days=11-25&departureDate=2027-08-06&ds=r&pageArea=package&returnDate=2027-08-30&roomAllocation=A-A-7-11&transportType=flight&hotelId=12912&hotelListId=7da1cbcf&bestSeller=1";
const CASAMUNDO =
  "https://www.casamundo.de/rental/33e7e6a874b3b81a?clickId=1KYQXX7SG3D1LQXF&adults=4&children=4&childrenAges[]=5&childrenAges[]=8&childrenAges[]=11&childrenAges[]=7&arrival=2027-08-14&dateRange=2027-08-21~2027-08-28&duration=14&persons=7&pCon=4620%7CEUR%7C2027-08-28%7C7%7C7%7C1794734186&priceRate=nonRefund";
const VRBO = "https://www.fewo-direkt.de/ferienwohnung-ferienhaus/p5212122?startDate=2027-08-21&endDate=2027-08-28&rm1=a4:c17:c17:c17:c17";
const ONELINK = "https://hmwy.onelink.me/hD4t/2q1msfos";

describe("analyzeLink", () => {
  it("reads an Airbnb link and flags the single guest", () => {
    const info = analyzeLink(AIRBNB);
    expect(info).toMatchObject({ platform: "airbnb", externalId: "18726447", canonicalUrl: "https://www.airbnb.de/rooms/18726447", kind: "vacation_home" });
    expect(info.stay).toMatchObject({ startDate: "2027-08-14", endDate: "2027-08-28", nights: 14, adults: 1 });
    expect(info.warnings.join(" ")).toMatch(/einem Gast/);
  });

  it("gives both Novasol spellings the same id", () => {
    expect(analyzeLink(NOVASOL)).toMatchObject({ platform: "novasol", externalId: "CLD520" });
    expect(analyzeLink(NOVASOL_SLUG).externalId).toBe("CLD520");
  });

  it("recognises a Check24 package holiday and its search window", () => {
    const info = analyzeLink(CHECK24);
    expect(info).toMatchObject({ platform: "check24", externalId: "12912", kind: "package", searchWindow: true });
    expect(analyzeLink(AIRBNB).searchWindow).toBe(false);
    expect(info.stay).toMatchObject({ adults: 2, children: 2, childAges: [7, 11], nights: null });
    expect(info.canonicalUrl).not.toMatch(/hotelListId|bestSeller|airport/);
    expect(info.warnings.join(" ")).toMatch(/11 bis 25 Tagen/);
  });

  it("reads party, dates and price from a Casamundo link and reports its contradictions", () => {
    const info = analyzeLink(CASAMUNDO);
    expect(info).toMatchObject({ platform: "casamundo", externalId: "33e7e6a874b3b81a", canonicalUrl: "https://www.casamundo.de/rental/33e7e6a874b3b81a" });
    expect(info.stay).toMatchObject({ startDate: "2027-08-21", endDate: "2027-08-28", nights: 7, adults: 4, children: 4, childAges: [5, 8, 11, 7] });
    expect(info.priceHint).toEqual({ totalEur: 4620, endDate: "2027-08-28", nights: 7, nonRefundable: true });
    expect(info.warnings).toHaveLength(2);
  });

  it("reads a FeWo-direkt link including the room string", () => {
    const info = analyzeLink(VRBO);
    expect(info).toMatchObject({ platform: "vrbo", externalId: "p5212122" });
    expect(info.stay).toMatchObject({ nights: 7, adults: 4, children: 4 });
    expect(info.warnings.join(" ")).toMatch(/pauschal mit 17/);
  });

  it("marks app short links for resolution", () => {
    expect(analyzeLink(ONELINK)).toMatchObject({ platform: "other", isShortLink: true });
    expect(embeddedTarget(new URL(`${ONELINK}?deep_link_value=${encodeURIComponent(VRBO)}`))).toBe(VRBO);
  });

  it("falls back to host and path for unknown sites", () => {
    expect(analyzeLink("https://www.ferienhaus-meier.example/haus-am-see/?utm_source=x")).toMatchObject({
      platform: "other",
      externalId: "www.ferienhaus-meier.example/haus-am-see",
      canonicalUrl: "https://www.ferienhaus-meier.example/haus-am-see/",
      isShortLink: false,
    });
  });

  it("rejects anything that is not a web link", () => {
    expect(() => analyzeLink("javascript:alert(1)")).toThrow();
    expect(() => analyzeLink("not a link")).toThrow();
  });
});

describe("urlForStay", () => {
  it("replaces the sharer's dates and party with those of the trip", () => {
    const url = new URL(urlForStay(analyzeLink(AIRBNB), { startDate: "2027-08-21", endDate: "2027-08-28", adults: 4, children: 4 }));
    expect(url.pathname).toBe("/rooms/18726447");
    expect(Object.fromEntries(url.searchParams)).toEqual({ check_in: "2027-08-21", check_out: "2027-08-28", adults: "4", children: "4" });
  });

  it("turns a Check24 search window into the trip's fixed stay", () => {
    const link = analyzeLink(CHECK24);
    const url = new URL(urlForStay(link, { startDate: "2027-05-15", endDate: "2027-05-29", adults: 4, children: 2 }));
    expect(Object.fromEntries(url.searchParams)).toMatchObject({ hotelId: "12912", departureDate: "2027-05-15", returnDate: "2027-05-29", days: "14", roomAllocation: "A-A-A-A-7-11", pageArea: "package" });
    // Another number of children than in the shared link: their ages are not known.
    expect(new URL(urlForStay(link, { startDate: "2027-05-15", endDate: "2027-05-29", adults: 2, children: 3 })).searchParams.get("roomAllocation")).toBe("A-A-10-10-10");
  });

  it("leaves the link alone without dates or for platforms without date parameters", () => {
    expect(urlForStay(analyzeLink(AIRBNB), { startDate: null, endDate: null, adults: 4, children: 0 })).toBe("https://www.airbnb.de/rooms/18726447");
    expect(urlForStay(analyzeLink(NOVASOL), { startDate: "2027-08-21", endDate: "2027-08-28", adults: 4, children: 0 })).toBe(NOVASOL);
  });
});
