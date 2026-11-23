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
  /** The app's bundle identifiers, separated by commas: who "Sign in with Apple" tokens have to be issued for. */
  APPLE_CLIENT_IDS: z.string().default("com.von-bleichert.travelplanner"),
  /** Team and bundle identifier: the app that may open invitation links of this server directly. */
  APPLE_APP_ID: z.string().default("AX2SZQVU9L.com.von-bleichert.travelplanner"),
  /** Where the app can be had while it is in testing. Named on the invitation page only when set. */
  TESTFLIGHT_URL: z.string().url().optional(),
});

export type Config = z.infer<typeof schema>;

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  // Empty strings in .env files mean "not set".
  const cleaned = Object.fromEntries(Object.entries(env).filter(([, v]) => v !== ""));
  return schema.parse(cleaned);
}
