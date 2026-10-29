// Per-user rate limits, the free plan follow limit, and the AeroAPI usage counter hook.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { ApiError } from "./errors.ts";
import { AeroApi, estimateCost } from "./aeroapi.ts";
import { serviceClient } from "./auth.ts";

/** Throws rate_limited (429) when the user already made `max` calls to `endpoint` in the window. Counts this call otherwise. */
export async function checkRate(
  userId: string,
  endpoint: string,
  max: number,
  windowMinutes: number,
  db: SupabaseClient = serviceClient(),
): Promise<void> {
  const { data, error } = await db.rpc("check_rate", {
    p_user: userId,
    p_endpoint: endpoint,
    p_max: max,
    p_window_minutes: windowMinutes,
  });
  if (error) throw new Error(`check_rate failed: ${error.message}`);
  if (data !== true) {
    throw new ApiError("rate_limited", 429, "Too many requests");
  }
}

/** Throws plan_limit (403) for a free user with 3 or more active follows (flights not arrived or canceled). */
export async function checkPlanFollowLimit(
  userId: string,
  db: SupabaseClient = serviceClient(),
): Promise<void> {
  const { data, error } = await db.rpc("plan_follow_allowed", {
    p_user: userId,
  });
  if (error) throw new Error(`plan_follow_allowed failed: ${error.message}`);
  if (data !== true) {
    throw new ApiError(
      "plan_limit",
      403,
      "Free plan allows 3 followed flights",
    );
  }
}

/** Global daily AeroAPI budget in USD when AEROAPI_DAILY_CAP_USD is unset or invalid (ruling F6). */
export const DEFAULT_DAILY_CAP_USD = 50;

/** AEROAPI_DAILY_CAP_USD, or the default for a missing, negative or non-numeric value. */
export function dailyCap(
  raw: string | undefined = Deno.env.get("AEROAPI_DAILY_CAP_USD"),
): number {
  const n = Number(raw);
  return raw && Number.isFinite(n) && n >= 0 ? n : DEFAULT_DAILY_CAP_USD;
}

/**
 * onCall hook for AeroApi: counts every request in today's usage_counters (UTC day) through
 * charge_usage, which refuses a paid request that would take today's estimated spend past `cap`.
 * A refusal throws provider_unavailable (503) before the request goes out, so callers fall back to
 * what they have cached. Free requests (alert create and delete) always pass.
 */
export function usageCounter(
  db: SupabaseClient,
  now: () => Date = () => new Date(),
  cap: number = dailyCap(),
): (endpoint: string) => Promise<void> {
  return async (endpoint) => {
    const { data, error } = await db.rpc("charge_usage", {
      p_day: now().toISOString().slice(0, 10),
      p_endpoint: endpoint,
      p_cost: estimateCost(endpoint),
      p_cap: cap,
    });
    if (error) throw new Error(`charge_usage failed: ${error.message}`);
    if (data !== true) {
      console.error(`daily AeroAPI cap reached, ${endpoint} refused`);
      throw new ApiError(
        "provider_unavailable",
        503,
        "Daily provider budget reached",
      );
    }
  };
}

/** AeroApi wired to the usage counter. Throws when AEROAPI_KEY is missing. */
export function productionAeroApi(db: SupabaseClient): AeroApi {
  const key = Deno.env.get("AEROAPI_KEY");
  if (!key) throw new Error("missing env AEROAPI_KEY");
  return new AeroApi(key, fetch, usageCounter(db));
}

/**
 * AeroApi built on first use, so a function starts and serves its non-AeroAPI paths with no
 * AEROAPI_KEY. Calling an AeroAPI method without the key throws provider_unavailable (503).
 */
export function lazyAeroApi(db: SupabaseClient): AeroApi {
  let client: AeroApi | undefined;
  return new Proxy({} as AeroApi, {
    get(_target, prop) {
      // Not a method call (await, inspection): never build the client for these.
      if (typeof prop === "symbol" || prop === "then") return undefined;
      if (!client) {
        try {
          client = productionAeroApi(db);
        } catch (e) {
          console.error("AeroAPI client unavailable", (e as Error).message);
          throw new ApiError(
            "provider_unavailable",
            503,
            "AeroAPI is not configured",
          );
        }
      }
      const v = Reflect.get(client, prop);
      return typeof v === "function" ? v.bind(client) : v;
    },
  });
}
