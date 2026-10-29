// POST /maintenance?mode=alerts|prune. Service role only: pg_cron calls it through pg_net.
// alerts: flights still holding a provider alert while nobody follows them (archived flights, or
//   an unfollow whose provider delete failed) go through releaseAlert, which deletes at the
//   provider first and clears alert_id only on success. Bounded to ALERT_BATCH flights a run.
// prune: prune_maintenance() deletes expired rate events, route cache, unviewed snapshots, old
//   processed webhook rows and old events of unfollowed flights, each bounded to PRUNE_BATCH rows.
// Answer: { ok, mode, checked, released, kept } or { ok, mode, pruned: { <table>: count } }.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { isServiceCaller } from "../_shared/auth.ts";
import { ApiError, errorResponse, json } from "../_shared/errors.ts";
import { type AlertApi, releaseAlert } from "../_shared/follow.ts";

export const ALERT_BATCH = 200;
export const PRUNE_BATCH = 5000;

export interface Deps {
  db: SupabaseClient;
  /** Built on first use, so prune runs without the AeroAPI key. */
  aero: () => AlertApi;
  /** The project's service role key, compared with the bearer token. Defaults to the env. */
  serviceKey?: () => string | undefined;
}

async function sweepAlerts(deps: Deps) {
  const { db } = deps;
  const ids = await db.rpc("orphan_alert_flights", { p_limit: ALERT_BATCH });
  if (ids.error) throw new Error(`orphan read failed: ${ids.error.message}`);
  const flights = (ids.data ?? []) as string[];
  let released = 0, kept = 0;
  if (flights.length === 0) return { checked: 0, released, kept };
  const aero = deps.aero();
  // One at a time: a run is small and the provider is rate limited.
  for (const id of flights) {
    try {
      await releaseAlert(db, aero, id);
    } catch (e) {
      console.error(`maintenance: release failed for flight ${id}`, e);
    }
    const after = await db.from("flights").select("alert_id").eq("id", id)
      .maybeSingle();
    if (!after.error && (after.data === null || after.data.alert_id === null)) {
      released++;
    } else kept++;
  }
  if (kept > 0) console.error(`maintenance: ${kept} alert(s) kept for retry`);
  return { checked: flights.length, released, kept };
}

export async function handler(req: Request, deps: Deps): Promise<Response> {
  try {
    if (req.method !== "POST") {
      throw new ApiError("invalid_request", 405, "Use POST");
    }
    const key = (deps.serviceKey ?? (() =>
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")))();
    if (!(await isServiceCaller(req, key))) {
      throw new ApiError("unauthorized", 401, "Service role only");
    }
    const mode = new URL(req.url).searchParams.get("mode");
    if (mode === "alerts") {
      return json({ ok: true, mode, ...(await sweepAlerts(deps)) });
    }
    if (mode === "prune") {
      const r = await deps.db.rpc("prune_maintenance", {
        p_batch: PRUNE_BATCH,
      });
      if (r.error) throw new Error(`prune failed: ${r.error.message}`);
      return json({ ok: true, mode, pruned: r.data });
    }
    throw new ApiError("invalid_request", 400, "mode must be alerts or prune");
  } catch (e) {
    return errorResponse(e);
  }
}
