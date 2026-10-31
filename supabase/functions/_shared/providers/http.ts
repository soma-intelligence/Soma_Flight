// Fetch and time helpers shared by the adapters.
import { ApiError } from "../errors.ts";

export type Fetch = typeof fetch;
export const DEFAULT_TIMEOUT_MS = 10_000;

/**
 * GET (or POST) and parse JSON. Network trouble, 5xx and auth or plan errors become
 * provider_unavailable (502), 429 becomes rate_limited and 404 not_found, as AeroApi does. Logs the
 * status and a label only, never the URL (it may carry a key).
 */
export async function fetchJson<T>(
  fetchFn: Fetch,
  label: string,
  url: string,
  init: RequestInit = {},
  timeoutMs = DEFAULT_TIMEOUT_MS,
): Promise<T> {
  let res: Response;
  try {
    res = await fetchFn(url, {
      ...init,
      signal: AbortSignal.timeout(timeoutMs),
      headers: { accept: "application/json", ...(init.headers ?? {}) },
    });
  } catch (e) {
    console.error(`${label} network error`, (e as Error).name);
    throw new ApiError("provider_unavailable", 502, "Provider unreachable");
  }
  const text = await res.text().catch(() => "");
  if (res.status === 404) {
    throw new ApiError("not_found", 404, "Not found at provider");
  }
  if (res.status === 429) {
    throw new ApiError("rate_limited", 429, "Provider rate limit");
  }
  if (!res.ok) {
    console.error(
      `${label} error status=${res.status} code=${errorCode(text) ?? "-"}`,
    );
    throw new ApiError(
      "provider_unavailable",
      502,
      `Provider error ${res.status}`,
    );
  }
  try {
    return JSON.parse(text) as T;
  } catch {
    throw new ApiError(
      "provider_unavailable",
      502,
      "Provider returned invalid JSON",
    );
  }
}

/**
 * The provider's error code from an error body ({ error: { code } } on Aviationstack), cut short and
 * limited to word characters so a log line never carries anything else from the body.
 */
export function errorCode(body: string | unknown): string | null {
  let o: unknown = body;
  if (typeof body === "string") {
    try {
      o = JSON.parse(body);
    } catch {
      return null;
    }
  }
  const c = (o as { error?: { code?: unknown } } | null)?.error?.code;
  return typeof c === "string" && /^\w{1,40}$/.test(c) ? c : null;
}

/** Offset of a timezone from UTC at an instant, in ms (local minus UTC). */
function zoneOffset(tz: string, at: Date): number {
  const p = Object.fromEntries(
    new Intl.DateTimeFormat("en-US", {
      timeZone: tz,
      hourCycle: "h23",
      year: "numeric",
      month: "numeric",
      day: "numeric",
      hour: "numeric",
      minute: "numeric",
      second: "numeric",
    }).formatToParts(at).map((x) => [x.type, Number(x.value)]),
  );
  const asUtc = Date.UTC(
    p.year,
    p.month - 1,
    p.day,
    p.hour,
    p.minute,
    p.second,
  );
  return asUtc - Math.floor(at.getTime() / 1000) * 1000;
}

const WALL =
  /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?/;

/**
 * A wall-clock time at an airport ("2024-06-18T23:10:00.000", any offset ignored) as a UTC ISO
 * string with milliseconds. Null for an unparseable value or an unknown timezone, so a time is never
 * placed in the wrong zone.
 */
export function wallToUtc(
  v: string | null | undefined,
  tz: string | null | undefined,
): string | null {
  if (!v || !tz) return null;
  const m = WALL.exec(v);
  if (!m) return null;
  const local = Date.UTC(
    Number(m[1]),
    Number(m[2]) - 1,
    Number(m[3]),
    Number(m[4]),
    Number(m[5]),
    Number(m[6] ?? 0),
  );
  try {
    let guess = local - zoneOffset(tz, new Date(local));
    guess = local - zoneOffset(tz, new Date(guess)); // settle across a DST change
    return new Date(guess).toISOString();
  } catch {
    return null;
  }
}

/**
 * A provider time that carries its own zone ("2026-10-31T08:30:00+00:00") or is stated as UTC
 * ("2026-10-31 08:30" in a *_utc field), as a UTC ISO string with milliseconds. Null otherwise.
 */
export function utcIso(v: string | null | undefined): string | null {
  if (!v) return null;
  const s = v.trim().replace(" ", "T");
  const withZone = /([zZ]|[+-]\d{2}:?\d{2})$/.test(s) ? s : `${s}Z`;
  const t = Date.parse(withZone);
  return Number.isFinite(t) ? new Date(t).toISOString() : null;
}

/** Unix seconds as a UTC ISO string, null for anything that is not a positive number. */
export function epochIso(v: unknown): string | null {
  return typeof v === "number" && Number.isFinite(v) && v > 0
    ? new Date(v * 1000).toISOString()
    : null;
}

/** YYYY-MM-DD of an instant in a timezone (UTC when the zone is unknown). */
export function localDay(iso: string, tz: string | null | undefined): string {
  const at = new Date(iso);
  try {
    return new Intl.DateTimeFormat("en-CA", {
      timeZone: tz ?? "UTC",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    }).format(at);
  } catch {
    return at.toISOString().slice(0, 10);
  }
}

/** A non-empty trimmed string, else null. */
export function text(v: unknown, max = 100): string | null {
  if (typeof v !== "string") return null;
  const t = v.trim();
  return t ? t.slice(0, max) : null;
}

/** Upper-case airport or airline code of the expected length, else null. */
export function code(v: unknown, len: number): string | null {
  const t = text(v, 8)?.toUpperCase() ?? null;
  return t && t.length === len && /^[A-Z0-9]+$/.test(t) ? t : null;
}
