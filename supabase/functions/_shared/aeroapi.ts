// FlightAware AeroAPI v4 client. Pure fetch, injectable for tests.
// Shapes and semantics checked against the official OpenAPI file (AeroAPI 4.17.1).
import { ApiError } from "./errors.ts";
import type {
  AeroFlight,
  AeroFullFlight,
  AeroInFlightStatus,
  FlightRow,
  PositionRow,
} from "./aeroapi_types.ts";

export type { AeroFlight, FlightRow, PositionRow } from "./aeroapi_types.ts";

export const AEROAPI_BASE = "https://aeroapi.flightaware.com/aeroapi";
export const DEFAULT_TIMEOUT_MS = 10_000;

export type AirportListKind =
  | "departures"
  | "arrivals"
  | "scheduled_departures"
  | "scheduled_arrivals";

/**
 * Estimated cost in USD per result set (page), keyed by endpoint template.
 * Source: docs/provider-check.md (official pricing page, checked 2026-10-28).
 * UNVERIFIED: /airports/{id}/flights/to/{dest_id} is not on the pricing page; 0.02 is the
 * combined-board price used as a stand-in. The OpenAPI file publishes no prices.
 */
export const ENDPOINT_COST: Record<string, number> = {
  "/flights/{ident}": 0.005,
  "/flights/{id}/position": 0.01,
  "/airports/{id}/flights/departures": 0.005,
  "/airports/{id}/flights/arrivals": 0.005,
  "/airports/{id}/flights/scheduled_departures": 0.005,
  "/airports/{id}/flights/scheduled_arrivals": 0.005,
  "/airports/{id}/flights/to/{dest_id}": 0.02,
  "/alerts": 0,
  "/alerts/{id}": 0,
};

/** Throws on an endpoint without a price, so a new call can never be counted as free. */
export function estimateCost(endpoint: string): number {
  const cost = ENDPOINT_COST[endpoint];
  if (cost === undefined) {
    throw new Error(`no cost entry for endpoint ${endpoint}`);
  }
  return cost;
}

/** Provider limit for start/end: no more than 10 days back and 2 days ahead. */
export function inProviderWindow(at: Date, now: Date = new Date()): boolean {
  const t = at.getTime();
  return t >= now.getTime() - 10 * 86_400_000 &&
    t <= now.getTime() + 2 * 86_400_000;
}

type Fetch = typeof fetch;

export interface AeroApiOptions {
  timeoutMs?: number;
  now?: () => Date;
}

export class AeroApi {
  private readonly timeoutMs: number;
  private readonly now: () => Date;

  constructor(
    private readonly key: string,
    private readonly fetchFn: Fetch = fetch,
    /** Called once per HTTP request (one per page) with the endpoint template. */
    private readonly onCall?: (endpoint: string) => Promise<void>,
    opts: AeroApiOptions = {},
  ) {
    this.timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;
    this.now = opts.now ?? (() => new Date());
  }

  /**
   * Flights for an ident. Prefer the ICAO ident (ident_icao, e.g. AFR84): codeshare idents
   * may be rewritten by the provider. start/end must sit inside the provider window.
   */
  async flightsByIdent(
    ident: string,
    start?: string,
    end?: string,
  ): Promise<AeroFlight[]> {
    const q = new URLSearchParams({ ident_type: "designator" });
    if (start) q.set("start", start);
    if (end) q.set("end", end);
    const body = await this.get<{ flights?: AeroFlight[] }>(
      "/flights/{ident}",
      `/flights/${encodeURIComponent(ident)}`,
      q,
    );
    return asArray(body.flights);
  }

  /** One flight by fa_flight_id. Null when unknown. A diverted flight returns two rows: both are returned by flightsByIdent, this takes the diverted one. */
  async flightById(faFlightId: string): Promise<AeroFlight | null> {
    const q = new URLSearchParams({ ident_type: "fa_flight_id" });
    try {
      const body = await this.get<{ flights?: AeroFlight[] }>(
        "/flights/{ident}",
        `/flights/${encodeURIComponent(faFlightId)}`,
        q,
      );
      const rows = dedupeByFaFlightId(asArray(body.flights));
      return rows[0] ?? null;
    } catch (e) {
      if (e instanceof ApiError && e.code === "not_found") return null;
      throw e;
    }
  }

