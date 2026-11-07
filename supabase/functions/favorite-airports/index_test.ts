// favorite-airports: the planning of who gets which push (pure), the gates of the handler (service role,
// mode, flag) and the push-sender input check. No database and no network: the db is a stub that fails
// when touched. The sweep's queries are covered by the local stack run, which this file does not need.
import { assert, assertEquals } from "jsr:@std/assert@1";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { Program } from "../_shared/faa_nas.ts";
import { programKey } from "../_shared/faa_nas.ts";
import { readFavoriteAlert } from "../_shared/favorite_alerts.ts";
import {
  type AirportRow,
  favoriteKey,
  handler,
  planFavoriteAlerts,
} from "./handler.ts";

const program = (over: Partial<Program> = {}): Program => ({
  airport: "SFO",
  kind: "ground_stop",
  reason: "low clouds",
  reason_raw: null,
  average_minutes: null,
  trend: null,
  extension: null,
  starts_at: "2026-11-07T18:00:00Z",
  ends_at: "2026-11-07T20:00:00Z",
  updated_at: null,
  advisory: null,
  ...over,
} as Program);

const SFO: AirportRow = { icao: "KSFO", iata: "SFO", country: "US" };
const CDG: AirportRow = { icao: "LFPG", iata: "CDG", country: "FR" };
const U1 = "11111111-1111-4111-8111-111111111111";
const U2 = "22222222-2222-4222-8222-222222222222";

Deno.test("plan: one push per user and program, only for followed airports", () => {
  const ps = [
    program(),
    program({ kind: "ground_delay", average_minutes: 45 }),
  ];
  const plan = planFavoriteAlerts(
    ps,
    [SFO],
    [
      { user_id: U2, airport_icao: "KSFO" },
      { user_id: U1, airport_icao: "KSFO" },
      { user_id: U1, airport_icao: "KJFK" },
    ],
    new Set(),
    new Set(),
  );
  assertEquals(plan.map((a) => [a.user_id, a.kind, a.code]), [
    [U1, "ground_stop", "SFO"],
    [U1, "ground_delay", "SFO"],
    [U2, "ground_stop", "SFO"],
    [U2, "ground_delay", "SFO"],
  ]);
  assertEquals(plan[0].key, favoriteKey("KSFO", ps[0]));
  assert(plan[0].key.startsWith("favorite:airport_program:KSFO:ground_stop:"));
});

Deno.test("plan: sent keys, flight covered users, non FAA airports and minor kinds are left out", () => {
  const p = program();
  const sent = new Set([`${U1} ${favoriteKey("KSFO", p)}`]);
  const covered = new Set([`${U2} ${programKey("KSFO", p)}`]);
  const favs = [
    { user_id: U1, airport_icao: "KSFO" },
    { user_id: U2, airport_icao: "KSFO" },
  ];
  assertEquals(planFavoriteAlerts([p], [SFO], favs, sent, covered), []);
  // A revision of the same program (later end, new average) keeps the key, so it is not sent again.
  const revised = program({
    ends_at: "2026-11-07T22:00:00Z",
    average_minutes: 30,
  });
  assertEquals(
    planFavoriteAlerts([revised], [SFO], favs, sent, new Set()).map((a) =>
      a.user_id
    ),
    [U2],
  );
  // A new program later at the same airport is new.
  const later = program({ starts_at: "2026-11-08T01:00:00Z" });
  assertEquals(
    planFavoriteAlerts([later], [SFO], favs, sent, covered).map((a) =>
      a.user_id
    ),
    [U1, U2],
  );
  assertEquals(
    planFavoriteAlerts(
      [program({ airport: "CDG" })],
      [CDG],
      [
        { user_id: U1, airport_icao: "LFPG" },
      ],
      new Set(),
      new Set(),
    ),
    [],
  );
  assertEquals(
    planFavoriteAlerts(
      [program({ kind: "departure_delay" })],
      [SFO],
      favs,
      new Set(),
      new Set(),
    ),
    [],
  );
});

const touched: string[] = [];
const db = new Proxy({}, {
  get: (_t, prop) => {
    touched.push(String(prop));
    throw new Error("db touched");
  },
}) as unknown as SupabaseClient;
const KEY = "service-key";
const post = (qs: string, token?: string) =>
  new Request(`http://x/favorite-airports${qs}`, {
    method: "POST",
    headers: token ? { authorization: `Bearer ${token}` } : {},
  });

Deno.test("handler: service role only, mode sweep, off by default", async () => {
  const deps = { db, serviceKey: () => KEY, enabled: () => false };
  assertEquals((await handler(post("?mode=sweep"), deps)).status, 401);
  assertEquals((await handler(post("?mode=sweep", "nope"), deps)).status, 401);
  assertEquals((await handler(post("?mode=x", KEY), deps)).status, 400);
  assertEquals(
    (await handler(new Request("http://x/", { method: "GET" }), deps)).status,
    405,
  );
  const off = await handler(post("?mode=sweep", KEY), deps);
  assertEquals(await off.json(), {
    ok: true,
    mode: "sweep",
    skipped: "disabled",
  });
  assertEquals(touched, []);
});

Deno.test("readFavoriteAlert accepts the sweep's shape and nothing else", () => {
  const good = {
    user_id: U1,
    key: "favorite:airport_program:KSFO:ground_stop:2026-11-07T18:00",
    kind: "ground_stop",
    code: "SFO",
    airport_icao: "KSFO",
    reason: "low clouds",
    average_minutes: null,
    ends_at: "2026-11-07T20:00:00Z",
  };
  assertEquals(readFavoriteAlert(good)?.code, "SFO");
  assertEquals(readFavoriteAlert({ ...good, user_id: "nope" }), null);
  assertEquals(readFavoriteAlert({ ...good, key: "airport_program:x" }), null);
  assertEquals(readFavoriteAlert({ ...good, kind: "deicing" }), null);
  assertEquals(readFavoriteAlert({ ...good, code: "sfo" }), null);
  assertEquals(readFavoriteAlert(null), null);
  assertEquals(
    readFavoriteAlert({ ...good, ends_at: "garbage" })?.ends_at,
    null,
  );
});
