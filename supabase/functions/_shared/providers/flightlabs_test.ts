// FlightLabs adapter against fixtures built from the documented field lists (FlightLabs publishes
// no sample answers and has no anonymous access). No network.
import { assertEquals, assertRejects, assertThrows } from "jsr:@std/assert@1";
import { ApiError } from "../errors.ts";
import { FlightLabs } from "./flightlabs.ts";
import { memoryQuota } from "./quota.ts";

const fixture = (name: string) =>
  Deno.readTextFile(new URL(`../fixtures/providers/${name}`, import.meta.url));
const NOW = new Date("2026-11-03T12:00:00Z");

function fake(routes: Record<string, string>) {
  const calls: { url: URL; auth: string | null }[] = [];
  const fetchFn = ((input: string | URL | Request, init?: RequestInit) => {
    const url = new URL(String(input));
    calls.push({ url, auth: new Headers(init?.headers).get("authorization") });
    const body = routes[url.pathname];
    return Promise.resolve(
      body
        ? new Response(body)
        : new Response('{"error":"x"}', { status: 404 }),
    );
  }) as typeof fetch;
  return { calls, fetchFn };
}

async function client(limit = 50) {
  const f = fake({
    "/advanced-flights-schedules": await fixture(
      "flightlabs_schedules_ksfo_built.json",
    ),
    "/flight": await fixture("flightlabs_flight_af84_built.json"),
    "/flights": await fixture("flightlabs_live_built.json"),
  });
  const charge = memoryQuota(limit);
  const fl = new FlightLabs({
    key: "s3cret",
    fetchFn: f.fetchFn,
    charge,
    now: () => NOW,
    iataOf: (icao) => Promise.resolve(icao === "KSFO" ? "SFO" : null),
  });
  return { fl, f, charge };
}

Deno.test("a timetable departs board maps rows, drops codeshares and keeps the key out of the URL", async () => {
  const { fl, f } = await client();
  const rows = await fl.boardFlights("KSFO", "departures");
  assertEquals(rows.map((r) => r.provider_id), [
    "flightlabs:AFR84:KSFO:2026-11-03",
    "flightlabs:UAL1:KSFO:2026-11-03",
  ]);
  const af = rows[0];
  assertEquals(af.ident, "AF84");
  assertEquals(af.scheduled_out, "2026-11-03T23:40:00.000Z");
  assertEquals(af.estimated_out, "2026-11-04T00:05:00.000Z");
  assertEquals(af.scheduled_in, "2026-11-04T10:15:00.000Z");
  assertEquals([af.gate_origin, af.terminal_origin, af.terminal_destination], [
    "A3",
    "I",
    "2E",
  ]);
  assertEquals([af.aircraft_type, af.registration, af.status], [
    "B77W",
    null,
    "scheduled",
  ]);
  // Runway times are not in the timetable.
  assertEquals([af.actual_off, af.estimated_off], [null, null]);
  assertEquals(rows[1].status, "departed"); // active with a gate out only
  assertEquals(rows[1].actual_out, "2026-11-03T19:08:00.000Z");
  const c = f.calls[0];
  assertEquals(c.url.searchParams.get("iataCode"), "SFO");
  assertEquals(c.url.searchParams.get("type"), "departure");
  assertEquals(c.url.searchParams.has("access_key"), false);
  assertEquals(c.auth, "Bearer s3cret");
});

Deno.test("an ident lookup finds the origin with /flight, then reads its timetable: two requests", async () => {
  const { fl, f, charge } = await client();
  const rows = await fl.flightsByIdent(
    "AF84",
    new Date("2026-11-02T00:00:00Z"),
    new Date("2026-11-05T00:00:00Z"),
  );
  assertEquals(rows.length, 1);
  assertEquals(f.calls.map((c) => c.url.pathname), [
    "/flight",
    "/advanced-flights-schedules",
  ]);
  assertEquals(f.calls[1].url.searchParams.get("iataCode"), "SFO");
  assertEquals(f.calls[1].url.searchParams.get("flight_iata"), "AF84");
  assertEquals(charge.used(), 2);
});

Deno.test("status, route and board need an IATA code; the poller's call is one request", async () => {
  const { fl, charge } = await client();
  const got = await fl.flightStatus({
    provider_id: "flightlabs:AFR84:KSFO:2026-11-03",
    ident: "AF84",
    operator: "AF",
    origin_icao: "KSFO",
    origin_iata: null,
    destination_icao: "LFPG",
    scheduled_out: "2026-11-03T23:40:00Z",
  });
  assertEquals(got?.gate_origin, "A3");
  assertEquals(charge.used(), 1);
  const route = await fl.searchRouteWindow(
    "KSFO",
    "LFPG",
    new Date("2026-11-03T08:00:00Z"),
    new Date("2026-11-04T08:00:00Z"),
  );
  assertEquals(route.map((r) => r.ident), ["AF84"]);
  const e = await assertRejects(
    () => fl.boardFlights("ZZZZ", "arrivals"),
    ApiError,
  );
  assertEquals(e.code, "provider_unavailable");
});

Deno.test("the live feed gives a position and the airframe", async () => {
  const { fl, f } = await client();
  const p = await fl.position({ provider_id: "x", callsign: "AFR84" });
  assertEquals(p, {
    position_lat: 48.5,
    position_lon: -30.25,
    position_altitude_ft: 36998,
    position_ground_speed_kt: 480,
    position_heading: 265,
    position_at: "2026-11-04T08:13:20.000Z",
  });
  assertEquals(f.calls[0].url.searchParams.get("flightIcao"), "AFR84");
  const a = await fl.aircraft({ registration: "F-GSQA" });
  assertEquals(a, {
    icao24: "3946e1",
    registration: "F-GSQA",
    aircraft_type: "B77W",
    operator: "AFR",
    country: null,
  });
  assertEquals(f.calls[1].url.searchParams.get("regNum"), "F-GSQA");
});

Deno.test("a quota refusal stops the call, and only https is accepted", async () => {
  const { fl, f } = await client(0);
  await assertRejects(
    () => fl.boardFlights("KSFO", "departures"),
    ApiError,
    "quota",
  );
  assertEquals(f.calls.length, 0);
  assertThrows(
    () =>
      new FlightLabs({
        key: "k",
        baseUrl: "http://www.goflightlabs.com",
        charge: memoryQuota(1),
      }),
  );
});
