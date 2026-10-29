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
  altitude: number | null; // hundreds of feet
  altitude_change?: string | null;
  groundspeed: number | null; // knots
  heading: number | null;
  latitude: number;
  longitude: number;
  timestamp: string; // ISO 8601
  update_type?: string | null;
}

export interface AeroFlight {
  ident: string;
  ident_icao: string | null;
  ident_iata: string | null;
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
  last_position?: AeroPosition | null;
}

/** Row for the `flights` table upsert (conflict target: provider_id). */
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
  status: "scheduled" | "departed" | "en_route" | "landed" | "arrived" | "canceled" | "diverted" | "unknown";
  position_lat: number | null;
  position_lon: number | null;
  position_altitude_ft: number | null;
  position_ground_speed_kt: number | null;
  position_heading: number | null;
  position_at: string | null;
  updated_at: string;
}
