// The FlightAware AeroAPI adapter: the existing client (../aeroapi.ts) behind the provider
// interfaces. Calls, prices and the spend cap are unchanged; only the shape handed back is the
// provider layer's (rows from toFlightRow, plus the origin timezone).
import {
  type AeroApi,
  type AeroFlight,
  dedupeByFaFlightId,
  toFlightRow,
} from "../aeroapi.ts";
import type {
  AircraftInfo,
  AircraftProvider,
  BoardProvider,
  FlightRef,
  PositionProvider,
  PositionQuery,
  ProviderFlight,
  StatusProvider,
} from "./types.ts";

export type AeroClient = Partial<
  Pick<
    AeroApi,
    | "flightsByIdent"
    | "searchRouteWindow"
    | "flightById"
    | "boardFlights"
    | "flightPosition"
  >
>;

/** AeroAPI flights as provider rows, one per fa_flight_id (a diverted flight comes back twice). */
export function aeroRows(flights: AeroFlight[], now: Date): ProviderFlight[] {
  return dedupeByFaFlightId(flights).map((f) => ({
    ...toFlightRow(f, now),
    origin_tz: f.origin?.timezone ?? null,
  }));
}

function need<T>(fn: T | undefined, what: string): T {
  if (!fn) throw new Error(`AeroAPI client has no ${what}`);
  return fn;
}

export class AeroApiProvider
  implements StatusProvider, BoardProvider, PositionProvider, AircraftProvider {
  readonly name = "aeroapi" as const;

  constructor(
    private readonly aero: AeroClient,
    private readonly now: () => Date = () => new Date(),
  ) {}

  async flightsByIdent(ident: string, from: Date, to: Date) {
    const f = need(this.aero.flightsByIdent, "flightsByIdent").bind(this.aero);
    return aeroRows(
      await f(ident, from.toISOString(), to.toISOString()),
      this.now(),
    );
  }

  async searchRouteWindow(
    origin: string,
    destination: string,
    start: Date,
    end: Date,
  ) {
    const f = need(this.aero.searchRouteWindow, "searchRouteWindow").bind(
      this.aero,
    );
    return aeroRows(await f(origin, destination, start, end), this.now());
  }

  /** By fa_flight_id: AeroAPI rows keep their own id. The webhook normally makes this unneeded. */
  async flightStatus(ref: FlightRef) {
    const f = need(this.aero.flightById, "flightById").bind(this.aero);
    const got = await f(ref.provider_id);
    return got ? aeroRows([got], this.now())[0] : null;
  }

  async boardFlights(icao: string, kind: "departures" | "arrivals") {
    const f = need(this.aero.boardFlights, "boardFlights").bind(this.aero);
    // Not deduped here: boardRowsFrom keeps the first row per id, as the board always did.
    const now = this.now();
    return (await f(icao, kind)).map((x) => toFlightRow(x, now));
  }

  async position(q: PositionQuery) {
    const f = need(this.aero.flightPosition, "flightPosition").bind(this.aero);
    return await f(q.provider_id);
  }

  /** Registration and type of the latest flight under this callsign ($0.005, one /flights call). */
  async aircraft(
    q: { callsign?: string | null },
  ): Promise<AircraftInfo | null> {
    if (!q.callsign) return null;
    const f = need(this.aero.flightsByIdent, "flightsByIdent").bind(this.aero);
    const rows = await f(q.callsign);
    const hit = rows.find((r) => r.registration);
    if (!hit) return null;
    return {
      icao24: null,
      registration: hit.registration,
      aircraft_type: hit.aircraft_type,
      operator: hit.operator_icao ?? hit.operator ?? null,
      country: null,
    };
  }
}
