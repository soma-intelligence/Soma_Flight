import { ApiError, callFunction } from "./api";
import { getSupabase } from "./client";
import { useFakes } from "./flights";

export const favoritesKey = ["favoriteAirports"] as const;
export const airportWeatherKey = (codes: string) => ["airportWeather", codes] as const;
export const faaStatusKey = (code: string) => ["faaStatus", code] as const;

/** Large airports across the world, the list's base after the favourites (AirportsListStore.hubs). */
export const HUBS: readonly string[] = [
  "KATL", "KLAX", "KORD", "KDFW", "KDEN", "KJFK", "KSFO", "KSEA", "KLAS", "KMCO", "KEWR", "KMIA", "KBOS",
  "KPHX", "KIAH", "CYYZ", "CYVR",
  "EGLL", "LFPG", "EHAM", "EDDF", "LEMD", "LIRF", "LSZH", "EIDW", "LTFM",
  "RJTT", "RKSI", "VHHH", "WSSS", "ZBAA", "VTBS", "VIDP",
  "OMDB", "OTHH",
  "MMMX", "SBGR", "SCEL", "SKBO",
  "YSSY", "NZAA", "FAOR", "HECA",
];

/** The list's codes: favourites first, then the hubs, each once, only those `known` to the directory. */
export function airportList(favorites: readonly string[], known: (icao: string) => boolean, hubs: readonly string[] = HUBS): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const raw of [...favorites, ...hubs]) {
    const c = raw.toUpperCase();
    if (!known(c) || seen.has(c)) continue;
    seen.add(c);
    out.push(c);
  }
  return out;
}

/** The countries whose airports the FAA status feed covers (FavoriteAirportAlertsStore.coveredCountries). */
const FAA_COUNTRIES = new Set(["US", "PR", "GU", "VI", "AS", "MP"]);
export const isFaaCovered = (country: string) => FAA_COUNTRIES.has(country.toUpperCase());

type PgError = { code?: string; message?: string };
function pgError(e: PgError): ApiError {
  if (e.code === "PGRST301" || e.code === "PGRST302") return new ApiError("unauthorized", 401, e.message);
  return new ApiError("provider_unavailable", 500, e.message);
}

/** The signed-in user's favourite airports (ICAO), oldest first. */
export async function fetchFavorites(): Promise<string[]> {
  if (useFakes() && import.meta.env.DEV) {
    const { fakeFavorites } = await import("@/fakes");
    return fakeFavorites();
  }
  const { data, error } = await getSupabase().from("favorite_airports").select("airport_icao").order("created_at");
  if (error) throw pgError(error);
  return (data ?? []).map((r) => String((r as { airport_icao: unknown }).airport_icao).toUpperCase());
}

/** Stars or unstars an airport. In fakes mode it only changes local state. */
export async function setFavorite(icao: string, on: boolean): Promise<void> {
  const code = icao.toUpperCase();
  if (useFakes() && import.meta.env.DEV) {
    const { setFakeFavorite } = await import("@/fakes");
    setFakeFavorite(code, on);
    return;
  }
  const sb = getSupabase();
  const { data } = await sb.auth.getSession();
  const uid = data.session?.user.id;
  if (!uid) throw new ApiError("unauthorized", 401);
  const { error } = on
    ? await sb.from("favorite_airports").insert({ user_id: uid, airport_icao: code })
    : await sb.from("favorite_airports").delete().eq("user_id", uid).eq("airport_icao", code);
  if (error) throw pgError(error);
}

export type AirportConditions = {
  category: string | null;
  ceilingFt: number | null;
  visibilitySm: number | null;
  windDirDeg: number | null;
  windKt: number | null;
  gustKt: number | null;
  tempC: number | null;
  wx: string | null;
  condition: string;
  summary: string;
  observedAt: Date | null;
  stale: boolean;
};
export type AirportWeather = { icao: string; iata: string | null; weather: AirportConditions | null };

const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);
const str = (v: unknown): string | null => (typeof v === "string" && v !== "" ? v : null);
const date = (v: unknown): Date | null => {
  const s = str(v);
  if (!s) return null;
  const d = new Date(s);
  return Number.isNaN(d.getTime()) ? null : d;
};
const rec = (v: unknown): Record<string, unknown> | null => (typeof v === "object" && v !== null ? (v as Record<string, unknown>) : null);

function decodeConditions(v: unknown): AirportConditions | null {
  const w = rec(v);
  if (!w) return null;
  return {
    category: str(w.category),
    ceilingFt: num(w.ceiling_ft),
    visibilitySm: num(w.visibility_sm),
    windDirDeg: num(w.wind_dir_deg),
    windKt: num(w.wind_kt),
    gustKt: num(w.gust_kt),
    tempC: num(w.temp_c),
    wx: str(w.wx),
    condition: str(w.condition) ?? "",
    summary: str(w.summary) ?? "",
    observedAt: date(w.observed_at),
    stale: w.stale === true,
  };
}

const BATCH = 40;

/** METARs in plain words for `codes` (one call per 40). A failed METAR leaves `weather` null. */
export async function fetchAirportWeather(codes: readonly string[]): Promise<AirportWeather[]> {
  if (useFakes() && import.meta.env.DEV) {
    const { fakeWeather } = await import("@/fakes");
    return fakeWeather(codes);
  }
  const out: AirportWeather[] = [];
  for (let i = 0; i < codes.length; i += BATCH) {
    const body = await callFunction<{ airports?: unknown[] }>("airport-weather", {
      method: "GET",
      query: { airports: codes.slice(i, i + BATCH).join(",") },
    });
    for (const a of body.airports ?? []) {
      const r = rec(a);
      const icao = r && str(r.icao);
      if (!r || !icao) continue;
      out.push({ icao: icao.toUpperCase(), iata: str(r.iata), weather: decodeConditions(r.weather) });
    }
  }
  return out;
}

export const FAA_KINDS = ["closure", "ground_stop", "ground_delay", "departure_delay", "arrival_delay", "deicing"] as const;
export type FaaKind = (typeof FAA_KINDS)[number];
export type FaaProgram = {
  kind: FaaKind;
  reason: string | null;
  averageMinutes: number | null;
  trend: string | null;
  startsAt: Date | null;
  endsAt: Date | null;
};
export type FaaStatus = { available: boolean; programs: FaaProgram[] };

/** The FAA's programs at a US airport. A kind the app does not know is dropped. */
export async function fetchFaaStatus(code: string): Promise<FaaStatus> {
  if (useFakes() && import.meta.env.DEV) {
    const { fakeFaa } = await import("@/fakes");
    return fakeFaa(code);
  }
  const body = await callFunction<Record<string, unknown>>("faa-status", { method: "GET", query: { airport: code } });
  const programs: FaaProgram[] = [];
  for (const p of Array.isArray(body.programs) ? body.programs : []) {
    const r = rec(p);
    if (!r || !(FAA_KINDS as readonly unknown[]).includes(r.kind)) continue;
    programs.push({
      kind: r.kind as FaaKind,
      reason: str(r.reason),
      averageMinutes: num(r.average_minutes),
      trend: str(r.trend),
      startsAt: date(r.starts_at),
      endsAt: date(r.ends_at),
    });
  }
  return { available: body.available === true, programs };
}
