import { assertEquals } from "jsr:@std/assert@1";
import type { PositionRow } from "../_shared/aeroapi_types.ts";
import { ApiError } from "../_shared/errors.ts";
import {
  fakeVerifier,
  loadIndexHandler,
  makeUser,
  test,
  testDb,
  trackFlightId,
} from "../_shared/test_util.ts";
import { handler } from "./handler.ts";

const db = await testDb();

const POSITION: PositionRow = {
  position_lat: 48.5,
  position_lon: -30.25,
  position_altitude_ft: 37000,
  position_ground_speed_kt: 480,
  position_heading: 265,
  position_at: "2026-11-03T16:00:00Z",
};

function fakeAero(
  answer: () => Promise<PositionRow | null> = () => Promise.resolve(POSITION),
) {
  const calls: string[] = [];
  return {
    calls,
    flightPosition(id: string) {
      calls.push(id);
      return answer();
    },
  };
}

function post(token: string | null, body: unknown): Request {
  return new Request("http://localhost/flight-position", {
    method: "POST",
    headers: token ? { authorization: `Bearer ${token}` } : {},
    body: JSON.stringify(body),
  });
}

async function flight(status: string, followers: string[]) {
  const providerId = `POS${crypto.randomUUID().slice(0, 8)}-1-schedule-1p`;
  const { data, error } = await db.from("flights").insert({
    provider_id: providerId,
    ident: "AF7",
    origin_icao: "KJFK",
    destination_icao: "LFPG",
    status,
  }).select("id").single();
  if (error) throw error;
  trackFlightId(data.id);
  for (const user_id of followers) {
    const r = await db.from("user_flights").insert({
      user_id,
      flight_id: data.id,
    });
    if (r.error) throw r.error;
  }
  return { id: data.id as string, providerId };
}

test(
  db,
  "an en route followed flight gets one position per window, shared by its followers",
  async () => {
    const a = await makeUser(db), b = await makeUser(db);
    const { id, providerId } = await flight("en_route", [a, b]);
    const aero = fakeAero();
    const d = { db, aero, verifier: fakeVerifier };
    const first = await handler(post(a, { flightId: id }), d);
    assertEquals(first.status, 200);
    const f = (await first.json()).flight;
    assertEquals([f.position_lat, f.position_lon], [48.5, -30.25]);
    assertEquals(f.position_altitude_ft, 37000);
    assertEquals(aero.calls, [providerId]);
    // Inside the window: the stored row, no provider call, whoever asks.
    for (const u of [a, b]) {
      const again = await handler(post(u, { flightId: id }), d);
      assertEquals((await again.json()).flight.position_lat, 48.5);
    }
    assertEquals(aero.calls.length, 1);
    // The window ends: the next viewer pays for a new one.
    await db.from("position_refresh_leases").update({
      until: new Date(Date.now() - 1000).toISOString(),
    }).eq("flight_id", id);
    await handler(post(b, { flightId: id }), d);
    assertEquals(aero.calls.length, 2);
  },
);

test(
  db,
  "no provider call for a flight on the ground or not followed by the caller",
  async () => {
    const a = await makeUser(db), other = await makeUser(db);
    const aero = fakeAero();
    const d = { db, aero, verifier: fakeVerifier };
    for (const status of ["scheduled", "landed", "arrived", "canceled"]) {
      const { id } = await flight(status, [a]);
      const res = await handler(post(a, { flightId: id }), d);
      assertEquals(res.status, 200);
      assertEquals((await res.json()).flight.status, status);
    }
    const { id } = await flight("departed", [a]);
    const res = await handler(post(other, { flightId: id }), d);
    assertEquals(res.status, 200);
    assertEquals((await res.json()).flight.position_lat, null);
    assertEquals(aero.calls.length, 0);
  },
);

test(db, "a provider failure answers the stored row", async () => {
  const a = await makeUser(db);
  const { id } = await flight("en_route", [a]);
  const orig = console.error;
  console.error = () => {};
  try {
    const aero = fakeAero(() =>
      Promise.reject(new ApiError("provider_unavailable", 503, "cap"))
    );
    const res = await handler(post(a, { flightId: id }), {
      db,
      aero,
      verifier: fakeVerifier,
    });
    assertEquals(res.status, 200);
    assertEquals((await res.json()).flight.id, id);
    assertEquals(aero.calls.length, 1);
  } finally {
    console.error = orig;
  }
});

test(
  db,
  "bad input, unknown flights and missing tokens are typed errors",
  async () => {
    const a = await makeUser(db);
    const d = { db, aero: fakeAero(), verifier: fakeVerifier };
    const bad = await handler(post(a, { flightId: "nope" }), d);
    assertEquals([bad.status, (await bad.json()).error.code], [
      400,
      "invalid_request",
    ]);
    const unknown = await handler(
      post(a, { flightId: crypto.randomUUID() }),
      d,
    );
    assertEquals([unknown.status, (await unknown.json()).error.code], [
      404,
      "not_found",
    ]);
    const anon = await handler(
      post(null, { flightId: crypto.randomUUID() }),
      d,
    );
    assertEquals(anon.status, 401);
    const get = await handler(
      new Request("http://localhost/flight-position", {
        headers: { authorization: `Bearer ${a}` },
      }),
      d,
    );
    assertEquals(get.status, 405);
  },
);

test(db, "flight-position starts without AEROAPI_KEY", async () => {
  const serve = await loadIndexHandler(
    new URL("./index.ts", import.meta.url).href,
  );
  const res = await serve(post(null, {}));
  assertEquals(res.status, 401);
});