  /** Latest position of an airborne flight from /flights/{id}/position. Null when none. */
  async flightPosition(faFlightId: string): Promise<PositionRow | null> {
    let body: AeroInFlightStatus;
    try {
      body = await this.get<AeroInFlightStatus>(
        "/flights/{id}/position",
        `/flights/${encodeURIComponent(faFlightId)}/position`,
      );
    } catch (e) {
      if (e instanceof ApiError && e.code === "not_found") return null;
      throw e;
    }
    const p = body.last_position;
    if (!p) return null;
    return {
      position_lat: p.latitude,
      position_lon: p.longitude,
      // AeroAPI altitude is in hundreds of feet.
      position_altitude_ft: p.altitude != null
        ? Math.round(p.altitude * 100)
        : null,
      position_ground_speed_kt: p.groundspeed != null
        ? Math.round(p.groundspeed)
        : null,
      position_heading: p.heading != null ? Math.round(p.heading) : null,
      position_at: p.timestamp,
    };
  }

  /**
   * Nonstop flights from `origin` to `destination` (ICAO preferred) whose scheduled_out falls on
   * `date` (YYYY-MM-DD, UTC). Follows links.next up to `maxPages` pages. Dates outside the provider window (10 days back, 2 ahead) return [].
   */
  async searchRoute(
    origin: string,
    destination: string,
    date: string,
    maxPages = 2,
  ): Promise<AeroFlight[]> {
    const start = new Date(`${date}T00:00:00Z`);
    if (Number.isNaN(start.getTime())) return [];
    return await this.searchRouteWindow(
      origin,
      destination,
      start,
      new Date(start.getTime() + 86_400_000),
      maxPages,
    );
  }

  /**
   * Nonstop flights from `origin` to `destination` whose scheduled_out is in [start, end)
   * (start inclusive, end exclusive, as the provider defines them). The window is clipped to the
   * provider limits (10 days back, 2 ahead); an empty window returns [] without a call.
   * Follows links.next up to `maxPages` pages.
   */
  async searchRouteWindow(
    origin: string,
    destination: string,
    start: Date,
    end: Date,
    maxPages = 2,
  ): Promise<AeroFlight[]> {
    const now = this.now();
    const from = new Date(
      Math.max(start.getTime(), now.getTime() - 10 * 86_400_000),
    );
    const to = new Date(
      Math.min(end.getTime(), now.getTime() + 2 * 86_400_000),
    );
    if (!(from.getTime() < to.getTime())) return [];
    const q = new URLSearchParams({
      connection: "nonstop",
      start: from.toISOString(),
      end: to.toISOString(),
    });
    const items = await this.paged<AeroFullFlight>(
      "/airports/{id}/flights/to/{dest_id}",
      `/airports/${encodeURIComponent(origin)}/flights/to/${
        encodeURIComponent(destination)
      }`,
      "flights",
      maxPages,
      q,
    );
    const out: AeroFlight[] = [];
    for (const item of items) {
      const segs = asArray(item.segments);
      if (segs.length !== 1) continue; // nonstop only
      const t = segs[0].scheduled_out ? Date.parse(segs[0].scheduled_out) : NaN;
      if (t >= from.getTime() && t < to.getTime()) out.push(segs[0]);
    }
    return dedupeByFaFlightId(out);
  }

  /**
   * One list of an airport board. departures/arrivals are flights already done (filtered on
   * actual_off/actual_on, default last 24 h); scheduled_* are upcoming (default -2 h to +24 h).
   * Follows links.next up to `maxPages` pages; every page is one billed request.
   */
  async airportFlights(
    icao: string,
    kind: AirportListKind,
    maxPages = 1,
  ): Promise<AeroFlight[]> {
    return await this.paged<AeroFlight>(
      `/airports/{id}/flights/${kind}`,
      `/airports/${encodeURIComponent(icao)}/flights/${kind}`,
      kind,
      maxPages,
    );
  }

