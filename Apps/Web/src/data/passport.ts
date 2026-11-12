import type { CorePastFlight } from "@/core/flightcore";
import type { AirportDirectory } from "@/ui/airports";
import { ApiError } from "./api";
import { getSupabase } from "./client";
import { useFakes } from "./flights";

export const pastFlightsKey = ["pastFlights"] as const;

export type PastFlightStatus = "completed" | "canceled" | "diverted";
export type PastFlightSource = "archive" | "manual" | "import";

/** The `past_flights` row, camelCase, the date as a Date (PastFlight.swift). */
export type PastFlight = {
  id: string;
  date: Date;
  ident: string;
  originIcao: string;
  destinationIcao: string;
  airline: string | null;
  aircraftType: string | null;
  registration: string | null;
  seat: string | null;
  distanceKm: number;
  blockMinutes: number | null;
  delayMinutes: number;
  status: PastFlightStatus;
  originTz: string | null;
  seatClass: string | null;
  reason: string | null;
  bookingCode: string | null;
  notes: string | null;
  originCountry: string | null;
  destinationCountry: string | null;
  airMinutes: number | null;
  seatPosition: string | null;
  source: PastFlightSource | null;
  arrivalDelayMinutes: number | null;
  departureDelayMinutes: number | null;
};

/** The columns the app reads (SupabaseHistoryService.columns). */
const COLUMNS =
  "id, date, ident, origin_icao, destination_icao, airline, aircraft_type, registration, seat, " +
  "distance_km, block_minutes, delay_minutes, status, origin_tz, seat_class, reason, booking_code, notes, " +
  "origin_country, destination_country, air_minutes, seat_position, source, " +
  "arrival_delay_minutes, departure_delay_minutes";

type Raw = Record<string, unknown>;
const str = (v: unknown): string | null => (typeof v === "string" && v !== "" ? v : null);
const int = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? Math.round(v) : null);

export function decodePastFlight(raw: unknown): PastFlight {
  const r = (raw ?? {}) as Raw;
  const id = str(r.id);
  const date = new Date(String(r.date));
  if (!id || Number.isNaN(date.getTime())) throw new Error("bad past flight row");
  const status = r.status === "canceled" || r.status === "diverted" ? r.status : "completed";
  const source = r.source === "archive" || r.source === "manual" || r.source === "import" ? r.source : null;
  return {
    id,
    date,
    ident: typeof r.ident === "string" ? r.ident : "",
    originIcao: typeof r.origin_icao === "string" ? r.origin_icao : "",
    destinationIcao: typeof r.destination_icao === "string" ? r.destination_icao : "",
    airline: str(r.airline),
    aircraftType: str(r.aircraft_type),
    registration: str(r.registration),
    seat: str(r.seat),
    distanceKm: int(r.distance_km) ?? 0,
    blockMinutes: int(r.block_minutes),
    delayMinutes: int(r.delay_minutes) ?? 0,
    status,
    originTz: str(r.origin_tz),
    seatClass: str(r.seat_class),
    reason: str(r.reason),
    bookingCode: str(r.booking_code),
    notes: str(r.notes),
    originCountry: str(r.origin_country),
    destinationCountry: str(r.destination_country),
    airMinutes: int(r.air_minutes),
    seatPosition: str(r.seat_position),
    source,
    arrivalDelayMinutes: int(r.arrival_delay_minutes),
    departureDelayMinutes: int(r.departure_delay_minutes),
  };
}

type PgError = { code?: string; message?: string };
function pgError(e: PgError): ApiError {
  if (e.code === "PGRST301" || e.code === "PGRST302") return new ApiError("unauthorized", 401, e.message);
  if (e.code === "23514" || e.code === "22P02") return new ApiError("invalid_request", 400, e.message);
  return new ApiError("provider_unavailable", 500, e.message);
}

const SAVE_FAILED = "This flight could not be saved.";
const OFFLINE = "You're offline. Showing the last update.";

/** What a database error on a write means to the user (SupabaseBackend.rejection, APIError.offline). */
function writeError(e: PgError): ApiError {
  const code = e.code ?? "";
  const rejected = (text: string, status = 400) => new ApiError(status === 401 ? "unauthorized" : "invalid_request", status, text);
  if (code === "23514") return rejected("An airport code, the flight number, the aircraft or the date isn't accepted");
  if (code === "23505") return rejected("Already in your Passport");
  if (code === "23502") return rejected("A required value is missing");
  if (code === "42501") return rejected("Your account can't save this flight. Sign in again and retry.", 401);
  if (code.startsWith("22")) return rejected("A value is in a format the server doesn't read");
  if (!code && (/fetch|network|load failed/i.test(e.message ?? "") || (typeof navigator !== "undefined" && navigator.onLine === false))) {
    return new ApiError("provider_unavailable", 0, OFFLINE);
  }
  const generic = pgError(e);
  return new ApiError(generic.code, generic.status); // no text: the screen falls back on the generic line
}

