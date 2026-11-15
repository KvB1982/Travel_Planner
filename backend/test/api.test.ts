import { listingSources } from "../src/db/schema.js";
import { describe, expect, it } from "vitest";
import { emptyProfile } from "../src/import/profile.js";
import type { Extractor } from "../src/import/extract.js";
import { fixture, page, testApp } from "./helpers.js";

const NOVASOL = "https://www.novasol.de/ferienhaeuser/XYZ123";
const AIRBNB = "https://www.airbnb.de/rooms/18726447?check_in=2027-08-14&check_out=2027-08-28&adults=1";
const CASAMUNDO = "https://www.casamundo.de/rental/33e7e6a874b3b81a?adults=4&children=4&dateRange=2027-08-21~2027-08-28&pCon=4620%7CEUR%7C2027-08-28%7C7&priceRate=nonRefund";

async function setup(options: Parameters<typeof testApp>[0] = {}) {
  const t = await testApp(options);
  const owner = await t.bootstrap();
  const created = await t.call("POST", "/trips", owner, {
    title: "Sommer 2027",
    region: "Kroatien",
    adults: 4,
    children: 4,
    dateOptions: [{ label: "Woche 2", startDate: "2027-08-21", endDate: "2027-08-28" }],
  });
  const tripId = created.body.trip.id as string;
  const join = async (role: "member" | "guest", name: string) => {
    const invite = await t.call("POST", `/trips/${tripId}/invites`, owner, { role });
    const accepted = await t.call("POST", `/auth/invites/${invite.body.token}/accept`, null, { name });
    return accepted.body.token as string;
  };
  const importLink = async (url: string, token = owner, html?: string) => {
    const res = await t.call("POST", `/trips/${tripId}/imports`, token, { url, html });
    await t.ctx.queue.idle();
    return res;
  };
  return { ...t, owner, tripId, join, importLink };
}

describe("setup and sign-in", () => {
  it("creates the first account once, and only with the secret", async () => {
    const t = await testApp();
    expect((await t.call("POST", "/auth/bootstrap", null, { secret: "wrong", name: "X" })).status).toBe(403);
    const token = await t.bootstrap();
    expect((await t.call("GET", "/me", token)).body.user.name).toBe("Kristian");
    expect((await t.call("POST", "/auth/bootstrap", null, { secret: "test-secret-with-enough-length-1234", name: "Zweiter" })).status).toBe(409);
  });

  it("requires a valid session", async () => {
    const t = await testApp();
    expect((await t.call("GET", "/trips")).status).toBe(401);
    expect((await t.call("GET", "/trips", "made-up-token")).status).toBe(401);
    const token = await t.bootstrap();
    expect((await t.call("POST", "/auth/logout", token)).status).toBe(204);
    expect((await t.call("GET", "/trips", token)).status).toBe(401);
  });
});

describe("trips and invites", () => {
  it("creates a trip with date options and lists it for its members only", async () => {
    const s = await setup();
    const detail = await s.call("GET", `/trips/${s.tripId}`, s.owner);
    expect(detail.body).toMatchObject({ role: "organizer", trip: { title: "Sommer 2027", adults: 4, children: 4 } });
    expect(detail.body.dateOptions).toHaveLength(1);
    expect(detail.body.members).toHaveLength(1);
    expect((await s.call("GET", "/trips", s.owner)).body.trips).toHaveLength(1);
  });

  it("rejects a date option that ends before it starts", async () => {
    const s = await setup();
    const res = await s.call("POST", `/trips/${s.tripId}/date-options`, s.owner, { startDate: "2027-08-28", endDate: "2027-08-21" });
    expect(res.status).toBe(400);
  });

  it("lets people join by invite, once per use", async () => {
    const s = await setup();
    const invite = await s.call("POST", `/trips/${s.tripId}/invites`, s.owner, { role: "member" });
    expect(invite.body.url).toBe(`https://reisen.example.test/einladung/${invite.body.token}`);
    expect((await s.call("GET", `/auth/invites/${invite.body.token}`)).body).toMatchObject({ trip: { title: "Sommer 2027" }, role: "member" });

    const first = await s.call("POST", `/auth/invites/${invite.body.token}/accept`, null, { name: "Anna" });
    expect(first.status).toBe(201);
    expect((await s.call("GET", `/trips/${s.tripId}`, first.body.token)).body.role).toBe("member");

    const second = await s.call("POST", `/auth/invites/${invite.body.token}/accept`, null, { name: "Ben" });
    expect(second.status).toBe(410);
    expect((await s.call("POST", "/auth/invites/unknown/accept", null, { name: "Ben" })).status).toBe(410);
  });

  it("hides a trip from people who are not in it", async () => {
    const s = await setup();
    const member = await s.join("member", "Anna");
    const other = await s.call("POST", "/trips", member, { title: "Pfingsten" });
    expect((await s.call("GET", `/trips/${other.body.trip.id}`, s.owner)).status).toBe(404);
    expect((await s.call("POST", `/trips/${other.body.trip.id}/imports`, s.owner, { url: NOVASOL })).status).toBe(404);
  });

  it("keeps invites and trip settings to the organizer", async () => {
    const s = await setup();
    const member = await s.join("member", "Anna");
    expect((await s.call("POST", `/trips/${s.tripId}/invites`, member, {})).status).toBe(403);
    expect((await s.call("PATCH", `/trips/${s.tripId}`, member, { title: "Gekapert" })).status).toBe(403);
    expect((await s.call("PATCH", `/trips/${s.tripId}`, s.owner, { status: "decided" })).body.trip.status).toBe("decided");
  });
});

