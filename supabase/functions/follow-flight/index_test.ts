import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  fakeVerifier,
  makeUser,
  test,
  testDb,
  trackFlightId,
} from "../_shared/test_util.ts";
import { handler } from "./handler.ts";

const db = await testDb();

function fakeAero(delayMs = 0) {
  const calls = {
    create: [] as { ident: string; start: string; end: string }[],
    del: [] as number[],
  };
  let next = Math.floor(Math.random() * 1e9);
  return {
    calls,
    failDelete: false,
    async createAlert(ident: string, start: string, end: string) {
      calls.create.push({ ident, start, end });
      const id = ++next;
      if (delayMs) await new Promise((r) => setTimeout(r, delayMs));
      return id;
    },
    deleteAlert(id: number) {
      if (this.failDelete) return Promise.reject(new Error("provider down"));
      calls.del.push(id);
      return Promise.resolve();
    },
  };
}

async function makeFlight(over: Record<string, unknown> = {}): Promise<string> {
  const tag = crypto.randomUUID().slice(0, 8).toUpperCase();
  const { data, error } = await db.from("flights").insert({
    provider_id: `TST${tag}-1793600000-schedule-1p`,
    ident: `TS${tag}`,
    origin_icao: "LFPG",
    destination_icao: "KSFO",
    scheduled_out: "2026-11-03T22:30:00Z",
    scheduled_in: "2026-11-04T09:00:00Z",
    status: "scheduled",
    ...over,
  }).select("id").single();
  if (error) throw error;
  trackFlightId(data.id);
  return data.id;
}

function req(method: string, user: string | null, body: unknown): Request {
  return new Request("http://localhost/follow-flight", {
    method,
    headers: user ? { authorization: `Bearer ${user}` } : {},
    body: JSON.stringify(body),
  });
}

const alertOf = async (id: string) =>
  (await db.from("flights").select("alert_id").eq("id", id).single()).data
    ?.alert_id;

test(db, "follow creates alert once", async () => {
  const [a, b] = [await makeUser(db), await makeUser(db)];
  const flight = await makeFlight();
  const aero = fakeAero();
  const d = { db, aero, verifier: fakeVerifier };
  assertEquals(
    (await handler(req("POST", a, { flightId: flight }), d)).status,
    200,
  );
  assertEquals(
    (await handler(req("POST", b, { flightId: flight }), d)).status,
    200,
  );
  assertEquals(aero.calls.create.length, 1);
  assertEquals(aero.calls.del.length, 0);
  assert((await alertOf(flight)) !== null);
  // ICAO ident; window = the local departure date only (22:30Z is 23:30 in Paris, still 11-03).
  assert(aero.calls.create[0].ident.startsWith("TST"));
  assertEquals(aero.calls.create[0].start, "2026-11-03");
  assertEquals(aero.calls.create[0].end, "2026-11-03");
});

test(db, "alert window uses the departure airport timezone", async () => {
  const user = await makeUser(db);
  // 2026-11-04T04:00Z is 20:00 on 11-03 in San Francisco and 05:00 on 11-04 in Paris.
  const flight = await makeFlight({
    origin_icao: "KSFO",
    scheduled_out: "2026-11-04T04:00:00Z",
  });
  const aero = fakeAero();
  await handler(req("POST", user, { flightId: flight }), {
    db,
    aero,
    verifier: fakeVerifier,
  });
  assertEquals(aero.calls.create[0].start, "2026-11-03");
  assertEquals(aero.calls.create[0].end, "2026-11-03");
});

test(db, "parallel follows of one flight leave exactly one alert", async () => {
  const users = await Promise.all([1, 2, 3, 4].map(() => makeUser(db)));
  const flight = await makeFlight();
  const aero = fakeAero(80);
  const d = { db, aero, verifier: fakeVerifier };
  const res = await Promise.all(
    users.map((u) => handler(req("POST", u, { flightId: flight }), d)),
  );
  assertEquals(res.map((r) => r.status), [200, 200, 200, 200]);
  const stored = await alertOf(flight);
  assert(stored !== null);
  assertEquals(aero.calls.create.length - aero.calls.del.length, 1);
  assert(!aero.calls.del.includes(Number(stored)));
});

test(
  db,
  "4th follow on free plan returns 403 plan_limit, pro passes",
  async () => {
    const free = await makeUser(db);
    const pro = await makeUser(db, "pro");
    const flights = [];
    for (let i = 0; i < 4; i++) flights.push(await makeFlight());
    const d = { db, aero: fakeAero(), verifier: fakeVerifier };
    for (let i = 0; i < 3; i++) {
      assertEquals(
        (await handler(req("POST", free, { flightId: flights[i] }), d)).status,
        200,
      );
    }
    const res = await handler(req("POST", free, { flightId: flights[3] }), d);
    assertEquals(res.status, 403);
    assertEquals((await res.json()).error.code, "plan_limit");
    // Following again a flight already followed is idempotent, not a new follow.
    assertEquals(
      (await handler(req("POST", free, { flightId: flights[0] }), d)).status,
      200,
    );
    for (let i = 0; i < 4; i++) {
      assertEquals(
        (await handler(req("POST", pro, { flightId: flights[i] }), d)).status,
        200,
      );
    }
  },
);

