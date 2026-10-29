// Typed wrapper over the flightcore WASM package (core/flightcore-wasm).
// Rebuild the package with core/scripts/build-wasm.sh. Shapes mirror the serde JSON.
import * as wasm from "./flightcore/pkg/flightcore_wasm.js";

export interface Coord {
  lat: number;
  lon: number;
}

export type FlightStatus =
  | "scheduled"
  | "departed"
  | "en_route"
  | "landed"
  | "arrived"
  | "canceled"
  | "diverted"
  | "unknown";

/** One row of an airport board. Input keys are snake_case. */
export interface BoardFlight {
  ident: string;
  operator: string | null;
  /** Destination for departures, origin for arrivals. */
  other_icao: string;
  status: FlightStatus;
  /** Unix seconds. */
  scheduled: number | null;
  estimated: number | null;
  actual: number | null;
}

export interface HourBucket {
  hour: number;
  onTime: number;
  late15: number;
  late45: number;
  canceled: number;
  diverted: number;
}

export interface RouteStat {
  icao: string;
  delayed: number;
  canceled: number;
}

export interface AirlineStat {
  operator: string;
  delayed: number;
  canceled: number;
}

export type Severity = "normal" | "moderate" | "major";

export interface DelayStats {
  total: number;
  onTime: number;
  delayed15: number;
  canceled: number;
  avgDelayMinutes: number;
  perHour: HourBucket[];
  worstRoutes: RouteStat[];
  worstAirlines: AirlineStat[];
  severity: Severity;
}

export type FlightCategory = "VFR" | "MVFR" | "IFR" | "LIFR";

export type PastFlightStatus = "completed" | "canceled" | "diverted";

/** A member's past flight. Input keys are snake_case. */
export interface PastFlight {
  /** Unix seconds. */
  departed_at: number;
  /** IANA zone of the departure airport; unknown values fall back to UTC. */
  tz: string;
  ident: string;
  origin_icao: string;
  destination_icao: string;
  airline: string | null;
  aircraft_type: string | null;
  distance_km: number;
  block_minutes: number | null;
  delay_minutes: number;
  status: PastFlightStatus;
}

export interface AircraftCount {
  aircraftType: string;
  count: number;
}

export interface PassportStats {
  flights: number;
  longHaul: number;
  distanceKm: number;
  flightMinutes: number;
  airports: number;
  airlines: number;
  delayLostMinutes: number;
  avgDelayMinutes: number;
  mostFlownAircraft: AircraftCount | null;
  routes: [string, string][];
}

const MAX_SEGMENTS = 100_000;
const I32_MIN = -2_147_483_648;
const I32_MAX = 2_147_483_647;

function isI32(n: number): boolean {
  return Number.isInteger(n) && n >= I32_MIN && n <= I32_MAX;
}

function fail(e: unknown): never {
  throw new Error(e instanceof Error ? e.message : String(e));
}

/** Parse a wasm JSON reply; `{"error":"..."}` becomes a thrown Error. */
function unwrap<T>(json: string): T {
  const v = JSON.parse(json);
  if (
    v !== null && typeof v === "object" && !Array.isArray(v) &&
    typeof v.error === "string"
  ) {
    throw new Error(v.error);
  }
  return v as T;
}

function stringify(v: unknown, what: string): string {
  const s = JSON.stringify(v);
  if (s === undefined) throw new Error(`invalid ${what}: not serializable`);
  return s;
}

export function distanceKm(a: Coord, b: Coord): number {
  try {
    return wasm.distanceKm(stringify(a, "coord a"), stringify(b, "coord b"));
  } catch (e) {
    fail(e);
  }
}

export function greatCircle(a: Coord, b: Coord, segments: number): Coord[] {
  if (!Number.isInteger(segments) || segments < 0 || segments > MAX_SEGMENTS) {
    throw new Error(
      `invalid segments: ${segments} (integer 0..${MAX_SEGMENTS})`,
    );
  }
  return unwrap<Coord[]>(
    wasm.greatCircle(
      stringify(a, "coord a"),
      stringify(b, "coord b"),
      segments,
    ),
  );
}

export function computeStats(rows: BoardFlight[]): DelayStats {
  return unwrap<DelayStats>(wasm.computeStats(stringify(rows, "rows")));
}

export function flightCategory(
  ceilingFt: number | null,
  visibilitySm: number,
): FlightCategory {
  if (ceilingFt !== null && !isI32(ceilingFt)) {
    throw new Error(`invalid ceilingFt: ${ceilingFt} (i32 integer or null)`);
  }
  if (!Number.isFinite(visibilitySm)) {
    throw new Error(`invalid visibilitySm: ${visibilitySm} (finite number)`);
  }
  return unwrap<FlightCategory>(wasm.flightCategory(ceilingFt, visibilitySm));
}

export function computePassport(
  flights: PastFlight[],
  year?: number,
): PassportStats {
  if (year !== undefined && !isI32(year)) {
    throw new Error(`invalid year: ${year} (i32 integer)`);
  }
  return unwrap<PassportStats>(
    wasm.computePassport(stringify(flights, "flights"), year),
  );
}
