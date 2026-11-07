import { assert, assertEquals } from "jsr:@std/assert@1";
import { AeroApi, type AeroSearchFlight } from "../_shared/aeroapi.ts";
import { ApiError } from "../_shared/errors.ts";
import { fakeVerifier } from "../_shared/test_util.ts";
import {
  boxAround,
  CACHE_TTL_MS,
  type Cached,
  cacheKey,
  type Deps,
  GRID_DEG,
  handler,
  MAX_PAGES,
  MAX_RADIUS_KM,
  type RadarCache,
  toRadarFlight,
} from "./handler.ts";

const NOW = new Date("2026-11-07T18:00:00Z");

function flight(over: Partial<AeroSearchFlight> = {}): AeroSearchFlight {
  return {
    fa_flight_id: "UAL1-1",
    ident: "UAL1",
    ident_iata: "UA1",
    operator_iata: "UA",
    aircraft_type: "B789",
    origin: {
      code: "KSFO",
      code_icao: "KSFO",
      code_iata: "SFO",
      timezone: null,
    },
    destination: {
      code: "EGLL",
      code_icao: "EGLL",
      code_iata: "LHR",
      timezone: null,
    },
    last_position: {
      altitude: 350,
      groundspeed: 460.4,
      heading: 361,
      latitude: 37.71234567,
      longitude: -122.1,
      timestamp: "2026-11-07T17:59:30Z",
    },
    ...over,
  };
}

function memoryCache(seed?: Record<string, Cached>) {
  const rows = new Map(Object.entries(seed ?? {}));
  const cache: RadarCache = {
    get: (k) => Promise.resolve(rows.get(k) ?? null),
    put: (k, v) => {
      rows.set(k, v);
      return Promise.resolve();
    },
  };
  return { cache, rows };
}

function deps(over: Partial<Deps> & { calls?: { n: number } } = {}): Deps {
  const calls = over.calls ?? { n: 0 };
  return {
    aero: {
      searchArea: () => {
        calls.n++;
        return Promise.resolve({ flights: [flight()], more: false });
      },
    },
    cache: memoryCache().cache,
    enabled: () => true,
    hasKey: () => true,
    verifier: fakeVerifier,
    rate: () => Promise.resolve(),
    now: () => NOW,
    ...over,
  };
}

const get = (query: string, token: string | null = "user-1") =>
  new Request(`http://localhost/nearby-flights?${query}`, {
    headers: token ? { authorization: `Bearer ${token}` } : {},
  });

Deno.test("off or no key: 503 provider_unavailable before auth, no provider call", async () => {
  for (
    const d of [
      deps({ enabled: () => false }),
      deps({ hasKey: () => false }),
    ]
  ) {
    const res = await handler(get("lat=37&lon=-122", null), d);
    assertEquals(res.status, 503);
    assertEquals((await res.json()).error.code, "provider_unavailable");
  }
});

Deno.test("needs a signed-in user and GET", async () => {
  assertEquals(
    (await handler(get("lat=37&lon=-122", null), deps())).status,
    401,
  );
  assertEquals(
    (await handler(get("lat=37&lon=-122", "bad"), deps())).status,
    401,
  );
  const post = new Request("http://localhost/nearby-flights?lat=1&lon=1", {
    method: "POST",
    headers: { authorization: "Bearer u" },
  });
  assertEquals((await handler(post, deps())).status, 405);
});

Deno.test("rate limit refusal is a 429 and nothing is fetched", async () => {
  const calls = { n: 0 };
  const res = await handler(
    get("lat=37&lon=-122"),
    deps({
      calls,
      rate: () => Promise.reject(new ApiError("rate_limited", 429)),
    }),
  );
  assertEquals(res.status, 429);
  assertEquals(calls.n, 0);
});

Deno.test("bad coordinates are a 400", async () => {
  for (
    const q of ["", "lat=37", "lat=x&lon=1", "lat=91&lon=0", "lat=0&lon=181"]
  ) {
    const res = await handler(get(q), deps());
    assertEquals(res.status, 400, q);
  }
});

Deno.test("answer shape, snapped box, airborne only, cached for 60 s", async () => {
  const calls = { n: 0 };
  const { cache } = memoryCache();
  const d = deps({
    calls,
    cache,
    aero: {
      searchArea: () => {
        calls.n++;
        return Promise.resolve({
          flights: [
            flight(),
            flight({
              fa_flight_id: "TAXI-1",
              ident: "TAXI",
              last_position: {
                altitude: 0,
                groundspeed: 12,
                heading: 10,
                latitude: 37.6,
                longitude: -122.4,
                timestamp: "2026-11-07T17:59:00Z",
              },
            }),
            flight({ fa_flight_id: null }),
            flight({ last_position: null, fa_flight_id: "NOPOS" }),
          ],
          more: true,
        });
      },
    },
  });
  const res = await handler(get("lat=37.62&lon=-122.38&radius_km=100"), d);
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.stale, false);
  assertEquals(body.truncated, true);
  assertEquals(body.flights.length, 1);
  assertEquals(body.flights[0], {
    id: "UAL1-1",
    ident: "UA1",
    operator: "UA",
    type: "B789",
    lat: 37.7123,
    lon: -122.1,
    altitude: 35000,
    groundspeed: 460,
    heading: 1,
    origin: "SFO",
    destination: "LHR",
  });
  assertEquals(body.box.south % GRID_DEG, 0);
  assert(body.box.south <= 37.62 && body.box.north >= 37.62);
  assertEquals(calls.n, 1);

  // Same area a few metres away, 30 s later: the cache row answers.
  const again = await handler(
    get("lat=37.621&lon=-122.381&radius_km=100"),
    { ...d, now: () => new Date(NOW.getTime() + 30_000) },
  );
  assertEquals(again.status, 200);
  assertEquals(calls.n, 1);
  // After the TTL it refreshes.
  await handler(get("lat=37.62&lon=-122.38&radius_km=100"), {
    ...d,
    now: () => new Date(NOW.getTime() + CACHE_TTL_MS + 1),
  });
  assertEquals(calls.n, 2);
});

