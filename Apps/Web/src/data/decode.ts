import type { Flight, FlightStatus } from "./types";

const STATUSES: readonly string[] = [
  "scheduled",
  "departed",
  "en_route",
  "landed",
  "arrived",
  "canceled",
  "diverted",
  "unknown",
];

type Row = Record<string, unknown>;

function str(r: Row, k: string): string {
  const v = r[k];
  if (typeof v !== "string" || v === "") throw new Error(`flight row: missing ${k}`);
  return v;
}
function optStr(r: Row, k: string): string | null {
  const v = r[k];
  return typeof v === "string" ? v : null;
}
function date(v: unknown, k: string): Date {
  const d = new Date(String(v));
  if (typeof v !== "string" || Number.isNaN(d.getTime())) throw new Error(`flight row: bad date ${k}`);
  return d;
}
function optDate(r: Row, k: string): Date | null {
  const v = r[k];
  if (v === null || v === undefined) return null;
  const d = new Date(String(v));
  return typeof v === "string" && !Number.isNaN(d.getTime()) ? d : null;
}
function optNum(r: Row, k: string): number | null {
  const v = r[k];
  return typeof v === "number" ? v : null;
}

/** snake_case row of the `flights` table to Flight. Throws on a row that lacks a required column. */
export function decodeFlight(row: unknown): Flight {
  if (typeof row !== "object" || row === null) throw new Error("flight row: not an object");
  const r = row as Row;
  const rawStatus = r.status;
  const status = (typeof rawStatus === "string" && STATUSES.includes(rawStatus) ? rawStatus : "unknown") as FlightStatus;
  const lat = optNum(r, "position_lat");
  const lon = optNum(r, "position_lon");
  const at = optDate(r, "position_at");
  return {
    id: str(r, "id"),
    providerId: str(r, "provider_id"),
    ident: str(r, "ident"),
    operator: optStr(r, "operator"),
    originIcao: str(r, "origin_icao"),
    originIata: optStr(r, "origin_iata"),
    destinationIcao: str(r, "destination_icao"),
    destinationIata: optStr(r, "destination_iata"),
    scheduledOut: optDate(r, "scheduled_out"),
    scheduledIn: optDate(r, "scheduled_in"),
    estimatedOut: optDate(r, "estimated_out"),
    estimatedIn: optDate(r, "estimated_in"),
    scheduledOff: optDate(r, "scheduled_off"),
    scheduledOn: optDate(r, "scheduled_on"),
    estimatedOff: optDate(r, "estimated_off"),
    estimatedOn: optDate(r, "estimated_on"),
    actualOut: optDate(r, "actual_out"),
    actualOff: optDate(r, "actual_off"),
    actualOn: optDate(r, "actual_on"),
    actualIn: optDate(r, "actual_in"),
    gateOrigin: optStr(r, "gate_origin"),
    gateDestination: optStr(r, "gate_destination"),
    terminalOrigin: optStr(r, "terminal_origin"),
    terminalDestination: optStr(r, "terminal_destination"),
    baggageBelt: optStr(r, "baggage_belt"),
    aircraftType: optStr(r, "aircraft_type"),
    registration: optStr(r, "registration"),
    status,
    position:
      lat !== null && lon !== null && at !== null
        ? {
            lat,
            lon,
            altitudeFt: optNum(r, "position_altitude_ft"),
            groundSpeedKt: optNum(r, "position_ground_speed_kt"),
            heading: optNum(r, "position_heading"),
            at,
          }
        : null,
    updatedAt: date(r.updated_at, "updated_at"),
  };
}
