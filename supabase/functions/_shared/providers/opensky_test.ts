// OpenSky adapter against real anonymous answers (2026-10-31) and a /flights/aircraft fixture built
// from the documented fields (anonymous calls to it answer 403). No network.
import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { ApiError } from "../errors.ts";
import {
  CREDITS_BOX,
  CREDITS_ICAO24,
  OpenSky,
  OPENSKY_TOKEN_URL,
  stateToPosition,
} from "./opensky.ts";
import { memoryQuota } from "./quota.ts";

const fixture = (name: string) =>
  Deno.readTextFile(new URL(`../fixtures/providers/${name}`, import.meta.url));

interface Call {
  url: string;
  auth: string | null;
  body?: string;
}

function fake(
  answer: (url: URL, calls: Call[]) => Response | Promise<Response>,
) {
  const calls: Call[] = [];
  const fetchFn =
    (async (input: string | URL | Request, init?: RequestInit) => {
      const url = new URL(String(input));
      calls.push({
        url: url.href,
        auth: new Headers(init?.headers).get("authorization"),
        body: typeof init?.body === "string" ? init.body : undefined,
      });
      return await answer(url, calls);
    }) as typeof fetch;
  return { calls, fetchFn };
}

const token = (n: number) =>
  new Response(
    JSON.stringify({
      access_token: `tok${n}`,
      expires_in: 1800,
      token_type: "Bearer",
    }),
  );

Deno.test("a real state vector becomes our position columns", async () => {
  const body = JSON.parse(
    await fixture("opensky_states_icao24_c0130c_20261031.json"),
  );
  assertEquals(stateToPosition(body.states[0]), {
    position_lat: 37.662,
    position_lon: -122.4215,
    position_altitude_ft: 11025,
    position_ground_speed_kt: 256,
    position_heading: 140,
    position_at: "2026-10-31T22:38:20.000Z",
  });
});

Deno.test("anonymous: a callsign is found in a 25 sq deg box around the hint, 1 credit", async () => {
  const states = await fixture("opensky_states_bbox_ksfo_20261031.json");
  const f = fake(() => new Response(states));
  const charge = memoryQuota(400);
  const os = new OpenSky({ fetchFn: f.fetchFn, charge });
  const p = await os.position({
    provider_id: "ACA566-1",
    callsign: "ACA566",
    near: { lat: 37.62, lon: -122.38 },
  });
  assertEquals(p?.position_lat, 37.6637);
  assertEquals(charge.used(), CREDITS_BOX);
  const u = new URL(f.calls[0].url);
  assertEquals(u.pathname, "/api/states/all");
  const box = ["lamin", "lamax", "lomin", "lomax"].map((k) =>
    Number(u.searchParams.get(k))
  );
  assertEquals((box[1] - box[0]) * (box[3] - box[2]), 25);
  assertEquals(f.calls[0].auth, null);
  // Not in the box: null, never a guess.
  assertEquals(
    await os.position({
      provider_id: "x",
      callsign: "AFR84",
      near: { lat: 37.6, lon: -122.4 },
    }),
    null,
  );
  // Neither icao24 nor a hint: no request at all.
  assertEquals(
    await os.position({ provider_id: "x", callsign: "AFR84" }),
    null,
  );
  assertEquals(f.calls.length, 2);
});

Deno.test("by icao24 costs 4 credits, and the airframe has no registration", async () => {
  const one = await fixture("opensky_states_icao24_c0130c_20261031.json");
  const f = fake(() => new Response(one));
  const charge = memoryQuota(400);
  const os = new OpenSky({ fetchFn: f.fetchFn, charge });
  const a = await os.aircraft({ icao24: "C0130C" });
  assertEquals(a, {
    icao24: "c0130c",
    registration: null,
    aircraft_type: null,
    operator: null,
    country: "Canada",
  });
  assertEquals(new URL(f.calls[0].url).searchParams.get("icao24"), "c0130c");
  assertEquals(charge.used(), CREDITS_ICAO24);
});