Deno.test("a refused refresh serves the stale row, or 503 with none", async () => {
  const box = boxAround(37.62, -122.38, 100);
  const old: Cached = {
    flights: [],
    truncated: false,
    fetched_at: "2026-11-07T10:00:00.000Z",
  };
  const refusing: Deps["aero"] = {
    searchArea: () =>
      Promise.reject(new ApiError("provider_unavailable", 503, "cap")),
  };
  const stale = await handler(
    get("lat=37.62&lon=-122.38"),
    deps({
      aero: refusing,
      cache: memoryCache({ [cacheKey(box)]: old }).cache,
    }),
  );
  assertEquals(stale.status, 200);
  const body = await stale.json();
  assertEquals(body.stale, true);
  assertEquals(body.fetched_at, old.fetched_at);

  const none = await handler(
    get("lat=37.62&lon=-122.38"),
    deps({ aero: refusing }),
  );
  assertEquals(none.status, 503);
});

Deno.test("the box is clamped: a huge radius costs no more than MAX_RADIUS_KM", () => {
  const big = boxAround(37.62, -122.38, 5000);
  const max = boxAround(37.62, -122.38, MAX_RADIUS_KM);
  assertEquals(big, max);
  assert(max.north - max.south <= 2 * (MAX_RADIUS_KM / 111.2) + 2 * GRID_DEG);
  // Near a pole the longitude half width is held down; the date line cuts the box.
  const pole = boxAround(85, 179, MAX_RADIUS_KM);
  assert(pole.east <= 180 && pole.north <= 90);
  assert(pole.east - pole.west <= 6 + 2 * GRID_DEG);
  // A tiny radius is raised to the minimum.
  assertEquals(boxAround(37.62, -122.38, 1), boxAround(37.62, -122.38, 10));
});

Deno.test("toRadarFlight keeps heading null when unknown and wraps 360", () => {
  const p = flight().last_position!;
  assertEquals(
    toRadarFlight(flight({ last_position: { ...p, heading: null } }))?.heading,
    null,
  );
  assertEquals(
    toRadarFlight(flight({ last_position: { ...p, heading: 360 } }))?.heading,
    0,
  );
});

Deno.test("searchArea asks /flights/search with a -latlong query and counts the call", async () => {
  const seen: string[] = [];
  const endpoints: string[] = [];
  const fetchFn = ((url: string) => {
    seen.push(String(url));
    return Promise.resolve(
      new Response(JSON.stringify({ flights: [flight()] })),
    );
  }) as typeof fetch;
  const api = new AeroApi("k", fetchFn, (e) => {
    endpoints.push(e);
    return Promise.resolve();
  });
  const out = await api.searchArea({
    south: 37,
    west: -123,
    north: 38,
    east: -121,
  });
  assertEquals(out.flights.length, 1);
  assertEquals(out.more, false);
  assertEquals(endpoints, ["/flights/search"]);
  const u = new URL(seen[0]);
  assertEquals(u.pathname, "/aeroapi/flights/search");
  assertEquals(u.searchParams.get("query"), '-latlong "37 -123 38 -121"');
  assert(MAX_PAGES >= 1);
});

/** The answer the app's contract test decodes: checked here so the two sides cannot drift. */
Deno.test("the contract example matches the handler's answer", async () => {
  const d = deps({
    aero: {
      searchArea: () =>
        Promise.resolve({
          flights: [
            flight(),
            flight({
              fa_flight_id: "AFR84-2",
              ident: "AFR84",
              ident_iata: "AF84",
              operator_iata: "AF",
              aircraft_type: "A359",
              origin: {
                code: "LFPG",
                code_icao: "LFPG",
                code_iata: "CDG",
                timezone: null,
              },
              destination: {
                code: "KSFO",
                code_icao: "KSFO",
                code_iata: "SFO",
                timezone: null,
              },
              last_position: {
                altitude: 380,
                groundspeed: 489,
                heading: 262,
                latitude: 37.9,
                longitude: -122.6,
                timestamp: "2026-11-07T17:59:40Z",
              },
            }),
          ],
          more: false,
        }),
    },
  });
  const res = await handler(get("lat=37.62&lon=-122.38&radius_km=100"), d);
  assertEquals(res.status, 200);
  const text = JSON.stringify(await res.json(), null, 2) + "\n";
  const contract = new URL("./contract/nearby.json", import.meta.url);
  if (Deno.env.get("UPDATE_CONTRACT") === "1") {
    await Deno.mkdir(new URL("./contract/", import.meta.url), {
      recursive: true,
    });
    await Deno.writeTextFile(contract, text);
    return;
  }
  assertEquals(
    JSON.parse(await Deno.readTextFile(contract)),
    JSON.parse(text),
    "contract/nearby.json is out of date: run with UPDATE_CONTRACT=1",
  );
});
