// Aviationstack adapter against the documented /v1/flights example (verbatim) and a fixture built
// from the documented fields (no anonymous call exists). No network.
import { assertEquals, assertRejects, assertThrows } from "jsr:@std/assert@1";
import { ApiError } from "../errors.ts";
import { assertBaseUrl, Aviationstack } from "./aviationstack.ts";
import { memoryQuota } from "./quota.ts";

const fixture = (name: string) =>
  Deno.readTextFile(new URL(`../fixtures/providers/${name}`, import.meta.url));
const NOW = new Date("2026-11-03T12:00:00Z");

function fake(body: string | (() => Response)) {
  const urls: string[] = [];
  const fetchFn = ((input: string | URL | Request) => {
    urls.push(String(input));
    return Promise.resolve(
      typeof body === "string" ? new Response(body, { status: 200 }) : body(),
    );
  }) as typeof fetch;
  return { urls, fetchFn };
}

function client(
  fetchFn: typeof fetch,
  times: "local" | "utc" = "local",
  limit = 100,
) {
  const charge = memoryQuota(limit);
  return {
    charge,
    as: new Aviationstack({
      key: "k3y",
      fetchFn,
      charge,
      now: () => NOW,
      times,
    }),
  };
}

Deno.test("the documented example maps to a flights row, wall clock times read at the airport", async () => {
  const f = fake(await fixture("aviationstack_flights_doc.json"));
  const { as } = client(f.fetchFn);
  const [row] = await as.boardFlights("KSFO", "departures");
  assertEquals(row.provider_id, "aviationstack:AAL1004:KSFO:2019-12-12");
  assertEquals(row.ident, "AA1004");
  assertEquals(row.operator, "AA");
  assertEquals([row.origin_icao, row.origin_iata, row.destination_icao], [
    "KSFO",
    "SFO",
    "KDFW",
  ]);
  // 04:20 in Los Angeles in December is 12:20 UTC; 04:20 in Chicago is 10:20 UTC.
  assertEquals(row.scheduled_out, "2019-12-12T12:20:00.000Z");
  assertEquals(row.actual_out, "2019-12-12T12:20:13.000Z");
  assertEquals(row.actual_off, "2019-12-12T12:20:13.000Z");
  assertEquals(row.scheduled_in, "2019-12-12T10:20:00.000Z");
  assertEquals(row.actual_in, null);
  assertEquals(row.actual_on, null);
  assertEquals([row.gate_origin, row.terminal_origin], ["D11", "2"]);
  assertEquals([
    row.gate_destination,
    row.terminal_destination,
    row.baggage_belt,
  ], ["A22", "A", "A17"]);
  assertEquals([row.aircraft_type, row.registration], ["A321", "N160AN"]);
  assertEquals(row.status, "en_route");
  assertEquals(row.origin_tz, "America/Los_Angeles");
  // Fields the API does not have stay null.
  assertEquals([row.scheduled_off, row.scheduled_on, row.estimated_on], [
    null,
    null,
    null,
  ]);
  const url = new URL(f.urls[0]);
  assertEquals(
    url.origin + url.pathname,
    "https://api.aviationstack.com/v1/flights",
  );
  assertEquals(url.searchParams.get("dep_icao"), "KSFO");
  assertEquals(url.searchParams.get("limit"), "100");
});

Deno.test("AVIATIONSTACK_TIMES=utc reads the offsets as given", async () => {
  const f = fake(await fixture("aviationstack_flights_doc.json"));
  const { as } = client(f.fetchFn, "utc");
  const [row] = await as.boardFlights("KSFO", "departures");
  assertEquals(row.scheduled_out, "2019-12-12T04:20:00.000Z");
});

Deno.test("an ident lookup skips codeshare listings, keeps cancels and applies the window", async () => {
  const f = fake(await fixture("aviationstack_flights_af84_built.json"));
  const { as, charge } = client(f.fetchFn);
  const rows = await as.flightsByIdent(
    "AF84",
    new Date("2026-11-01T00:00:00Z"),
    new Date("2026-11-05T00:00:00Z"),
  );
  assertEquals(rows.map((r) => [r.provider_id, r.status]), [
    ["aviationstack:AFR84:KSFO:2026-11-03", "scheduled"],
    ["aviationstack:AFR84:KSFO:2026-11-02", "canceled"],
  ]);
  assertEquals(rows[0].scheduled_out, "2026-11-03T23:40:00.000Z");
  assertEquals(rows[0].estimated_out, "2026-11-04T00:05:00.000Z");
  assertEquals(rows[0].scheduled_in, "2026-11-04T10:15:00.000Z");
  assertEquals(new URL(f.urls[0]).searchParams.get("flight_iata"), "AF84");
  assertEquals(charge.used(), 1);
  const narrow = await as.flightsByIdent(
    "AFR84",
    new Date("2026-11-03T00:00:00Z"),
    new Date("2026-11-04T00:00:00Z"),
  );
  assertEquals(narrow.length, 1);
  assertEquals(new URL(f.urls[1]).searchParams.get("flight_icao"), "AFR84");
});

