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

export type SeatClass = "economy" | "premium_economy" | "business" | "first";

export type TripReason = "personal" | "business";

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
  /** ISO 3166-1 alpha-2; null, empty or absent when unknown. */
  origin_country?: string | null;
  destination_country?: string | null;
  /** Wheels up to wheels down. */
  air_minutes?: number | null;
  registration?: string | null;
  seat_class?: SeatClass | null;
  seat?: string | null;
  reason?: TripReason | null;
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
  delayedFlights: number;
  avgDelayedMinutes: number;
  mostFlownAircraft: AircraftCount | null;
  routes: [string, string][];
}

export type Region =
  | "europe"
  | "north_america"
  | "central_america"
  | "caribbean"
  | "south_america"
  | "africa"
  | "middle_east"
  | "asia"
  | "oceania";

/** One reference country. Input keys are snake_case. */
export interface CountryInfo {
  iso2: string;
  region: Region;
}

export interface YearCount {
  year: number;
  flights: number;
}

export interface FlightRef {
  ident: string;
  originIcao: string;
  destinationIcao: string;
  /** Unix seconds. */
  departedAt: number;
  distanceKm: number;
  blockMinutes: number | null;
  airline: string | null;
}

export interface AirportVisits {
  icao: string;
  visits: number;
}

export interface Tally {
  key: string;
  flights: number;
  distanceKm: number;
}

export interface CountryCount {
  iso2: string;
  flights: number;
}

export interface RegionCount {
  region: Region;
  visited: number;
  total: number;
}

export interface PassportDetail {
  flights: number;
  domestic: number;
  international: number;
  longHaul: number;
  /** All-time history, ascending, whatever the year filter. */
  perYear: YearCount[];
  /** 12 counts, January first, local departure time. */
  perMonth: number[];
  /** 7 counts, Monday first, local departure time. */
  perWeekday: number[];
  distanceKm: number;
  avgDistanceKm: number;
  earthRatio: number;
  moonRatio: number;
  sunRatio: number;
  shortestByDistance: FlightRef | null;
  longestByDistance: FlightRef | null;
  shortestByTime: FlightRef | null;
  longestByTime: FlightRef | null;
  flightMinutes: number;
  avgFlightMinutes: number;
  airMinutes: number;
  taxiMinutes: number;
  airports: AirportVisits[];
  airlinesByFlights: Tally[];
  airlinesByDistance: Tally[];
  routesByFlights: Tally[];
  routesByDistance: Tally[];
  countries: CountryCount[];
  unknownCountryFlights: number;
  /** All nine regions, in declaration order. */
  regions: RegionCount[];
}

/** One reference aircraft type. Input keys are snake_case. */
export interface TypeInfo {
  icao_type: string;
  /** Family code, "a320", "b777", ... */
  family: string;
  manufacturer: string;
}

/** What is known about one airframe. Input keys are snake_case. */
export interface AircraftFact {
  registration: string;
  /** Unix seconds. */
  delivered_at: number | null;
  name: string | null;
}

export interface Share {
  key: string;
  flights: number;
  /** Rounded half up. */
  percent: number;
}

export interface TypeTally {
  icaoType: string;
  flights: number;
  minutes: number;
  distanceKm: number;
}

export interface TailTally {
  registration: string;
  flights: number;
  icaoType: string | null;
  airline: string | null;
  name: string | null;
}

export interface SeatClassCounts {
  economy: number;
  premiumEconomy: number;
  business: number;
  first: number;
}

export interface PositionCounts {
  window: number;
  middle: number;
  aisle: number;
}

export interface SeatTally {
  seat: string;
  flights: number;
}

export interface ReasonCounts {
  personal: number;
  business: number;
}

export interface DecadeCount {
  decade: number;
  aircraft: number;
}

export interface AgedAircraft {
  registration: string;
  icaoType: string | null;
  /** Unix seconds. */
  deliveredAt: number;
  ageMonths: number;
}

export interface AircraftStats {
  totalTypes: number;
  manufacturers: Share[];
  typesByFlights: TypeTally[];
  typesByMinutes: TypeTally[];
  typesByDistance: TypeTally[];
  mostFlown: TypeTally | null;
  tails: TailTally[];
  seatClasses: SeatClassCounts;
  seatPositions: PositionCounts;
  favouriteSeat: SeatTally | null;
  reasons: ReasonCounts;
  /** Ascending, empty decades between the first and the last included. */
  decades: DecadeCount[];
  medianAgeMonths: number | null;
  newest: AgedAircraft | null;
  oldest: AgedAircraft | null;
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

export function computePassportDetail(
  flights: PastFlight[],
  year: number | undefined,
  countries: CountryInfo[],
): PassportDetail {
  if (year !== undefined && !isI32(year)) {
    throw new Error(`invalid year: ${year} (i32 integer)`);
  }
  return unwrap<PassportDetail>(
    wasm.computePassportDetail(
      stringify(flights, "flights"),
      year,
      stringify(countries, "countries"),
    ),
  );
}

/** `asOf` is unix seconds; aircraft ages are measured up to it. */
export function computeAircraftStats(
  flights: PastFlight[],
  year: number | undefined,
  types: TypeInfo[],
  facts: AircraftFact[],
  asOf: number,
): AircraftStats {
  if (year !== undefined && !isI32(year)) {
    throw new Error(`invalid year: ${year} (i32 integer)`);
  }
  if (!Number.isSafeInteger(asOf)) {
    throw new Error(`invalid asOf: ${asOf} (integer unix seconds)`);
  }
  return unwrap<AircraftStats>(
    wasm.computeAircraftStats(
      stringify(flights, "flights"),
      year,
      stringify(types, "types"),
      stringify(facts, "facts"),
      BigInt(asOf),
    ),
  );
}
