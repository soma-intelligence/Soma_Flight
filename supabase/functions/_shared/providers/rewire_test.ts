// The functions through the provider layer with a non-AeroAPI provider: lookup, board, position,
// follow without alerts, and maintenance's poll mode. Fake providers, local stack.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { handler as boardHandler } from "../../airport-board/handler.ts";
import { handler as lookupHandler } from "../../flight-lookup/handler.ts";
import {
  callsignOf,
  handler as positionHandler,
} from "../../flight-position/handler.ts";
import { handler as followHandler } from "../../follow-flight/handler.ts";
import { handler as maintenanceHandler } from "../../maintenance/handler.ts";
import {
  fakeVerifier,
  makeUser,
  test,
  testDb,
  trackFlightId,
  trackProviderIds,
} from "../test_util.ts";
import { blankRow } from "./common.ts";
import { memoryQuota } from "./quota.ts";
import type { PositionQuery, ProviderFlight, StatusProvider } from "./types.ts";

const db = await testDb();
const HOUR = 3_600_000;

function flightAt(providerId: string, out: Date): ProviderFlight {
  const r = blankRow(providerId, "AF84", new Date());
  r.operator = "AF";
  r.origin_icao = "KSFO";
  r.origin_iata = "SFO";
  r.destination_icao = "LFPG";
  r.destination_iata = "CDG";
  r.scheduled_out = out.toISOString();
  r.scheduled_in = new Date(out.getTime() + 10 * HOUR).toISOString();
  r.gate_origin = "A3";
  r.status = "scheduled";
  return { ...r, origin_tz: "America/Los_Angeles" };
}

const post = (url: string, user: string, body: unknown) =>
  new Request(url, {
    method: "POST",
    headers: { authorization: `Bearer ${user}` },
    body: JSON.stringify(body),
  });

test(
  db,
  "flight-lookup stores a provider's rows and answers them, without AeroAPI",
  async () => {
    const user = await makeUser(db);
    const now = new Date();
    const pid = `aviationstack:AFR84:KSFO:RW${crypto.randomUUID().slice(0, 6)}`;
    trackProviderIds([pid]);
    // Two hours from now; the lookup date is its origin-local date.
    const out = new Date(now.getTime() + 2 * HOUR);
    const asked: [string, Date, Date][] = [];
    const status = {
      flightsByIdent(ident: string, from: Date, to: Date) {
        asked.push([ident, from, to]);
        return Promise.resolve([flightAt(pid, out)]);
      },
      searchRouteWindow: () => Promise.resolve([]),
    };
    const local = new Intl.DateTimeFormat("en-CA", {
      timeZone: "America/Los_Angeles",
    })
      .format(out);
    const res = await lookupHandler(
      post("http://local/flight-lookup", user, { ident: "AF84", date: local }),
      { db, status, verifier: fakeVerifier },
    );
    assertEquals(res.status, 200);
    const body = await res.json();
    assertEquals(
      body.flights.map((f: { provider_id: string }) => f.provider_id),
      [pid],
    );
    assertEquals(body.flights[0].gate_origin, "A3");
    assertEquals("origin_tz" in body.flights[0], false);
    assertEquals(asked[0][0], "AF84");
  },
);

test(db, "airport-board draws a provider's rows", async () => {
  const user = await makeUser(db);
  const icao = "KSFO";
  await db.from("airport_snapshots").delete().eq("icao", icao).eq(
    "kind",
    "departures",
  );
  const board = {
    boardFlights: (_icao: string, _kind: "departures" | "arrivals") =>
      Promise.resolve([
        flightAt(
          "flightlabs:AFR84:KSFO:2026-11-03",
          new Date("2026-11-03T23:40:00Z"),
        ),
      ]),
  };
  const res = await boardHandler(
    new Request(`http://local/airport-board?airport=SFO&kind=departures`, {
      headers: { authorization: `Bearer ${user}` },
    }),
    { db, board, verifier: fakeVerifier },
  );
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.flights.length, 1);
  assertEquals(body.flights[0].scheduled_out, "2026-11-03T23:40:00.000Z");
  assertEquals("origin_tz" in body.flights[0], false);
  await db.from("airport_snapshots").delete().eq("icao", icao).eq(
    "kind",
    "departures",
  );
});

