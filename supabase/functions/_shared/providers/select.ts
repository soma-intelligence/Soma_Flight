// Which provider answers each capability, from function secrets:
//   STATUS_PROVIDER    aeroapi (default) | aviationstack | flightlabs | none
//   BOARD_PROVIDER     aeroapi (default) | aviationstack | flightlabs | none
//   POSITION_PROVIDER  aeroapi (default) | aviationstack | flightlabs | opensky | none
// Keys: AEROAPI_KEY, AVIATIONSTACK_KEY, FLIGHTLABS_KEY, OPENSKY_CLIENT_ID + OPENSKY_CLIENT_SECRET
// (OpenSky works without them, anonymously). Unset selection secrets keep today's AeroAPI behaviour.
// A value a capability does not support (opensky for status, a typo) fails closed: it selects none
// and logs, so no request goes to a provider nobody chose.
//
// Providers are built on first use, so a function starts and serves its other paths without keys; a
// call to a selected provider whose key is missing throws provider_unavailable (503).
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { ApiError } from "../errors.ts";
import { lazyAeroApi } from "../limits.ts";
import { AeroApiProvider } from "./aeroapi.ts";
import { Aviationstack } from "./aviationstack.ts";
import { FlightLabs } from "./flightlabs.ts";
import type { Fetch } from "./http.ts";
import { OpenSky } from "./opensky.ts";
import {
  type FREE_TIER,
  pollShare,
  type QuotaCharge,
  quotaCounter,
  quotaRule,
} from "./quota.ts";
import type {
  AircraftProvider,
  BoardProvider,
  PositionProvider,
  ProviderName,
  StatusProvider,
} from "./types.ts";

export type Env = (name: string) => string | undefined;
export type Capability = "status" | "board" | "position";

export const SELECTION_ENV: Record<Capability, string> = {
  status: "STATUS_PROVIDER",
  board: "BOARD_PROVIDER",
  position: "POSITION_PROVIDER",
};

/** What each capability accepts. OpenSky has no schedules, gates or live boards: position only. */
export const SUPPORTED: Record<Capability, readonly ProviderName[]> = {
  status: ["aeroapi", "aviationstack", "flightlabs", "none"],
  board: ["aeroapi", "aviationstack", "flightlabs", "none"],
  position: ["aeroapi", "aviationstack", "flightlabs", "opensky", "none"],
};

/** The provider chosen for a capability: aeroapi when unset, none (logged) when unsupported. */
export function chosen(cap: Capability, env: Env): ProviderName {
  const raw = (env(SELECTION_ENV[cap]) ?? "").trim().toLowerCase();
  if (raw === "") return "aeroapi";
  if ((SUPPORTED[cap] as readonly string[]).includes(raw)) {
    return raw as ProviderName;
  }
  console.error(
    `${SELECTION_ENV[cap]}=${raw.slice(0, 20)} is not supported, using none`,
  );
  return "none";
}

/** True unless SUPABASE_URL points at a local stack. Unknown counts as production (fail closed). */
export function isProduction(env: Env): boolean {
  const url = env("SUPABASE_URL");
  if (!url) return true;
  try {
    const host = new URL(url).hostname;
    return ![
      "localhost",
      "127.0.0.1",
      "::1",
      "[::1]",
      "kong",
      "host.docker.internal",
    ]
      .includes(host) && !host.endsWith(".localhost");
  } catch {
    return true;
  }
}

/** Answers "nothing configured": status and board refuse, position and aircraft know nothing. */
export class NoProvider
  implements StatusProvider, BoardProvider, PositionProvider, AircraftProvider {
  readonly name = "none" as const;
  private refusal() {
    return Promise.reject(
      new ApiError(
        "provider_unavailable",
        503,
        "No flight data provider is configured",
      ),
    );
  }
  flightsByIdent(): Promise<never> {
    return this.refusal();
  }
  searchRouteWindow(): Promise<never> {
    return this.refusal();
  }
  /** The poller treats none as "nothing to poll", never as a failure. */
  flightStatus() {
    return Promise.resolve(null);
  }
  boardFlights(): Promise<never> {
    return this.refusal();
  }
  position() {
    return Promise.resolve(null);
  }
  aircraft() {
    return Promise.resolve(null);
  }
}

export interface SelectOptions {
  env?: Env;
  fetchFn?: Fetch;
  now?: () => Date;
  /** The polling refresh: quota ceilings shrink to POLL_QUOTA_SHARE of each allowance. */
  forPoll?: boolean;
  /** Replaces the database quota counter (tests). */
  charge?: (provider: keyof typeof FREE_TIER, limit: number) => QuotaCharge;
}