  /** Full board: done list then upcoming list, merged and deduped by fa_flight_id (done wins). */
  async boardFlights(
    icao: string,
    kind: "departures" | "arrivals",
    maxPages = 2,
  ): Promise<AeroFlight[]> {
    const upcoming: AirportListKind = kind === "departures"
      ? "scheduled_departures"
      : "scheduled_arrivals";
    const [done, next] = await Promise.all([
      this.airportFlights(icao, kind, maxPages),
      this.airportFlights(icao, upcoming, maxPages),
    ]);
    const seen = new Set<string>();
    const merged: AeroFlight[] = [];
    for (const f of [...done, ...next]) {
      if (seen.has(f.fa_flight_id)) continue;
      seen.add(f.fa_flight_id);
      merged.push(f);
    }
    return merged;
  }

  /**
   * Creates an alert for an ident. It fires for every flight with that ident in the window, so
   * pass the ICAO ident (ident_icao) and a one-day window. `start` and `end` are YYYY-MM-DD
   * dates in the departure airport's timezone (end inclusive). Returns the alert id.
   */
  async createAlert(
    ident: string,
    start: string,
    end: string,
  ): Promise<number> {
    const res = await this.request("/alerts", "/alerts", {
      method: "POST",
      body: JSON.stringify({
        ident,
        start,
        end,
        max_weekly: 1000,
        events: {
          arrival: true,
          departure: true,
          cancelled: true,
          diverted: true,
          filed: true,
          out: true,
          off: true,
          on: true,
          in: true,
        },
      }),
    });
    const location = res.headers.get("location");
    const fromHeader = location
      ? /\/alerts\/(\d+)/.exec(location)?.[1]
      : undefined;
    if (fromHeader) return Number(fromHeader);
    const body = await res.json().catch(() => null) as { id?: number } | null;
    if (typeof body?.id === "number") return body.id;
    throw new ApiError(
      "provider_unavailable",
      502,
      "Alert created without an id",
    );
  }

  async deleteAlert(alertId: number): Promise<void> {
    try {
      const res = await this.request("/alerts/{id}", `/alerts/${alertId}`, {
        method: "DELETE",
      });
      await res.body?.cancel();
    } catch (e) {
      if (e instanceof ApiError && e.code === "not_found") return; // already gone
      throw e;
    }
  }

  private async paged<T>(
    endpoint: string,
    path: string,
    key: string,
    maxPages: number,
    base?: URLSearchParams,
  ): Promise<T[]> {
    const out: T[] = [];
    let cursor: string | null = null;
    for (let page = 0; page < Math.max(1, maxPages); page++) {
      const q = new URLSearchParams(base);
      if (cursor) q.set("cursor", cursor);
      const body:
        & { links?: { next?: string | null } | null }
        & Record<string, unknown> = await this
          .get(endpoint, path, q);
      out.push(...asArray(body[key] as T[] | undefined));
      cursor = cursorOf(body.links?.next);
      if (!cursor) break;
    }
    return out;
  }

  private async get<T>(
    endpoint: string,
    path: string,
    query?: URLSearchParams,
  ): Promise<T> {
    const qs = query && [...query].length ? `?${query}` : "";
    const res = await this.request(endpoint, path + qs, { method: "GET" });
    try {
      return await res.json() as T;
    } catch {
      throw new ApiError(
        "provider_unavailable",
        502,
        "Provider returned invalid JSON",
      );
    }
  }

  private async request(
    endpoint: string,
    pathAndQuery: string,
    init: RequestInit,
  ): Promise<Response> {
    try {
      await this.onCall?.(endpoint);
    } catch (e) {
      // A counter outage must not block lookups.
      console.error(`usage counter failed for ${endpoint}`, e);
    }
    let res: Response;
    try {
      res = await this.fetchFn(AEROAPI_BASE + pathAndQuery, {
        ...init,
        signal: AbortSignal.timeout(this.timeoutMs),
        headers: {
          "x-apikey": this.key,
          accept: "application/json; charset=UTF-8",
          ...(init.body ? { "content-type": "application/json" } : {}),
        },
      });
    } catch (e) {
      console.error(
        `aeroapi network error on ${endpoint}`,
        (e as Error).name,
        (e as Error).message,
      );
      throw new ApiError("provider_unavailable", 502, "Provider unreachable");
    }
    if (res.ok) return res;
    await res.body?.cancel();
    if (res.status === 404) {
      throw new ApiError("not_found", 404, "Not found at provider");
    }
    if (res.status === 429) {
      throw new ApiError("rate_limited", 429, "Provider rate limit");
    }
    // 400/401/402/403 and 5xx: a bad request, key or plan problem looks like an outage to the
    // user; log it for us. Status and endpoint only, never the key.
    console.error(`aeroapi error status=${res.status} endpoint=${endpoint}`);
    throw new ApiError(
      "provider_unavailable",
      502,
      `Provider error ${res.status}`,
    );
  }
}