/** The line for a failed save: the app's distinct line when there is one, else "This flight could not be saved." */
export function saveFailureCopy(e: unknown): string {
  if (e instanceof ApiError && e.message && e.message !== e.code) return e.message;
  return SAVE_FAILED;
}

/** The signed-in user's past flights, newest first. A row that cannot be read is left out. */
export async function fetchPastFlights(): Promise<PastFlight[]> {
  if (useFakes() && import.meta.env.DEV) {
    const { fakePastFlights } = await import("@/fakes/passport");
    return fakePastFlights();
  }
  const { data, error } = await getSupabase().from("past_flights").select(COLUMNS).order("date", { ascending: false });
  if (error) throw pgError(error);
  const out: PastFlight[] = [];
  for (const row of (data ?? []) as unknown[]) {
    try {
      out.push(decodePastFlight(row));
    } catch {
      // one bad row never fails the list
    }
  }
  return out;
}

/** Deletes a past flight; a delete that matches no row (gone, someone else's) is `not_found`. */
export async function deletePastFlight(id: string): Promise<void> {
  if (useFakes() && import.meta.env.DEV) {
    const { deleteFakePast } = await import("@/fakes/passport");
    if (!deleteFakePast(id)) throw new ApiError("not_found", 404);
    return;
  }
  const { data, error } = await getSupabase().from("past_flights").delete().eq("id", id.toLowerCase()).select("id");
  if (error) throw pgError(error);
  if (!Array.isArray(data) || data.length === 0) throw new ApiError("not_found", 404);
}

// MARK: Add

export type NewPastFlight = { ident: string; day: string; from: string; to: string };
export type NewFlightProblem = "date" | "origin" | "destination" | "sameAirports" | "ident";
export type NewFlightResult =
  | { ok: true; value: { ident: string; from: string; to: string; day: string } }
  | { ok: false; errors: Partial<Record<NewFlightProblem, string>> };

export const PROBLEM_COPY: Record<NewFlightProblem, string> = {
  date: "Pick a day that has already come.",
  origin: "Pick the airport you left from.",
  destination: "Pick the airport you flew to.",
  sameAirports: "The flight has to land somewhere else.",
  ident: "A flight number reads like UA990 or AF84.",
};

/** The first scheduled flights flew in 1919 (PastFlightRules.earliest). */
const EARLIEST = Date.UTC(1919, 0, 1);
/** A day picked here is stored at noon at the origin; the server allows a day of slack. */
const FUTURE_SLACK_MS = 12 * 3600_000;

/** A trimmed, upper-cased code of three or four letters and digits, else null (PastFlightRules.airportCode). */
function airportCode(s: string): string | null {
  const t = s.trim().toUpperCase();
  return /^[A-Z0-9]{3,4}$/.test(t) ? t : null;
}

/** The airport as its ICAO code when the directory knows it, else a well-formed code as typed. */
function resolveAirport(s: string, dir: AirportDirectory): string {
  return dir(s)?.icao ?? airportCode(s) ?? "";
}

/** The instant of 12:00 on `day` (YYYY-MM-DD) in `tz`; UTC when the zone is null or unknown. */
export function noonAt(day: string, tz: string | null): Date {
  const [y, m, d] = day.split("-").map(Number) as [number, number, number];
  const wall = Date.UTC(y, m - 1, d, 12);
  if (!tz) return new Date(wall);
  try {
    const f = new Intl.DateTimeFormat("en-US", {
      timeZone: tz,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
      hourCycle: "h23",
    });
    const offsetAt = (t: number) => {
      const p: Record<string, string> = {};
      for (const x of f.formatToParts(new Date(t))) p[x.type] = x.value;
      const local = Date.UTC(+p.year!, +p.month! - 1, +p.day!, +p.hour!, +p.minute!, +p.second!);
      return local - Math.floor(t / 1000) * 1000;
    };
    // The offset at the guess, then at the corrected instant (settles across a DST edge).
    const first = wall - offsetAt(wall);
    return new Date(wall - offsetAt(first));
  } catch {
    return new Date(wall);
  }
}

