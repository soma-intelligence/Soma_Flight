// OpenSky Network REST adapter: live positions from state vectors (GET /states/all), the airframe
// seen under a callsign, and an airframe's past legs (GET /flights/aircraft). Checked 2026-10-31
// against openskynetwork.github.io/opensky-api/rest.html and real anonymous answers (the fixtures).
//
// Auth: OAuth2 client credentials (OPENSKY_CLIENT_ID, OPENSKY_CLIENT_SECRET); basic auth is no
// longer accepted. Without them, or when the token endpoint fails, calls go out anonymous (400
// credits a day per IP, only the latest state vectors). Tokens live 30 minutes and are reused until a
// minute before that.
//
// Credits (charged against the quota before each call): a state vector query costs 1 credit for a
// box of up to 25 square degrees and 4 for a query by icao24 alone (seen on the live API: the
// documentation's "serial-only = 1" is for /states/own). /flights costs 4 a day of range or more.
//
// Terms: OpenSky requires a written licence for any for-profit entity and for any operational use of
// the REST API in a live product (docs/free-providers.md). Keep POSITION_PROVIDER off opensky in
// production until that licence is signed.
import { ApiError } from "../errors.ts";
import { type Fetch, fetchJson } from "./http.ts";
import type { QuotaCharge } from "./quota.ts";
import type {
  AircraftInfo,
  AircraftProvider,
  PositionProvider,
  PositionQuery,
  PositionRow,
} from "./types.ts";

export const OPENSKY_API = "https://opensky-network.org/api";
export const OPENSKY_TOKEN_URL =
  "https://auth.opensky-network.org/auth/realms/opensky-network/protocol/openid-connect/token";

/** Half the side of the search box around a hint point: 5 x 5 degrees = 25 sq deg = 1 credit. */
export const BOX_HALF_DEG = 2.5;
export const CREDITS_BOX = 1;
export const CREDITS_ICAO24 = 4;
export const CREDITS_FLIGHTS = 4;

/** A state vector, as the API sends it: an array indexed by field. */
export type StateVector = [
  string, // 0 icao24
  string | null, // 1 callsign
  string, // 2 origin_country
  number | null, // 3 time_position
  number, // 4 last_contact
  number | null, // 5 longitude
  number | null, // 6 latitude
  number | null, // 7 baro_altitude (m)
  boolean, // 8 on_ground
  number | null, // 9 velocity (m/s)
  number | null, // 10 true_track (deg)
  number | null, // 11 vertical_rate
  number[] | null, // 12 sensors
  number | null, // 13 geo_altitude (m)
  string | null, // 14 squawk
  boolean, // 15 spi
  number, // 16 position_source
  number?, // 17 category (extended=1 only)
];

export interface OpenSkyFlight {
  icao24: string;
  firstSeen: number;
  estDepartureAirport: string | null;
  lastSeen: number;
  estArrivalAirport: string | null;
  callsign: string | null;
}

export interface OpenSkyOptions {
  clientId?: string;
  clientSecret?: string;
  fetchFn?: Fetch;
  charge: QuotaCharge;
  now?: () => Date;
  apiBase?: string;
  tokenUrl?: string;
}

interface Token {
  value: string;
  expiresAt: number;
}

/** A state vector as our position columns. Null without a position fix. */
export function stateToPosition(s: StateVector): PositionRow | null {
  const lon = s[5], lat = s[6];
  if (typeof lat !== "number" || typeof lon !== "number") return null;
  const at = s[3] ?? s[4];
  if (typeof at !== "number") return null;
  const alt = s[7] ?? s[13];
  return {
    position_lat: lat,
    position_lon: lon,
    // On the ground the barometric altitude is null: it stays null rather than becoming 0.
    position_altitude_ft: typeof alt === "number"
      ? Math.round(alt * 3.28084)
      : null,
    position_ground_speed_kt: typeof s[9] === "number"
      ? Math.round(s[9] * 1.943844)
      : null,
    position_heading: typeof s[10] === "number" ? Math.round(s[10]) : null,
    position_at: new Date(at * 1000).toISOString(),
  };
}

const trimCallsign = (c: string | null) => (c ?? "").trim().toUpperCase();

export class OpenSky implements PositionProvider, AircraftProvider {
  readonly name = "opensky" as const;
  private readonly fetchFn: Fetch;
  private readonly now: () => Date;
  private readonly api: string;
  private readonly tokenUrl: string;
  private token: Token | null = null;

  constructor(private readonly opts: OpenSkyOptions) {
    this.fetchFn = opts.fetchFn ?? fetch;
    this.now = opts.now ?? (() => new Date());
    this.api = opts.apiBase ?? OPENSKY_API;
    this.tokenUrl = opts.tokenUrl ?? OPENSKY_TOKEN_URL;
  }

  get authenticated(): boolean {
    return !!(this.opts.clientId && this.opts.clientSecret);
  }