function asArray<T>(v: T[] | null | undefined): T[] {
  return Array.isArray(v) ? v : [];
}

/** links.next is a uri-reference such as "/airports/KAUS/flights/departures?cursor=abc". */
function cursorOf(next: string | null | undefined): string | null {
  if (!next) return null;
  try {
    return new URL(next, AEROAPI_BASE).searchParams.get("cursor");
  } catch {
    return null;
  }
}

/**
 * A diverted flight comes back as two rows with the same fa_flight_id. Keep one per id:
 * the diverted row if there is one, otherwise the last row.
 */
export function dedupeByFaFlightId(flights: AeroFlight[]): AeroFlight[] {
  const byId = new Map<string, AeroFlight>();
  for (const f of flights) {
    const prev = byId.get(f.fa_flight_id);
    if (prev?.diverted && !f.diverted) continue;
    byId.set(f.fa_flight_id, f);
  }
  return [...byId.values()];
}

function statusOf(f: AeroFlight): FlightRow["status"] {
  if (f.cancelled) return "canceled";
  if (f.diverted) return "diverted";
  if (f.actual_in) return "arrived";
  if (f.actual_on) return "landed";
  if (f.actual_off) return "en_route";
  if (f.actual_out) return "departed";
  const s = (f.status ?? "").toLowerCase();
  if (s.startsWith("arrived")) return "arrived";
  if (s.startsWith("landed")) return "landed";
  if (s.startsWith("en route")) return "en_route";
  if (s.startsWith("departed")) return "departed";
  if (s.startsWith("cancel")) return "canceled";
  if (s.startsWith("diverted")) return "diverted";
  if (s.startsWith("scheduled")) return "scheduled";
  return "unknown";
}

/** Position columns are not set here: /flights/{ident} carries no position. */
export function toFlightRow(f: AeroFlight, now: Date = new Date()): FlightRow {
  return {
    provider_id: f.fa_flight_id,
    ident: f.ident_iata ?? f.ident,
    operator: f.operator_iata ?? f.operator ?? null,
    origin_icao: f.origin?.code_icao ?? null,
    origin_iata: f.origin?.code_iata ?? null,
    destination_icao: f.destination?.code_icao ?? null,
    destination_iata: f.destination?.code_iata ?? null,
    scheduled_out: f.scheduled_out ?? null,
    scheduled_in: f.scheduled_in ?? null,
    estimated_out: f.estimated_out ?? null,
    estimated_in: f.estimated_in ?? null,
    actual_out: f.actual_out ?? null,
    actual_off: f.actual_off ?? null,
    actual_on: f.actual_on ?? null,
    actual_in: f.actual_in ?? null,
    gate_origin: f.gate_origin ?? null,
    gate_destination: f.gate_destination ?? null,
    terminal_origin: f.terminal_origin ?? null,
    terminal_destination: f.terminal_destination ?? null,
    baggage_belt: f.baggage_claim ?? null,
    aircraft_type: f.aircraft_type ?? null,
    registration: f.registration ?? null,
    status: statusOf(f),
    updated_at: now.toISOString(),
  };
}

/** Rows for one upsert batch: one per provider_id, so ON CONFLICT never hits a row twice. */
export function toFlightRows(
  flights: AeroFlight[],
  now: Date = new Date(),
): FlightRow[] {
  return dedupeByFaFlightId(flights).map((f) => toFlightRow(f, now));
}
