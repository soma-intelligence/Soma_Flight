// Aviationstack (apilayer) adapter: flight status, route search, airport boards and positions from
// GET /v1/flights. Shapes follow the official documentation (aviationstack.com/documentation, read
// 2026-10-31 through its 2025-12-27 archive): docs/free-providers.md.
//
// One request per call, never paged: the free tier is 100 requests a month, so each call is charged
// against the quota first (quota.ts). The key travels as `access_key` in the query string, the only
// way the API takes it, which is why plain HTTP is refused in production (see `assertBaseUrl`).
//
// Times: the documentation shows times with a "+00:00" offset; whether they are UTC or the airport's
// wall clock with a wrong offset is not settled by the docs. AVIATIONSTACK_TIMES picks: "local"
// (default, read as wall clock at departure.timezone / arrival.timezone) or "utc". Check one real
// answer against the airline's site before relying on it.
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
import {
  code,
  type Fetch,
  fetchJson,
  localDay,
  text,
  utcIso,
  wallToUtc,
} from "./http.ts";
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

export const AVIATIONSTACK_BASE = "https://api.aviationstack.com/v1";

interface AsSide {
  airport?: string | null;
  timezone?: string | null;
  iata?: string | null;
  icao?: string | null;
  terminal?: string | null;
  gate?: string | null;
  baggage?: string | null;
  delay?: number | null;
  scheduled?: string | null;
  estimated?: string | null;
  actual?: string | null;
  estimated_runway?: string | null;
  actual_runway?: string | null;
}

/** One item of GET /v1/flights (documented fields). */
export interface AsFlight {
  flight_date?: string | null;
  flight_status?: string | null;
  departure?: AsSide | null;
  arrival?: AsSide | null;
  airline?:
    | { name?: string | null; iata?: string | null; icao?: string | null }
    | null;
  flight?: {
    number?: string | null;
    iata?: string | null;
    icao?: string | null;
    codeshared?: unknown;
  } | null;
  aircraft?: {
    registration?: string | null;
    iata?: string | null;
    icao?: string | null;
    icao24?: string | null;
  } | null;
  live?: {
    updated?: string | null;
    latitude?: number | null;
    longitude?: number | null;
    altitude?: number | null; // metres
    direction?: number | null;
    speed_horizontal?: number | null; // km/h
    speed_vertical?: number | null;
    is_ground?: boolean | null;
  } | null;
}

interface AsPage {
  data?: AsFlight[] | null;
  error?: { code?: string; message?: string } | null;
}

export interface AviationstackOptions {
  key: string;
  baseUrl?: string;
  /** AVIATIONSTACK_ALLOW_HTTP: lets a non-production run use an http:// base URL. */
  allowHttp?: boolean;
  /** True on the hosted project. An http:// base is refused there whatever allowHttp says. */
  production?: boolean;
  times?: "local" | "utc";
  fetchFn?: Fetch;
  charge: QuotaCharge;
  now?: () => Date;
}

/**
 * Refuses a base URL that would send the key in clear text in production, or anywhere unless
 * AVIATIONSTACK_ALLOW_HTTP is set. Thrown at construction, so a bad setting fails every call loudly
 * instead of leaking the key once.
 */
export function assertBaseUrl(
  baseUrl: string,
  allowHttp: boolean,
  production: boolean,
): void {
  let u: URL;
  try {
    u = new URL(baseUrl);
  } catch {
    throw new Error("AVIATIONSTACK_BASE_URL is not a URL");
  }
  if (u.protocol === "https:") return;
  if (u.protocol !== "http:") {
    throw new Error("AVIATIONSTACK_BASE_URL must be http or https");
  }
  if (production) {
    throw new Error(
      "Aviationstack over plain HTTP is refused in production: the key would travel in clear text",
    );
  }
  if (!allowHttp) {
    throw new Error(
      "AVIATIONSTACK_BASE_URL is http: set AVIATIONSTACK_ALLOW_HTTP=true for a local test",
    );
  }
}

const STATUS: Record<string, ProviderFlight["status"]> = {
  scheduled: "scheduled",
  active: "en_route",
  landed: "landed",
  cancelled: "canceled",
  diverted: "diverted",
  // "incident" says nothing we can show: left unknown.
};