/** Checks the add form as PastFlightEditorModel does: codes, flight number, day, and two distinct airports. */
export function validateNewFlight(input: NewPastFlight, dir: AirportDirectory, now: Date = new Date()): NewFlightResult {
  const errors: Partial<Record<NewFlightProblem, string>> = {};
  const from = resolveAirport(input.from, dir);
  const to = resolveAirport(input.to, dir);
  const ident = input.ident.replace(/\s/g, "").toUpperCase();
  const okDay = /^\d{4}-\d{2}-\d{2}$/.test(input.day);
  if (!okDay) errors.date = PROBLEM_COPY.date;
  else {
    const t = noonAt(input.day, dir(from)?.tz ?? null).getTime();
    if (Number.isNaN(t) || t < EARLIEST || t > now.getTime() + FUTURE_SLACK_MS) errors.date = PROBLEM_COPY.date;
  }
  if (!from) errors.origin = PROBLEM_COPY.origin;
  if (!to) errors.destination = PROBLEM_COPY.destination;
  if (from && from === to) errors.sameAirports = PROBLEM_COPY.sameAirports;
  if (ident !== "" && !/^[A-Z0-9]{2,3}[0-9]{1,5}[A-Z]?$/.test(ident)) errors.ident = PROBLEM_COPY.ident;
  if (Object.keys(errors).length > 0) return { ok: false, errors };
  return { ok: true, value: { ident, from, to, day: input.day } };
}

/**
 * Stores a past flight the traveller adds by hand, as SupabaseHistoryService.add does: every column is sent
 * (null included), the derived ones (distance, countries, origin zone) as null so the server fills them from
 * airports, `source` manual, the user the column default (auth.uid()), the day stored at noon at the origin.
 * Throws `invalid_request` when the input does not validate.
 */
export async function addPastFlight(input: NewPastFlight, dir: AirportDirectory): Promise<PastFlight> {
  const v = validateNewFlight(input, dir);
  if (!v.ok) throw new ApiError("invalid_request", 400);
  const { ident, from, to, day } = v.value;
  const date = noonAt(day, dir(from)?.tz ?? null);
  const id = crypto.randomUUID().toLowerCase();
  if (useFakes() && import.meta.env.DEV) {
    const { addFakePast } = await import("@/fakes/passport");
    const o = dir(from);
    const d = dir(to);
    const f: PastFlight = {
      id,
      date,
      ident,
      originIcao: from,
      destinationIcao: to,
      airline: null,
      aircraftType: null,
      registration: null,
      seat: null,
      distanceKm: 0,
      blockMinutes: null,
      delayMinutes: 0,
      status: "completed",
      originTz: o?.tz ?? null,
      seatClass: null,
      reason: null,
      bookingCode: null,
      notes: null,
      originCountry: o?.country || null,
      destinationCountry: d?.country || null,
      airMinutes: null,
      seatPosition: null,
      source: "manual",
      arrivalDelayMinutes: null,
      departureDelayMinutes: null,
    };
    addFakePast(f);
    return f;
  }
  const body = {
    id,
    date: date.toISOString(),
    ident,
    origin_icao: from,
    destination_icao: to,
    airline: null,
    aircraft_type: null,
    registration: null,
    seat: null,
    distance_km: null,
    block_minutes: null,
    delay_minutes: 0,
    status: "completed",
    seat_class: null,
    reason: null,
    booking_code: null,
    notes: null,
    air_minutes: null,
    seat_position: null,
    arrival_delay_minutes: null,
    departure_delay_minutes: null,
    source: "manual",
    origin_tz: null,
    origin_country: null,
    destination_country: null,
  };
  const { data, error } = await getSupabase().from("past_flights").insert(body).select(COLUMNS);
  if (error) throw writeError(error);
  const first = ((data ?? []) as unknown[])[0];
  if (!first) throw new ApiError("not_found", 404);
  return decodePastFlight(first);
}

// MARK: Stats input

/** IANA zone of the origin: the row's, else the airport's, else UTC. */
function zoneOf(f: PastFlight, dir: AirportDirectory): string {
  return f.originTz ?? dir(f.originIcao)?.tz ?? "UTC";
}

/** The local calendar year of the departure in the origin's zone (the core's bucketing). */
export function localYear(f: PastFlight, dir: AirportDirectory): number {
  try {
    return Number(new Intl.DateTimeFormat("en-US", { timeZone: zoneOf(f, dir), year: "numeric" }).format(f.date));
  } catch {
    return f.date.getUTCFullYear();
  }
}

