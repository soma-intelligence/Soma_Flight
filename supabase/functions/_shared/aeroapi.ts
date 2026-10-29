// FlightAware AeroAPI v4 client. Pure fetch, injectable for tests.
import { ApiError } from "./errors.ts";
import type { AeroFlight, FlightRow } from "./aeroapi_types.ts";

export type { AeroFlight, FlightRow } from "./aeroapi_types.ts";

export const AEROAPI_BASE = "https://aeroapi.flightaware.com/aeroapi";

/**
 * Estimated cost in USD per result set, keyed by endpoint template (docs/provider-check.md,
 * checked 2026-10-28). Alert management is free; alert deliveries are billed on the webhook side.
 */
export const ENDPOINT_COST: Record<string, number> = {
  "/flights/{ident}": 0.005,
  "/flights/search": 0.05,
  "/airports/{id}/flights/departures": 0.005,
  "/airports/{id}/flights/arrivals": 0.005,
  "/alerts": 0,
  "/alerts/{id}": 0,
};

export function estimateCost(endpoint: string): number {
  return ENDPOINT_COST[endpoint] ?? 0;
}

type Fetch = typeof fetch;

export class AeroApi {
  constructor(
    private readonly key: string,
    private readonly fetchFn: Fetch = fetch,
    /** Called once per request with the endpoint template, e.g. "/flights/{ident}". */
    private readonly onCall?: (endpoint: string) => Promise<void>,
  ) {}

  async flightsByIdent(ident: string, start?: string, end?: string): Promise<AeroFlight[]> {
    const q = new URLSearchParams();
    if (start) q.set("start", start);
    if (end) q.set("end", end);
    const body = await this.get<{ flights?: AeroFlight[] }>(
      "/flights/{ident}",
      `/flights/${encodeURIComponent(ident)}`,
      q,
    );
    return body.flights ?? [];
  }

  /** Looks up one flight by fa_flight_id. Null when the provider has no such flight. */
  async flightById(faFlightId: string): Promise<AeroFlight | null> {
    const q = new URLSearchParams({ ident_type: "fa_flight_id" });
    try {
      const body = await this.get<{ flights?: AeroFlight[] }>(
        "/flights/{ident}",
        `/flights/${encodeURIComponent(faFlightId)}`,
        q,
      );
      return body.flights?.[0] ?? null;
    } catch (e) {
      if (e instanceof ApiError && e.code === "not_found") return null;
      throw e;
    }
  }

  /** Flights between two airports (ICAO or IATA codes) whose scheduled_out falls on `date` (YYYY-MM-DD, UTC). */
  async searchRoute(origin: string, destination: string, date: string): Promise<AeroFlight[]> {
    const q = new URLSearchParams({ query: `-origin ${origin} -destination ${destination}` });
    const body = await this.get<{ flights?: AeroFlight[] }>("/flights/search", "/flights/search", q);
    return (body.flights ?? []).filter((f) => (f.scheduled_out ?? "").startsWith(date));
  }

  async airportFlights(icao: string, kind: "departures" | "arrivals"): Promise<AeroFlight[]> {
    const body = await this.get<{ departures?: AeroFlight[]; arrivals?: AeroFlight[] }>(
      `/airports/{id}/flights/${kind}`,
      `/airports/${encodeURIComponent(icao)}/flights/${kind}`,
    );
    return body[kind] ?? [];
  }

  /** Creates a per-flight alert. Returns the alert id. Delivery target is configured once on the account. */
  async createAlert(ident: string, start: string, end: string): Promise<number> {
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
    const fromHeader = location ? /\/alerts\/(\d+)/.exec(location)?.[1] : undefined;
    if (fromHeader) return Number(fromHeader);
    const body = await res.json().catch(() => null) as { id?: number } | null;
    if (typeof body?.id === "number") return body.id;
    throw new ApiError("provider_unavailable", 502, "Alert created without an id");
  }

  async deleteAlert(alertId: number): Promise<void> {
    try {
      await this.request("/alerts/{id}", `/alerts/${alertId}`, { method: "DELETE" });
    } catch (e) {
      if (e instanceof ApiError && e.code === "not_found") return; // already gone
      throw e;
    }
  }

  private async get<T>(endpoint: string, path: string, query?: URLSearchParams): Promise<T> {
    const qs = query && [...query].length ? `?${query}` : "";
    const res = await this.request(endpoint, path + qs, { method: "GET" });
    try {
      return await res.json() as T;
    } catch {
      throw new ApiError("provider_unavailable", 502, "Provider returned invalid JSON");
    }
  }

  private async request(endpoint: string, pathAndQuery: string, init: RequestInit): Promise<Response> {
    await this.onCall?.(endpoint);
    let res: Response;
    try {
      res = await this.fetchFn(AEROAPI_BASE + pathAndQuery, {
        ...init,
        headers: {
          "x-apikey": this.key,
          accept: "application/json; charset=UTF-8",
          ...(init.body ? { "content-type": "application/json" } : {}),
        },
      });
    } catch (e) {
      throw new ApiError("provider_unavailable", 502, `Provider unreachable: ${(e as Error).message}`);
    }
    if (res.ok) return res;
    await res.body?.cancel();
    if (res.status === 404) throw new ApiError("not_found", 404, "Not found at provider");
    if (res.status === 429) throw new ApiError("rate_limited", 429, "Provider rate limit");
    throw new ApiError("provider_unavailable", 502, `Provider error ${res.status}`);
  }
}

function statusOf(f: AeroFlight): FlightRow["status"] {
  if (f.cancelled) return "canceled";
  if (f.diverted) return "diverted";
  const s = (f.status ?? "").toLowerCase();
  if (s.startsWith("arrived") || f.actual_in) return "arrived";
  if (s.startsWith("landed") || f.actual_on) return "landed";
  if (s.startsWith("en route") || f.actual_off) return "en_route";
  if (s.startsWith("departed") || f.actual_out) return "departed";
  if (s.startsWith("scheduled")) return "scheduled";
  return "unknown";
}

export function toFlightRow(f: AeroFlight): FlightRow {
  const p = f.last_position;
  return {
    provider_id: f.fa_flight_id,
    ident: f.ident_iata ?? f.ident,
    operator: f.operator_iata ?? f.operator,
    origin_icao: f.origin?.code_icao ?? null,
    origin_iata: f.origin?.code_iata ?? null,
    destination_icao: f.destination?.code_icao ?? null,
    destination_iata: f.destination?.code_iata ?? null,
    scheduled_out: f.scheduled_out,
    scheduled_in: f.scheduled_in,
    estimated_out: f.estimated_out,
    estimated_in: f.estimated_in,
    actual_out: f.actual_out,
    actual_off: f.actual_off,
    actual_on: f.actual_on,
    actual_in: f.actual_in,
    gate_origin: f.gate_origin,
    gate_destination: f.gate_destination,
    terminal_origin: f.terminal_origin,
    terminal_destination: f.terminal_destination,
    baggage_belt: f.baggage_claim,
    aircraft_type: f.aircraft_type,
    registration: f.registration,
    status: statusOf(f),
    position_lat: p?.latitude ?? null,
    position_lon: p?.longitude ?? null,
    // AeroAPI altitude is in hundreds of feet.
    position_altitude_ft: p?.altitude != null ? Math.round(p.altitude * 100) : null,
    position_ground_speed_kt: p?.groundspeed ?? null,
    position_heading: p?.heading ?? null,
    position_at: p?.timestamp ?? null,
    updated_at: new Date().toISOString(),
  };
}
