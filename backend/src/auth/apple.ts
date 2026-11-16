import { createHash, createPublicKey, verify } from "node:crypto";
import type { webcrypto } from "node:crypto";
type JsonWebKey = webcrypto.JsonWebKey;

/** Where Apple publishes the keys its identity tokens are signed with. */
const KEYS_URL = "https://appleid.apple.com/auth/keys";
const ISSUER = "https://appleid.apple.com";

export type AppleKey = JsonWebKey & { kid?: string; alg?: string };
export type AppleKeySource = () => Promise<AppleKey[]>;

export interface AppleIdentity {
  sub: string;
  email: string | null;
}

/** Apple's keys, fetched at most once an hour, and again when a token names a key not seen yet. */
export function appleKeys(): AppleKeySource & { refresh: () => Promise<AppleKey[]> } {
  let cached: { keys: AppleKey[]; at: number } | null = null;
  const refresh = async () => {
    const res = await fetch(KEYS_URL, { signal: AbortSignal.timeout(10_000) });
    if (!res.ok) throw new Error(`apple keys: ${res.status}`);
    const body = (await res.json()) as { keys: AppleKey[] };
    cached = { keys: body.keys, at: Date.now() };
    return body.keys;
  };
  const source = async () => (cached && Date.now() - cached.at < 3_600_000 ? cached.keys : refresh());
  return Object.assign(source, { refresh });
}

const decode = (part: string) => JSON.parse(Buffer.from(part, "base64url").toString("utf8")) as Record<string, unknown>;

/**
 * Checks an identity token from "Sign in with Apple": signed by Apple, issued for this app, not expired.
 * Returns null for anything else. The reason is not told to the caller.
 */
export async function verifyAppleToken(token: string, audiences: string[], keys: AppleKeySource & { refresh?: () => Promise<AppleKey[]> }, opts: { nonce?: string; now?: number } = {}): Promise<AppleIdentity | null> {
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  let header: Record<string, unknown>;
  let claims: Record<string, unknown>;
  try {
    header = decode(parts[0]!);
    claims = decode(parts[1]!);
  } catch {
    return null;
  }
  // Only the algorithm Apple uses. A token that names its own algorithm is not believed.
  if (header.alg !== "RS256" || typeof header.kid !== "string") return null;
  let key = (await keys()).find((k) => k.kid === header.kid);
  if (!key && keys.refresh) key = (await keys.refresh()).find((k) => k.kid === header.kid);
  if (!key || key.kty !== "RSA") return null;
  let good = false;
  try {
    good = verify("RSA-SHA256", Buffer.from(`${parts[0]}.${parts[1]}`), createPublicKey({ key, format: "jwk" }), Buffer.from(parts[2]!, "base64url"));
  } catch {
    return null;
  }
  if (!good) return null;

  const now = Math.floor((opts.now ?? Date.now()) / 1000);
  if (claims.iss !== ISSUER) return null;
  const aud = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (!aud.some((a) => typeof a === "string" && audiences.includes(a))) return null;
  if (typeof claims.exp !== "number" || claims.exp < now - 60) return null;
  if (typeof claims.iat === "number" && claims.iat > now + 300) return null;
  if (typeof claims.sub !== "string" || !claims.sub) return null;
  if (opts.nonce !== undefined) {
    // The app hands Apple the hash of its nonce; some hand over the nonce itself.
    const hashed = createHash("sha256").update(opts.nonce).digest("hex");
    if (claims.nonce !== hashed && claims.nonce !== opts.nonce) return null;
  }
  return { sub: claims.sub, email: typeof claims.email === "string" ? claims.email.toLowerCase() : null };
}
