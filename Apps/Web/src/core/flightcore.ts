import init, * as pkg from "./pkg/flightcore_wasm.js";

export type LatLon = { lat: number; lon: number };

type Source = Parameters<typeof init>[0];

let loading: Promise<void> | null = null;

/**
 * Loads the wasm once; later calls share the first load. In the browser the
 * package fetches its own .wasm. Tests pass the bytes in because Node cannot
 * fetch a file URL.
 */
export function initCore(source?: BufferSource): Promise<void> {
  loading ??= init(source as Source).then(
    () => undefined,
    (e: unknown) => {
      loading = null; // allow a retry after a failed load
      throw e;
    },
  );
  return loading;
}

/** Throws a JS Error when the core rejects its input. */
function parsed<T>(json: string): T {
  const v = JSON.parse(json) as T | { error: string };
  if (v && typeof v === "object" && "error" in v && typeof v.error === "string") {
    throw new Error(v.error);
  }
  return v as T;
}

export function distanceKm(a: LatLon, b: LatLon): number {
  return pkg.distanceKm(JSON.stringify(a), JSON.stringify(b));
}

export function greatCircle(a: LatLon, b: LatLon, segments: number): LatLon[] {
  return parsed<LatLon[]>(pkg.greatCircle(JSON.stringify(a), JSON.stringify(b), segments));
}

export type FlightCategory = "VFR" | "MVFR" | "IFR" | "LIFR";

/** The FAA flight category of a ceiling (feet, null when none) and a visibility (statute miles). */
export function flightCategory(ceilingFt: number | null, visibilitySm: number): FlightCategory {
  return parsed<FlightCategory>(pkg.flightCategory(ceilingFt, visibilitySm));
}

/** A past flight as the core reads it (`PastFlight` in core/flightcore/src/passport.rs, snake_case). */
export type CorePastFlight = {
  /** Departure instant, unix seconds. */
  departed_at: number;
  /** IANA zone of the departure airport; unknown values fall back to UTC. */
  tz: string;
  ident: string;
  origin_icao: string;
  destination_icao: string;
  airline?: string | null;
  aircraft_type?: string | null;
  distance_km: number;
  block_minutes?: number | null;
  delay_minutes: number;
  status: "completed" | "canceled" | "diverted";
  origin_country?: string | null;
  destination_country?: string | null;
  air_minutes?: number | null;
  registration?: string | null;
  seat_class?: string | null;
  seat?: string | null;
  reason?: string | null;
  seat_position?: string | null;
};

export type PassportStats = {
  flights: number;
  longHaul: number;
  distanceKm: number;
  flightMinutes: number;
  airports: number;
  airlines: number;
  delayLostMinutes: number;
  avgDelayMinutes: number;
  delayedFlights: number;
  avgDelayedMinutes: number;
  mostFlownAircraft: { aircraftType: string; count: number } | null;
  routes: [string, string][];
};

/** Passport totals over `rows`, all time or one local departure `year` (compute_passport_js). */
export function computePassport(rows: CorePastFlight[], year?: number | null): PassportStats {
  return parsed<PassportStats>(pkg.computePassport(JSON.stringify(rows), year ?? undefined));
}

export type CountryRegion =
  | "europe"
  | "north_america"
  | "central_america"
  | "caribbean"
  | "south_america"
  | "africa"
  | "middle_east"
  | "asia"
  | "oceania";

/** A reference country: its ISO 3166-1 alpha-2 code and region (the regions only count visits per region). */
export type CountryInfo = { iso2: string; region: CountryRegion };

/** The detail the core builds; the web reads the visited countries, the rest keeps the core's camelCase shape. */
export type PassportDetail = {
  flights: number;
  countries: { iso2: string; flights: number }[];
  unknownCountryFlights: number;
  [key: string]: unknown;
};

/** The full passport detail (compute_passport_detail_js): `countries` is the reference list for the per-region counts. */
export function computePassportDetail(
  rows: CorePastFlight[],
  year?: number | null,
  countries: CountryInfo[] = [],
): PassportDetail {
  return parsed<PassportDetail>(pkg.computePassportDetail(JSON.stringify(rows), year ?? undefined, JSON.stringify(countries)));
}
