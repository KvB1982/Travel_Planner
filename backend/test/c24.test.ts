import { expect, it } from "vitest";
import { chooseStay, joinReviews } from "../src/import/pipeline.js";
import { advertsOwn, coverOf, extractBlocks, joinPhotos, sameIn } from "../src/import/blocks.js";
import { aboutHeadcount } from "../src/routes/candidates.js";
it("tells a guest's snapshot from a hotel picture through the nested Check24 image services, and keeps the widest size", () => {
  const b = (t: string) => Buffer.from(t).toString("base64url");
  const c = "https://cdn1.urlaub.check24.de";
  const room = b(`https://cdn-cts-1.community.example/source=${b("https://images.example.test/1.jpg")}!aa/p.jpg`);
  const guest = b(`https://cdn-cts-1.community.example/source=${b("https://pv-cts-prod.s3.example/cts-ratings/x.jpg")}!aa/p.jpg`);
  const state = { hotel: { images: [`${c}/size=450x/di=3/source=${room}!s1/picture.jpg`, `${c}/size=1920x/di=3/source=${room}!s2/picture.jpg`, `${c}/size=1920x/di=3/source=${guest}!s3/picture.jpg`] } };
  const blocks = extractBlocks(`<html><body><script id="js-hotel-data" type="application/json">${JSON.stringify(state)}</script></body></html>`);
  expect(blocks.photos.map((p) => p.url)).toEqual([`${c}/size=1920x/di=3/source=${room}!s2/picture.jpg`]);
});

it("puts two readings together: the newer leads, the larger rendition stays, old extras remain", () => {
  const c = "https://image.novasol.com/pic";
  const joined = joinPhotos([{ url: `${c}/2048/a.jpg` }, { url: `${c}/600/b.jpg` }], [{ url: `${c}/600/a.jpg` }, { url: `${c}/1024/b.jpg` }, { url: `${c}/600/c.jpg` }, { url: "https://images.ctfassets.net/news.jpg" }]);
  expect(joined.map((p) => p.url)).toEqual([`${c}/2048/a.jpg`, `${c}/1024/b.jpg`, `${c}/600/c.jpg`]);
  expect(sameIn(`${c}/600/a.jpg`, joined)).toBe(`${c}/2048/a.jpg`);
});

it("drops Check24 previews once a gallery of sharp pictures is there", () => {
  const c = "https://cdn1.urlaub.check24.de";
  const sharp = Array.from({ length: 10 }, (_, i) => ({ url: `${c}/size=1920x/di=3/source=big${i}!a/picture.jpg` }));
  const small = [{ url: `${c}/size=335c220/di=3/source=old1!a/picture.jpg` }, { url: `${c}/size=800x/di=3/source=mid1!a/picture.jpg` }];
  expect(joinPhotos(sharp, small).map((p) => p.url)).toEqual([...sharp.map((p) => p.url), small[1]!.url]);
  expect(joinPhotos(sharp.slice(0, 3), small)).toHaveLength(5);
});

it("does not let a reading full of previews push sharp pictures out", () => {
  const c = "https://cdn1.urlaub.check24.de";
  const previews = Array.from({ length: 80 }, (_, i) => ({ url: `${c}/size=335c220/di=3/source=p${i}!a/picture.jpg` }));
  const sharp = Array.from({ length: 80 }, (_, i) => ({ url: `${c}/size=1920x/di=3/source=p${i + 45}!b/picture.jpg` }));
  const joined = joinPhotos(previews, sharp);
  expect(joined).toHaveLength(80);
  expect(joined.every((p) => p.url.includes("size=1920x"))).toBe(true);
});

it("keeps the reviews an earlier reading found beside those of a thinner one", () => {
  const old = [{ author: "Jörg", text: "Sehr schönes Haus am Meer" }, { author: "Anna", text: "Tolle Lage" }];
  expect(joinReviews([{ author: "Anna", text: "Tolle  Lage" }, { author: "Tim", text: "Gutes Essen" }], old).map((r) => r.author)).toEqual(["Anna", "Tim", "Jörg"]);
});

it("ranks a Check24 picture by the smallest size on the way to the original", () => {
  const b = (t: string) => Buffer.from(t).toString("base64url");
  const c = "https://cdn1.urlaub.check24.de";
  const original = "https://i.giatamedia.example/i.php?uid=1&k=abc";
  const blownUp = `${c}/size=1920x/di=3/source=${b(`https://cdn-cts-1.community.check24.de/size=800c600/source=${b(original)}!x/p.jpg`)}!s1/picture.jpg`;
  const direct = `${c}/di=3/nfc=200/source=${b(original)}!s2/picture.jpg`;
  expect(joinPhotos([{ url: blownUp }], [{ url: direct }]).map((p) => p.url)).toEqual([direct]);
});

it("lets the wished length lead, a clearly cheaper longer stay pass it, and takes the nearest where it is not to be had", () => {
  const s = (nights: number, total: number) => ({ nights, total });
  const pick = (list: { nights: number; total: number }[], wish: number | null) => {
    const c = chooseStay(list, (x) => x.nights, (x) => x.total / x.nights, wish);
    return c && [c.stay.nights, c.why];
  };
  expect(pick([s(7, 2100), s(10, 3500), s(14, 4760)], null)).toEqual([7, "cheapest"]);
  expect(pick([s(7, 2100), s(10, 3500), s(14, 4760)], 10)).toEqual([10, "preferred"]);
  // Fourteen nights at a tenth less by the night than the ten wished for.
  expect(pick([s(10, 3500), s(14, 4200)], 10)).toEqual([14, "cheaper_longer"]);
  // Only whole weeks to be had.
  expect(pick([s(7, 2100), s(14, 4760)], 12)).toEqual([14, "nearest"]);
  expect(pick([], 10)).toBeNull();
});

it("hides only the plain hint on headcount, not one that says more", () => {
  expect(aboutHeadcount("Der Preis gilt für 2 Erwachsene und 2 Kinder, nicht für 8 Personen.")).toBe(true);
  expect(aboutHeadcount("Preis für 4 Personen.")).toBe(true);
  expect(aboutHeadcount("Der Preis gilt nur für die 2 Erwachsenen, Kinderpreise fehlen.")).toBe(false);
  expect(aboutHeadcount("Der Preis für 4 Personen ist ein Ab-Preis, der Zeitraum passt nicht genau.")).toBe(false);
  expect(aboutHeadcount("Preis je Person statt gesamt, bei 4 Personen.")).toBe(false);
  expect(aboutHeadcount("Kein Aufzug.")).toBe(false);
});

it("takes the portal's regional stock pictures out, also from what was stored, and picks another cover", () => {
  const b = (t: string) => Buffer.from(t).toString("base64url");
  const c = "https://cdn1.urlaub.check24.de";
  const city = `${c}/size=1920x/di=3/source=${b("https://bigassets.urlaub.check24.de/urlaub/sem/bg/city_961.jpg")}!s1/picture.jpg`;
  const badge = "https://cdn-public.community.check24.de/group-images/12.webp";
  const room = `${c}/size=1920x/di=3/source=${b("https://images.example.test/1.jpg")}!s2/picture.jpg`;
  expect(advertsOwn([{ url: city }, { url: badge }, { url: room }])).toEqual([{ url: room }]);
  expect(coverOf(city, [{ url: city }, { url: room }])).toBe(room);
  expect(coverOf(room, [{ url: city }, { url: room }])).toBe(room);
  expect(joinPhotos([{ url: room }], [{ url: city }]).map((p) => p.url)).toEqual([room]);
});