describe("import", () => {
  it("turns a shared link into a filled candidate", async () => {
    const s = await setup();
    const res = await s.importLink(NOVASOL);
    expect(res.status).toBe(202);
    expect(res.body).toMatchObject({ platform: "novasol", duplicate: false });

    const list = await s.call("GET", `/trips/${s.tripId}/candidates`, s.owner);
    expect(list.body.candidates).toHaveLength(1);
    expect(list.body.candidates[0]).toMatchObject({
      status: "new",
      importStatus: "partial", // no language model in this test: structured data only
      addedBy: "Kristian",
      listing: { title: "Ferienhaus Musterort (XYZ123)", place: "Musterort", bedrooms: 3, maxGuests: 8, platforms: ["novasol"] },
    });
    expect(list.body.candidates[0].importNote).toMatch(/Ohne KI/);
    expect(list.body.candidates[0].listing.fillPercent).toBeGreaterThan(30);
  });

  it("asks the platform for the trip's dates and party, not the sharer's", async () => {
    const s = await setup({ fetcher: async () => page(fixture("novasol.html")) });
    await s.importLink(AIRBNB);
    const url = new URL(s.requested.at(-1)!);
    expect(Object.fromEntries(url.searchParams)).toEqual({ check_in: "2027-08-21", check_out: "2027-08-28", adults: "4", children: "4" });
  });

  it("labels the stay with the trip's dates and party when the page was fetched for them", async () => {
    const s = await setup({ fetcher: async () => page(fixture("novasol.html")) });
    const res = await s.importLink(AIRBNB);
    const detail = await s.call("GET", `/candidates/${res.body.candidateId}`, s.owner);
    // The link said 14 nights from 14 August for one guest.
    expect(detail.body.listing.profile.price).toMatchObject({ startDate: "2027-08-21", endDate: "2027-08-28", nights: 7, persons: 8 });
  });

  it("does not turn a search window into a stay", async () => {
    const s = await setup({ fetcher: async () => page(fixture("novasol.html")) });
    const res = await s.importLink("https://urlaub.check24.de/suche/angebot?days=11-25&departureDate=2027-08-06&pageArea=package&returnDate=2027-08-30&roomAllocation=A-A-7-11&hotelId=12912");
    const detail = await s.call("GET", `/candidates/${res.body.candidateId}`, s.owner);
    expect(detail.body.listing.profile.price).toMatchObject({ startDate: null, endDate: null, nights: null, persons: 4 });
    expect(detail.body.listing.profile.warnings.join(" ")).toMatch(/11 bis 25 Tagen/);
  });

  it("reads an advert again on request, but not twice within a minute", async () => {
    const s = await setup();
    const id = (await s.importLink(NOVASOL)).body.candidateId as string;
    expect((await s.call("POST", `/candidates/${id}/refresh`, s.owner)).status).toBe(429);
    await s.ctx.db.update(listingSources).set({ lastFetchedAt: new Date(Date.now() - 120_000) });
    const before = s.requested.length;
    expect((await s.call("POST", `/candidates/${id}/refresh`, s.owner)).status).toBe(202);
    await s.ctx.queue.idle();
    expect(s.requested.length).toBe(before + 1);
    expect((await s.call("GET", `/candidates/${id}`, s.owner)).body.candidate.importStatus).toBe("partial");
  });

  it("removes an advert from a trip and lets the same link be shared again", async () => {
    const s = await setup();
    const id = (await s.importLink(NOVASOL)).body.candidateId as string;
    await s.call("PUT", `/candidates/${id}/vote`, s.owner, { verdict: "yes" });
    await s.call("POST", `/candidates/${id}/comments`, s.owner, { body: "Hm." });
    const guest = await s.join("guest", "Gast");
    expect((await s.call("DELETE", `/candidates/${id}`, guest)).status).toBe(403);
    expect((await s.call("DELETE", `/candidates/${id}`, s.owner)).status).toBe(204);
    expect((await s.call("GET", `/candidates/${id}`, s.owner)).status).toBe(404);
    expect((await s.call("GET", `/trips/${s.tripId}/candidates`, s.owner)).body.candidates).toHaveLength(0);
    const again = await s.importLink(NOVASOL);
    expect(again.body.candidateId).not.toBe(id);
    expect((await s.call("GET", `/trips/${s.tripId}/candidates`, s.owner)).body.candidates).toHaveLength(1);
  });

  it("recognises the same advert shared twice", async () => {
    const s = await setup();
    const first = await s.importLink(NOVASOL);
    const again = await s.importLink("https://www.novasol.de/ferienhaeuser/musterort-xyz123?utm_source=whatsapp");
    expect(again.status).toBe(200);
    expect(again.body).toMatchObject({ duplicate: true, candidateId: first.body.candidateId });
    expect((await s.call("GET", `/trips/${s.tripId}/candidates`, s.owner)).body.candidates).toHaveLength(1);
  });

  it("keeps what the link says when the platform blocks the server, then fills in from the device", async () => {
    const s = await setup({ fetcher: async () => page(fixture("blocked.html"), { status: 403, blocked: true }) });
    const res = await s.importLink(CASAMUNDO);
    const id = res.body.candidateId as string;

    let detail = await s.call("GET", `/candidates/${id}`, s.owner);
    expect(detail.body.candidate).toMatchObject({ importStatus: "partial" });
    expect(detail.body.candidate.importNote).toMatch(/auf deinem Gerät/);
    expect(detail.body.listing.profile.price).toMatchObject({ startDate: "2027-08-21", endDate: "2027-08-28", nights: 7, persons: 8, totalEur: 4620 });
    expect(detail.body.listing.profile.uncertain).toContain("price.totalEur");
    expect(detail.body.listing.profile.cancellation).toMatch(/nicht erstattbar/);

    const listed = await s.call("GET", `/trips/${s.tripId}/candidates`, s.owner);
    expect(listed.body.candidates[0].price).toMatchObject({ totalCents: 462000, nights: 7, forThisTrip: false });

    const capture = await s.call("POST", `/candidates/${id}/capture`, s.owner, { html: fixture("novasol.html") });
    expect(capture.status).toBe(202);
    await s.ctx.queue.idle();
    detail = await s.call("GET", `/candidates/${id}`, s.owner);
    expect(detail.body.listing).toMatchObject({ title: "Ferienhaus Musterort (XYZ123)", profile: { bedrooms: 3, price: { totalEur: 4620 } } });
    expect(detail.body.sources[0].provenance.details).toBe("Auf dem Gerät ausgelesen");
    expect(detail.body.prices[0]).toMatchObject({ totalCents: 462000, capture: "device", tripId: s.tripId });
  });

  it("does not pass a link's price off as the price of a trip with other dates, and records it once", async () => {
    const s = await setup({ fetcher: async () => page(fixture("blocked.html"), { status: 403, blocked: true }) });
    const other = await s.call("POST", "/trips", s.owner, { title: "Pfingsten 2027", adults: 4, children: 4, dateOptions: [{ startDate: "2027-05-15", endDate: "2027-05-29" }] });
    const tripId = other.body.trip.id as string;
    const res = await s.call("POST", `/trips/${tripId}/imports`, s.owner, { url: CASAMUNDO });
    await s.ctx.queue.idle();
    const id = res.body.candidateId as string;
    for (let i = 0; i < 2; i++) {
      await s.call("POST", `/candidates/${id}/capture`, s.owner, { html: fixture("novasol.html") });
      await s.ctx.queue.idle();
    }
    const detail = await s.call("GET", `/candidates/${id}`, s.owner);
    // The August price from the link is still known, but belongs to no trip.
    expect(detail.body.prices).toHaveLength(1);
    expect(detail.body.prices[0]).toMatchObject({ totalCents: 462000, startDate: "2027-08-21", tripId: null });
    const listed = await s.call("GET", `/trips/${tripId}/candidates`, s.owner);
    expect(listed.body.candidates[0].price).toMatchObject({ forThisTrip: false });
    // Pictures come with the detail, first one is the cover.
    expect(detail.body.photos.map((p: { url: string }) => p.url)).toEqual(["https://images.example.test/1.jpg", "https://images.example.test/2.jpg", "https://images.example.test/3.jpg"]);
    expect(detail.body.photos[0]).toMatchObject({ id: expect.stringMatching(/^[0-9a-f]{16}$/), thumbUrl: null, caption: null });
  });

  it("uses page content sent along with the link instead of fetching", async () => {
    const s = await setup({
      fetcher: async () => {
        throw new Error("must not fetch");
      },
    });
    await s.importLink(NOVASOL, s.owner, fixture("novasol.html"));
    const list = await s.call("GET", `/trips/${s.tripId}/candidates`, s.owner);
    expect(list.body.candidates[0].listing.title).toBe("Ferienhaus Musterort (XYZ123)");
    expect(s.requested).toHaveLength(0);
  });

  it("stores the language model's reading, its price and its warnings", async () => {
    const extractor: Extractor = async ({ baseline }) => ({
      profile: { ...baseline, sleepingPlaces: 8, summary: "Villa am Meer.", warnings: ["Der vierte Schlafplatz ist ein Schlafsofa."], uncertain: ["sleepingPlaces"], price: { ...emptyProfile().price, totalEur: 2646, kind: "from", nights: 7 } },
      note: null,
    });
    const s = await setup({ extractor });
    const res = await s.importLink(AIRBNB);
    const detail = await s.call("GET", `/candidates/${res.body.candidateId}`, s.owner);
    expect(detail.body.candidate.importStatus).toBe("ready");
    expect(detail.body.listing.profile).toMatchObject({ sleepingPlaces: 8, summary: "Villa am Meer.", uncertain: ["sleepingPlaces"] });
    // The page was read for the trip, so the sharer's single guest is no longer worth a hint.
    expect(detail.body.listing.profile.warnings).toEqual(["Der vierte Schlafplatz ist ein Schlafsofa."]);
    expect(detail.body.prices[0]).toMatchObject({ totalCents: 264600, kind: "from", capture: "import" });
  });

  it("marks the candidate as failed when reading the page breaks", async () => {
    const s = await setup({
      fetcher: async () => {
        throw new Error("network down");
      },
    });
    const res = await s.importLink(NOVASOL);
    const detail = await s.call("GET", `/candidates/${res.body.candidateId}`, s.owner);
    expect(detail.body.candidate).toMatchObject({ importStatus: "failed" });
    expect(detail.body.candidate.importNote).toMatch(/von Hand/);
  });

  it("refuses links that are not web links", async () => {
    const s = await setup();
    expect((await s.call("POST", `/trips/${s.tripId}/imports`, s.owner, { url: "ftp://example.com/x" })).status).toBe(422);
    expect((await s.call("POST", `/trips/${s.tripId}/imports`, s.owner, { url: "kein link" })).status).toBe(400);
  });
});

