// Per provider quota counter. A free tier is a hard ceiling (Aviationstack bills overage, OpenSky
// answers 429 and a trial key dies), so every request is charged against provider_quota through
// charge_provider_quota (migration 20261031000027) before it goes out. A refusal throws the same
// provider_unavailable (503) the AeroAPI spend cap throws, so callers serve what they have cached.
// AeroAPI keeps its USD spend cap (limits.ts usageCounter); this counter is for the others.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { ApiError } from "../errors.ts";
import type { ProviderName } from "./types.ts";

export type QuotaPeriod = "day" | "month";

/** How a provider's allowance is counted, and its free tier when no secret overrides it. */
export interface QuotaRule {
  period: QuotaPeriod;
  /** Units per period. */
  limit: number;
}

/**
 * Free tier allowances, checked 2026-10-31 (docs/free-providers.md):
 * - Aviationstack Free: 100 requests a month.
 * - FlightLabs: a 7 day trial of at most 50 requests (no lasting free tier); Starter is 4,000.
 * - OpenSky: 400 API credits a day anonymous, 4,000 with a standard account (8,000 for feeders).
 */
export const FREE_TIER: Record<
  Exclude<ProviderName, "aeroapi" | "none">,
  QuotaRule
> = {
  aviationstack: { period: "month", limit: 100 },
  flightlabs: { period: "month", limit: 50 },
  opensky: { period: "day", limit: 400 },
};

/** OpenSky's daily credits once OAuth2 client credentials are set. */
export const OPENSKY_ACCOUNT_CREDITS = 4000;

/** Env names of the quota overrides, for a paid plan or a feeder account. */
export const QUOTA_ENV: Record<keyof typeof FREE_TIER, string> = {
  aviationstack: "AVIATIONSTACK_MONTHLY_QUOTA",
  flightlabs: "FLIGHTLABS_MONTHLY_QUOTA",
  opensky: "OPENSKY_DAILY_CREDITS",
};

/**
 * The polling refresh may use this share of a quota; the rest stays for users' own lookups, so a
 * busy day of polling never leaves the search screen empty. POLL_QUOTA_SHARE overrides it.
 */
export const DEFAULT_POLL_SHARE = 0.7;

type Env = (name: string) => string | undefined;
const realEnv: Env = (n) => Deno.env.get(n);

/** The rule for a provider: the env override when it is a whole number >= 0, else the free tier. */
export function quotaRule(
  provider: keyof typeof FREE_TIER,
  env: Env = realEnv,
): QuotaRule {
  const base = FREE_TIER[provider];
  const raw = env(QUOTA_ENV[provider]);
  const n = Number(raw);
  if (raw && Number.isInteger(n) && n >= 0) return { ...base, limit: n };
  if (
    provider === "opensky" && env("OPENSKY_CLIENT_ID") &&
    env("OPENSKY_CLIENT_SECRET")
  ) {
    return { ...base, limit: OPENSKY_ACCOUNT_CREDITS };
  }
  return base;
}

/** POLL_QUOTA_SHARE when it is in (0, 1], else the default. */
export function pollShare(env: Env = realEnv): number {
  const n = Number(env("POLL_QUOTA_SHARE"));
  return Number.isFinite(n) && n > 0 && n <= 1 ? n : DEFAULT_POLL_SHARE;
}

/** First day of the counting period (UTC), as YYYY-MM-DD. */
export function periodStart(period: QuotaPeriod, now: Date): string {
  const day = now.toISOString().slice(0, 10);
  return period === "day" ? day : `${day.slice(0, 8)}01`;
}

/** Charges `units` against a provider's quota or throws. Injected into every adapter. */
export type QuotaCharge = (units: number) => Promise<void>;

/**
 * A QuotaCharge on provider_quota. `limit` is the ceiling this caller may reach (the poller passes
 * its share). A database error is thrown as is: unlike the AeroAPI counter, a free tier must never
 * be overrun because the counter was down.
 */
export function quotaCounter(
  db: SupabaseClient,
  provider: keyof typeof FREE_TIER,
  rule: QuotaRule,
  now: () => Date = () => new Date(),
  limit: number = rule.limit,
): QuotaCharge {
  return async (units) => {
    const { data, error } = await db.rpc("charge_provider_quota", {
      p_provider: provider,
      p_period: periodStart(rule.period, now()),
      p_units: units,
      p_limit: Math.floor(limit),
    });
    if (error) {
      throw new ApiError(
        "provider_unavailable",
        503,
        `Quota counter unavailable: ${error.message}`,
      );
    }
    if (data !== true) {
      console.error(`${provider} quota reached (${rule.period}, ${limit})`);
      throw new ApiError(
        "provider_unavailable",
        503,
        rule.period === "day"
          ? "Daily provider quota reached"
          : "Monthly provider quota reached",
      );
    }
  };
}

/** A QuotaCharge that counts in memory, for tests and for local runs without a database. */
export function memoryQuota(
  limit: number,
): QuotaCharge & { used: () => number } {
  let used = 0;
  const charge = (units: number) => {
    if (used + units > limit) {
      return Promise.reject(
        new ApiError(
          "provider_unavailable",
          503,
          "Monthly provider quota reached",
        ),
      );
    }
    used += units;
    return Promise.resolve();
  };
  return Object.assign(charge, { used: () => used });
}
