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
import { ledgerRoutes } from "./routes/ledger.js";
import { candidateRoutes } from "./routes/candidates.js";
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
}

export async function buildApp(deps: Omit<AppContext, "queue">, options: { logger?: boolean } = {}): Promise<{ app: FastifyInstance; ctx: AppContext }> {
  const app = Fastify({
    // Invite tokens travel in the path. They are secrets and must not end up in the log.
    logger: options.logger
      ? {
          serializers: {
            req: (req: { method: string; url: string; hostname?: string; ip?: string }) => ({
              method: req.method,
              url: req.url.replace(/(\/auth\/invites\/)[^/?]+/, "$1…"),
              hostname: req.hostname,
              remoteAddress: req.ip,
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
    if (e.statusCode && e.statusCode < 500) {
      return reply.code(e.statusCode).send({ error: { code: e.statusCode === 429 ? "rate_limited" : "invalid_request", message: e.statusCode === 429 ? "Zu viele Anfragen. Bitte kurz warten." : (e.message ?? "Ungültige Anfrage.") } });
    }
    app.log.error({ err }, "unhandled error");
    return reply.code(500).send({ error: { code: "internal", message: "Interner Fehler." } });
  });
  app.setNotFoundHandler((_req, reply) => reply.code(404).send({ error: { code: "not_found", message: "Nicht gefunden." } }));

  app.get("/health", async () => ({ ok: true }));
  authRoutes(app, ctx);
  tripRoutes(app, ctx);
  candidateRoutes(app, ctx);
  ledgerRoutes(app, ctx);

  app.addHook("onClose", async () => ctx.queue.idle());
  return { app, ctx };
}
