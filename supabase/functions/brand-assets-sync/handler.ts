// POST /brand-assets-sync?mode=logos&limit=50[&icao=UAL,AFR]. Service role only: pg_cron calls it hourly through
// pg_net. Pulls logos and brand colours from the licensed provider into the private brand-assets
// bucket (see _shared/brand/sync.ts). With no provider configured (the state until the licence is
// signed) the call is a logged no-op: { ok: true, skipped: "provider not configured" }.
// Answer: { ok, mode, checked, changed, added, failed }.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { isServiceCaller } from "../_shared/auth.ts";
import { ApiError, errorResponse, json } from "../_shared/errors.ts";
import type { LogoProvider } from "../_shared/brand/logo_provider.ts";
import { ProviderUnavailable } from "../_shared/brand/logo_provider.ts";
import { syncLogos } from "../_shared/brand/sync.ts";

export const DEFAULT_LIMIT = 50;
export const MAX_LIMIT = 200;

export interface Deps {
  db: SupabaseClient;
  /** null when no provider is configured. Built per call so the key is read only when used. */
  provider: () => LogoProvider | null;
  serviceKey?: () => string | undefined;
  now?: () => Date;
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
    if (mode !== "logos") {
      throw new ApiError("invalid_request", 400, "mode must be logos");
    }
    const raw = q.get("limit");
    const limit = raw === null ? DEFAULT_LIMIT : Number(raw);
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
    const provider = deps.provider();
    if (!provider) {
      console.log("brand-assets-sync: provider not configured, skipping");
      return json({ ok: true, mode, skipped: "provider not configured" });
    }
    try {
      const report = await syncLogos(deps.db, deps.db.storage, provider, {
        limit,
        icaos,
        now: (deps.now ?? (() => new Date()))(),
      });
      return json({ ok: true, mode, ...report });
    } catch (e) {
      if (e instanceof ProviderUnavailable) {
        throw new ApiError("provider_unavailable", 502, e.message);
      }
      throw e;
    }
  } catch (e) {
    return errorResponse(e);
  }
}
