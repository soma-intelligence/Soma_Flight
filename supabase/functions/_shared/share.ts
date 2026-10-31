// Live flight sharing rules shared by share-flight (creates and revokes links) and flight-page (shows them):
// the token, how it is stored, and when a share expires.

/** A share link stays open this long after the flight arrives. */
export const SHARE_TTL_AFTER_ARRIVAL_MS = 24 * 3600_000;
/** With no arrival time at all, the arrival is taken as this long after departure. */
export const FALLBACK_BLOCK_MS = 24 * 3600_000;
/** Where share links point; the landing site rewrites /f/* to flight-page. */
export const DEFAULT_SHARE_BASE = "https://somalabs.me/f/";

/** 32 random bytes in base64url: 43 characters, 256 bits, never guessed. */
export const TOKEN_RE = /^[A-Za-z0-9_-]{43}$/;

/** A new share token from the system's CSPRNG. */
export function newToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** What the table stores for a token: its SHA-256 in lower case hex. */
export async function hashToken(token: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(token),
  );
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/** The share link for `token` under `base` (SHARE_BASE_URL, else somalabs.me/f/). */
export function shareUrl(token: string, base?: string | null): string {
  const b = base && /^https:\/\//.test(base) ? base : DEFAULT_SHARE_BASE;
  return (b.endsWith("/") ? b : `${b}/`) + token;
}

/** The flight times expiry reads (a flights row, or any slice of one). */
export interface FlightTimes {
  scheduled_out?: string | null;
  estimated_out?: string | null;
  actual_out?: string | null;
  scheduled_in?: string | null;
  estimated_in?: string | null;
  actual_in?: string | null;
  scheduled_on?: string | null;
  estimated_on?: string | null;
  actual_on?: string | null;
}

function ms(v: string | null | undefined): number | null {
  if (!v) return null;
  const t = Date.parse(v);
  return Number.isFinite(t) ? t : null;
}

/**
 * The flight's best known arrival: at the gate, else on the runway, else the estimate, else the schedule.
 * With no arrival time at all, a day after its best departure time; null when it has no time at all.
 */
export function arrivalOf(f: FlightTimes): number | null {
  const arr = ms(f.actual_in) ?? ms(f.actual_on) ?? ms(f.estimated_in) ??
    ms(f.estimated_on) ?? ms(f.scheduled_in) ?? ms(f.scheduled_on);
  if (arr !== null) return arr;
  const dep = ms(f.actual_out) ?? ms(f.estimated_out) ?? ms(f.scheduled_out);
  return dep === null ? null : dep + FALLBACK_BLOCK_MS;
}

/**
 * When a share of `f` stops working: 24 hours after the flight arrives. It moves with the flight (a delay
 * keeps the link open longer). A flight with no time at all expires 48 hours after the share was made.
 */
export function shareExpiresAt(f: FlightTimes, createdAt: Date): Date {
  const arr = arrivalOf(f);
  return new Date(
    arr === null
      ? createdAt.getTime() + FALLBACK_BLOCK_MS + SHARE_TTL_AFTER_ARRIVAL_MS
      : arr + SHARE_TTL_AFTER_ARRIVAL_MS,
  );
}

/** A stored share as both functions read it. */
export interface ShareRow {
  id: string;
  flight_id: string;
  user_id: string;
  created_at: string;
  revoked_at: string | null;
}

/** True while the share opens its page: not revoked and not past its flight's expiry. */
export function shareIsOpen(
  share: Pick<ShareRow, "created_at" | "revoked_at">,
  f: FlightTimes,
  now: Date,
): boolean {
  if (share.revoked_at) return false;
  return now.getTime() <
    shareExpiresAt(f, new Date(share.created_at)).getTime();
}
