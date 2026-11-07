// The live wiring of the airport conditions summary (_shared/conditions.ts): the METAR and TAF from
// aviationweather.gov (kept per airport in the isolate for 10 minutes) and the notices from the shared
// faa_notam_cache table (the same rows faa-notams fills and reads). Any source that fails is simply not
// read: the summary says so in `sources`, and one failing source never fails the answer.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { type Conditions, inferConditions } from "../_shared/conditions.ts";
import {
  credentialsFromEnv,
  fetchNotams,
  type Notam,
  type NotamCredentials,
} from "../_shared/notam.ts";
import { fetchWeather, type Weather } from "../_shared/weather.ts";

export const WEATHER_TTL_MS = 10 * 60_000;
/** Same as faa-notams: a notice read stays fresh 15 minutes and is usable stale up to 6 hours. */
export const NOTAM_TTL_MS = 15 * 60_000;
export const NOTAM_STALE_MAX_MS = 6 * 3600_000;

export type ConditionsFor = (
  icao: string,
  now: Date,
) => Promise<Conditions | null>;

export interface LiveOptions {
  fetchFn?: typeof fetch;
  credentials?: () => NotamCredentials | undefined;
}

export function liveConditions(
  db: SupabaseClient,
  opts: LiveOptions = {},
): ConditionsFor {
  const kept = new Map<string, { at: number; value: Weather | null }>();

  async function weatherOf(icao: string, now: Date): Promise<Weather | null> {
    const hit = kept.get(icao);
    if (hit && now.getTime() - hit.at < WEATHER_TTL_MS) return hit.value;
    try {
      const value = await fetchWeather(icao, opts.fetchFn ?? fetch);
      kept.set(icao, { at: now.getTime(), value });
      if (kept.size > 2000) kept.delete(kept.keys().next().value as string);
      return value;
    } catch (e) {
      console.error(
        `faa-status: weather read failed for ${icao}`,
        e instanceof Error ? e.message : e,
      );
      return null;
    }
  }

  async function notamsOf(icao: string, now: Date): Promise<Notam[] | null> {
    const creds = (opts.credentials ?? (() => credentialsFromEnv()))();
    if (!creds) return null;
    try {
      const hit = await db.from("faa_notam_cache").select("payload, fetched_at")
        .eq("airport_icao", icao).maybeSingle();
      if (hit.error) throw new Error(hit.error.message);
      const age = hit.data
        ? now.getTime() - Date.parse(hit.data.fetched_at)
        : Infinity;
      const cached =
        () => ((hit.data!.payload as { notams?: Notam[] }).notams ?? []);
      if (age < NOTAM_TTL_MS) return cached();
      try {
        const notams = await fetchNotams(
          creds,
          icao,
          opts.fetchFn ?? fetch,
          now,
        );
        const row = await db.from("airports").select("iata").eq("icao", icao)
          .maybeSingle();
        const { error } = await db.from("faa_notam_cache").upsert({
          airport_icao: icao,
          payload: {
            airport: icao,
            iata: (row.data?.iata as string | null | undefined) ?? null,
            configured: true,
            stale: false,
            fetched_at: now.toISOString(),
            notams,
          },
          fetched_at: now.toISOString(),
        });
        if (error) console.error("faa_notam_cache write failed", error.message);
        return notams;
      } catch (e) {
        console.error(
          `faa-status: NOTAM read failed for ${icao}`,
          e instanceof Error ? e.message : e,
        );
        return age < NOTAM_STALE_MAX_MS ? cached() : null;
      }
    } catch (e) {
      console.error(
        `faa-status: NOTAM cache failed for ${icao}`,
        e instanceof Error ? e.message : e,
      );
      return null;
    }
  }

  return async (icao, now) => {
    const [weather, notams] = await Promise.all([
      weatherOf(icao, now),
      notamsOf(icao, now),
    ]);
    // Nothing read at all is not "all clear": there is no summary to give.
    if (weather === null && notams === null) return null;
    return inferConditions({ weather, notams, now });
  };
}
