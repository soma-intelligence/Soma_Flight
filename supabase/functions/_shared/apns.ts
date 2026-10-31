// APNs sending: provider token (ES256 JWT), one HTTP/2 request per device token. What an event is
// worth lives in alerts.ts, the words in alert_copy.ts.
import { importPKCS8, SignJWT } from "npm:jose@5";

export type FlightEventKind =
  | "gate_change"
  | "delay"
  | "departure"
  | "arrival"
  | "cancel"
  | "diversion"
  | "position"
  | "update";

const JWT_TTL_S = 50 * 60;
const jwtCache = new Map<string, { jwt: string; iat: number }>();

/**
 * Provider token for token based APNs auth. Apple wants a fresh one between every 20 and 60
 * minutes, so one is cached for 50. `now` is in seconds.
 */
export async function apnsJwt(
  teamId: string,
  keyId: string,
  p8: string,
  now: number,
): Promise<string> {
  const cacheKey = `${teamId}\n${keyId}\n${p8}`;
  const hit = jwtCache.get(cacheKey);
  if (hit && now >= hit.iat && now - hit.iat < JWT_TTL_S) return hit.jwt;
  const key = await importPKCS8(p8, "ES256");
  const jwt = await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: keyId })
    .setIssuer(teamId)
    .setIssuedAt(now)
    .sign(key);
  jwtCache.set(cacheKey, { jwt, iat: now });
  return jwt;
}

/** Drops the cached provider token, after APNs refused it. */
export function evictApnsJwt(teamId: string, keyId: string, p8: string): void {
  jwtCache.delete(`${teamId}\n${keyId}\n${p8}`);
}

export interface SendOpts {
  pushType: "alert" | "liveactivity";
  /** Bundle id for alerts; `<bundle id>.push-type.liveactivity` for Live Activities. */
  topic: string;
  sandbox: boolean;
  /** Provider token from apnsJwt. */
  jwt: string;
  /** 10 sends now (default), 5 lets the system batch it. */
  priority?: 5 | 10;
  /** Absolute UNIX seconds after which APNs drops an undelivered push. 0 means do not store. */
  expiration?: number;
  collapseId?: string;
  /** Wait before the one retry on 429 or 503. Default 500 ms. */
  retryDelayMs?: number;
}

export interface ApnsResult {
  ok: boolean;
  status: number;
  reason?: string;
}

export function apnsHost(sandbox: boolean): string {
  return sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com";
}

const SEND_TIMEOUT_MS = 10_000;

/** One push to one device token, retried once after a pause on 429 or 503. Never throws. */
export async function sendApns(
  token: string,
  payload: object,
  opts: SendOpts,
  fetchFn: typeof fetch = fetch,
): Promise<ApnsResult> {
  const first = await sendOnce(token, payload, opts, fetchFn);
  if (first.status !== 429 && first.status !== 503) return first;
  await new Promise((r) => setTimeout(r, opts.retryDelayMs ?? 500));
  return sendOnce(token, payload, opts, fetchFn);
}

async function sendOnce(
  token: string,
  payload: object,
  opts: SendOpts,
  fetchFn: typeof fetch = fetch,
): Promise<ApnsResult> {
  const headers: Record<string, string> = {
    authorization: `bearer ${opts.jwt}`,
    "apns-push-type": opts.pushType,
    "apns-topic": opts.topic,
    "apns-priority": String(opts.priority ?? 10),
    "content-type": "application/json",
  };
  if (opts.expiration !== undefined) {
    headers["apns-expiration"] = String(opts.expiration);
  }
  if (opts.collapseId) headers["apns-collapse-id"] = opts.collapseId;
  try {
    const res = await fetchFn(
      `https://${apnsHost(opts.sandbox)}/3/device/${token}`,
      {
        method: "POST",
        headers,
        body: JSON.stringify(payload),
        signal: AbortSignal.timeout(SEND_TIMEOUT_MS),
      },
    );
    if (res.status === 200) {
      await res.body?.cancel();
      return { ok: true, status: 200 };
    }
    let reason: string | undefined;
    try {
      const body = await res.json();
      if (typeof body?.reason === "string") reason = body.reason;
    } catch { /* APNs error bodies are JSON, but do not depend on it */ }
    return { ok: false, status: res.status, reason };
  } catch (e) {
    return {
      ok: false,
      status: 0,
      reason: e instanceof Error ? e.name : "network_error",
    };
  }
}

/** True when APNs says the token is gone for good (410 or Unregistered). */
export function isDeadToken(r: ApnsResult): boolean {
  return r.status === 410 || r.reason === "Unregistered";
}

/** BadDeviceToken: a bad token, or every token when APNS_SANDBOX is wrong. Needs two strikes. */
export function isBadDeviceToken(r: ApnsResult): boolean {
  return r.reason === "BadDeviceToken";
}

/** The provider token itself was refused: nothing in this batch can succeed. */
export function isProviderTokenRejected(r: ApnsResult): boolean {
  return r.status === 403 &&
    (r.reason === "ExpiredProviderToken" ||
      r.reason === "InvalidProviderToken");
}

/** Constant-time string compare (hashes both, so length does not leak either). */
export async function safeEqual(a: string, b: string): Promise<boolean> {
  const enc = new TextEncoder();
  const [x, y] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(a)),
    crypto.subtle.digest("SHA-256", enc.encode(b)),
  ]);
  const xa = new Uint8Array(x), ya = new Uint8Array(y);
  let diff = 0;
  for (let i = 0; i < xa.length; i++) diff |= xa[i] ^ ya[i];
  return diff === 0;
}

/** Runs `fn` over `items`, at most `limit` at a time. A rejection never stops the others. */
export async function mapLimit<T, R>(
  items: T[],
  limit: number,
  fn: (item: T) => Promise<R>,
): Promise<PromiseSettledResult<R>[]> {
  const out: PromiseSettledResult<R>[] = new Array(items.length);
  let next = 0;
  const worker = async () => {
    while (next < items.length) {
      const i = next++;
      try {
        out[i] = { status: "fulfilled", value: await fn(items[i]) };
      } catch (reason) {
        out[i] = { status: "rejected", reason };
      }
    }
  };
  await Promise.all(
    Array.from({ length: Math.min(limit, items.length) }, worker),
  );
  return out;
}