Deno.test("with an account: one client credentials token, reused, renewed once on a 401", async () => {
  const one = await fixture("opensky_states_icao24_c0130c_20261031.json");
  let tokens = 0;
  let rejectNext = false;
  const f = fake((url) => {
    if (url.href === OPENSKY_TOKEN_URL) return token(++tokens);
    if (rejectNext) {
      rejectNext = false;
      return new Response("", { status: 401 });
    }
    return new Response(one);
  });
  let now = new Date("2026-10-31T22:00:00Z");
  const os = new OpenSky({
    clientId: "soma",
    clientSecret: "sec",
    fetchFn: f.fetchFn,
    charge: memoryQuota(4000),
    now: () => now,
  });
  await os.position({ provider_id: "x", callsign: null, icao24: "c0130c" });
  await os.position({ provider_id: "x", callsign: null, icao24: "c0130c" });
  assertEquals(tokens, 1);
  const body = new URLSearchParams(f.calls[0].body);
  assertEquals(body.get("grant_type"), "client_credentials");
  assertEquals(body.get("client_id"), "soma");
  assertEquals(f.calls[1].auth, "Bearer tok1");
  rejectNext = true;
  await os.position({ provider_id: "x", callsign: null, icao24: "c0130c" });
  assertEquals(tokens, 2);
  assertEquals(f.calls.at(-1)!.auth, "Bearer tok2");
  // Past its 30 minutes the token is fetched again.
  now = new Date(now.getTime() + 31 * 60_000);
  await os.position({ provider_id: "x", callsign: null, icao24: "c0130c" });
  assertEquals(tokens, 3);
});

Deno.test("a failing token endpoint falls back to an anonymous call", async () => {
  const one = await fixture("opensky_states_icao24_c0130c_20261031.json");
  const f = fake((url) =>
    url.href === OPENSKY_TOKEN_URL
      ? new Response("", { status: 500 })
      : new Response(one)
  );
  const os = new OpenSky({
    clientId: "a",
    clientSecret: "b",
    fetchFn: f.fetchFn,
    charge: memoryQuota(10),
  });
  const p = await os.position({
    provider_id: "x",
    callsign: null,
    icao24: "c0130c",
  });
  assertEquals(p?.position_lon, -122.4215);
  assertEquals(f.calls.at(-1)!.auth, null);
});

Deno.test("429 is rate_limited, and flights by aircraft need an account", async () => {
  const f = fake(() => new Response("", { status: 429 }));
  const os = new OpenSky({ fetchFn: f.fetchFn, charge: memoryQuota(10) });
  const e = await assertRejects(
    () => os.position({ provider_id: "x", callsign: null, icao24: "c0130c" }),
    ApiError,
  );
  assertEquals(e.code, "rate_limited");
  await assertRejects(
    () =>
      os.flightsByAircraft(
        "c0130c",
        new Date("2026-10-29T00:00:00Z"),
        new Date("2026-10-30T00:00:00Z"),
      ),
    ApiError,
    "account",
  );
});

Deno.test("flights by aircraft: estimated airports from the documented fields", async () => {
  const legs = await fixture("opensky_flights_aircraft_built.json");
  const f = fake((url) =>
    url.href === OPENSKY_TOKEN_URL ? token(1) : new Response(legs)
  );
  const os = new OpenSky({
    clientId: "a",
    clientSecret: "b",
    fetchFn: f.fetchFn,
    charge: memoryQuota(100),
  });
  const got = await os.flightsByAircraft(
    "C0130C",
    new Date("2026-10-29T00:00:00Z"),
    new Date("2026-10-30T00:00:00Z"),
  );
  assertEquals(got.map((l) => [l.estDepartureAirport, l.estArrivalAirport]), [[
    "CYVR",
    "KSFO",
  ]]);
  const u = new URL(f.calls[1].url);
  assertEquals([u.pathname, u.searchParams.get("icao24")], [
    "/api/flights/aircraft",
    "c0130c",
  ]);
  // More than the 2 days the API takes: nothing asked.
  assertEquals(
    await os.flightsByAircraft(
      "c0130c",
      new Date("2026-10-20T00:00:00Z"),
      new Date("2026-10-30T00:00:00Z"),
    ),
    [],
  );
});
