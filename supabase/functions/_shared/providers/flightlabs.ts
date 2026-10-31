// FlightLabs (goflightlabs.com) adapter: flight status and airport boards from the airport timetable
// (GET /advanced-flights-schedules), the departure airport of a flight number from GET /flight, and
// live positions and airframes from GET /flights. Field names follow the official endpoint pages
// (read 2026-10-31, docs/free-providers.md); no sample answer was published, so the test fixtures are
// built from those field lists.
//
// The key goes in an Authorization: Bearer header (the provider's preferred form), never in the URL.
// Every request is charged against the quota first: there is no lasting free tier, only a 7 day
// trial capped at 50 requests, and Starter is 4,000 a month.
import { ApiError } from "../errors.ts";
import {
  blankRow,
  cleanIdent,
  deriveStatus,
  isIcaoIdent,
  nearest,
  ofIdent,
  syntheticId,
} from "./common.ts";
import { code, epochIso, type Fetch, fetchJson, text, utcIso } from "./http.ts";
import type { QuotaCharge } from "./quota.ts";
import type {
  AircraftInfo,
  AircraftProvider,
  BoardProvider,
  FlightRef,
  PositionProvider,
  PositionQuery,
  PositionRow,
  ProviderFlight,
  StatusProvider,
} from "./types.ts";

export const FLIGHTLABS_BASE = "https://www.goflightlabs.com";

/** One timetable entry of /advanced-flights-schedules (documented fields, subset). */
export interface FlSchedule {
  airline_iata?: string | null;
  airline_icao?: string | null;
  flight_iata?: string | null;
  flight_icao?: string | null;
  flight_number?: string | null;
  dep_iata?: string | null;
  dep_icao?: string | null;
  dep_terminal?: string | null;
  dep_gate?: string | null;
  dep_time?: string | null;
  dep_time_utc?: string | null;
  dep_estimated_utc?: string | null;
  dep_actual_utc?: string | null;
  arr_iata?: string | null;
  arr_icao?: string | null;
  arr_terminal?: string | null;
  arr_gate?: string | null;
  arr_baggage?: string | null;
  arr_time_utc?: string | null;
  arr_estimated_utc?: string | null;
  arr_actual_utc?: string | null;
  cs_flight_iata?: string | null;
  status?: string | null;
  aircraft_icao?: string | null;
  dep_time_ts?: number | null;
  arr_time_ts?: number | null;
  dep_estimated_ts?: number | null;
  arr_estimated_ts?: number | null;
  dep_actual_ts?: number | null;
  arr_actual_ts?: number | null;
}

/** One live aircraft of /flights (documented fields, subset). */
export interface FlLive {
  hex?: string | null;
  reg_number?: string | null;
  lat?: number | null;
  lng?: number | null;
  alt?: number | null; // metres
  dir?: number | null;
  speed?: number | null; // km/h
  airline_icao?: string | null;
  aircraft_icao?: string | null;
  flight_icao?: string | null;
  flight_iata?: string | null;
  dep_icao?: string | null;
  arr_icao?: string | null;
  updated?: number | null; // unix seconds
  status?: string | null;
}

/** One item of /flight (flight info by number): display strings, not times. */
interface FlInfo {
  DATE?: string | null;
  FROM?: string | null;
  TO?: string | null;
  STATUS?: string | null;
}

export interface FlightLabsOptions {
  key: string;
  baseUrl?: string;
  fetchFn?: Fetch;
  charge: QuotaCharge;
  now?: () => Date;
  /** ICAO to IATA for the timetable, which takes IATA airport codes only. */
  iataOf?: (icao: string) => Promise<string | null>;
}

const STATUS: Record<string, ProviderFlight["status"]> = {
  scheduled: "scheduled",
  active: "en_route",
  "en-route": "en_route",
  landed: "landed",
  cancelled: "canceled",
  diverted: "diverted",
};

