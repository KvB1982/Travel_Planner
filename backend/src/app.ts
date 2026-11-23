import cors from "@fastify/cors";
import rateLimit from "@fastify/rate-limit";
import Fastify, { type FastifyInstance } from "fastify";
import type { Config } from "./config.js";
import type { Db } from "./db/client.js";
import { HttpError } from "./http.js";
import type { Extractor, ReviewSummarizer } from "./import/extract.js";
import type { Searcher } from "./import/search.js";
import type { PageFetcher } from "./import/fetch.js";
import { ImportQueue } from "./import/pipeline.js";
import { authRoutes } from "./routes/auth.js";
import { bookingRoutes } from "./routes/bookings.js";
import { checklistRoutes } from "./routes/checklists.js";
import { ledgerRoutes } from "./routes/ledger.js";
import { groupRoutes } from "./routes/groups.js";
import { planRoutes } from "./routes/plans.js";
import { candidateRoutes } from "./routes/candidates.js";
import type { AppleKeySource } from "./auth/apple.js";
import { tripRoutes } from "./routes/trips.js";

export interface AppContext {
  db: Db;
  config: Config;
  fetcher: PageFetcher;
  extractor: Extractor;
  summarizer?: ReviewSummarizer | null;
  /** Absent without an API key: then other platforms can only be added by link. */
  searcher?: Searcher | null;
  queue: ImportQueue;
  /** Apple's public keys. Tests put their own in. */
  appleKeys?: AppleKeySource;
}

export async function buildApp(deps: Omit<AppContext, "queue">, options: { logger?: boolean } = {}): Promise<{ app: FastifyInstance; ctx: AppContext }> {
  const app = Fastify({
    // Invite tokens travel in the path. They are secrets and must not end up in the log.
    logger: options.logger
      ? {
          serializers: {
            req: (req: { method: string; url: string; hostname?: string; ip?: string; headers?: Record<string, unknown> }) => ({
              method: req.method,
              url: req.url.replace(/(\/auth\/invites\/|\/einladung\/)[^/?]+/, "$1…"),
              hostname: req.hostname,
              remoteAddress: req.ip,
              // Which build of the app asked, so a fault can be tied to a version.
              appBuild: typeof req.headers?.["x-app-build"] === "string" ? (req.headers["x-app-build"] as string).slice(0, 20) : undefined,
            }),
          },
        }
      : false,
    bodyLimit: 256 * 1024,
    // The API sits behind a tunnel or reverse proxy; client addresses come from its header.
    trustProxy: true,
  });
  const ctx: AppContext = { ...deps, queue: new ImportQueue((err) => app.log.error({ err }, "import failed")) };

  await app.register(cors, { origin: false });
  await app.register(rateLimit, { max: 300, timeWindow: "1 minute" });

  app.setErrorHandler((err: unknown, _req, reply) => {
    if (err instanceof HttpError) return reply.code(err.statusCode).send({ error: { code: err.code, message: err.message } });
    const e = err as { statusCode?: number; code?: string; message?: string };
    if (e.statusCode === 413) return reply.code(413).send({ error: { code: "too_large", message: "Die Seite ist zu groß, um sie zu übertragen." } });
    if (e.statusCode && e.statusCode < 500) {
      return reply.code(e.statusCode).send({ error: { code: e.statusCode === 429 ? "rate_limited" : "invalid_request", message: e.statusCode === 429 ? "Zu viele Anfragen. Bitte kurz warten." : (e.message ?? "Ungültige Anfrage.") } });
    }
    app.log.error({ err }, "unhandled error");
    return reply.code(500).send({ error: { code: "internal", message: "Interner Fehler." } });
  });
  app.setNotFoundHandler((_req, reply) => reply.code(404).send({ error: { code: "not_found", message: "Nicht gefunden." } }));

  app.get("/health", async () => ({ ok: true }));

  // Lets a tap on an invitation link open the app instead of the browser.
  app.get("/.well-known/apple-app-site-association", async (_req, reply) =>
    reply.type("application/json").send({ applinks: { details: [{ appIDs: [deps.config.APPLE_APP_ID], components: [{ "/": "/einladung/*" }] }] } }),
  );

  /**
   * What the browser shows where the app did not open by itself. The page says nothing about the invitation:
   * the token is neither looked up nor used here, redeeming stays with the app.
   */
  app.get("/einladung/:token", async (req, reply) => {
    const token = (req.params as { token: string }).token;
    if (!/^[A-Za-z0-9_-]{8,200}$/.test(token)) return reply.code(404).type("text/html; charset=utf-8").send(invitePage(null, deps.config.PUBLIC_BASE_URL, deps.config.TESTFLIGHT_URL));
    return reply
      .header("cache-control", "no-store")
      .header("referrer-policy", "no-referrer")
      .header("x-robots-tag", "noindex")
      .type("text/html; charset=utf-8")
      .send(invitePage(token, deps.config.PUBLIC_BASE_URL, deps.config.TESTFLIGHT_URL));
  });
  authRoutes(app, ctx);
  tripRoutes(app, ctx);
  candidateRoutes(app, ctx);
  ledgerRoutes(app, ctx);
  bookingRoutes(app, ctx);
  checklistRoutes(app, ctx);
  planRoutes(app, ctx);
  groupRoutes(app, ctx);

  app.addHook("onClose", async () => ctx.queue.idle());
  return { app, ctx };
}

const esc = (v: string) => v.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);

function invitePage(token: string | null, base: string, testflight: string | undefined): string {
  const open = token ? `reiseplaner://einladung/${token}?server=${encodeURIComponent(base.replace(/\/$/, ""))}` : null;
  const getIt = testflight
    ? `<p>Du hast die App noch nicht? Sie kommt über TestFlight: <a href="${esc(testflight)}">Reiseplaner laden</a>. Tippe danach noch einmal auf den Einladungslink.</p>`
    : `<p>Du hast die App noch nicht? Sie kommt über TestFlight; den Zugang bekommst du von der Person, die dich eingeladen hat. Tippe danach noch einmal auf den Einladungslink.</p>`;
  return `<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>Einladung zum Reiseplaner</title>
<style>
  :root { color-scheme: light dark; }
  body { margin: 0; font: 17px/1.5 -apple-system, system-ui, sans-serif; background: #f4f1ea; color: #1d2a26; }
  main { max-width: 26rem; margin: 0 auto; padding: 3rem 1.25rem; }
  h1 { font-size: 1.6rem; line-height: 1.2; margin: 0 0 .75rem; }
  a.button { display: block; margin: 1.75rem 0; padding: .9rem 1rem; border-radius: 14px; background: #1f6f5c; color: #fff; text-align: center; text-decoration: none; font-weight: 600; }
  p { margin: 0 0 1rem; }
  .hint { font-size: .9rem; opacity: .75; }
  a { color: #1f6f5c; }
  @media (prefers-color-scheme: dark) { body { background: #14201c; color: #e7efe9; } a { color: #7fd1b9; } a.button { background: #2c8b74; color: #fff; } }
</style>
</head>
<body>
<main>
<h1>Einladung zum Reiseplaner</h1>
${open ? `<p>Du wurdest eingeladen, eine Reise gemeinsam zu planen. Die Einladung öffnest du in der App.</p>
<a class="button" href="${esc(open)}">In der App öffnen</a>` : `<p>Dieser Link ist unvollständig. Bitte tippe den Einladungslink noch einmal an oder lass ihn dir neu schicken.</p>`}
<div class="hint">${getIt}</div>
</main>
</body>
</html>`;
}
