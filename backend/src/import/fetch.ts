import { lookup } from "node:dns/promises";
import net from "node:net";

/**
 * A desktop browser identity. Tests showed that app short links send phone
 * browsers to the App Store and that link-preview bot identities get blocked.
 */
const USER_AGENT =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

const MAX_BYTES = 4 * 1024 * 1024;
const MAX_REDIRECTS = 6;
const TIMEOUT_MS = 15_000;

export interface FetchedPage {
  finalUrl: string;
  status: number;
  html: string;
  /** Set when the site answered with a bot check instead of the page. */
  blocked: boolean;
  redirects: string[];
}

export type PageFetcher = (url: string) => Promise<FetchedPage>;

export class UnsafeUrlError extends Error {}

function isPrivateAddress(ip: string): boolean {
  if (net.isIPv4(ip)) {
    const [a, b] = ip.split(".").map(Number) as [number, number];
    return (
      a === 0 ||
      a === 10 ||
      a === 127 ||
      (a === 100 && b >= 64 && b <= 127) || // carrier-grade NAT, used by Tailscale
      (a === 169 && b === 254) ||
      (a === 172 && b >= 16 && b <= 31) ||
      (a === 192 && b === 168) ||
      a >= 224
    );
  }
  const v6 = ip.toLowerCase();
  if (v6.startsWith("::ffff:")) return isPrivateAddress(v6.slice(7));
  return v6 === "::1" || v6 === "::" || v6.startsWith("fc") || v6.startsWith("fd") || v6.startsWith("fe80") || v6.startsWith("ff");
}

/** The server must never be usable to reach the home network or the tailnet. */
export async function assertPublicUrl(raw: string): Promise<URL> {
  const url = new URL(raw);
  if (url.protocol !== "https:" && url.protocol !== "http:") throw new UnsafeUrlError("Only http and https are allowed.");
  if (url.username || url.password) throw new UnsafeUrlError("Links with credentials are not allowed.");
  if (url.port && !["80", "443"].includes(url.port)) throw new UnsafeUrlError("Only the standard web ports are allowed.");
  const host = url.hostname.replace(/^\[|\]$/g, "");
  if (net.isIP(host)) {
    if (isPrivateAddress(host)) throw new UnsafeUrlError("Private addresses are not allowed.");
    return url;
  }
  if (host === "localhost" || host.endsWith(".local") || host.endsWith(".internal") || host.endsWith(".ts.net")) {
    throw new UnsafeUrlError("Internal host names are not allowed.");
  }
  const addresses = await lookup(host, { all: true });
  if (addresses.length === 0 || addresses.some((a) => isPrivateAddress(a.address))) {
    throw new UnsafeUrlError("The host resolves to a private address.");
  }
  return url;
}

const BLOCK_MARKERS = [
  /cf-mitigated|Just a moment\.\.\.|challenge-platform/i,
  /Bot oder Mensch|Bot or human|px-captcha|perimeterx/i,
  /captcha-delivery\.com|datadome/i,
  /<title>\s*Access Denied\s*<\/title>/i,
];

export function looksBlocked(status: number, html: string): boolean {
  if (status === 403 || status === 429) return true;
  return html.length < 200_000 && BLOCK_MARKERS.some((re) => re.test(html));
}

async function readLimited(res: Response): Promise<string> {
  const reader = res.body?.getReader();
  if (!reader) return "";
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > MAX_BYTES) {
      await reader.cancel();
      break;
    }
    chunks.push(value);
  }
  return Buffer.concat(chunks).toString("utf8");
}

/** Plain HTTP fetch with redirects followed by hand, so every hop is checked. */
export const fetchPage: PageFetcher = async (startUrl) => {
  let current = startUrl;
  const redirects: string[] = [];
  for (let hop = 0; hop <= MAX_REDIRECTS; hop++) {
    const url = await assertPublicUrl(current);
    const res = await fetch(url, {
      redirect: "manual",
      signal: AbortSignal.timeout(TIMEOUT_MS),
      headers: {
        "user-agent": USER_AGENT,
        accept: "text/html,application/xhtml+xml;q=0.9,*/*;q=0.8",
        "accept-language": "de-DE,de;q=0.9,en;q=0.5",
      },
    });
    const location = res.headers.get("location");
    if (res.status >= 300 && res.status < 400 && location) {
      await res.body?.cancel();
      const next = new URL(location, url);
      // App-store and deep links end the chain: there is no web page behind them.
      if (next.protocol !== "https:" && next.protocol !== "http:") break;
      redirects.push(next.toString());
      current = next.toString();
      continue;
    }
    const html = await readLimited(res);
    return { finalUrl: url.toString(), status: res.status, html, blocked: looksBlocked(res.status, html), redirects };
  }
  return { finalUrl: current, status: 0, html: "", blocked: false, redirects };
};