export class FlightLabs
  implements StatusProvider, BoardProvider, PositionProvider, AircraftProvider {
  readonly name = "flightlabs" as const;
  private readonly base: string;
  private readonly fetchFn: Fetch;
  private readonly now: () => Date;

  constructor(private readonly opts: FlightLabsOptions) {
    this.base = (opts.baseUrl ?? FLIGHTLABS_BASE).replace(/\/+$/, "");
    if (!this.base.startsWith("https://")) {
      throw new Error("FLIGHTLABS_BASE_URL must be https");
    }
    this.fetchFn = opts.fetchFn ?? fetch;
    this.now = opts.now ?? (() => new Date());
  }

  private async get<T>(
    path: string,
    params: Record<string, string>,
  ): Promise<T[]> {
    await this.opts.charge(1);
    const body = await fetchJson<unknown>(
      this.fetchFn,
      `flightlabs ${path}`,
      `${this.base}${path}?${new URLSearchParams(params)}`,
      { headers: { authorization: `Bearer ${this.opts.key}` } },
    );
    if (Array.isArray(body)) return body as T[];
    const o = body as { success?: boolean; data?: unknown; error?: unknown };
    if (Array.isArray(o?.data)) return o.data as T[];
    // { success: false, ... } or { error: ... } on a 200: a plan or input problem, never data.
    if (o?.success === false || o?.error) {
      console.error(`flightlabs ${path} answered without data`);
      throw new ApiError("provider_unavailable", 502, "Provider error");
    }
    return [];
  }

  private async iata(
    icao: string | null,
    iata: string | null,
  ): Promise<string | null> {
    if (iata) return iata;
    if (!icao) return null;
    return (await this.opts.iataOf?.(icao)) ?? null;
  }

  /** A timetable entry as a `flights` row; null for a codeshare entry or one without an origin. */
  toRow(s: FlSchedule): ProviderFlight | null {
    if (text(s.cs_flight_iata)) return null; // the operating flight is listed on its own
    const ident = text(s.flight_iata) ?? text(s.flight_icao);
    const origin = code(s.dep_icao, 4) ?? code(s.dep_iata, 3);
    // dep_time is the airport's wall clock, so its date is the origin-local day.
    const day = text(s.dep_time)?.slice(0, 10) ??
      text(s.dep_time_utc)?.slice(0, 10);
    if (!ident || !origin || !day || !/^\d{4}-\d{2}-\d{2}$/.test(day)) {
      return null;
    }
    const row = blankRow(
      syntheticId(
        "flightlabs",
        cleanIdent(text(s.flight_icao) ?? ident),
        origin,
        day,
      ),
      cleanIdent(ident),
      this.now(),
    );
    const t = (utc: string | null | undefined, ts: number | null | undefined) =>
      utcIso(utc) ?? epochIso(ts);
    row.operator = code(s.airline_iata, 2) ?? code(s.airline_icao, 3);
    row.origin_icao = code(s.dep_icao, 4);
    row.origin_iata = code(s.dep_iata, 3);
    row.destination_icao = code(s.arr_icao, 4);
    row.destination_iata = code(s.arr_iata, 3);
    row.scheduled_out = t(s.dep_time_utc, s.dep_time_ts);
    row.estimated_out = t(s.dep_estimated_utc, s.dep_estimated_ts);
    row.actual_out = t(s.dep_actual_utc, s.dep_actual_ts);
    row.scheduled_in = t(s.arr_time_utc, s.arr_time_ts);
    row.estimated_in = t(s.arr_estimated_utc, s.arr_estimated_ts);
    row.actual_in = t(s.arr_actual_utc, s.arr_actual_ts);
    row.gate_origin = text(s.dep_gate);
    row.gate_destination = text(s.arr_gate);
    row.terminal_origin = text(s.dep_terminal);
    row.terminal_destination = text(s.arr_terminal);
    row.baggage_belt = text(s.arr_baggage);
    row.aircraft_type = text(s.aircraft_icao, 8);
    // Registration is not in the timetable (the docs say so): it stays null.
    row.status = deriveStatus(
      row,
      STATUS[(s.status ?? "").toLowerCase()] ?? null,
    );
    if (row.status === "en_route" && !row.actual_out) row.status = "departed";
    return row;
  }

  private rows(list: FlSchedule[]): ProviderFlight[] {
    const seen = new Set<string>();
    const out: ProviderFlight[] = [];
    for (const s of list) {
      const r = this.toRow(s);
      if (!r || seen.has(r.provider_id)) continue;
      seen.add(r.provider_id);
      out.push(r);
    }
    return out;
  }

  private schedules(
    iata: string,
    kind: "departure" | "arrival",
    ident?: string,
  ) {
    const p: Record<string, string> = { iataCode: iata, type: kind };
    if (ident) {
      const id = cleanIdent(ident);
      p[isIcaoIdent(id) ? "flight_icao" : "flight_iata"] = id;
    }
    return this.get<FlSchedule>("/advanced-flights-schedules", p);
  }

  /**
   * Two requests: /flight for where the number leaves from, then that airport's timetable for the
   * number. The timetable covers the airport's current day, so the window mostly holds today.
   */
  async flightsByIdent(ident: string, from: Date, to: Date) {
    const info = await this.get<FlInfo>("/flight", {
      flight_number: cleanIdent(ident),
    });
    const origins = new Set<string>();
    for (const i of info) {
      const m = /\(([A-Z0-9]{3})\)\s*$/.exec(text(i.FROM, 200) ?? "");
      if (m) origins.add(m[1]);
    }
    const out: ProviderFlight[] = [];
    for (const iata of [...origins].slice(0, 1)) {
      const listed = this.rows(await this.schedules(iata, "departure", ident));
      for (const r of ofIdent(listed, ident)) {
        const t = r.scheduled_out ? Date.parse(r.scheduled_out) : NaN;
        if (t >= from.getTime() && t < to.getTime()) out.push(r);
      }
    }
    return out;
  }

  async searchRouteWindow(
    origin: string,
    destination: string,
    start: Date,
    end: Date,
  ) {
    const iata = await this.iata(origin, null);
    if (!iata) return [];
    return this.rows(await this.schedules(iata, "departure")).filter((r) => {
      const t = r.scheduled_out ? Date.parse(r.scheduled_out) : NaN;
      return r.destination_icao === destination && t >= start.getTime() &&
        t < end.getTime();
    });
  }

  async flightStatus(ref: FlightRef) {
    const iata = await this.iata(ref.origin_icao, ref.origin_iata);
    if (!iata) return null;
    const rows = ofIdent(
      this.rows(await this.schedules(iata, "departure", ref.ident)),
      ref.ident,
    );
    return nearest(rows, ref.scheduled_out);
  }

  async boardFlights(icao: string, kind: "departures" | "arrivals") {
    const iata = await this.iata(icao, null);
    if (!iata) {
      throw new ApiError(
        "provider_unavailable",
        502,
        "Airport has no IATA code",
      );
    }
    return this.rows(
      await this.schedules(
        iata,
        kind === "departures" ? "departure" : "arrival",
      ),
    );
  }

  private live(
    q: {
      callsign?: string | null;
      icao24?: string | null;
      registration?: string | null;
    },
  ) {
    if (q.icao24) {
      return this.get<FlLive>("/flights", { hex: q.icao24.toUpperCase() });
    }
    if (q.registration) {
      return this.get<FlLive>("/flights", { regNum: q.registration });
    }
    if (q.callsign) {
      const id = cleanIdent(q.callsign);
      return this.get<FlLive>(
        "/flights",
        isIcaoIdent(id) ? { flightIcao: id } : { flightIata: id },
      );
    }
    return Promise.resolve([] as FlLive[]);
  }

  async position(q: PositionQuery): Promise<PositionRow | null> {
    if (!q.icao24 && !q.callsign) return null;
    for (const l of await this.live(q)) {
      if (typeof l.lat !== "number" || typeof l.lng !== "number") continue;
      const at = epochIso(l.updated);
      if (!at) continue;
      return {
        position_lat: l.lat,
        position_lon: l.lng,
        position_altitude_ft: typeof l.alt === "number"
          ? Math.round(l.alt * 3.28084)
          : null,
        position_ground_speed_kt: typeof l.speed === "number"
          ? Math.round(l.speed / 1.852)
          : null,
        position_heading: typeof l.dir === "number" ? Math.round(l.dir) : null,
        position_at: at,
      };
    }
    return null;
  }

  /** Airframe of an aircraft in the live feed (only while it is flying or seen recently). */
  async aircraft(q: {
    registration?: string | null;
    icao24?: string | null;
    callsign?: string | null;
  }): Promise<AircraftInfo | null> {
    if (!q.icao24 && !q.registration && !q.callsign) return null;
    const l = (await this.live(q))[0];
    if (!l) return null;
    return {
      icao24: text(l.hex, 6)?.toLowerCase() ?? null,
      registration: text(l.reg_number, 16),
      aircraft_type: text(l.aircraft_icao, 8),
      operator: code(l.airline_icao, 3),
      country: null,
    };
  }
}