test(db, "plan limit holds under parallel follows", async () => {
  const free = await makeUser(db);
  const flights = [];
  for (let i = 0; i < 6; i++) flights.push(await makeFlight());
  const d = { db, aero: fakeAero(), verifier: fakeVerifier };
  const res = await Promise.all(
    flights.map((f) => handler(req("POST", free, { flightId: f }), d)),
  );
  assertEquals(res.filter((r) => r.status === 200).length, 3);
  assertEquals(res.filter((r) => r.status === 403).length, 3);
});

test(db, "finished flights do not count toward the free limit", async () => {
  const free = await makeUser(db);
  const d = { db, aero: fakeAero(), verifier: fakeVerifier };
  for (const status of ["arrived", "canceled", "arrived"]) {
    const f = await makeFlight({ status });
    assertEquals(
      (await handler(req("POST", free, { flightId: f }), d)).status,
      200,
    );
  }
  assertEquals(d.aero.calls.create.length, 0);
  for (let i = 0; i < 3; i++) {
    const f = await makeFlight();
    assertEquals(
      (await handler(req("POST", free, { flightId: f }), d)).status,
      200,
    );
  }
});

test(db, "unfollow by last follower deletes alert", async () => {
  const [a, b] = [await makeUser(db), await makeUser(db)];
  const flight = await makeFlight();
  const aero = fakeAero();
  const d = { db, aero, verifier: fakeVerifier };
  await handler(req("POST", a, { flightId: flight }), d);
  await handler(req("POST", b, { flightId: flight }), d);
  const alert = await alertOf(flight);
  assertEquals(
    (await handler(req("DELETE", a, { flightId: flight }), d)).status,
    200,
  );
  assertEquals(aero.calls.del.length, 0);
  assertEquals(await alertOf(flight), alert);
  assertEquals(
    (await handler(req("DELETE", b, { flightId: flight }), d)).status,
    200,
  );
  assertEquals(aero.calls.del, [Number(alert)]);
  assertEquals(await alertOf(flight), null);
  assertEquals(
    (await handler(req("DELETE", b, { flightId: flight }), d)).status,
    200,
  );
  assertEquals(aero.calls.del.length, 1);
});

test(
  db,
  "unfollow while createAlert is in flight leaves no orphan alert",
  async () => {
    const user = await makeUser(db);
    const flight = await makeFlight();
    const aero = fakeAero(250);
    const d = { db, aero, verifier: fakeVerifier };
    const follow = handler(req("POST", user, { flightId: flight }), d);
    // Wait for the follow row, then unfollow while the alert is still being created.
    for (let i = 0; i < 100; i++) {
      const r = await db.from("user_flights").select("user_id").eq(
        "flight_id",
        flight,
      );
      if ((r.data ?? []).length > 0) break;
      await new Promise((r) => setTimeout(r, 5));
    }
    const unfollow = await handler(
      req("DELETE", user, { flightId: flight }),
      d,
    );
    assertEquals(unfollow.status, 200);
    assertEquals((await follow).status, 200);
    assertEquals(await alertOf(flight), null);
    assertEquals(aero.calls.create.length, 1);
    assertEquals(aero.calls.del.length, 1);
  },
);

test(db, "provider delete failure keeps alert_id for a retry", async () => {
  const user = await makeUser(db);
  const flight = await makeFlight();
  const aero = fakeAero();
  const d = { db, aero, verifier: fakeVerifier };
  await handler(req("POST", user, { flightId: flight }), d);
  const alert = await alertOf(flight);
  assert(alert !== null);
  aero.failDelete = true;
  const res = await handler(req("DELETE", user, { flightId: flight }), d);
  assertEquals(res.status, 200);
  assertEquals(await alertOf(flight), alert);
  // The provider recovers: a later release clears it.
  aero.failDelete = false;
  const other = await makeUser(db);
  await handler(req("POST", other, { flightId: flight }), d);
  await handler(req("DELETE", other, { flightId: flight }), d);
  assertEquals(aero.calls.del, [Number(alert)]);
  assertEquals(await alertOf(flight), null);
});

test(db, "auth, validation and unknown flight", async () => {
  const user = await makeUser(db);
  const d = { db, aero: fakeAero(), verifier: fakeVerifier };
  assertEquals(
    (await handler(req("POST", null, { flightId: crypto.randomUUID() }), d))
      .status,
    401,
  );
  const bad = await handler(req("POST", user, { flightId: "nope" }), d);
  assertEquals(bad.status, 400);
  assertEquals((await bad.json()).error.code, "invalid_request");
  const missing = await handler(
    req("POST", user, { flightId: crypto.randomUUID() }),
    d,
  );
  assertEquals(missing.status, 404);
  assertEquals((await missing.json()).error.code, "not_found");
});

test(db, "alert failure rolls back a new follow", async () => {
  const user = await makeUser(db);
  const flight = await makeFlight();
  const aero = {
    createAlert: () => Promise.reject(new Error("provider down")),
    deleteAlert: () => Promise.resolve(),
  };
  const res = await handler(req("POST", user, { flightId: flight }), {
    db,
    aero,
    verifier: fakeVerifier,
  });
  assertEquals(res.status, 500);
  const rows = await db.from("user_flights").select("user_id").eq(
    "flight_id",
    flight,
  );
  assertEquals(rows.data?.length, 0);
});
