import { expect, it } from "vitest";
import { extractBlocks } from "../src/import/blocks.js";
it("tells a guest's snapshot from a hotel picture through the nested Check24 image services, and keeps the widest size", () => {
  const b = (t: string) => Buffer.from(t).toString("base64url");
  const c = "https://cdn1.urlaub.check24.de";
  const room = b(`https://cdn-cts-1.community.example/source=${b("https://images.example.test/1.jpg")}!aa/p.jpg`);
  const guest = b(`https://cdn-cts-1.community.example/source=${b("https://pv-cts-prod.s3.example/cts-ratings/x.jpg")}!aa/p.jpg`);
  const state = { hotel: { images: [`${c}/size=450x/di=3/source=${room}!s1/picture.jpg`, `${c}/size=1920x/di=3/source=${room}!s2/picture.jpg`, `${c}/size=1920x/di=3/source=${guest}!s3/picture.jpg`] } };
  const blocks = extractBlocks(`<html><body><script id="js-hotel-data" type="application/json">${JSON.stringify(state)}</script></body></html>`);
  expect(blocks.photos.map((p) => p.url)).toEqual([`${c}/size=1920x/di=3/source=${room}!s2/picture.jpg`]);
});
