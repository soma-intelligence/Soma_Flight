// APNs sending: provider token (ES256 JWT), one HTTP/2 request per device token, alert copy.
import { importPKCS8, SignJWT } from "npm:jose@5";
import type { FlightRow } from "./aeroapi_types.ts";

export type FlightEventKind =
  | "gate_change"
  | "delay"
  | "departure"
  | "arrival"
  | "cancel"
  | "diversion"
  | "position";

/** A delay event exists from this many minutes. Below it, alertCopy returns null. */
export const MIN_DELAY_ALERT_MIN = 15;

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

// ---- copy ----

type CopyFlight = Pick<
  FlightRow,
  | "ident"
  | "status"
  | "scheduled_out"
  | "scheduled_in"
  | "estimated_out"
  | "estimated_in"
  | "actual_out"
  | "gate_origin"
  | "gate_destination"
  | "origin_iata"
  | "origin_icao"
  | "destination_iata"
  | "destination_icao"
  | "baggage_belt"
>;

export interface CopyContext {
  /** flight_events.payload, read for `delay_minutes` and `changes`. */
  payload?: Record<string, unknown> | null;
  /** IANA zones of the two airports, to show local times. UTC when missing. */
  originTz?: string | null;
  destinationTz?: string | null;
}

const ms = (v: string | null | undefined): number | null => {
  if (!v) return null;
  const t = Date.parse(v);
  return Number.isFinite(t) ? t : null;
};

/** New delay in minutes: the event payload first, then the flight row. Null when unknown. */
export function delayMinutes(
  flight: CopyFlight,
  payload?: Record<string, unknown> | null,
): number | null {
  const p = payload?.delay_minutes;
  if (typeof p === "number" && Number.isFinite(p)) return Math.round(p);
  const dep = diffMin(flight.estimated_out, flight.scheduled_out);
  const arr = diffMin(flight.estimated_in, flight.scheduled_in);
  return (flight.actual_out ? arr ?? dep : dep ?? arr);
}

function diffMin(
  est: string | null | undefined,
  sched: string | null | undefined,
): number | null {
  const e = ms(est), s = ms(sched);
  return e === null || s === null ? null : Math.round((e - s) / 60_000);
}

function clock(iso: string, tz: string | null | undefined): string {
  const fmt = (zone: string) =>
    new Intl.DateTimeFormat("en-US", {
      hour: "numeric",
      minute: "2-digit",
      timeZone: zone,
    }).format(new Date(iso));
  try {
    if (tz) return fmt(tz);
  } catch { /* unknown zone: fall through to UTC */ }
  return `${fmt("UTC")} UTC`;
}

const code = (iata: string | null, icao: string | null) => iata ?? icao ?? null;

function changedTo(
  payload: Record<string, unknown> | null | undefined,
  key: string,
): string | null {
  const changes = payload?.changes as Record<string, unknown> | undefined;
  const entry = changes?.[key] as { to?: unknown } | undefined;
  return typeof entry?.to === "string" && entry.to ? entry.to : null;
}

function route(f: CopyFlight): string {
  const o = code(f.origin_iata, f.origin_icao);
  const d = code(f.destination_iata, f.destination_icao);
  return o && d ? `${o} to ${d}` : "";
}

/**
 * Notification text for an event, or null when it gets no alert (position, small delays).
 * Short English, no dashes. Titles carry the IATA flight ident.
 */
export function alertCopy(
  kind: FlightEventKind,
  flight: CopyFlight,
  ctx: CopyContext = {},
): { title: string; body: string } | null {
  const id = flight.ident;
  const dest = code(flight.destination_iata, flight.destination_icao);
  const orig = code(flight.origin_iata, flight.origin_icao);
  switch (kind) {
    case "gate_change": {
      const gateO = changedTo(ctx.payload, "gate_origin");
      const gateD = changedTo(ctx.payload, "gate_destination");
      // With the event's changes, say what moved. Without, the gate for the leg that is next.
      const departed = flight.actual_out !== null ||
        !["scheduled", "unknown"].includes(flight.status);
      const originSide = gateO !== null && gateD === null
        ? true
        : gateD !== null && gateO === null
        ? false
        : !departed;
      const gate = originSide
        ? gateO ?? flight.gate_origin
        : gateD ?? flight.gate_destination;
      const body = gate
        ? originSide
          ? `Departure gate is now ${gate}${orig ? ` at ${orig}` : ""}.`
          : `Arrival gate is now ${gate}${dest ? ` at ${dest}` : ""}.`
        : "Your gate changed. Open the app for the new one.";
      return { title: `${id} gate change`, body };
    }
    case "delay": {
      const min = delayMinutes(flight, ctx.payload);
      if (min === null || min < MIN_DELAY_ALERT_MIN) return null;
      const late = `${min} min late`;
      const departed = flight.actual_out !== null;
      const at = departed ? flight.estimated_in : flight.estimated_out;
      const verb = departed ? "arrive" : "depart";
      const tz = departed ? ctx.destinationTz : ctx.originTz;
      const when = at ? clock(at, tz) : null;
      return {
        title: `${id} delayed`,
        body: when
          ? `Now expected to ${verb} at ${when}, ${late}.`
          : `Now running ${late}.`,
      };
    }
    case "departure":
      return {
        title: `${id} departed`,
        body: dest ? `On its way to ${dest}.` : "On its way.",
      };
    case "arrival": {
      const belt = flight.baggage_belt
        ? ` Baggage on belt ${flight.baggage_belt}.`
        : "";
      const gate = flight.gate_destination
        ? ` Gate ${flight.gate_destination}.`
        : "";
      return {
        title: `${id} landed`,
        body: `${dest ? `Landed at ${dest}.` : "Landed."}${gate}${belt}`,
      };
    }
    case "cancel": {
      const r = route(flight);
      return {
        title: `${id} canceled`,
        body: r
          ? `The flight from ${r} was canceled.`
          : "The flight was canceled.",
      };
    }
    case "diversion":
      return {
        title: `${id} diverted`,
        body:
          "The flight is landing at a different airport. Open the app for details.",
      };
    case "position":
      return null;
  }
}
