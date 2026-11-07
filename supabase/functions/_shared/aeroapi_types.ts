// FlightAware AeroAPI v4 shapes (subset we use). Field names follow the published docs.

export interface AeroAirportRef {
  code: string | null;
  code_icao: string | null;
  code_iata: string | null;
  code_lid?: string | null;
  timezone: string | null;
  name?: string | null;
  city?: string | null;
  airport_info_url?: string | null;
}

export interface AeroPosition {
  fa_flight_id?: string | null;
  altitude: number; // hundreds of feet
  altitude_change?: "C" | "D" | "-";
  groundspeed: number; // knots
  heading: number | null; // 0-360
  latitude: number;
  longitude: number;
  timestamp: string; // ISO 8601
  update_type?: string | null;
}

/** Response of GET /flights/{id}/position (InFlightStatus, subset). Only this endpoint carries last_position among the ones we use. */
export interface AeroInFlightStatus {
  ident: string;
  ident_icao: string | null;
  ident_iata: string | null;
  fa_flight_id: string;
  last_position: AeroPosition | null;
}

/**
 * One item of GET /schedules/{date_start}/{date_end} (ScheduledFlight, subset): a flight in the
 * airline schedules. A plan, not a tracked flight: no status, estimates, gates or registration.
 */
export interface AeroScheduledFlight {
  ident: string;
  ident_icao: string | null;
  ident_iata: string | null;
  /** For a codeshare, the operating flight's ident; null for the operating flight itself. */
  actual_ident?: string | null;
  actual_ident_icao?: string | null;
  actual_ident_iata?: string | null;
  aircraft_type: string | null;
  scheduled_in: string;
  scheduled_out: string;
  origin: string;
  origin_icao: string | null;
  origin_iata: string | null;
  origin_lid?: string | null;
  destination: string;
  destination_icao: string | null;
  destination_iata: string | null;
  destination_lid?: string | null;
  /** Null for a flight the provider has not started tracking yet. */
  fa_flight_id: string | null;
  meal_service?: string | null;
  seats_cabin_business?: number | null;
  seats_cabin_coach?: number | null;
  seats_cabin_first?: number | null;
}

/**
 * One item of GET /flights/search (subset): a flight with its latest position. UNVERIFIED shape: the
 * fields the radar reads, all optional so a missing one drops the flight instead of failing the call.
 */
export interface AeroSearchFlight {
  fa_flight_id?: string | null;
  ident?: string | null;
  ident_iata?: string | null;
  ident_icao?: string | null;
  operator?: string | null;
  operator_icao?: string | null;
  operator_iata?: string | null;
  aircraft_type?: string | null;
  origin?: AeroAirportRef | null;
  destination?: AeroAirportRef | null;
  last_position?: AeroPosition | null;
}

/** One item of GET /airports/{id}/flights/to/{dest_id}: a possibly multi-leg itinerary. */
export interface AeroFullFlight {
  segments: AeroFlight[];
}

export interface AeroFlight {
  ident: string;
  ident_icao: string | null;
  ident_iata: string | null;
  actual_runway_off?: string | null;
  actual_runway_on?: string | null;
  fa_flight_id: string;
  operator: string | null;
  operator_icao?: string | null;
  operator_iata?: string | null;
  flight_number?: string | null;
  registration: string | null;
  atc_ident?: string | null;
  inbound_fa_flight_id?: string | null;
  codeshares?: string[] | null;
  codeshares_iata?: string[] | null;
  blocked?: boolean;
  diverted: boolean;
  cancelled: boolean;
  position_only?: boolean;
  origin: AeroAirportRef | null;
  destination: AeroAirportRef | null;
  departure_delay?: number | null; // seconds
  arrival_delay?: number | null; // seconds
  filed_ete?: number | null;
  scheduled_out: string | null;
  estimated_out: string | null;
  actual_out: string | null;
  scheduled_off: string | null;
  estimated_off: string | null;
  actual_off: string | null;
  scheduled_on: string | null;
  estimated_on: string | null;
  actual_on: string | null;
  scheduled_in: string | null;
  estimated_in: string | null;
  actual_in: string | null;
  progress_percent?: number | null;
  status: string;
  aircraft_type: string | null;
  route_distance?: number | null;
  filed_airspeed?: number | null;
  filed_altitude?: number | null;
  route?: string | null;
  baggage_claim: string | null;
  seats_cabin_business?: number | null;
  seats_cabin_coach?: number | null;
  seats_cabin_first?: number | null;
  gate_origin: string | null;
  gate_destination: string | null;
  terminal_origin: string | null;
  terminal_destination: string | null;
  type?: string | null;
}

/** Row for the `flights` table upsert (conflict target: provider_id). Position columns are left out on purpose so an upsert never wipes them. */
export interface FlightRow {
  provider_id: string;
  ident: string;
  operator: string | null;
  origin_icao: string | null;
  origin_iata: string | null;
  destination_icao: string | null;
  destination_iata: string | null;
  scheduled_out: string | null;
  scheduled_in: string | null;
  estimated_out: string | null;
  estimated_in: string | null;
  scheduled_off: string | null;
  scheduled_on: string | null;
  estimated_off: string | null;
  estimated_on: string | null;
  actual_out: string | null;
  actual_off: string | null;
  actual_on: string | null;
  actual_in: string | null;
  gate_origin: string | null;
  gate_destination: string | null;
  terminal_origin: string | null;
  terminal_destination: string | null;
  baggage_belt: string | null;
  aircraft_type: string | null;
  registration: string | null;
  status:
    | "scheduled"
    | "departed"
    | "en_route"
    | "landed"
    | "arrived"
    | "canceled"
    | "diverted"
    | "unknown";
  updated_at: string;
}

/** Position columns of `flights`, written only from /flights/{id}/position or webhook events. */
export interface PositionRow {
  position_lat: number;
  position_lon: number;
  position_altitude_ft: number | null;
  position_ground_speed_kt: number | null;
  position_heading: number | null;
  position_at: string;
}
