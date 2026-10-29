// POST /brand-assets-sync?mode=logos|side_views&limit=50[&icao=UAL,AFR]. Service role only: pg_cron calls it hourly through
// pg_net (logos at minute 17, side views at minute 41). Pulls logos and brand colours from the licensed provider into the private brand-assets
// bucket (see _shared/brand/sync.ts). With no provider configured (the state until the licence is
// signed) the call is a logged no-op: { ok: true, skipped: "provider not configured" }.
// Answer: { ok, mode, checked, changed, added, failed, unchanged, missed, skipped, rejected, dropped,
// deferred, requests, ms, stoppedBy }. stoppedBy is done, deadline (100 s), budget (400 provider
// requests) or provider_unavailable (retried with backoff first; answered 502 with ok false).
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { isServiceCaller } from "../_shared/auth.ts";
import { ApiError, errorResponse, json } from "../_shared/errors.ts";
import type { LogoProvider } from "../_shared/brand/logo_provider.ts";
import type { SideViewProvider } from "../_shared/brand/side_view_provider.ts";
import {
  syncLogos,
  type SyncOpts,
  syncSideViews,
} from "../_shared/brand/sync.ts";

export const DEFAULT_LIMIT = 50;
export const MAX_LIMIT = 200;
/** Side view runs fetch more files per tick: the catalogue is large and each pair is fetched once. */
export const DEFAULT_SIDE_VIEW_LIMIT = 100;

export interface Deps {
  db: SupabaseClient;
  /** null when no provider is configured. Built per call so the key is read only when used. */
  provider: () => LogoProvider | null;
  /** null when no side view provider is configured (SIDE_VIEW_PROVIDER unset). */
  sideViewProvider?: () => SideViewProvider | null;
  serviceKey?: () => string | undefined;
  now?: () => Date;
  /** Time and request budget, sleep and clock overrides (tests). */
  budget?: Pick<SyncOpts, "budgetMs" | "maxRequests" | "clock" | "sleep">;
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
    const q = new URL(req.url).searchParams;
    const mode = q.get("mode");
    if (mode !== "logos" && mode !== "side_views") {
      throw new ApiError(
        "invalid_request",
        400,
        "mode must be logos or side_views",
      );
    }
    const raw = q.get("limit");
    const limit = raw === null
      ? (mode === "logos" ? DEFAULT_LIMIT : DEFAULT_SIDE_VIEW_LIMIT)
      : Number(raw);
    if (!Number.isInteger(limit) || limit < 1 || limit > MAX_LIMIT) {
      throw new ApiError(
        "invalid_request",
        400,
        `limit must be 1 to ${MAX_LIMIT}`,
      );
    }
    // icao=UAL,AFR limits the run to those airlines (manual resync); the cron call never sets it.
    const rawIcao = q.get("icao");
    const icaos = rawIcao === null ? undefined : rawIcao.split(",");
    if (icaos && !icaos.every((c) => /^[A-Z]{3}$/.test(c))) {
      throw new ApiError("invalid_request", 400, "icao must be ICAO codes");
    }
    const opts: SyncOpts = {
      limit,
      icaos,
      now: (deps.now ?? (() => new Date()))(),
      ...deps.budget,
    };
    let report;
    if (mode === "side_views") {
      const sv = deps.sideViewProvider?.() ?? null;
      if (!sv) {
        console.log(
          "brand-assets-sync: side view provider not configured, skipping",
        );
        return json({ ok: true, mode, skipped: "provider not configured" });
      }
      report = await syncSideViews(deps.db, deps.db.storage, sv, opts);
    } else {
      const provider = deps.provider();
      if (!provider) {
        console.log("brand-assets-sync: provider not configured, skipping");
        return json({ ok: true, mode, skipped: "provider not configured" });
      }
      report = await syncLogos(deps.db, deps.db.storage, provider, opts);
    }
    // An outage is a failed tick (cron logs it, the next tick retries); the summary rides along.
    if (report.stoppedBy === "provider_unavailable") {
      return json({ ok: false, mode, ...report }, 502);
    }
    return json({ ok: true, mode, ...report });
  } catch (e) {
    return errorResponse(e);
  }
}
