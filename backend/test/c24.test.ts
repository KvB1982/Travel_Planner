import { expect, it } from "vitest";
import { joinReviews } from "../src/import/pipeline.js";
import { extractBlocks, joinPhotos, sameIn } from "../src/import/blocks.js";
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
