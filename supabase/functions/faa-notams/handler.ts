// GET /faa-notams?airport=SFO -> { airport, iata, configured, stale, fetched_at, notams }
// The NOTAMs of an airport that a passenger can feel (closed runways, taxiways or airport, an ILS out
// of service, construction, unlit obstacles), decoded into plain English with the published text kept,
// most felt first. For the Operations Report and the flight sheet's Good to Know ("2 runway closures").
// docs/api-contract.md.
//
// Source: the FAA NOTAM API (_shared/notam.ts). It needs a client id and secret from the owner's FAA
// developer account. Without them in the function's env, the answer is configured: false with no
// notams, and the app hides the section; the API is never called.
//
// Answers are cached whole per airport in faa_notam_cache for CACHE_TTL_MS. When the API fails, a
// cached answer up to STALE_MAX_MS old is served with stale: true; older, 503 provider_unavailable.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { resolveAirport } from "../_shared/airports.ts";
import { requireUser, type TokenVerifier } from "../_shared/auth.ts";
import { ApiError, errorResponse, json } from "../_shared/errors.ts";
import { checkRate } from "../_shared/limits.ts";
import {
  credentialsFromEnv,
  fetchNotams,
  type Notam,
  type NotamCredentials,
} from "../_shared/notam.ts";

export const CACHE_TTL_MS = 15 * 60_000;
export const STALE_MAX_MS = 6 * 3600_000;
export const NOTAMS_MAX_PER_HOUR = 120;

export interface Deps {
  db: SupabaseClient;
  verifier?: TokenVerifier;
  now?: () => Date;
  fetchFn?: typeof fetch;
  /** The API key; credentialsFromEnv() otherwise. Undefined means not configured. */
  credentials?: () => NotamCredentials | undefined;
}

export interface Answer {
  airport: string;
  iata: string | null;
  /** False when the FAA key is not set: no notams, and the app shows no NOTAM section. */
  configured: boolean;
  stale: boolean;
  fetched_at: string;
  /** Most felt first (Notam.relevance). */
  notams: Notam[];
}

export async function handler(req: Request, deps: Deps): Promise<Response> {
  try {
    if (req.method !== "GET") {
      throw new ApiError("invalid_request", 405, "GET only");
    }
    const { userId } = await requireUser(req, deps.verifier);
    const { db } = deps;
    const now = (deps.now ?? (() => new Date()))();
    await checkRate(userId, "faa-notams", NOTAMS_MAX_PER_HOUR, 60, db);
    const icao = await resolveAirport(
      db,
      new URL(req.url).searchParams.get("airport"),
    );
    const row = await db.from("airports").select("iata").eq("icao", icao)
      .single();
    if (row.error) throw new Error(`airport read failed: ${row.error.message}`);
    const base = {
      airport: icao,
      iata: (row.data.iata as string | null) ?? null,
    };

    const creds = (deps.credentials ?? (() => credentialsFromEnv()))();
    if (!creds) {
      return json(
        {
          ...base,
          configured: false,
          stale: false,
          fetched_at: now.toISOString(),
          notams: [],
        } satisfies Answer,
      );
    }

    const hit = await db.from("faa_notam_cache").select("payload, fetched_at")
      .eq("airport_icao", icao).maybeSingle();
    if (hit.error) {
      throw new Error(`faa_notam_cache read failed: ${hit.error.message}`);
    }
    const age = hit.data
      ? now.getTime() - Date.parse(hit.data.fetched_at)
      : Infinity;
    if (age < CACHE_TTL_MS) return json(hit.data!.payload as Answer);

    try {
      const notams = await fetchNotams(creds, icao, deps.fetchFn ?? fetch, now);
      const answer: Answer = {
        ...base,
        configured: true,
        stale: false,
        fetched_at: now.toISOString(),
        notams,
      };
      const { error } = await db.from("faa_notam_cache").upsert({
        airport_icao: icao,
        payload: answer,
        fetched_at: answer.fetched_at,
      });
      if (error) console.error("faa_notam_cache write failed", error.message);
      return json(answer);
    } catch (e) {
      // Never the key in a log line: only the status the API gave.
      console.error(
        `faa-notams: NOTAM API failed for ${icao}`,
        e instanceof Error ? e.message : e,
      );
      if (age < STALE_MAX_MS) {
        return json({ ...(hit.data!.payload as Answer), stale: true });
      }
      throw new ApiError(
        "provider_unavailable",
        503,
        "The FAA NOTAM service is not answering",
      );
    }
  } catch (e) {
    return errorResponse(e);
  }
}
