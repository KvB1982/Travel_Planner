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
    expect((await s.call("GET", "/trips", s.owner)).body.trips.filter((t: { kind: string }) => t.kind === "trip")).toHaveLength(1);
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

  it("asks for the trip's own stay where the shared link only had a search window", async () => {
    const s = await setup({ fetcher: async () => page(fixture("novasol.html")) });
    const res = await s.importLink("https://urlaub.check24.de/suche/angebot?days=11-25&departureDate=2027-08-06&pageArea=package&returnDate=2027-08-30&roomAllocation=A-A-7-11&hotelId=12912");
    const detail = await s.call("GET", `/candidates/${res.body.candidateId}`, s.owner);
    expect(new URL(s.requested.at(-1)!).searchParams.get("days")).toBe("7");
    expect(detail.body.listing.profile.price).toMatchObject({ startDate: "2027-08-21", endDate: "2027-08-28", nights: 7, persons: 8 });
    // The window of the shared link is beside the point once the page was read for the trip.
    expect(detail.body.listing.profile.warnings.join(" ")).not.toMatch(/11 bis 25 Tagen/);
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
    // No single reviews on this page: the app shows nothing.
    expect(detail.body.reviews).toBeNull();
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
    expect(detail.body.listing.profile).toMatchObject({ sleepingPlaces: 8, summary: "Villa am Meer.", uncertain: ["sleepingPlaces", "lat", "lon"] });
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

describe("hints and comparison", () => {
  it("hides single hints for a trip without losing them", async () => {
    const s = await setup();
    const id = (await s.importLink(NOVASOL)).body.candidateId as string;
    await s.call("PATCH", `/candidates/${id}/profile`, s.owner, { warnings: ["Endreinigung kostet extra", "Pool nicht beheizt"] });
    expect((await s.call("PATCH", `/candidates/${id}`, s.owner, { hiddenWarnings: ["Pool nicht beheizt"] })).status).toBe(200);

    const detail = await s.call("GET", `/candidates/${id}`, s.owner);
    expect(detail.body.warnings).toEqual([
      { text: "Endreinigung kostet extra", hidden: false },
      { text: "Pool nicht beheizt", hidden: true },
    ]);
    expect(detail.body.listing.profile.warnings).toHaveLength(2);
    const list = await s.call("GET", `/trips/${s.tripId}/candidates`, s.owner);
    expect(list.body.candidates[0].listing.warningCount).toBe(1);

    await s.call("PATCH", `/candidates/${id}`, s.owner, { hiddenWarnings: [] });
    expect((await s.call("GET", `/candidates/${id}`, s.owner)).body.warnings.every((w: { hidden: boolean }) => !w.hidden)).toBe(true);
  });

  it("sets candidates side by side and marks who is ahead", async () => {
    const s = await setup();
    const a = (await s.importLink(NOVASOL)).body.candidateId as string;
    const b = (await s.importLink(CASAMUNDO)).body.candidateId as string;
    await s.call("PATCH", `/candidates/${a}/profile`, s.owner, { bedrooms: 3, amenities: { pool: true, sauna: false }, rating: { value: 4.5, scale: 5, count: 10 } });
    await s.call("PATCH", `/candidates/${b}/profile`, s.owner, { bedrooms: 5, amenities: { pool: false, sauna: false }, rating: { value: 8, scale: 10, count: 40 } });
    await s.call("POST", `/candidates/${a}/prices`, s.owner, { totalCents: 300000, startDate: "2027-08-21", endDate: "2027-08-28", persons: 8 });
    await s.call("POST", `/candidates/${b}/prices`, s.owner, { totalCents: 420000, startDate: "2027-08-21", endDate: "2027-08-28", persons: 8 });

    const res = await s.call("GET", `/trips/${s.tripId}/compare?ids=${a},${b}`, s.owner);
    expect(res.status).toBe(200);
    expect(res.body.candidates.map((c: { id: string }) => c.id)).toEqual([a, b]);
    const row = (key: string) => res.body.criteria.find((r: { key: string }) => r.key === key);
    expect(row("price.total")).toMatchObject({ values: [3000, 4200], best: [a], format: "eur" });
    expect(row("price.perNight").values[0]).toBeCloseTo(428.57);
    expect(row("bedrooms")).toMatchObject({ values: [3, 5], best: [b] });
    expect(row("rating")).toMatchObject({ values: [9, 8], best: [a] });
    expect(row("amenities.pool")).toMatchObject({ values: [true, false], best: [a] });
    expect(row("amenities.sauna")).toBeUndefined();
    expect(res.body.candidates[0].bestCount).toBeGreaterThan(0);

    await s.call("PATCH", `/candidates/${b}`, s.owner, { status: "rejected" });
    expect((await s.call("GET", `/trips/${s.tripId}/compare`, s.owner)).body.candidates).toHaveLength(1);
    expect((await s.call("GET", `/trips/${s.tripId}/compare?ids=${a},00000000-0000-4000-8000-000000000000`, s.owner)).status).toBe(404);
  });
});

describe("the same property on other platforms", () => {
  const perPlatform: Extractor = async ({ baseline, link }) => ({
    profile: {
      ...baseline,
      title: `Titel bei ${link.platform}`,
      bathrooms: link.platform === "airbnb" ? 2 : null,
      rating: { value: link.platform === "airbnb" ? 4.8 : 4.2, scale: 5, count: 10 },
      reviews: [{ id: `${link.platform}-1`, text: `Schön, sagt ein Gast bei ${link.platform}.`, title: null, rating: 5, scale: 5, date: "2026-08-01", author: "A", platform: null }],
      reviewSummary: { summary: `Stimmen bei ${link.platform}.`, positives: ["Lage"], negatives: [], basedOn: 1 },
      price: { ...baseline.price, totalEur: link.platform === "airbnb" ? 3500 : 3000, kind: "total" },
      warnings: [`Hinweis von ${link.platform}`],
    },
    note: null,
  });

  it("proposes matches, attaches a confirmed one and joins reviews and prices", async () => {
    const asked: string[] = [];
    const s = await setup({
      extractor: perPlatform,
      searcher: async ({ profile, known }) => {
        asked.push(`${profile.title} | ${known.map((k) => k.platform).join(",")}`);
        return {
          hits: [
            { url: "https://www.airbnb.de/rooms/555666?adults=2", title: "Haus am Meer", reason: "Gleicher Ort, drei Schlafzimmer.", confidence: "high" },
            { url: "https://www.novasol.de/ferienhaeuser/ABC999", title: "Anderes Haus", reason: "Selbe Plattform.", confidence: "low" },
          ],
          note: null,
        };
      },
      summarizer: async (sources) => ({ summary: `Über ${sources.length} Plattformen gesehen.`, positives: ["Lage"], negatives: [], basedOn: 2 }),
    });
    const id = (await s.importLink(NOVASOL)).body.candidateId as string;

    expect((await s.call("POST", `/candidates/${id}/sources/search`, s.owner)).status).toBe(202);
    await s.ctx.queue.idle();
    expect(asked).toEqual(["Titel bei novasol | novasol"]);
    expect((await s.call("POST", `/candidates/${id}/sources/search`, s.owner)).status).toBe(429);

    let detail = await s.call("GET", `/candidates/${id}`, s.owner);
    expect(detail.body.otherPlatforms).toMatchObject({ available: true, status: "done" });
    // The hit on the platform that is already attached is not proposed.
    expect(detail.body.otherPlatforms.suggestions).toHaveLength(1);
    const suggestion = detail.body.otherPlatforms.suggestions[0];
    expect(suggestion).toMatchObject({ platform: "airbnb", url: "https://www.airbnb.de/rooms/555666", confidence: "high", status: "proposed" });

    const accepted = await s.call("POST", `/candidates/${id}/suggestions/${suggestion.id}`, s.owner, { decision: "accept" });
    expect(accepted.status).toBe(202);
    await s.ctx.queue.idle();

    detail = await s.call("GET", `/candidates/${id}`, s.owner);
    expect(detail.body.sources.map((x: { platform: string; primary: boolean; read: boolean }) => [x.platform, x.primary, x.read])).toEqual([
      ["novasol", true, true],
      ["airbnb", false, true],
    ]);
    expect(detail.body.sources[1].rating).toMatchObject({ value: 4.8 });
    // The advert keeps its name, hints and price; the further source fills gaps and adds its reviews.
    expect(detail.body.listing).toMatchObject({ title: "Titel bei novasol", profile: { bathrooms: 2, warnings: ["Hinweis von novasol"], price: { totalEur: 3000 } } });
    expect(detail.body.reviews.items.map((r: { platform: string }) => r.platform).sort()).toEqual(["airbnb", "novasol"]);
    expect(detail.body.reviews.summary).toBe("Über 2 Plattformen gesehen.");
    expect(detail.body.prices.map((p: { totalCents: number }) => p.totalCents).sort()).toEqual([300000, 350000]);
    expect(detail.body.otherPlatforms.suggestions[0].status).toBe("accepted");
    expect(detail.body.candidate.importStatus).toBe("ready");

    // Reading the leading source again keeps the other platform's reviews.
    await s.db.update(listingSources).set({ lastFetchedAt: new Date(Date.now() - 120_000) });
    await s.call("POST", `/candidates/${id}/refresh`, s.owner);
    await s.ctx.queue.idle();
    detail = await s.call("GET", `/candidates/${id}`, s.owner);
    expect(detail.body.reviews.items).toHaveLength(2);

    // A wrong match can be taken away again.
    const airbnb = detail.body.sources[1].id as string;
    expect((await s.call("DELETE", `/candidates/${id}/sources/${detail.body.sources[0].id}`, s.owner)).status).toBe(409);
    expect((await s.call("DELETE", `/candidates/${id}/sources/${airbnb}`, s.owner)).status).toBe(204);
    detail = await s.call("GET", `/candidates/${id}`, s.owner);
    expect(detail.body.sources).toHaveLength(1);
    expect(detail.body.reviews.items.map((r: { platform: string }) => r.platform)).toEqual(["novasol"]);
    expect(detail.body.reviews.summary).toBe("Stimmen bei novasol.");
    expect(detail.body.prices).toHaveLength(1);
  });

  it("takes a link by hand, and a blocked platform waits for the device", async () => {
    const s = await setup({ extractor: perPlatform, fetcher: async (url) => (url.includes("casamundo") ? page(fixture("blocked.html"), { status: 403, blocked: true }) : page(fixture("novasol.html"))) });
    const id = (await s.importLink(NOVASOL)).body.candidateId as string;
    expect((await s.call("POST", `/candidates/${id}/sources/search`, s.owner)).status).toBe(503);

    const added = await s.call("POST", `/candidates/${id}/sources`, s.owner, { url: CASAMUNDO });
    expect(added.status).toBe(202);
    await s.ctx.queue.idle();
    let detail = await s.call("GET", `/candidates/${id}`, s.owner);
    expect(detail.body.sources[1]).toMatchObject({ platform: "casamundo", read: false, needsDevice: true });
    // The advert itself is not marked as incomplete because a further source was refused.
    expect(detail.body.candidate.importStatus).toBe("ready");

    const capture = await s.call("POST", `/candidates/${id}/capture`, s.owner, { html: fixture("novasol.html"), sourceId: added.body.sourceId });
    expect(capture.status).toBe(202);
    await s.ctx.queue.idle();
    detail = await s.call("GET", `/candidates/${id}`, s.owner);
    expect(detail.body.sources[1]).toMatchObject({ read: true, needsDevice: false });
    expect(detail.body.listing.title).toBe("Titel bei novasol");
    expect(detail.body.reviews.items).toHaveLength(2);

    // A link that is its own advert elsewhere is not swallowed.
    const other = (await s.importLink(AIRBNB)).body.candidateId as string;
    expect(other).not.toBe(id);
    expect((await s.call("POST", `/candidates/${id}/sources`, s.owner, { url: AIRBNB })).status).toBe(409);
  });
});

describe("checking a whole trip", () => {
  it("reads every open candidate for the trip's dates and reports what is no longer to be had", async () => {
    let soldOut = false;
    const extractor: Extractor = async ({ baseline, link }) => ({
      profile: { ...baseline, title: `Haus bei ${link.platform}`, price: { ...baseline.price, totalEur: 3000, kind: "total", available: link.platform === "airbnb" && soldOut ? false : true } },
      note: null,
    });
    const s = await setup({ extractor, fetcher: async (url) => (url.includes("casamundo") ? page(fixture("blocked.html"), { status: 403, blocked: true }) : page(fixture("novasol.html"))) });
    const a = (await s.importLink(AIRBNB)).body.candidateId as string;
    const b = (await s.importLink(CASAMUNDO)).body.candidateId as string;

    let list = (await s.call("GET", `/trips/${s.tripId}/candidates`, s.owner)).body.candidates as { id: string; availability: string; needsDevice: boolean; checkUrl: string; price: { available: boolean | null; totalCents: number } | null }[];
    expect(list.find((c) => c.id === a)).toMatchObject({ availability: "available", needsDevice: true, price: { available: true, totalCents: 300000 } });
    expect(list.find((c) => c.id === b)).toMatchObject({ availability: "unknown", needsDevice: true });
    expect(list.find((c) => c.id === b)!.checkUrl).toContain("2027-08-21");

    soldOut = true;
    await s.db.update(listingSources).set({ lastFetchedAt: new Date(Date.now() - 120_000) });
    const check = await s.call("POST", `/trips/${s.tripId}/refresh`, s.owner);
    expect(check.status).toBe(202);
    expect(check.body.checks.map((c: { candidateId: string; mode: string }) => [c.candidateId, c.mode]).sort()).toEqual([[a, "device"], [b, "device"]].sort());
    // Prices for a stay appear on these platforms only in a browser: the device reads the page for the trip.
    await s.call("POST", `/candidates/${a}/capture`, s.owner, { html: fixture("novasol.html"), forTrip: true });
    await s.ctx.queue.idle();

    list = (await s.call("GET", `/trips/${s.tripId}/candidates`, s.owner)).body.candidates;
    const gone = list.find((c) => c.id === a)!;
    // The last known price stays visible next to the news that the dates are gone.
    expect(gone).toMatchObject({ availability: "unavailable", price: { available: false, totalCents: 300000 } });
    expect((await s.call("GET", `/candidates/${a}`, s.owner)).body.listing.profile.price).toMatchObject({ available: false, totalEur: null });

    // A security check the platform showed the device instead of the advert leaves everything as it was.
    const titleBefore = (await s.call("GET", `/candidates/${a}`, s.owner)).body.listing.profile.title;
    await s.call("POST", `/candidates/${a}/capture`, s.owner, { html: `<html><head><title>Bot oder Mensch?</title></head><body>${"<p>Bitte bestätige, dass du ein Mensch bist.</p>".repeat(20)}</body></html>`, forTrip: true });
    await s.ctx.queue.idle();
    const after = (await s.call("GET", `/candidates/${a}`, s.owner)).body.listing.profile;
    expect(after.title).toBe(titleBefore);
    expect(after.title).not.toMatch(/Bot oder Mensch/);

    // Rejected candidates are left alone, and a guest may not trigger the check.
    await s.call("PATCH", `/candidates/${a}`, s.owner, { status: "rejected" });
    await s.db.update(listingSources).set({ lastFetchedAt: new Date(Date.now() - 120_000) });
    expect((await s.call("POST", `/trips/${s.tripId}/check`, s.owner)).body.checks).toHaveLength(1);
    const guest = await s.join("guest", "Oma");
    expect((await s.call("POST", `/trips/${s.tripId}/check`, guest)).status).toBe(403);
  });
});

describe("moving candidates and the watchlist", () => {
  it("gives everyone a watchlist and moves a candidate there and back", async () => {
    const s = await setup();
    const trips = (await s.call("GET", "/trips", s.owner)).body.trips as { id: string; kind: string; title: string }[];
    const shelf = trips.find((t) => t.kind === "watchlist")!;
    expect(shelf.title).toBe("Merkliste");
    expect(trips.filter((t) => t.kind === "watchlist")).toHaveLength(1);
    expect((await s.call("GET", "/trips", s.owner)).body.trips.filter((t: { kind: string }) => t.kind === "watchlist")).toHaveLength(1);
    expect((await s.call("POST", `/trips/${shelf.id}/invites`, s.owner, {})).status).toBe(409);
    expect((await s.call("POST", `/trips/${shelf.id}/refresh`, s.owner)).status).toBe(409);

    const added = await s.call("POST", `/trips/${s.tripId}/imports`, s.owner, { url: "https://www.novasol.de/ferienhaeuser/CLD520" });
    const id = added.body.candidateId as string;
    await s.ctx.queue.idle();
    await s.call("PATCH", `/candidates/${id}`, s.owner, { status: "favorite", notes: "Mit Pool" });
    await s.call("PUT", `/candidates/${id}/vote`, s.owner, { verdict: "yes" });

    const moved = await s.call("POST", `/candidates/${id}/move`, s.owner, { tripId: shelf.id });
    expect(moved.status).toBe(200);
    expect(moved.body).toMatchObject({ candidateId: id, tripId: shelf.id });
    expect((await s.call("GET", `/trips/${s.tripId}/candidates`, s.owner)).body.candidates).toHaveLength(0);
    const onShelf = (await s.call("GET", `/trips/${shelf.id}/candidates`, s.owner)).body.candidates;
    expect(onShelf).toHaveLength(1);
    expect(onShelf[0]).toMatchObject({ id, status: "new" });
    const detail = (await s.call("GET", `/candidates/${id}`, s.owner)).body;
    expect(detail.candidate.notes).toBe("Mit Pool");
    expect(detail.votes).toMatchObject({ yes: 0, maybe: 0, no: 0 });

    // Somebody who is not in the target trip cannot move anything there.
    const other = await s.join("member", "Tante");
    const theirs = ((await s.call("GET", "/trips", other)).body.trips as { id: string; kind: string }[]).find((t) => t.kind === "watchlist")!;
    expect(theirs.id).not.toBe(shelf.id);
    expect((await s.call("POST", `/candidates/${id}/move`, s.owner, { tripId: theirs.id })).status).toBe(404);

    expect((await s.call("POST", `/candidates/${id}/move`, s.owner, { tripId: s.tripId })).status).toBe(200);
    const again = await s.call("POST", `/trips/${shelf.id}/imports`, s.owner, { url: "https://www.novasol.de/ferienhaeuser/CLD520" });
    await s.ctx.queue.idle();
    expect((await s.call("POST", `/candidates/${again.body.candidateId}/move`, s.owner, { tripId: s.tripId })).status).toBe(409);
  });
});

describe("criteria", () => {
  it("measures candidates against the trip's must-haves and wishes", async () => {
    const s = await setup();
    const added = await s.call("POST", `/trips/${s.tripId}/imports`, s.owner, { url: "https://www.novasol.de/ferienhaeuser/CLD520" });
    const id = added.body.candidateId as string;
    await s.ctx.queue.idle();
    const profile = (await s.call("GET", `/candidates/${id}`, s.owner)).body.listing.profile;
    expect(profile.bedrooms).toBeGreaterThan(0);

    const none = (await s.call("GET", `/trips/${s.tripId}/candidates`, s.owner)).body.candidates[0];
    expect(none.criteria).toBeNull();
    const offered = await s.call("GET", `/trips/${s.tripId}/criteria`, s.owner);
    expect(offered.body.measurable.find((m: { key: string }) => m.key === "bedrooms")).toMatchObject({ rule: "min" });

    expect((await s.call("PUT", `/trips/${s.tripId}/criteria`, s.owner, { criteria: [{ key: "bedrooms", level: "must" }] })).status).toBe(400);
    const put = await s.call("PUT", `/trips/${s.tripId}/criteria`, s.owner, {
      criteria: [
        { key: "bedrooms", level: "must", target: profile.bedrooms },
        { key: "bedrooms", level: "wish", target: profile.bedrooms + 5 },
        { key: "custom", label: "Ruhige Lage", level: "must" },
      ],
    });
    expect(put.status).toBe(200);
    const [must, wish, quiet] = put.body.criteria as { id: string }[];

    let entry = (await s.call("GET", `/trips/${s.tripId}/candidates`, s.owner)).body.candidates[0];
    // One must-have is met, one nobody has judged yet, the wish is missed.
    expect(entry.criteria).toMatchObject({ light: "yellow", must: { met: 1, missed: 0, unknown: 1 }, wish: { met: 0, missed: 1, unknown: 0 } });

    await s.call("PATCH", `/candidates/${id}`, s.owner, { criteriaChecks: { [quiet!.id]: "missed" } });
    entry = (await s.call("GET", `/trips/${s.tripId}/candidates`, s.owner)).body.candidates[0];
    expect(entry.criteria.light).toBe("red");

    await s.call("PATCH", `/candidates/${id}`, s.owner, { criteriaChecks: { [quiet!.id]: "met", [wish!.id]: "met" } });
    const detail = (await s.call("GET", `/candidates/${id}`, s.owner)).body;
    expect(detail.criteria.light).toBe("green");
    expect(detail.criteria.results.find((r: { id: string }) => r.id === must!.id)).toMatchObject({ status: "met", manual: false, value: profile.bedrooms, label: "Schlafzimmer" });
    expect(detail.criteria.results.find((r: { id: string }) => r.id === wish!.id)).toMatchObject({ status: "met", manual: true });

    // Keeping the ids keeps what was judged by hand.
    await s.call("PUT", `/trips/${s.tripId}/criteria`, s.owner, { criteria: [{ id: quiet!.id, key: "custom", label: "Sehr ruhige Lage", level: "must" }] });
    entry = (await s.call("GET", `/trips/${s.tripId}/candidates`, s.owner)).body.candidates[0];
    expect(entry.criteria).toMatchObject({ light: "green", must: { met: 1 } });
  });
});

describe("several periods", () => {
  it("keeps prices and availability apart for each of the trip's periods", async () => {
    let amount = 3000;
    const extractor: Extractor = async ({ baseline, link }) => ({ profile: { ...baseline, title: `Haus bei ${link.platform}`, price: { ...baseline.price, totalEur: amount, kind: "total", available: true } }, note: null });
    const s = await setup({ extractor });
    const second = (await s.call("POST", `/trips/${s.tripId}/date-options`, s.owner, { label: "Herbst", startDate: "2027-10-09", endDate: "2027-10-16" })).body.dateOption as { id: string };
    const a = (await s.importLink(AIRBNB)).body.candidateId as string;

    amount = 2100;
    const check = await s.call("POST", `/trips/${s.tripId}/check`, s.owner, { dateOptionId: second.id });
    expect(check.body).toMatchObject({ dateOptionId: second.id, startDate: "2027-10-09" });
    expect(check.body.checks[0].checkUrl).toContain("2027-10-09");
    await s.call("POST", `/candidates/${a}/capture`, s.owner, { html: fixture("novasol.html"), forTrip: true, dateOptionId: second.id });
    await s.ctx.queue.idle();

    const first = (await s.call("GET", `/trips/${s.tripId}/candidates`, s.owner)).body.candidates[0];
    expect(first.periods).toHaveLength(2);
    expect(first.periods.find((p: { dateOptionId: string }) => p.dateOptionId === second.id)).toMatchObject({ availability: "available", totalCents: 210000 });
    expect(first.periods.find((p: { dateOptionId: string }) => p.dateOptionId !== second.id)).toMatchObject({ totalCents: 300000 });
    // The list as a whole speaks for the earliest period unless another one is asked for.
    expect(first.price).toMatchObject({ totalCents: 300000, forThisTrip: true });
    const autumn = (await s.call("GET", `/trips/${s.tripId}/candidates?dateOptionId=${second.id}`, s.owner)).body.candidates[0];
    expect(autumn.price).toMatchObject({ totalCents: 210000, forThisTrip: true });
    expect(autumn.checkUrl).toContain("2027-10-09");
  });
});

describe("daily allowance", () => {
  it("refuses further readings once the day's allowance is used up", async () => {
    const s = await setup();
    s.ctx.config.DAILY_READINGS = 2;
    expect((await s.call("POST", `/trips/${s.tripId}/imports`, s.owner, { url: "https://www.novasol.de/ferienhaeuser/CLD520" })).status).toBe(202);
    expect((await s.call("POST", `/trips/${s.tripId}/imports`, s.owner, { url: "https://www.novasol.de/ferienhaeuser/CLD521" })).status).toBe(202);
    const third = await s.call("POST", `/trips/${s.tripId}/imports`, s.owner, { url: "https://www.novasol.de/ferienhaeuser/CLD522" });
    expect(third.status).toBe(429);
    expect(third.body.error.code).toBe("daily_limit");
    await s.ctx.queue.idle();
  });
});

describe("pitch and decision", () => {
  it("ranks the finalists by points and records what the group settled on", async () => {
    const s = await setup();
    const ids: string[] = [];
    for (const code of ["CLD520", "CLD521", "CLD522"]) ids.push((await s.call("POST", `/trips/${s.tripId}/imports`, s.owner, { url: `https://www.novasol.de/ferienhaeuser/${code}` })).body.candidateId);
    await s.ctx.queue.idle();
    const [a, b, c] = ids as [string, string, string];
    const member = await s.join("member", "Tante");

    expect((await s.call("GET", `/trips/${s.tripId}`, s.owner)).body.trip).toMatchObject({ phase: "research", currentPhase: "research" });
    expect((await s.call("POST", `/trips/${s.tripId}/pitch`, member, { candidateIds: [a, b] })).status).toBe(403);
    const opened = await s.call("POST", `/trips/${s.tripId}/pitch`, s.owner, { candidateIds: [a, b] });
    expect(opened.body).toMatchObject({ phase: "decision", maxPoints: 4 });
    expect(opened.body.finalists).toHaveLength(2);
    expect(opened.body.missing).toHaveLength(2);

    expect((await s.call("PUT", `/trips/${s.tripId}/ranking`, s.owner, { order: [a, c] })).status).toBe(400);
    await s.call("PUT", `/trips/${s.tripId}/ranking`, s.owner, { order: [b, a] });
    const ranked = await s.call("PUT", `/trips/${s.tripId}/ranking`, member, { order: [b] });
    expect(ranked.body.finalists.map((f: { candidate: { id: string }; points: number; place: number }) => [f.candidate.id, f.points, f.place])).toEqual([[b, 4, 1], [a, 1, 2]]);
    expect(ranked.body.missing).toHaveLength(0);
    expect(ranked.body.myRanking).toEqual([b]);

    // A veto outweighs points.
    await s.call("PUT", `/candidates/${b}/vote`, member, { verdict: "no", veto: true });
    expect((await s.call("GET", `/trips/${s.tripId}/pitch`, s.owner)).body.finalists[0].candidate.id).toBe(a);

    const decided = await s.call("POST", `/trips/${s.tripId}/decision`, s.owner, { candidateId: a });
    expect(decided.body).toMatchObject({ phase: "booking", decided: { candidateId: a } });
    expect((await s.call("GET", `/trips/${s.tripId}`, s.owner)).body.trip).toMatchObject({ phase: "booking", status: "decided", decidedCandidateId: a });
    expect((await s.call("DELETE", `/trips/${s.tripId}/decision`, s.owner)).body).toMatchObject({ phase: "decision", decided: null });
  });
});

describe("shared purse", () => {
  it("keeps expenses per household and says who owes whom", async () => {
    const s = await setup();
    const aunt = await s.join("member", "Tante");
    expect((await s.call("POST", `/trips/${s.tripId}/expenses`, s.owner, { title: "Einkauf", amountCents: 9000, paidBy: "00000000-0000-4000-8000-000000000000" })).status).toBe(409);

    const suggested = await s.call("POST", `/trips/${s.tripId}/parties/suggest`, s.owner);
    expect(suggested.body.parties).toHaveLength(2);
    const set = await s.call("PUT", `/trips/${s.tripId}/parties`, s.owner, {
      parties: [
        { id: suggested.body.parties[0].id, name: "Familie A", adults: 2, children: 2, memberIds: suggested.body.parties[0].memberIds },
        { id: suggested.body.parties[1].id, name: "Familie B", adults: 2, children: 0, memberIds: suggested.body.parties[1].memberIds },
        { name: "Oma", adults: 1, children: 0 },
      ],
    });
    const [a, b, c] = set.body.parties.map((p: { id: string }) => p.id) as [string, string, string];
    expect(set.body.myPartyId).toBe(a);

    await s.call("POST", `/trips/${s.tripId}/expenses`, s.owner, { title: "Haus", amountCents: 30000, paidBy: a });
    const second = await s.call("POST", `/trips/${s.tripId}/expenses`, aunt, { title: "Bootstour", amountCents: 8000, paidBy: b, mode: "custom", weights: { [a]: 1, [b]: 1 } });
    expect(second.status).toBe(201);
    let ledger = second.body.ledger;
    expect(ledger.totalCents).toBe(38000);
    expect(ledger.parties.map((p: { balanceCents: number }) => p.balanceCents)).toEqual([16000, -6000, -10000]);
    expect(ledger.transfers).toEqual([{ from: c, to: a, amountCents: 10000 }, { from: b, to: a, amountCents: 6000 }]);

    ledger = (await s.call("POST", `/trips/${s.tripId}/payments`, s.owner, { fromParty: c, toParty: a, amountCents: 10000 })).body.ledger;
    expect(ledger.transfers).toEqual([{ from: b, to: a, amountCents: 6000 }]);

    // Counting heads with children at half changes the shares of the house.
    await s.call("PATCH", `/trips/${s.tripId}`, s.owner, { splitMode: "heads", childWeight: 0.5 });
    ledger = (await s.call("GET", `/trips/${s.tripId}/ledger`, aunt)).body;
    expect(ledger.myPartyId).toBe(b);
    expect(ledger.parties[0].shareCents).toBe(15000 + 4000);

    const gone = await s.call("DELETE", `/expenses/${second.body.expense.id}`, s.owner);
    expect(gone.body.ledger.expenses).toHaveLength(1);
  });
});