  /** A bearer token, or null for an anonymous call (no credentials, or the token endpoint failed). */
  private async bearer(force = false): Promise<string | null> {
    if (!this.authenticated) return null;
    const t = this.now().getTime();
    if (!force && this.token && this.token.expiresAt - 60_000 > t) {
      return this.token.value;
    }
    try {
      const body = await fetchJson<
        { access_token?: string; expires_in?: number }
      >(
        this.fetchFn,
        "opensky token",
        this.tokenUrl,
        {
          method: "POST",
          headers: { "content-type": "application/x-www-form-urlencoded" },
          body: new URLSearchParams({
            grant_type: "client_credentials",
            client_id: this.opts.clientId!,
            client_secret: this.opts.clientSecret!,
          }).toString(),
        },
      );
      if (typeof body.access_token !== "string") {
        throw new Error("no access_token");
      }
      const life = typeof body.expires_in === "number" ? body.expires_in : 1800;
      this.token = { value: body.access_token, expiresAt: t + life * 1000 };
      return this.token.value;
    } catch (e) {
      console.error(
        "opensky token failed, calling anonymously",
        (e as Error).message,
      );
      this.token = null;
      return null;
    }
  }

  /** One charged GET. A 401 with a token gets one retry with a fresh token. */
  private async get<T>(
    path: string,
    q: URLSearchParams,
    credits: number,
  ): Promise<T> {
    await this.opts.charge(credits);
    const url = `${this.api}${path}?${q}`;
    const call = async (token: string | null) =>
      await fetchJson<T>(
        this.fetchFn,
        `opensky ${path}`,
        url,
        token ? { headers: { authorization: `Bearer ${token}` } } : {},
      );
    const token = await this.bearer();
    try {
      return await call(token);
    } catch (e) {
      // fetchJson maps 401 to provider_unavailable 502; only a token can be the cause.
      if (
        token && e instanceof ApiError && e.message === "Provider error 401"
      ) {
        return await call(await this.bearer(true));
      }
      throw e;
    }
  }

  /** State vectors by icao24 (4 credits) or inside a 25 sq deg box around a point (1 credit). */
  async states(
    q: { icao24?: string | null; near?: { lat: number; lon: number } | null },
  ) {
    const p = new URLSearchParams();
    let credits: number;
    if (q.icao24) {
      p.set("icao24", q.icao24.toLowerCase());
      credits = CREDITS_ICAO24;
    } else if (q.near) {
      const lat = Math.min(90, Math.max(-90, q.near.lat));
      p.set("lamin", String(Math.max(-90, lat - BOX_HALF_DEG)));
      p.set("lamax", String(Math.min(90, lat + BOX_HALF_DEG)));
      p.set("lomin", String(Math.max(-180, q.near.lon - BOX_HALF_DEG)));
      p.set("lomax", String(Math.min(180, q.near.lon + BOX_HALF_DEG)));
      credits = CREDITS_BOX;
    } else {
      return [] as StateVector[];
    }
    const body = await this.get<{ states?: StateVector[] | null }>(
      "/states/all",
      p,
      credits,
    );
    return Array.isArray(body.states) ? body.states : [];
  }

  /**
   * The state vector for a flight: by icao24 when known, else the aircraft with this callsign
   * inside the box around `near`. OpenSky has no callsign filter, so without either nothing is asked.
   */
  private async find(
    q: {
      icao24?: string | null;
      callsign?: string | null;
      near?: { lat: number; lon: number } | null;
    },
  ) {
    const want = trimCallsign(q.callsign ?? null);
    if (q.icao24) {
      return (await this.states({ icao24: q.icao24 }))[0] ?? null;
    }
    if (!want || !q.near) return null;
    return (await this.states({ near: q.near })).find((s) =>
      trimCallsign(s[1]) === want
    ) ?? null;
  }

  async position(q: PositionQuery): Promise<PositionRow | null> {
    const s = await this.find(q);
    return s ? stateToPosition(s) : null;
  }

  /**
   * What OpenSky says about an airframe: its icao24 and country of registration. The registration
   * and type lived in the aircraft metadata API, which answers 410 Gone since 2025, and in a database
   * file under the same licence terms: they stay null.
   */
  async aircraft(
    q: {
      icao24?: string | null;
      callsign?: string | null;
      near?: { lat: number; lon: number } | null;
    },
  ): Promise<AircraftInfo | null> {
    const s = await this.find(q);
    if (!s) return null;
    return {
      icao24: s[0],
      registration: null,
      aircraft_type: null,
      operator: null,
      country: s[2] || null,
    };
  }

  /**
   * Legs of an airframe in [begin, end] (at most 2 days), with OpenSky's estimated airports. Needs an
   * account (anonymous calls answer 403) and is filled in a nightly batch: only yesterday and older.
   */
  async flightsByAircraft(
    icao24: string,
    begin: Date,
    end: Date,
  ): Promise<OpenSkyFlight[]> {
    if (!this.authenticated) {
      throw new ApiError(
        "provider_unavailable",
        503,
        "OpenSky flights need an account",
      );
    }
    const b = Math.floor(begin.getTime() / 1000),
      e = Math.floor(end.getTime() / 1000);
    if (!(b < e) || e - b > 2 * 86_400) return [];
    let rows: OpenSkyFlight[];
    try {
      rows = await this.get<OpenSkyFlight[]>(
        "/flights/aircraft",
        new URLSearchParams({
          icao24: icao24.toLowerCase(),
          begin: String(b),
          end: String(e),
        }),
        CREDITS_FLIGHTS,
      );
    } catch (err) {
      if (err instanceof ApiError && err.code === "not_found") return [];
      throw err;
    }
    return Array.isArray(rows) ? rows : [];
  }
}
