import { buildApp } from "./app.js";
import { loadConfig } from "./config.js";
import { connect } from "./db/client.js";
import { baselineExtractor, claudeExtractor, claudeReviewSummarizer } from "./import/extract.js";
import { claudeSearcher } from "./import/search.js";
import { fetchPage } from "./import/fetch.js";

const config = loadConfig();
const { db, close } = await connect(config.DATABASE_URL);
const extractor = config.ANTHROPIC_API_KEY ? claudeExtractor({ apiKey: config.ANTHROPIC_API_KEY, model: config.EXTRACTION_MODEL }) : baselineExtractor;

const summarizer = config.ANTHROPIC_API_KEY ? claudeReviewSummarizer({ apiKey: config.ANTHROPIC_API_KEY, model: config.EXTRACTION_MODEL }) : null;
const searcher = config.ANTHROPIC_API_KEY ? claudeSearcher({ apiKey: config.ANTHROPIC_API_KEY, model: config.SEARCH_MODEL }) : null;

const { app } = await buildApp({ db, config, fetcher: fetchPage, extractor, summarizer, searcher }, { logger: true });
if (!config.ANTHROPIC_API_KEY) app.log.warn("ANTHROPIC_API_KEY is not set: imports use structured page data only.");

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    void app.close().then(close).then(() => process.exit(0));
  });
}

await app.listen({ port: config.PORT, host: config.HOST });
