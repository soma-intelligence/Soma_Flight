// GET /brand-asset?airline=<ICAO>&kind=logo|logo_dark|wordmark|tail|side_view[&type=<ICAO type>]
//   -> { version, format, width, url, smallUrl, expiresAt }
// Reads airline_assets and signs the object in the private brand-assets bucket for 3600 s. The app
// only ever sees our bucket; the provider licence key stays with the sync job. No row is 404
// not_found (the app falls back to its own mark). `type` is required for side_view and refused for
// every other kind. 600 calls per user per hour.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { requireUser, type TokenVerifier } from "../_shared/auth.ts";
import { ApiError, errorResponse, json } from "../_shared/errors.ts";
import { checkRate } from "../_shared/limits.ts";

export const BRAND_ASSET_MAX_PER_HOUR = 600;
export const SIGNED_URL_SECONDS = 3600;
const BUCKET = "brand-assets";
const KINDS = new Set([
  "logo",
  "logo_dark",
  "wordmark",
  "tail",
  "side_view",
]);
const ICAO_AIRLINE = /^[A-Z]{3}$/;
const ICAO_TYPE = /^[A-Z0-9]{2,4}$/;

export interface Deps {
  db: SupabaseClient;
  verifier?: TokenVerifier;
  now?: () => Date;
}

export async function handler(req: Request, deps: Deps): Promise<Response> {
  try {
    if (req.method !== "GET") {
      throw new ApiError("invalid_request", 405, "GET only");
    }
    const { userId } = await requireUser(req, deps.verifier);
    const { db } = deps;
    await checkRate(userId, "brand-asset", BRAND_ASSET_MAX_PER_HOUR, 60, db);

    const q = new URL(req.url).searchParams;
    const airline = (q.get("airline") ?? "").toUpperCase();
    const kind = q.get("kind") ?? "";
    const rawType = q.get("type");
    if (!ICAO_AIRLINE.test(airline)) {
      throw new ApiError(
        "invalid_request",
        400,
        "airline must be an ICAO code",
      );
    }
    if (!KINDS.has(kind)) {
      throw new ApiError("invalid_request", 400, "Unknown kind");
    }
    let aircraftType = "";
    if (kind === "side_view") {
      aircraftType = (rawType ?? "").toUpperCase();
      if (!ICAO_TYPE.test(aircraftType)) {
        throw new ApiError(
          "invalid_request",
          400,
          "side_view needs an ICAO type",
        );
      }
    } else if (rawType !== null) {
      throw new ApiError("invalid_request", 400, "type is only for side_view");
    }

    const known = await db.from("airlines").select("icao").eq("icao", airline)
      .maybeSingle();
    if (known.error) {
      throw new Error(`airline read failed: ${known.error.message}`);
    }
    if (!known.data) throw new ApiError("not_found", 404, "Unknown airline");

    const got = await db.from("airline_assets")
      .select("path, path_small, format, width, version")
      .eq("icao", airline).eq("kind", kind).eq("aircraft_type", aircraftType)
      .maybeSingle();
    if (got.error) throw new Error(`asset read failed: ${got.error.message}`);
    if (!got.data) throw new ApiError("not_found", 404, "No asset");

    const signed = await db.storage.from(BUCKET).createSignedUrl(
      got.data.path,
      SIGNED_URL_SECONDS,
    );
    if (signed.error || !signed.data) {
      // The row points at an object that is gone: same answer as no asset, the app falls back.
      console.error(
        `brand asset unsigned: ${got.data.path}`,
        signed.error?.message,
      );
      throw new ApiError("not_found", 404, "No asset");
    }
    // The 192 px rendition of a rendered vector, when there is one; a failure to sign it is not an error.
    let smallUrl: string | null = null;
    if (got.data.path_small) {
      const small = await db.storage.from(BUCKET).createSignedUrl(
        got.data.path_small,
        SIGNED_URL_SECONDS,
      );
      smallUrl = small.data?.signedUrl ?? null;
    }
    const now = (deps.now ?? (() => new Date()))();
    return json({
      version: got.data.version,
      format: got.data.format,
      width: got.data.width,
      url: signed.data.signedUrl,
      smallUrl,
      expiresAt: new Date(now.getTime() + SIGNED_URL_SECONDS * 1000)
        .toISOString(),
    });
  } catch (e) {
    return errorResponse(e);
  }
}