/** Flights as the core reads them: countries from the airports when the row carries none. */
export function toCore(rows: PastFlight[], dir: AirportDirectory): CorePastFlight[] {
  return rows.map((f) => ({
    departed_at: Math.floor(f.date.getTime() / 1000),
    tz: zoneOf(f, dir),
    ident: f.ident,
    origin_icao: f.originIcao,
    destination_icao: f.destinationIcao,
    airline: f.airline,
    aircraft_type: f.aircraftType,
    distance_km: Math.max(0, f.distanceKm),
    block_minutes: f.blockMinutes === null ? null : Math.max(0, f.blockMinutes),
    delay_minutes: Math.max(0, f.delayMinutes),
    status: f.status,
    origin_country: f.originCountry ?? (dir(f.originIcao)?.country || null),
    destination_country: f.destinationCountry ?? (dir(f.destinationIcao)?.country || null),
    air_minutes: f.airMinutes === null ? null : Math.max(0, f.airMinutes),
    registration: f.registration,
    seat_class: f.seatClass,
    seat: f.seat,
    reason: f.reason,
    seat_position: f.seatPosition,
  }));
}

// MARK: Export (PastFlightExport.swift)

export type ExportFormat = "csv" | "json";

const LEGACY_HEADER =
  "date,flight,from,to,airline,aircraft,registration,seat,distance_km,block_minutes,delay_minutes,status";
export const CSV_HEADER = `${LEGACY_HEADER},arrival_delay_minutes,departure_delay_minutes`;

/** Whole-second ISO 8601 in UTC ("2025-03-14T06:05:00Z"). */
const utc = (d: Date) => d.toISOString().replace(/\.\d{3}Z$/, "Z");

/** A text cell a spreadsheet would run as a formula gets a leading single quote. */
const csvText = (s: string) => (s !== "" && "=+-@\t\r".includes(s[0]!) ? `'${s}` : s);
const csvField = (s: string) => (/[,"\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s);

/** RFC 4180 CSV, CRLF between records, the UTF-8 byte order mark first, the app's columns and quoting. */
export function pastFlightsCsv(rows: PastFlight[]): string {
  const records = [CSV_HEADER];
  for (const p of rows) {
    const text = [p.ident, p.originIcao, p.destinationIcao, p.airline ?? "", p.aircraftType ?? "", p.registration ?? "", p.seat ?? ""].map(csvText);
    const fields = [
      utc(p.date),
      ...text,
      String(p.distanceKm),
      p.blockMinutes === null ? "" : String(p.blockMinutes),
      String(p.delayMinutes),
      p.status,
      p.arrivalDelayMinutes === null ? "" : String(p.arrivalDelayMinutes),
      p.departureDelayMinutes === null ? "" : String(p.departureDelayMinutes),
    ];
    records.push(fields.map(csvField).join(","));
  }
  return "﻿" + records.join("\r\n");
}

/** snake_case keys, sorted, a missing value left out, whole-second UTC dates, pretty printed, ending in a newline. */
export function pastFlightsJson(rows: PastFlight[]): string {
  const out = rows.map((p) => {
    const o: Record<string, unknown> = {
      id: p.id.toUpperCase(),
      date: utc(p.date),
      ident: p.ident,
      origin_icao: p.originIcao,
      destination_icao: p.destinationIcao,
      airline: p.airline,
      aircraft_type: p.aircraftType,
      registration: p.registration,
      seat: p.seat,
      distance_km: p.distanceKm,
      block_minutes: p.blockMinutes,
      delay_minutes: p.delayMinutes,
      status: p.status,
      origin_tz: p.originTz,
      seat_class: p.seatClass,
      reason: p.reason,
      booking_code: p.bookingCode,
      notes: p.notes,
      origin_country: p.originCountry,
      destination_country: p.destinationCountry,
      air_minutes: p.airMinutes,
      seat_position: p.seatPosition,
      source: p.source,
      arrival_delay_minutes: p.arrivalDelayMinutes,
      departure_delay_minutes: p.departureDelayMinutes,
    };
    const sorted: Record<string, unknown> = {};
    for (const k of Object.keys(o).sort()) if (o[k] !== null && o[k] !== undefined) sorted[k] = o[k];
    return sorted;
  });
  return JSON.stringify(out, null, 2) + "\n";
}

/** `soma-flight-history-YYYY-MM-DD.csv` (or `.json`), after the local day. */
export function exportFileName(format: ExportFormat, on: Date): string {
  const p = (n: number) => String(n).padStart(2, "0");
  return `soma-flight-history-${on.getFullYear()}-${p(on.getMonth() + 1)}-${p(on.getDate())}.${format}`;
}

/** Saves the export through a Blob link: built in the browser, sent nowhere. */
export function downloadExport(format: ExportFormat, rows: PastFlight[], now: Date = new Date()): void {
  const text = format === "csv" ? pastFlightsCsv(rows) : pastFlightsJson(rows);
  const blob = new Blob([text], { type: format === "csv" ? "text/csv;charset=utf-8" : "application/json" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = exportFileName(format, now);
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 0);
}