export class Aviationstack
  implements StatusProvider, BoardProvider, PositionProvider, AircraftProvider {
  readonly name = "aviationstack" as const;
  private readonly base: string;
  private readonly fetchFn: Fetch;
  private readonly now: () => Date;
  private readonly times: "local" | "utc";

  constructor(private readonly opts: AviationstackOptions) {
    this.base = (opts.baseUrl ?? AVIATIONSTACK_BASE).replace(/\/+$/, "");
    assertBaseUrl(this.base, opts.allowHttp ?? false, opts.production ?? true);
    this.fetchFn = opts.fetchFn ?? fetch;
    this.now = opts.now ?? (() => new Date());
    this.times = opts.times ?? "local";
  }

  /** One charged GET /flights. A documented error body becomes the matching ApiError. */
  private async flights(params: Record<string, string>): Promise<AsFlight[]> {
    await this.opts.charge(1);
    const q = new URLSearchParams({ ...params, access_key: this.opts.key });
    const body = await fetchJson<AsPage>(
      this.fetchFn,
      "aviationstack /flights",
      `${this.base}/flights?${q}`,
    );
    if (body.error) {
      const c = body.error.code ?? "unknown";
      console.error(`aviationstack error code=${c.slice(0, 40)}`);
      if (c === "rate_limit_reached") {
        throw new ApiError("rate_limited", 429, "Provider rate limit");
      }
      throw new ApiError(
        "provider_unavailable",
        c === "usage_limit_reached" ? 503 : 502,
        `Provider error ${c.slice(0, 40)}`,
      );
    }
    return Array.isArray(body.data) ? body.data : [];
  }

  private time(v: string | null | undefined, tz: string | null | undefined) {
    return this.times === "utc" ? utcIso(v) : wallToUtc(v, tz);
  }

  /** A documented flight as a `flights` row; null for a codeshare listing or a row without ident. */
  toRow(f: AsFlight): ProviderFlight | null {
    if (f.flight?.codeshared) return null; // the operating flight carries the data
    const ident = text(f.flight?.iata) ?? text(f.flight?.icao);
    if (!ident) return null;
    const dep = f.departure ?? {}, arr = f.arrival ?? {};
    const originIcao = code(dep.icao, 4), originIata = code(dep.iata, 3);
    const scheduledOut = this.time(dep.scheduled, dep.timezone);
    const origin = originIcao ?? originIata;
    const day = f.flight_date ??
      (scheduledOut ? localDay(scheduledOut, dep.timezone) : null);
    if (!origin || !day) return null;
    const idIdent = text(f.flight?.icao) ?? ident;
    const row = blankRow(
      syntheticId("aviationstack", cleanIdent(idIdent), origin, day),
      cleanIdent(ident),
      this.now(),
    );
    row.operator = code(f.airline?.iata, 2) ?? code(f.airline?.icao, 3);
    row.origin_icao = originIcao;
    row.origin_iata = originIata;
    row.destination_icao = code(arr.icao, 4);
    row.destination_iata = code(arr.iata, 3);
    row.scheduled_out = scheduledOut;
    row.estimated_out = this.time(dep.estimated, dep.timezone);
    row.actual_out = this.time(dep.actual, dep.timezone);
    row.estimated_off = this.time(dep.estimated_runway, dep.timezone);
    row.actual_off = this.time(dep.actual_runway, dep.timezone);
    row.scheduled_in = this.time(arr.scheduled, arr.timezone);
    row.estimated_in = this.time(arr.estimated, arr.timezone);
    row.actual_in = this.time(arr.actual, arr.timezone);
    row.estimated_on = this.time(arr.estimated_runway, arr.timezone);
    row.actual_on = this.time(arr.actual_runway, arr.timezone);
    row.gate_origin = text(dep.gate);
    row.gate_destination = text(arr.gate);
    row.terminal_origin = text(dep.terminal);
    row.terminal_destination = text(arr.terminal);
    row.baggage_belt = text(arr.baggage);
    row.aircraft_type = text(f.aircraft?.icao, 8);
    row.registration = text(f.aircraft?.registration, 16);
    row.status = deriveStatus(
      row,
      STATUS[(f.flight_status ?? "").toLowerCase()] ?? null,
    );
    // "active" without any actual time: the flight left, the API does not say when.
    if (row.status === "en_route" && !row.actual_off && !row.actual_out) {
      row.status = "departed";
    }
    return { ...row, origin_tz: text(dep.timezone, 64) };
  }

  private rows(list: AsFlight[]): ProviderFlight[] {
    const seen = new Set<string>();
    const out: ProviderFlight[] = [];
    for (const f of list) {
      const r = this.toRow(f);
      if (!r || seen.has(r.provider_id)) continue;
      seen.add(r.provider_id);
      out.push(r);
    }
    return out;
  }

  private identParam(ident: string): Record<string, string> {
    const id = cleanIdent(ident);
    return isIcaoIdent(id) ? { flight_icao: id } : { flight_iata: id };
  }

  /**
   * The free tier has no flight_date (historical, Basic plan and up): one request returns the
   * flights the API holds now for the ident; the window is applied here.
   */
  async flightsByIdent(ident: string, from: Date, to: Date) {
    const rows = ofIdent(
      this.rows(await this.flights(this.identParam(ident))),
      ident,
    );
    return rows.filter((r) => {
      const t = r.scheduled_out ? Date.parse(r.scheduled_out) : NaN;
      return t >= from.getTime() && t < to.getTime();
    });
  }

  async searchRouteWindow(
    origin: string,
    destination: string,
    start: Date,
    end: Date,
  ) {
    const rows = this.rows(
      await this.flights({
        dep_icao: origin,
        arr_icao: destination,
        limit: "100",
      }),
    );
    return rows.filter((r) => {
      const t = r.scheduled_out ? Date.parse(r.scheduled_out) : NaN;
      return t >= start.getTime() && t < end.getTime();
    });
  }

  async flightStatus(ref: FlightRef) {
    const params = this.identParam(ref.ident);
    if (ref.origin_icao) params.dep_icao = ref.origin_icao;
    else if (ref.origin_iata) params.dep_iata = ref.origin_iata;
    return nearest(
      ofIdent(this.rows(await this.flights(params)), ref.ident),
      ref.scheduled_out,
    );
  }

  /** One page of 100 flights leaving (or reaching) the airport, as the API orders them. */
  async boardFlights(icao: string, kind: "departures" | "arrivals") {
    return this.rows(
      await this.flights({
        [kind === "departures" ? "dep_icao" : "arr_icao"]: icao,
        limit: "100",
      }),
    );
  }

  /** The `live` block of the flight with this callsign. Speeds converted to knots, metres to feet. */
  async position(q: PositionQuery): Promise<PositionRow | null> {
    if (!q.callsign) return null;
    const list = await this.flights(this.identParam(q.callsign));
    for (const f of list) {
      const l = f.live;
      if (
        !l || typeof l.latitude !== "number" || typeof l.longitude !== "number"
      ) continue;
      const at = utcIso(l.updated);
      if (!at) continue;
      return {
        position_lat: l.latitude,
        position_lon: l.longitude,
        position_altitude_ft: typeof l.altitude === "number"
          ? Math.round(l.altitude * 3.28084)
          : null,
        position_ground_speed_kt: typeof l.speed_horizontal === "number"
          ? Math.round(l.speed_horizontal / 1.852)
          : null,
        position_heading: typeof l.direction === "number"
          ? Math.round(l.direction)
          : null,
        position_at: at,
      };
    }
    return null;
  }

  /** Airframe of the flight with this callsign (the free tier has no registration search). */
  async aircraft(
    q: { callsign?: string | null },
  ): Promise<AircraftInfo | null> {
    if (!q.callsign) return null;
    const list = await this.flights(this.identParam(q.callsign));
    const a = list.find((f) => f.aircraft?.registration || f.aircraft?.icao24);
    if (!a) return null;
    return {
      icao24: text(a.aircraft?.icao24, 6)?.toLowerCase() ?? null,
      registration: text(a.aircraft?.registration, 16),
      aircraft_type: text(a.aircraft?.icao, 8),
      operator: code(a.airline?.icao, 3),
      country: null,
    };
  }
}
