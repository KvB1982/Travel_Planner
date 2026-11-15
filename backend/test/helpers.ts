import { PGlite } from "@electric-sql/pglite";
import { drizzle } from "drizzle-orm/pglite";
import { migrate } from "drizzle-orm/pglite/migrator";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { buildApp } from "../src/app.js";
import { loadConfig } from "../src/config.js";
import { migrationsFolder, type Db } from "../src/db/client.js";
import * as schema from "../src/db/schema.js";
import { baselineExtractor, type Extractor, type ReviewSummarizer } from "../src/import/extract.js";
import type { Searcher } from "../src/import/search.js";
import type { FetchedPage, PageFetcher } from "../src/import/fetch.js";

const here = path.dirname(fileURLToPath(import.meta.url));
export const fixture = (name: string) => readFileSync(path.join(here, "fixtures", name), "utf8");

export const BOOTSTRAP_SECRET = "test-secret-with-enough-length-1234";

/** A real PostgreSQL engine in process, with the production migrations applied. */
export async function testDb(): Promise<Db> {
  const client = new PGlite();
  const db = drizzle(client, { schema });
  await migrate(db, { migrationsFolder });
  return db as unknown as Db;
}

export function page(html: string, overrides: Partial<FetchedPage> = {}): FetchedPage {
  return { finalUrl: "https://example.test/", status: 200, html, blocked: false, redirects: [], ...overrides };
}

export async function testApp(options: { fetcher?: PageFetcher; extractor?: Extractor; searcher?: Searcher; summarizer?: ReviewSummarizer } = {}) {
  const db = await testDb();
  const requested: string[] = [];
  const fetcher: PageFetcher = async (url) => {
    requested.push(url);
    return (options.fetcher ?? (async () => page(fixture("novasol.html"))))(url);
  };
  const config = loadConfig({ DATABASE_URL: "pglite://memory", BOOTSTRAP_SECRET, PUBLIC_BASE_URL: "https://reisen.example.test" });
  const { app, ctx } = await buildApp({ db, config, fetcher, extractor: options.extractor ?? baselineExtractor, searcher: options.searcher ?? null, summarizer: options.summarizer ?? null });

  const call = async (method: "GET" | "POST" | "PATCH" | "PUT" | "DELETE", url: string, token?: string | null, body?: unknown) => {
    const res = await app.inject({ method, url, headers: token ? { authorization: `Bearer ${token}` } : {}, ...(body !== undefined ? { payload: body as object } : {}) });
    return { status: res.statusCode, body: res.body ? res.json() : null };
  };

  const bootstrap = async (name = "Kristian") => {
    const res = await call("POST", "/auth/bootstrap", null, { secret: BOOTSTRAP_SECRET, name });
    return res.body.token as string;
  };

  return { app, ctx, db, call, bootstrap, requested };
}