describe("working with candidates", () => {
  it("lets guests vote and comment but not import or edit", async () => {
    const s = await setup();
    const id = (await s.importLink(NOVASOL)).body.candidateId as string;
    const guest = await s.join("guest", "Oma");

    expect((await s.call("POST", `/trips/${s.tripId}/imports`, guest, { url: AIRBNB })).status).toBe(403);
    expect((await s.call("PATCH", `/candidates/${id}`, guest, { status: "rejected" })).status).toBe(403);
    expect((await s.call("PUT", `/candidates/${id}/vote`, guest, { verdict: "yes" })).status).toBe(200);
    expect((await s.call("POST", `/candidates/${id}/comments`, guest, { body: "Schöner Pool!" })).status).toBe(201);
  });

  it("counts votes, lets people change their mind and shows who voted", async () => {
    const s = await setup();
    const id = (await s.importLink(NOVASOL)).body.candidateId as string;
    const anna = await s.join("member", "Anna");

    await s.call("PUT", `/candidates/${id}/vote`, s.owner, { verdict: "yes" });
    await s.call("PUT", `/candidates/${id}/vote`, anna, { verdict: "maybe" });
    await s.call("PUT", `/candidates/${id}/vote`, anna, { verdict: "no", veto: true });

    const list = await s.call("GET", `/trips/${s.tripId}/candidates`, anna);
    expect(list.body.candidates[0].votes).toEqual({ yes: 1, maybe: 0, no: 1, vetoes: 1 });
    expect(list.body.candidates[0].myVote).toMatchObject({ verdict: "no", veto: true });
    const detail = await s.call("GET", `/candidates/${id}`, s.owner);
    expect(detail.body.votes.entries.map((v: { name: string }) => v.name).sort()).toEqual(["Anna", "Kristian"]);
  });

  it("records status, rejection reason, notes and tags", async () => {
    const s = await setup();
    const id = (await s.importLink(NOVASOL)).body.candidateId as string;
    const res = await s.call("PATCH", `/candidates/${id}`, s.owner, { status: "rejected", rejectionReason: "Kein Zaun", tags: ["Pool"] });
    expect(res.body.candidate).toMatchObject({ status: "rejected", rejectionReason: "Kein Zaun", tags: ["Pool"] });
    expect((await s.call("PATCH", `/candidates/${id}`, s.owner, { status: "vielleicht" })).status).toBe(400);
    const activity = await s.call("GET", `/trips/${s.tripId}/activity`, s.owner);
    expect(activity.body.events.map((e: { type: string }) => e.type)).toEqual(expect.arrayContaining(["trip_created", "candidate_added", "candidate_status"]));
  });

  it("applies manual corrections and clears the uncertain mark of edited fields", async () => {
    const extractor: Extractor = async ({ baseline }) => ({ profile: { ...baseline, livingAreaSqm: 250, uncertain: ["livingAreaSqm", "amenities.grill"] }, note: null });
    const s = await setup({ extractor });
    const id = (await s.importLink(NOVASOL)).body.candidateId as string;

    const res = await s.call("PATCH", `/candidates/${id}/profile`, s.owner, { livingAreaSqm: 180, amenities: { fenced: true }, price: { depositEur: 500 } });
    expect(res.status).toBe(200);
    expect(res.body.listing.profile).toMatchObject({ livingAreaSqm: 180, bedrooms: 3, amenities: { fenced: true, pool: true }, price: { depositEur: 500 }, uncertain: ["amenities.grill"] });

    expect((await s.call("PATCH", `/candidates/${id}/profile`, s.owner, { bedrooms: "drei" })).status).toBe(400);
    expect((await s.call("PATCH", `/candidates/${id}/profile`, s.owner, { erfunden: 1 })).status).toBe(400);
  });

  it("prefers a price recorded for this trip over the one that came with the link", async () => {
    const s = await setup();
    const id = (await s.importLink(CASAMUNDO)).body.candidateId as string;
    const res = await s.call("POST", `/candidates/${id}/prices`, s.owner, { totalCents: 498000, startDate: "2027-08-21", endDate: "2027-08-28", persons: 8, breakdown: [{ item: "Endreinigung", amountCents: 15000 }] });
    expect(res.status).toBe(201);
    expect(res.body.price).toMatchObject({ nights: 7, capture: "manual" });
    const list = await s.call("GET", `/trips/${s.tripId}/candidates`, s.owner);
    expect(list.body.candidates[0].price).toMatchObject({ totalCents: 498000, forThisTrip: true, nights: 7 });
  });
});