Deno.test("the poller's status call asks one ident at one origin and picks the nearest departure", async () => {
  const f = fake(await fixture("aviationstack_flights_af84_built.json"));
  const { as } = client(f.fetchFn);
  const got = await as.flightStatus({
    provider_id: "AFR84-1762000000-schedule-0001",
    ident: "AF84",
    operator: "AF",
    origin_icao: "KSFO",
    origin_iata: "SFO",
    destination_icao: "LFPG",
    scheduled_out: "2026-11-03T23:40:00Z",
  });
  assertEquals(got?.gate_origin, "A3");
  assertEquals(new URL(f.urls[0]).searchParams.get("dep_icao"), "KSFO");
});

Deno.test("live block becomes a position, km/h to knots and metres to feet", async () => {
  const f = fake(await fixture("aviationstack_flights_doc.json"));
  const { as } = client(f.fetchFn);
  const p = await as.position({ provider_id: "x", callsign: "AAL1004" });
  assertEquals(p, {
    position_lat: 36.2856,
    position_lon: -106.807,
    position_altitude_ft: 29025,
    position_ground_speed_kt: 483,
    position_heading: 114,
    position_at: "2019-12-12T10:00:00.000Z",
  });
  const a = await as.aircraft({ callsign: "AAL1004" });
  assertEquals(a, {
    icao24: "a0f1bb",
    registration: "N160AN",
    aircraft_type: "A321",
    operator: "AAL",
    country: null,
  });
});

Deno.test("documented error codes map to our errors", async () => {
  const body = (code: string, status: number) => () =>
    new Response(JSON.stringify({ error: { code, message: "m" } }), { status });
  for (
    const [c, status, want] of [
      ["usage_limit_reached", 429, "rate_limited"],
      ["function_access_restricted", 403, "provider_unavailable"],
      ["invalid_access_key", 401, "provider_unavailable"],
    ] as const
  ) {
    const { as } = client(fake(body(c, status)).fetchFn);
    const e = await assertRejects(
      () => as.boardFlights("KSFO", "arrivals"),
      ApiError,
    );
    assertEquals(e.code, want);
  }
  // An error object on a 200 is still an error, and a quota one says so with a 503.
  const { as } = client(fake(body("usage_limit_reached", 200)).fetchFn);
  const e = await assertRejects(
    () => as.boardFlights("KSFO", "arrivals"),
    ApiError,
  );
  assertEquals([e.code, e.status], ["provider_unavailable", 503]);
});

Deno.test("an exhausted quota refuses before any request goes out", async () => {
  const f = fake(await fixture("aviationstack_flights_doc.json"));
  const { as } = client(f.fetchFn, "local", 1);
  await as.boardFlights("KSFO", "departures");
  const e = await assertRejects(
    () => as.boardFlights("KSFO", "departures"),
    ApiError,
  );
  assertEquals([e.code, e.status], ["provider_unavailable", 503]);
  assertEquals(f.urls.length, 1);
});

Deno.test("plain HTTP is refused in production and needs the setting elsewhere", () => {
  assertThrows(
    () => assertBaseUrl("http://api.aviationstack.com/v1", true, true),
    Error,
    "production",
  );
  assertThrows(
    () => assertBaseUrl("http://api.aviationstack.com/v1", false, false),
    Error,
    "ALLOW_HTTP",
  );
  assertBaseUrl("http://api.aviationstack.com/v1", true, false);
  assertBaseUrl("https://api.aviationstack.com/v1", false, true);
  assertThrows(() => assertBaseUrl("ftp://x", true, false));
  assertThrows(
    () =>
      new Aviationstack({
        key: "k",
        baseUrl: "http://api.aviationstack.com/v1",
        allowHttp: true,
        production: true,
        charge: memoryQuota(1),
      }),
    Error,
    "production",
  );
});
