import { assert, assertEquals } from "jsr:@std/assert@1";
import type { AeroFlight } from "../_shared/aeroapi_types.ts";
import { fakeVerifier, makeUser, testDb } from "../_shared/test_util.ts";
import { handler } from "./handler.ts";

const NOW = new Date("2026-11-02T12:00:00Z");
const fixture = async (name: string) =>
  JSON.parse(
    await Deno.readTextFile(
      new URL(`../_shared/fixtures/${name}`, import.meta.url),
    ),
  );
const af84: AeroFlight[] = (await fixture("flight_af84.json")).flights;
const route: AeroFlight[] = (await fixture("route_kaus_kdfw.json")).flights
  .map((f: { segments: AeroFlight[] }) => f.segments[0]);

const db = await testDb();

function fakeAero() {
  const calls = {
    ident: [] as unknown[][],
    route: [] as unknown[][],
  };
  return {
    calls,
    flightsByIdent(...a: unknown[]) {
      calls.ident.push(a);
      return Promise.resolve(af84);
    },
    searchRoute(...a: unknown[]) {
      calls.route.push(a);
      return Promise.resolve(route);
    },
  };
}

function post(token: string | null, body: unknown): Request {
  return new Request("http://localhost/flight-lookup", {
    method: "POST",
    headers: token ? { authorization: `Bearer ${token}` } : {},
    body: JSON.stringify(body),
  });
}

function deps(aero = fakeAero()) {
  return { db, aero, verifier: fakeVerifier, now: () => NOW };
}

const opts = { sanitizeOps: false, sanitizeResources: false };

Deno.test({ name: "lookup by ident upserts once", ...opts }, async () => {
  const user = await makeUser(db);
  const d = deps();
  for (let i = 0; i < 2; i++) {
    const res = await handler(
      post(user, { ident: "af84", date: "2026-11-03" }),
      d,
    );
    assertEquals(res.status, 200);
    const body = await res.json();
    assertEquals(body.flights.length, 1);
    assertEquals(body.flights[0].provider_id, af84[0].fa_flight_id);
  }
  const rows = await db.from("flights").select("id").eq(
    "provider_id",
    af84[0].fa_flight_id,
  );
  assertEquals(rows.data?.length, 1);
  assertEquals(d.aero.calls.ident[0][0], "AF84");
});

Deno.test({ name: "lookup accepts IATA airports", ...opts }, async () => {
  const user = await makeUser(db);
  await db.from("route_cache").delete().eq("origin_icao", "LFPG");
  const d = deps();
  const res = await handler(
    post(user, { origin: "cdg", destination: "SFO", date: "2026-11-03" }),
    d,
  );
  assertEquals(res.status, 200);
  assertEquals(d.aero.calls.route.length, 1);
  assertEquals(d.aero.calls.route[0].slice(0, 3), [
    "LFPG",
    "KSFO",
    "2026-11-03",
  ]);
});

Deno.test(
  { name: "ICAO airports work and the route is cached", ...opts },
  async () => {
    const user = await makeUser(db);
    await db.from("route_cache").delete().eq("origin_icao", "KAUS");
    const d = deps();
    const body = { origin: "KAUS", destination: "DFW", date: "2026-11-03" };
    const first = await (await handler(post(user, body), d)).json();
    const second = await (await handler(post(user, body), d)).json();
    assertEquals(d.aero.calls.route.length, 1); // second search served from the cache
    assert(first.flights.length > 0);
    assertEquals(
      second.flights.map((f: { id: string }) => f.id).sort(),
      first.flights.map((f: { id: string }) => f.id).sort(),
    );
    // After the cache expires the provider is called again.
    const later = { ...d, now: () => new Date(NOW.getTime() + 11 * 60_000) };
    await handler(post(user, body), later);
    assertEquals(d.aero.calls.route.length, 2);
  },
);

Deno.test(
  { name: "31st lookup in an hour returns 429 rate_limited", ...opts },
  async () => {
    const user = await makeUser(db);
    const d = deps();
    for (let i = 0; i < 30; i++) {
      const res = await handler(
        post(user, { ident: "AF84", date: "2026-11-03" }),
        d,
      );
      assertEquals(res.status, 200);
    }
    const res = await handler(
      post(user, { ident: "AF84", date: "2026-11-03" }),
      d,
    );
    assertEquals(res.status, 429);
    assertEquals((await res.json()).error.code, "rate_limited");
  },
);

Deno.test({ name: "no JWT returns 401 unauthorized", ...opts }, async () => {
  const res = await handler(
    post(null, { ident: "AF84", date: "2026-11-03" }),
    deps(),
  );
  assertEquals(res.status, 401);
  assertEquals((await res.json()).error.code, "unauthorized");
  const bad = await handler(
    post("bad", { ident: "AF84", date: "2026-11-03" }),
    deps(),
  );
  assertEquals(bad.status, 401);
});

Deno.test({
  name: "dates outside the provider window never reach AeroAPI",
  ...opts,
}, async () => {
  const user = await makeUser(db);
  const d = deps();
  for (const date of ["2026-10-01", "2026-11-20"]) {
    const res = await handler(post(user, { ident: "AF84", date }), d);
    assertEquals(res.status, 400);
    assertEquals((await res.json()).error.code, "out_of_window");
    const r2 = await handler(
      post(user, { origin: "CDG", destination: "SFO", date }),
      d,
    );
    assertEquals((await r2.json()).error.code, "out_of_window");
  }
  assertEquals(d.aero.calls.ident.length + d.aero.calls.route.length, 0);
});

Deno.test({ name: "bad input is a typed 400", ...opts }, async () => {
  const user = await makeUser(db);
  const d = deps();
  const cases: unknown[] = [
    { date: "2026-11-03" },
    { ident: "AF84", origin: "CDG", destination: "SFO", date: "2026-11-03" },
    { origin: "CDG", date: "2026-11-03" },
    { origin: "ZZZ", destination: "SFO", date: "2026-11-03" },
    { ident: "AF84", date: "03/11/2026" },
    { ident: "AF 84; drop", date: "2026-11-03" },
  ];
  for (const c of cases) {
    const res = await handler(post(user, c), d);
    assertEquals(res.status, 400, JSON.stringify(c));
    assertEquals((await res.json()).error.code, "invalid_request");
  }
  assertEquals(d.aero.calls.ident.length + d.aero.calls.route.length, 0);
});
