import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { AeroApi, estimateCost, toFlightRow } from "./aeroapi.ts";
import { ApiError, errorResponse } from "./errors.ts";

const fixture = (name: string) => Deno.readTextFile(new URL(`./fixtures/${name}`, import.meta.url));

function fakeFetch(body: string | null, status = 200, calls: Request[] = []): typeof fetch {
  return (input, init) => {
    calls.push(new Request(input as string, init));
    return Promise.resolve(new Response(body, { status, headers: { "content-type": "application/json" } }));
  };
}

Deno.test("flightsByIdent parses fixture", async () => {
  const api = new AeroApi("k", fakeFetch(await fixture("flight_af84.json")));
  const flights = await api.flightsByIdent("AF84");
  assertEquals(flights.length, 1);
  assertEquals(flights[0].ident_iata, "AF84");
  const row = toFlightRow(flights[0]);
  assertEquals(row.origin_icao, "LFPG");
  assertEquals(row.destination_icao, "KSFO");
  assert(row.scheduled_out !== null);
  assertEquals(row.status, "en_route");
  assertEquals(row.baggage_belt, "G");
  assertEquals(row.position_altitude_ft, 38000);
  assertEquals(row.ident, "AF84");
});

Deno.test("airportFlights parses departures fixture", async () => {
  const calls: Request[] = [];
  const api = new AeroApi("k", fakeFetch(await fixture("departures_kaus.json"), 200, calls));
  const flights = await api.airportFlights("KAUS", "departures");
  assertEquals(flights.length, 3);
  assertEquals(new URL(calls[0].url).pathname, "/aeroapi/airports/KAUS/flights/departures");
  assertEquals(toFlightRow(flights[2]).status, "departed");
});

for (
  const [status, code] of [[404, "not_found"], [429, "rate_limited"], [503, "provider_unavailable"]] as const
) {
  Deno.test(`${status} becomes ${code}`, async () => {
    const api = new AeroApi("k", fakeFetch("{}", status));
    const e = await assertRejects(() => api.flightsByIdent("AF84"), ApiError);
    assertEquals(e.code, code);
  });
}

Deno.test("fetch throws becomes provider_unavailable", async () => {
  const api = new AeroApi("k", () => Promise.reject(new TypeError("boom")));
  const e = await assertRejects(() => api.flightsByIdent("AF84"), ApiError);
  assertEquals(e.code, "provider_unavailable");
});

Deno.test("onCall is invoked once per request with the endpoint path", async () => {
  const seen: string[] = [];
  const api = new AeroApi("k", fakeFetch(await fixture("flight_af84.json")), (e) => {
    seen.push(e);
    return Promise.resolve();
  });
  await api.flightsByIdent("AF84");
  assertEquals(seen, ["/flights/{ident}"]);
  assertEquals(estimateCost(seen[0]), 0.005);
  assertEquals(estimateCost("/flights/search"), 0.05);
  assertEquals(estimateCost("/airports/{id}/flights/departures"), 0.005);
});

Deno.test("sends x-apikey header", async () => {
  const calls: Request[] = [];
  const api = new AeroApi("secret-key", fakeFetch(await fixture("flight_af84.json"), 200, calls));
  await api.flightsByIdent("AF84");
  assertEquals(calls[0].headers.get("x-apikey"), "secret-key");
  assert(calls[0].url.startsWith("https://aeroapi.flightaware.com/aeroapi/flights/AF84"));
});

Deno.test("flightById returns null on 404", async () => {
  const api = new AeroApi("k", fakeFetch("{}", 404));
  assertEquals(await api.flightById("x"), null);
});

Deno.test("createAlert reads id from Location, deleteAlert tolerates 404", async () => {
  const create: typeof fetch = () =>
    Promise.resolve(new Response(null, { status: 201, headers: { location: "/alerts/8841" } }));
  assertEquals(await new AeroApi("k", create).createAlert("AF84", "2026-11-03", "2026-11-04"), 8841);
  await new AeroApi("k", fakeFetch(null, 404)).deleteAlert(8841);
});

Deno.test("errorResponse shapes", async () => {
  const r = errorResponse(new ApiError("plan_limit", 402, "Free plan"));
  assertEquals(r.status, 402);
  assertEquals((await r.json()).error.code, "plan_limit");
  const u = errorResponse(new Error("x"));
  assertEquals(u.status, 500);
  assertEquals((await u.json()).error.code, "provider_unavailable");
});
