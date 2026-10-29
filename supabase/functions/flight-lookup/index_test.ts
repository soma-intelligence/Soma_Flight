import { assert, assertEquals } from "jsr:@std/assert@1";
import type { AeroFlight } from "../_shared/aeroapi_types.ts";
import {
  fakeVerifier,
  makeUser,
  test,
  testDb,
  trackAirport,
  trackProviderIds,
  trackRoute,
} from "../_shared/test_util.ts";
import { handler, zonedDayStart } from "./handler.ts";

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

function fakeAero(idents: AeroFlight[] = af84) {
  const calls = {
    ident: [] as unknown[][],
    route: [] as unknown[][],
  };
  return {
    calls,
    flightsByIdent(...a: unknown[]) {
      calls.ident.push(a);
      return Promise.resolve(idents);
    },
    // Honours the window like the provider: start inclusive, end exclusive.
    searchRouteWindow(o: string, d: string, start: Date, end: Date) {
      calls.route.push([o, d, start.toISOString(), end.toISOString()]);
      return Promise.resolve(route.filter((f) => {
        const t = Date.parse(f.scheduled_out!);
        return t >= start.getTime() && t < end.getTime();
      }));
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

/** Fixture flights land in the shared table: track them so the test removes them. */
function track(...lists: AeroFlight[][]) {
  trackProviderIds(lists.flat().map((f) => f.fa_flight_id));
}

test(db, "lookup by ident upserts once", async () => {
  track(af84);
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

test(
  db,
  "ident search answers origin-local dates from the day before to the day after",
  async () => {
    // Departs 20:00 on 11-03 in San Francisco, which is 04:00Z on 11-04.
    const late: AeroFlight = {
      ...af84[0],
      fa_flight_id: "UAL999-1793600000-schedule-9p",
      ident: "UAL999",
      ident_iata: "UA999",
      scheduled_out: "2026-11-04T04:00:00Z",
      origin: {
        ...af84[0].origin!,
        code_icao: "KSFO",
        timezone: "America/Los_Angeles",
      },
    };
    // The same ident a day earlier, 20:00 on 11-02 in San Francisco.
    const earlier: AeroFlight = {
      ...late,
      fa_flight_id: "UAL999-1793500000-schedule-9p",
      scheduled_out: "2026-11-03T04:00:00Z",
    };
    track([late, earlier]);
    const user = await makeUser(db);
    const d = deps(fakeAero([late, earlier]));
    const ask = async (date: string) =>
      (await (await handler(post(user, { ident: "UA999", date }), d)).json())
        .flights.map((f: { provider_id: string }) => f.provider_id);
    // A user in Paris on 11-04 still finds the flight that left San Francisco on its 11-03.
    assertEquals(await ask("2026-11-04"), [late.fa_flight_id]);
    // All matches, sorted by departure, none picked silently.
    assertEquals(await ask("2026-11-03"), [
      earlier.fa_flight_id,
      late.fa_flight_id,
    ]);
    assertEquals(await ask("2026-11-02"), [
      earlier.fa_flight_id,
      late.fa_flight_id,
    ]);
    assertEquals(await ask("2026-10-31"), []);
    // The provider window: two days back, three ahead of the UTC date, clipped to now + 2 days.
    assertEquals(d.aero.calls.ident[1].slice(1), [
      "2026-11-01T00:00:00.000Z",
      "2026-11-04T12:00:00.000Z",
    ]);
  },
);

test(
  db,
  "flights without an ICAO origin or destination are left out",
  async () => {
    const noIcao: AeroFlight = {
      ...af84[0],
      fa_flight_id: "AFR84-LID-schedule-1p",
      origin: { ...af84[0].origin!, code_icao: null as unknown as string },
    };
    track(af84, [noIcao]);
    const user = await makeUser(db);
    const res = await handler(
      post(user, { ident: "AF84", date: "2026-11-03" }),
      deps(fakeAero([...af84, noIcao])),
    );
    assertEquals(res.status, 200);
    const ids = (await res.json()).flights.map((f: { provider_id: string }) =>
      f.provider_id
    );
    assertEquals(ids, [af84[0].fa_flight_id]);
    const stored = await db.from("flights").select("id").eq(
      "provider_id",
      noIcao.fa_flight_id,
    );
    assertEquals(stored.data?.length, 0);
  },
);

test(
  db,
  "a lookup never moves the webhook's status and actual times backwards",
  async () => {
    track(af84);
    const user = await makeUser(db);
    const d = deps();
    await handler(post(user, { ident: "AF84", date: "2026-11-03" }), d);
    // The webhook has seen the flight land; the provider's /flights snapshot (en route) lags.
    const up = await db.from("flights").update({
      status: "landed",
      actual_out: "2026-11-03T13:40:00Z",
      actual_on: "2026-11-03T20:00:00Z",
    }).eq("provider_id", af84[0].fa_flight_id);
    if (up.error) throw up.error;
    const res = await handler(
      post(user, { ident: "AF84", date: "2026-11-03" }),
      d,
    );
    const [f] = (await res.json()).flights;
    assertEquals(f.status, "landed");
    assertEquals(Date.parse(f.actual_out), Date.parse("2026-11-03T13:40:00Z"));
    assertEquals(Date.parse(f.actual_on), Date.parse("2026-11-03T20:00:00Z"));
  },
);

test(
  db,
  "lookup accepts IATA airports and makes one call for the local day",
  async () => {
    track(route);
    trackRoute("LFPG", "KSFO", "2026-11-03");
    await db.from("route_cache").delete().eq("origin_icao", "LFPG").eq(
      "destination_icao",
      "KSFO",
    );
    const user = await makeUser(db);
    const d = deps();
    const res = await handler(
      post(user, { origin: "cdg", destination: "SFO", date: "2026-11-03" }),
      d,
    );
    assertEquals(res.status, 200);
    // Paris is UTC+1: local 11-03 is one provider call, 11-02T23:00Z to 11-03T23:00Z.
    assertEquals(d.aero.calls.route, [
      ["LFPG", "KSFO", "2026-11-02T23:00:00.000Z", "2026-11-03T23:00:00.000Z"],
    ]);
    // The 01:30Z flight of 11-04 is 02:30 on 11-04 in Paris, outside the window.
    assertEquals((await res.json()).flights.length, 2);
  },
);

test(db, "ICAO airports work and the route is cached", async () => {
  track(route);
  trackRoute("KAUS", "KDFW", "2026-11-03");
  await db.from("route_cache").delete().eq("origin_icao", "KAUS").eq(
    "destination_icao",
    "KDFW",
  );
  const user = await makeUser(db);
  const d = deps();
  const body = { origin: "KAUS", destination: "DFW", date: "2026-11-03" };
  const first = await (await handler(post(user, body), d)).json();
  assertEquals(d.aero.calls.route.length, 1);
  assertEquals(d.aero.calls.route[0].slice(2), [
    "2026-11-03T06:00:00.000Z",
    "2026-11-04T06:00:00.000Z",
  ]);
  const callsAfterFirst = d.aero.calls.route.length;
  const second = await (await handler(post(user, body), d)).json();
  assertEquals(d.aero.calls.route.length, callsAfterFirst);
  assertEquals(first.flights.length, 3);
  assertEquals(
    second.flights.map((f: { id: string }) => f.id).sort(),
    first.flights.map((f: { id: string }) => f.id).sort(),
  );
  const later = { ...d, now: () => new Date(NOW.getTime() + 11 * 60_000) };
  await handler(post(user, body), later);
  assert(d.aero.calls.route.length > callsAfterFirst);
});

test(db, "31st lookup in an hour returns 429 rate_limited", async () => {
  track(af84);
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
});

test(db, "no JWT returns 401 unauthorized", async () => {
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

test(db, "dates outside the provider window never reach AeroAPI", async () => {
  const user = await makeUser(db);
  const d = deps();
  // now = 2026-11-02T12:00Z: 10-22 ended before now - 10 days, 11-05 starts after now + 2 days.
  for (const date of ["2026-10-01", "2026-10-22", "2026-11-05", "2026-11-20"]) {
    const res = await handler(post(user, { ident: "AF84", date }), d);
    assertEquals(res.status, 400, date);
    assertEquals((await res.json()).error.code, "out_of_window");
    const r2 = await handler(
      post(user, { origin: "CDG", destination: "SFO", date }),
      d,
    );
    assertEquals((await r2.json()).error.code, "out_of_window");
  }
  assertEquals(d.aero.calls.ident.length + d.aero.calls.route.length, 0);
});

test(db, "oldest and newest days of the window are accepted", async () => {
  track(af84); // the default fake answers with the fixture flight, which lands in the table
  const user = await makeUser(db);
  const d = deps();
  for (const date of ["2026-10-23", "2026-11-04"]) {
    const res = await handler(post(user, { ident: "AF84", date }), d);
    assertEquals(res.status, 200, date);
  }
});

test(db, "bad input is a typed 400", async () => {
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

test(db, "local day bounds follow the zone, including a DST change", () => {
  assertEquals(
    zonedDayStart("America/Los_Angeles", "2026-11-01").toISOString(),
    "2026-11-01T07:00:00.000Z",
  );
  assertEquals(
    zonedDayStart("America/Los_Angeles", "2026-11-02").toISOString(),
    "2026-11-02T08:00:00.000Z",
  );
  assertEquals(
    zonedDayStart("Asia/Kolkata", "2026-11-03").toISOString(),
    "2026-11-02T18:30:00.000Z",
  );
  return Promise.resolve();
});

test(
  db,
  "an airport without a timezone falls back to UTC with a warning",
  async () => {
    const ins = await db.from("airports").insert({
      icao: "ZZTZ",
      iata: null,
      name: "No Tz Test",
      lat: 0,
      lon: 0,
      tz: null,
    });
    if (ins.error) throw ins.error;
    trackAirport("ZZTZ");
    track(route);
    trackRoute("ZZTZ", "KSFO", "2026-11-03");
    const user = await makeUser(db);
    const d = deps();
    const warns: string[] = [];
    const orig = console.warn;
    console.warn = (...a: unknown[]) => warns.push(a.join(" "));
    try {
      const res = await handler(
        post(user, { origin: "ZZTZ", destination: "SFO", date: "2026-11-03" }),
        d,
      );
      assertEquals(res.status, 200);
    } finally {
      console.warn = orig;
    }
    assertEquals(d.aero.calls.route[0].slice(2), [
      "2026-11-03T00:00:00.000Z",
      "2026-11-04T00:00:00.000Z",
    ]);
    assert(warns.some((w) => w.includes("ZZTZ") && w.includes("UTC")));
  },
);
