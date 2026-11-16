import { z } from "zod";

const schema = z.object({
  DATABASE_URL: z.string().min(1),
  PORT: z.coerce.number().int().default(3000),
  HOST: z.string().default("0.0.0.0"),
  PUBLIC_BASE_URL: z.string().url().default("http://localhost:3000"),
  BOOTSTRAP_SECRET: z.string().min(24).optional(),
  ANTHROPIC_API_KEY: z.string().min(1).optional(),
  EXTRACTION_MODEL: z.string().default("claude-haiku-5-5"),
  /** Finding the same property on other platforms needs web search and more judgement than reading a page. */
  SEARCH_MODEL: z.string().default("claude-sonnet-5-5"),
  /** Per person and day: pages read with the language model, and web searches for the same property. */
  DAILY_READINGS: z.coerce.number().int().min(1).default(400),
  DAILY_SEARCHES: z.coerce.number().int().min(1).default(30),
  /** Where uploaded documents are kept. In the container a volume is mounted here. */
  FILES_DIR: z.string().default("/data/files"),
});

export type Config = z.infer<typeof schema>;

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  // Empty strings in .env files mean "not set".
  const cleaned = Object.fromEntries(Object.entries(env).filter(([, v]) => v !== ""));
  return schema.parse(cleaned);
}