test(
  db,
  "flight-position hands the provider a callsign and a point near the origin",
  async () => {
    const user = await makeUser(db);
    const { data } = await db.from("flights").insert({
      provider_id: `aviationstack:AFR84:KSFO:POS${
        crypto.randomUUID().slice(0, 6)
      }`,
      ident: "AF84",
      origin_icao: "KSFO",
      destination_icao: "LFPG",
      status: "en_route",
    }).select("id").single();
    trackFlightId(data!.id);
    await db.from("user_flights").insert({
      user_id: user,
      flight_id: data!.id,
    });
    const seen: PositionQuery[] = [];
    const position = {
      position(q: PositionQuery) {
        seen.push(q);
        return Promise.resolve({
          position_lat: 38,
          position_lon: -123,
          position_altitude_ft: 12000,
          position_ground_speed_kt: 300,
          position_heading: 250,
          position_at: new Date().toISOString(),
        });
      },
    };
    const res = await positionHandler(
      post("http://local/flight-position", user, { flightId: data!.id }),
      { db, position, verifier: fakeVerifier },
    );
    assertEquals((await res.json()).flight.position_lat, 38);
    assertEquals(seen[0].callsign, "AFR84");
    assert(seen[0].near && Math.abs(seen[0].near.lat - 37.62) < 0.1);
  },
);

Deno.test("callsigns from AeroAPI ids, synthetic ids and bare idents", () => {
  assertEquals(callsignOf("AFR84-1793600000-schedule-0001", "AF84"), "AFR84");
  assertEquals(callsignOf("flightlabs:AFR84:KSFO:2026-11-03", "AF84"), "AFR84");
  assertEquals(callsignOf("odd", "AF84"), "AF84");
});

test(
  db,
  "follow-flight without AeroAPI follows and makes no alert",
  async () => {
    const user = await makeUser(db);
    const { data } = await db.from("flights").insert({
      provider_id: `aviationstack:AFR84:KSFO:FOL${
        crypto.randomUUID().slice(0, 6)
      }`,
      ident: "AF84",
      origin_icao: "KSFO",
      destination_icao: "LFPG",
      scheduled_out: new Date(Date.now() + 5 * HOUR).toISOString(),
      status: "scheduled",
    }).select("id").single();
    trackFlightId(data!.id);
    const res = await followHandler(
      post("http://local/follow-flight", user, { flightId: data!.id }),
      { db, aero: null, verifier: fakeVerifier },
    );
    assertEquals(res.status, 200);
    const f = await db.from("flights").select("alert_id").eq("id", data!.id)
      .single();
    assertEquals(f.data?.alert_id, null);
    const del = await followHandler(
      new Request("http://local/follow-flight", {
        method: "DELETE",
        headers: { authorization: `Bearer ${user}` },
        body: JSON.stringify({ flightId: data!.id }),
      }),
      { db, aero: null, verifier: fakeVerifier },
    );
    assertEquals(del.status, 200);
  },
);

const b64 = (o: object) =>
  btoa(JSON.stringify(o)).replace(/=+$/, "").replace(/\+/g, "-").replace(
    /\//g,
    "_",
  );
const SERVICE_KEY = `${b64({ alg: "HS256" })}.${
  b64({ role: "service_role" })
}.sig`;
const maint = (mode: string) =>
  new Request(`http://local/maintenance?mode=${mode}`, {
    method: "POST",
    headers: { authorization: `Bearer ${SERVICE_KEY}` },
  });

test(
  db,
  "maintenance poll skips AeroAPI and none, and runs for a polled provider",
  async () => {
    const base = {
      db,
      aero: () => ({
        createAlert: () => Promise.resolve(1),
        deleteAlert: () => Promise.resolve(),
      }),
      serviceKey: () => SERVICE_KEY,
    };
    const never = {
      name: "aeroapi",
      flightStatus: () => Promise.reject(new Error("no")),
    } as unknown as StatusProvider;
    const skipped = await maintenanceHandler(maint("poll"), {
      ...base,
      poller: () => ({ name: "aeroapi", status: never, pace: memoryQuota(1) }),
    });
    assertEquals(await skipped.json(), {
      ok: true,
      mode: "poll",
      skipped: "aeroapi",
    });
    const none = await maintenanceHandler(maint("poll"), base);
    assertEquals((await none.json()).skipped, "none");
    const status = {
      name: "flightlabs",
      flightStatus: () => Promise.resolve(null),
    } as unknown as StatusProvider;
    const ran = await maintenanceHandler(maint("poll"), {
      ...base,
      poller: () => ({ name: "flightlabs", status, pace: memoryQuota(1000) }),
    });
    const body = await ran.json();
    assertEquals([body.ok, body.provider, body.stoppedBy], [
      true,
      "flightlabs",
      null,
    ]);
    assertEquals(typeof body.checked, "number");
  },
);
