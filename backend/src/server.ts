import { buildApp } from "./app.js";
import { loadConfig } from "./config.js";
import { connect } from "./db/client.js";
import { baselineExtractor, claudeExtractor } from "./import/extract.js";
import { fetchPage } from "./import/fetch.js";

const config = loadConfig();
const { db, close } = await connect(config.DATABASE_URL);
const extractor = config.ANTHROPIC_API_KEY ? claudeExtractor({ apiKey: config.ANTHROPIC_API_KEY, model: config.EXTRACTION_MODEL }) : baselineExtractor;

const { app } = await buildApp({ db, config, fetcher: fetchPage, extractor }, { logger: true });
if (!config.ANTHROPIC_API_KEY) app.log.warn("ANTHROPIC_API_KEY is not set: imports use structured page data only.");

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    void app.close().then(close).then(() => process.exit(0));
  });
}

await app.listen({ port: config.PORT, host: config.HOST });
