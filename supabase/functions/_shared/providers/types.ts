// The provider layer: one interface per capability, so a function asks for "flight status" or "a
// live position" and the secrets decide who answers (select.ts). Every adapter maps its answer into
// the `flights` row shape that toFlightRow (aeroapi.ts) produces; a field the provider does not give
// stays null, never guessed. docs/free-providers.md compares the sources.
import type { FlightRow, PositionRow } from "../aeroapi_types.ts";

export type { FlightRow, PositionRow };

/** The names a selection secret takes (STATUS_PROVIDER, POSITION_PROVIDER, BOARD_PROVIDER). */
export type ProviderName =
  | "aeroapi"
  | "aviationstack"
  | "flightlabs"
  | "opensky"
  | "none";

export const PROVIDER_NAMES: readonly ProviderName[] = [
  "aeroapi",
  "aviationstack",
  "flightlabs",
  "opensky",
  "none",
];

/**
 * A provider flight as a `flights` row, plus the origin's IANA timezone when the provider says it
 * (flight-lookup filters on origin-local dates). `origin_tz` is not a column: strip it before an
 * upsert (rowOf).
 */
export interface ProviderFlight extends FlightRow {
  origin_tz?: string | null;
}

/** The FlightRow part of a ProviderFlight, for upsert_provider_flights. */
export function rowOf(f: ProviderFlight): FlightRow {
  const { origin_tz: _tz, ...row } = f;
  return row;
}

/**
 * A stored flight the poller asks about again. `provider_id` is the stored id, which may come
 * from another provider (the row was looked up before a switch): adapters match on ident, origin
 * and departure time, never on that id alone.
 */
export interface FlightRef {
  provider_id: string;
  ident: string;
  operator: string | null;
  origin_icao: string | null;
  origin_iata: string | null;
  destination_icao: string | null;
  scheduled_out: string | null;
}

/** Flight status by ident and date, and route search. */
export interface StatusProvider {
  readonly name: ProviderName;
  /**
   * Flights with this ident (IATA "AF84" or ICAO "AFR84") whose scheduled departure falls in
   * [from, to). A provider that only knows today's flights returns those; the caller filters.
   */
  flightsByIdent(
    ident: string,
    from: Date,
    to: Date,
  ): Promise<ProviderFlight[]>;
  /** Nonstop flights origin to destination (ICAO) scheduled to leave in [start, end). */
  searchRouteWindow(
    origin: string,
    destination: string,
    start: Date,
    end: Date,
  ): Promise<ProviderFlight[]>;
  /**
   * The current state of one stored flight, for the polling refresh. Null when the provider no
   * longer lists it. Costs one request on every free provider.
   */
  flightStatus(ref: FlightRef): Promise<ProviderFlight | null>;
}

/** One airport's board: flights done in the last hours and the next ones. */
export interface BoardProvider {
  readonly name: ProviderName;
  boardFlights(
    icao: string,
    kind: "departures" | "arrivals",
  ): Promise<ProviderFlight[]>;
}

/** What a position provider can be asked with. Each adapter uses what it understands. */
export interface PositionQuery {
  /** The stored flight's provider id (AeroAPI fa_flight_id). */
  provider_id: string;
  /** ATC callsign, normally the ICAO ident (AFR84). */
  callsign: string | null;
  /** ICAO 24-bit address, lowercase hex, when known. */
  icao24?: string | null;
  /** Where to look when neither id is enough (OpenSky): last position, else the origin. */
  near?: { lat: number; lon: number } | null;
}

export interface PositionProvider {
  readonly name: ProviderName;
  position(q: PositionQuery): Promise<PositionRow | null>;
}

/** An airframe, as far as the provider knows it. Missing parts stay null. */
export interface AircraftInfo {
  icao24: string | null;
  registration: string | null;
  aircraft_type: string | null;
  /** Airline ICAO code, or the provider's country of registration for OpenSky. */
  operator: string | null;
  country: string | null;
}

/** Aircraft registration lookup by registration, ICAO24 address or callsign. */
export interface AircraftProvider {
  readonly name: ProviderName;
  aircraft(q: {
    registration?: string | null;
    icao24?: string | null;
    callsign?: string | null;
    near?: { lat: number; lon: number } | null;
  }): Promise<AircraftInfo | null>;
}