export interface Providers {
  names: Record<Capability, ProviderName>;
  status: StatusProvider;
  board: BoardProvider;
  position: PositionProvider;
  /** Registration lookup, from the position provider (the one that sees airframes). */
  aircraft: AircraftProvider;
  /** Builds (or returns) the adapter for one provider, whatever is selected. */
  get(
    name: ProviderName,
  ): StatusProvider & BoardProvider & PositionProvider & AircraftProvider;
}

type Any = StatusProvider & BoardProvider & PositionProvider & AircraftProvider;

/**
 * Wraps a factory so the adapter is built on the first method call. When it cannot be built (a
 * missing key, a refused base URL), every method returns a rejected promise with a 503, so callers
 * handle it like any provider outage.
 */
function lazy(name: ProviderName, build: () => Any): Any {
  let inst: Any | undefined;
  return new Proxy({ name } as Any, {
    get(_t, prop) {
      if (prop === "name") return name;
      if (typeof prop === "symbol" || prop === "then") return undefined;
      if (!inst) {
        try {
          inst = build();
        } catch (e) {
          console.error(`${name} provider unavailable`, (e as Error).message);
          const err = e instanceof ApiError ? e : new ApiError(
            "provider_unavailable",
            503,
            `${name} is not configured`,
          );
          return () => Promise.reject(err);
        }
      }
      const v = Reflect.get(inst, prop);
      return typeof v === "function" ? v.bind(inst) : v;
    },
  });
}

/** ICAO to IATA from the airports table, for FlightLabs' timetable. */
function iataResolver(db: SupabaseClient) {
  return async (icao: string): Promise<string | null> => {
    const { data, error } = await db.from("airports").select("iata").eq(
      "icao",
      icao,
    )
      .maybeSingle();
    if (error) throw new Error(`airport lookup failed: ${error.message}`);
    return (data?.iata as string | null) ?? null;
  };
}

export function selectProviders(
  db: SupabaseClient,
  opts: SelectOptions = {},
): Providers {
  const env: Env = opts.env ?? ((n) => Deno.env.get(n));
  const fetchFn = opts.fetchFn ?? fetch;
  const now = opts.now ?? (() => new Date());
  const share = opts.forPoll ? pollShare(env) : 1;
  const charge = (p: keyof typeof FREE_TIER): QuotaCharge => {
    const rule = quotaRule(p, env);
    const limit = Math.floor(rule.limit * share);
    return opts.charge
      ? opts.charge(p, limit)
      : quotaCounter(db, p, rule, now, limit);
  };
  const key = (n: string) => {
    const v = env(n);
    if (!v) throw new Error(`missing env ${n}`);
    return v;
  };

  const cache = new Map<ProviderName, Any>();
  const get = (name: ProviderName): Any => {
    const hit = cache.get(name);
    if (hit) return hit;
    let made: Any;
    switch (name) {
      case "aeroapi":
        made = new AeroApiProvider(lazyAeroApi(db), now) as Any;
        break;
      case "aviationstack":
        made = lazy(name, () =>
          new Aviationstack({
            key: key("AVIATIONSTACK_KEY"),
            baseUrl: env("AVIATIONSTACK_BASE_URL") || undefined,
            allowHttp: env("AVIATIONSTACK_ALLOW_HTTP") === "true",
            production: isProduction(env),
            times: env("AVIATIONSTACK_TIMES") === "utc" ? "utc" : "local",
            fetchFn,
            charge: charge("aviationstack"),
            now,
          }));
        break;
      case "flightlabs":
        made = lazy(name, () =>
          new FlightLabs({
            key: key("FLIGHTLABS_KEY"),
            baseUrl: env("FLIGHTLABS_BASE_URL") || undefined,
            fetchFn,
            charge: charge("flightlabs"),
            now,
            iataOf: iataResolver(db),
          }));
        break;
      case "opensky":
        made = lazy(name, () => {
          const os = new OpenSky({
            clientId: env("OPENSKY_CLIENT_ID") || undefined,
            clientSecret: env("OPENSKY_CLIENT_SECRET") || undefined,
            fetchFn,
            charge: charge("opensky"),
            now,
          });
          // OpenSky has no status or board: the methods exist only so the type is uniform.
          const none = new NoProvider();
          return Object.assign(os, {
            flightsByIdent: none.flightsByIdent.bind(none),
            searchRouteWindow: none.searchRouteWindow.bind(none),
            flightStatus: none.flightStatus.bind(none),
            boardFlights: none.boardFlights.bind(none),
          }) as unknown as Any;
        });
        break;
      default:
        made = new NoProvider();
    }
    cache.set(name, made);
    return made;
  };

  const names = {
    status: chosen("status", env),
    board: chosen("board", env),
    position: chosen("position", env),
  };
  return {
    names,
    status: get(names.status),
    board: get(names.board),
    position: get(names.position),
    aircraft: get(names.position),
    get,
  };
}
