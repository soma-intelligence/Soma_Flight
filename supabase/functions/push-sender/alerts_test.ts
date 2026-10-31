// push-sender's wider alerts on the local stack: preferences, dedupe in alert_log, the delay
// baseline, the inbound aircraft and the Live Activity priority of update events.
import { assertEquals } from "jsr:@std/assert@1";
import { exportPKCS8, generateKeyPair } from "npm:jose@5";
import {
  makeUser,
  test,
  testDb,
  trackFlightId,
  userClient,
} from "../_shared/test_util.ts";
import { type ApnsConfig, handler, mutedBy } from "./handler.ts";

const db = await testDb();
const { privateKey } = await generateKeyPair("ES256", { extractable: true });
const CFG: ApnsConfig = {
  teamId: "TEAMTEST01",
  keyId: "KEYTEST001",
  p8: await exportPKCS8(privateKey),
  bundleId: "me.soma.flight",
  sandbox: false,
};
const b64 = (o: object) =>
  btoa(JSON.stringify(o)).replace(/=+$/, "").replace(/\+/g, "-").replace(
    /\//g,
    "_",
  );
const SERVICE_KEY = `${b64({ alg: "HS256" })}.${
  b64({ role: "service_role" })
}.sig`;

interface Call {
  token: string;
  headers: Record<string, string>;
  // deno-lint-ignore no-explicit-any
  body: Record<string, any>;
}

function fakeApns() {
  const calls: Call[] = [];
  const fn = ((url: string, init: RequestInit) => {
    calls.push({
      token: url.split("/").pop()!,
      headers: init.headers as Record<string, string>,
      body: JSON.parse(init.body as string),
    });
    return Promise.resolve(new Response(null, { status: 200 }));
  }) as unknown as typeof fetch;
  return { calls, fn, alerts: () => calls.filter((c) => c.body.aps.alert) };
}

const hex = (n: number) => n.toString(16).padStart(8, "0").repeat(8);
let seq = Math.floor(Math.random() * 1e6) * 100 + 50;
const newToken = () => hex(++seq);

async function makeFlight(over: Record<string, unknown> = {}) {
  const tag = crypto.randomUUID().slice(0, 8).toUpperCase();
  const { data, error } = await db.from("flights").insert({
    provider_id: `ALT${tag}-1793600000-schedule-1p`,
    ident: "AF84",
    origin_icao: "LFPG",
    origin_iata: "CDG",
    destination_icao: "KSFO",
    destination_iata: "SFO",
    scheduled_out: "2026-11-03T22:30:00Z",
    scheduled_in: "2026-11-04T09:00:00Z",
    estimated_out: "2026-11-03T22:30:00Z",
    estimated_in: "2026-11-04T09:00:00Z",
    gate_origin: "K36",
    status: "scheduled",
    ...over,
  }).select("id, provider_id").single();
  if (error) throw error;
  trackFlightId(data.id);
  return { id: data.id as string, providerId: data.provider_id as string };
}

type Changes = Record<string, [unknown, unknown]>;

async function makeEvent(
  flightId: string,
  kind: string,
  changes: Changes,
  providerEventId = `t-${crypto.randomUUID()}`,
) {
  const { data, error } = await db.from("flight_events").insert({
    flight_id: flightId,
    provider_event_id: providerEventId,
    kind,
    payload: {
      changes: Object.fromEntries(
        Object.entries(changes).map(([k, [from, to]]) => [k, { from, to }]),
      ),
    },
  }).select("id").single();
  if (error) throw error;
  return data.id as string;
}

/** A follower with one alert token and, for `flightId`, one Live Activity token. */
async function follower(flightId: string, prefs?: Record<string, boolean>) {
  const u = await makeUser(db);
  const f = await db.from("user_flights").insert({
    user_id: u,
    flight_id: flightId,
  });
  if (f.error) throw f.error;
  const alert = newToken(), la = newToken();
  const t = await db.from("push_tokens").insert([
    { user_id: u, token: alert, kind: "alert" },
    { user_id: u, token: la, kind: "live_activity", flight_id: flightId },
  ]);
  if (t.error) throw t.error;
  if (prefs) {
    const p = await db.from("notification_preferences").insert({
      user_id: u,
      ...prefs,
    });
    if (p.error) throw p.error;
  }
  return { user: u, alert, la };
}

async function call(flightId: string, eventId: string, apns = fakeApns()) {
  const res = await handler(
    new Request("http://localhost/push-sender", {
      method: "POST",
      headers: { authorization: `Bearer ${SERVICE_KEY}` },
      body: JSON.stringify({ flightId, eventId }),
    }),
    {
      db,
      config: () => CFG,
      serviceKey: () => SERVICE_KEY,
      fetchFn: apns.fn,
      now: () => new Date("2026-11-03T21:00:00Z"),
    },
  );
  assertEquals(res.status, 200);
  return { out: await res.json(), apns };
}

test(db, "a muted category is skipped for that user only", async () => {
  const f = await makeFlight();
  const all = await follower(f.id);
  const noGates = await follower(f.id, { gates: false });
  const e = await makeEvent(f.id, "update", {
    gate_origin: ["K36", "G91"],
    actual_out: [null, "2026-11-03T22:41:00Z"],
    status: ["scheduled", "departed"],
  });
  const { out, apns } = await call(f.id, e);
  assertEquals(out.kinds.sort(), ["departed", "gate_change"]);
  const gate = apns.alerts().filter((c) => c.body.kind === "gate_change");
  assertEquals(gate.map((c) => c.token), [all.alert]);
  assertEquals(gate[0].body.aps.alert.title, "Gate changed to G91");
  const left = apns.alerts().filter((c) => c.body.kind === "departed");
  assertEquals(
    left.map((c) => c.token).sort(),
    [all.alert, noGates.alert].sort(),
  );
  assertEquals(out.alerts.sent, 3);
});

test(
  db,
  "each alert goes once: a retried call and the two events of a delivery",
  async () => {
    const f = await makeFlight();
    const u = await follower(f.id);
    const changes: Changes = {
      gate_origin: ["K36", "K50"],
      estimated_out: ["2026-11-03T22:30:00Z", "2026-11-03T23:10:00Z"],
    };
    const dlv = `dlv-${crypto.randomUUID()}`;
    const gate = await makeEvent(f.id, "gate_change", changes, dlv);
    const delay = await makeEvent(f.id, "delay", changes, `${dlv}:delay`);
    const first = await call(f.id, gate);
    assertEquals(first.out.kinds.sort(), ["departure_delay", "gate_change"]);
    assertEquals(
      first.apns.alerts().find((c) => c.body.kind === "departure_delay")!.body
        .aps.alert.title,
      "AF 84 is now 40m late",
    );
    const again = await call(f.id, gate);
    const second = await call(f.id, delay);
    assertEquals(again.out.kinds, []);
    assertEquals(second.out.kinds, []);
    assertEquals(again.apns.alerts().length + second.apns.alerts().length, 0);
    // The Live Activity is still updated every time.
    assertEquals(second.apns.calls.map((c) => c.token), [u.la]);
    const log = await db.from("alert_log").select("kind, minutes").eq(
      "flight_id",
      f.id,
    );
    assertEquals(
      (log.data ?? []).map((r) => `${r.kind}:${r.minutes}`).sort(),
      ["departure_delay:40", "gate_change:null"],
    );
  },
);

test(
  db,
  "the next delay alert is measured from the last one sent",
  async () => {
    const f = await makeFlight();
    await follower(f.id);
    const est = (a: string, b: string) => ({
      estimated_out: [a, b] as [string, string],
    });
    const steps: [string, string, boolean][] = [
      ["2026-11-03T22:30:00Z", "2026-11-03T22:55:00Z", true], // 25 late
      ["2026-11-03T22:55:00Z", "2026-11-03T23:02:00Z", false], // 32: 7 off the last
      ["2026-11-03T23:02:00Z", "2026-11-03T23:15:00Z", true], // 45: 20 off
      ["2026-11-03T23:15:00Z", "2026-11-03T22:32:00Z", true], // back on time
      ["2026-11-03T22:32:00Z", "2026-11-03T22:30:00Z", false],
    ];
    const titles: string[] = [];
    for (const [a, b, sends] of steps) {
      // The row moves with the delivery, as process_alert writes it.
      await db.from("flights").update({ estimated_out: b }).eq("id", f.id);
      const { out, apns } = await call(
        f.id,
        await makeEvent(f.id, "update", est(a, b)),
      );
      assertEquals(out.kinds.length, sends ? 1 : 0, `${a} to ${b}`);
      titles.push(...apns.alerts().map((c) => c.body.aps.alert.title));
    }
    assertEquals(titles, [
      "AF 84 is now 25m late",
      "AF 84 is now 45m late",
      "AF 84 is back on time",
    ]);
  },
);

test(
  db,
  "inbound aircraft late: from the inbound leg's event and from the flight's own",
  async () => {
    const inbound = await makeFlight({
      ident: "AF83",
      origin_icao: "KSFO",
      origin_iata: "SFO",
      destination_icao: "LFPG",
      destination_iata: "CDG",
      scheduled_out: "2026-11-03T10:00:00Z",
      scheduled_in: "2026-11-03T21:30:00Z",
      estimated_in: "2026-11-03T21:40:00Z",
      actual_out: "2026-11-03T10:00:00Z",
      status: "en_route",
    });
    const f = await makeFlight({ inbound_provider_id: inbound.providerId });
    const u = await follower(f.id);
    // On time inbound: nothing for the flight.
    const quiet = await call(
      inbound.id,
      await makeEvent(inbound.id, "update", {
        estimated_in: ["2026-11-03T21:30:00Z", "2026-11-03T21:40:00Z"],
      }),
    );
    assertEquals(quiet.out.kinds, []);
    // Now 22:20, ready at 22:50 for a 22:30 departure.
    await db.from("flights").update({ estimated_in: "2026-11-03T22:20:00Z" })
      .eq("id", inbound.id);
    const late = await call(
      inbound.id,
      await makeEvent(inbound.id, "update", {
        estimated_in: ["2026-11-03T21:40:00Z", "2026-11-03T22:20:00Z"],
      }),
    );
    assertEquals(late.out.kinds, ["inbound_late"]);
    const c = late.apns.alerts()[0];
    assertEquals(c.token, u.alert);
    assertEquals(c.body.flightId, f.id);
    assertEquals(c.body.aps.alert.title, "AF 84 inbound plane is late");
    // Once only, whichever flight's event comes next.
    const own = await call(
      f.id,
      await makeEvent(f.id, "update", { terminal_origin: ["2E", "2F"] }),
    );
    assertEquals(own.out.kinds, ["terminal_change"]);
  },
);

test(db, "a flight with an unknown inbound leg skips the check", async () => {
  const f = await makeFlight({ inbound_provider_id: "NOT-IN-FLIGHTS-1" });
  await follower(f.id);
  const { out } = await call(
    f.id,
    await makeEvent(f.id, "update", { terminal_origin: ["2E", "2F"] }),
  );
  assertEquals(out.kinds, ["terminal_change"]);
});

test(
  db,
  "update events: priority 10 for take-off, 5 for an estimate",
  async () => {
    const f = await makeFlight({
      status: "en_route",
      actual_out: "2026-11-03T22:41:00Z",
      actual_off: "2026-11-03T22:58:00Z",
    });
    const u = await follower(f.id);
    const off = await call(
      f.id,
      await makeEvent(f.id, "update", {
        actual_off: [null, "2026-11-03T22:58:00Z"],
        status: ["departed", "en_route"],
      }),
    );
    assertEquals(off.out.kinds, ["takeoff"]);
    const la = (c: Call[]) => c.find((x) => x.token === u.la)!;
    assertEquals(la(off.apns.calls).headers["apns-priority"], "10");
    assertEquals(off.apns.alerts()[0].body.aps.alert.title, "AF 84 took off");
    const est = await call(
      f.id,
      await makeEvent(f.id, "update", {
        estimated_in: ["2026-11-04T09:00:00Z", "2026-11-04T09:06:00Z"],
      }),
    );
    assertEquals(est.out.kinds, []);
    assertEquals(la(est.apns.calls).headers["apns-priority"], "5");
  },
);

test(
  db,
  "the app's upsert saves preferences, only for its own user",
  async () => {
    const [a, b] = [await makeUser(db), await makeUser(db)];
    const ca = await userClient(db, a);
    const cb = await userClient(db, b);
    for (const gates of [false, true, false]) {
      const r = await ca.from("notification_preferences").upsert(
        {
          user_id: a,
          gates,
          delays: true,
          updated_at: new Date().toISOString(),
        },
        { onConflict: "user_id" },
      );
      assertEquals(r.error, null);
    }
    const mine = await ca.from("notification_preferences").select(
      "gates, baggage",
    );
    assertEquals(mine.data, [{ gates: false, baggage: true }]);
    assertEquals(
      (await cb.from("notification_preferences").select("*")).data,
      [],
    );
    const steal = await cb.from("notification_preferences").upsert(
      { user_id: a, gates: true },
      { onConflict: "user_id" },
    );
    assertEquals(steal.error?.code, "42501");
    const muted = await mutedBy(db, new Set([a, b]));
    assertEquals([...muted.get("gates")!], [a]);
    assertEquals(muted.get("delays")!.size, 0);
  },
);

test(
  db,
  "a connection at risk is told once, to the users who follow both flights",
  async () => {
    // AF 84 lands at SFO at 09:00Z, UA 1958 leaves at 11:00Z: 2 hours against SFO's 1h 30m.
    const a = await makeFlight();
    const b = await makeFlight({
      ident: "UA1958",
      origin_icao: "KSFO",
      origin_iata: "SFO",
      destination_icao: "KORD",
      destination_iata: "ORD",
      scheduled_out: "2026-11-04T11:00:00Z",
      scheduled_in: "2026-11-04T15:15:00Z",
      estimated_out: "2026-11-04T11:00:00Z",
      estimated_in: "2026-11-04T15:15:00Z",
      gate_origin: "F3",
    });
    const both = await follower(a.id);
    const second = await db.from("user_flights").insert({
      user_id: both.user,
      flight_id: b.id,
    });
    if (second.error) throw second.error;
    const onlyFirst = await follower(a.id);
    const delaysOff = await follower(a.id, { delays: false });
    const third = await db.from("user_flights").insert({
      user_id: delaysOff.user,
      flight_id: b.id,
    });
    if (third.error) throw third.error;

    // Still 1h 45m: tight, nothing to say.
    await db.from("flights").update({ estimated_in: "2026-11-04T09:15:00Z" })
      .eq("id", a.id);
    const fine = await call(
      a.id,
      await makeEvent(a.id, "update", {
        estimated_in: ["2026-11-04T09:00:00Z", "2026-11-04T09:15:00Z"],
      }),
    );
    assertEquals(fine.out.kinds, []);

    // 45 minutes: at risk.
    await db.from("flights").update({ estimated_in: "2026-11-04T10:15:00Z" })
      .eq("id", a.id);
    const risk = await call(
      a.id,
      await makeEvent(a.id, "update", {
        estimated_in: ["2026-11-04T09:15:00Z", "2026-11-04T10:15:00Z"],
      }),
    );
    assertEquals(risk.out.kinds, ["connection_at_risk"]);
    const sent = risk.apns.alerts();
    assertEquals(sent.map((c) => c.token), [both.alert]);
    assertEquals(sent[0].body.flightId, a.id);
    assertEquals(sent[0].body.aps.alert, {
      title: "AF 84 connection at risk",
      body:
        "Only 45m to make UA 1958 at SFO, where it usually takes 1h 30m. Tell the crew you are connecting.",
    });
    assertEquals(onlyFirst.alert === sent[0].token, false);

    // Worse again, seen from the onward flight's event: already told.
    await db.from("flights").update({ estimated_in: "2026-11-04T10:40:00Z" })
      .eq("id", a.id);
    const again = await call(
      b.id,
      await makeEvent(b.id, "update", { gate_origin: ["F3", "F5"] }),
    );
    assertEquals(again.out.kinds.includes("connection_at_risk"), false);
  },
);
// MARK: Airport program alerts (faa-status's sweep)

async function callProgram(
  flightId: string,
  program: unknown,
  apns = fakeApns(),
) {
  const res = await handler(
    new Request("http://localhost/push-sender", {
      method: "POST",
      headers: { authorization: `Bearer ${SERVICE_KEY}` },
      body: JSON.stringify({ flightId, program }),
    }),
    {
      db,
      config: () => CFG,
      serviceKey: () => SERVICE_KEY,
      fetchFn: apns.fn,
      now: () => new Date("2026-11-03T21:00:00Z"),
    },
  );
  return { status: res.status, out: await res.json(), apns };
}

const PROGRAM = {
  key: "airport_program:KSFO:ground_delay:2026-11-03T20:00",
  kind: "ground_delay",
  end: "destination",
  code: "SFO",
  reason: "low clouds",
  average_minutes: 47,
  ends_at: "2026-11-04T07:00:00Z",
};

test(
  db,
  "a program alert goes once, to the followers who want delays",
  async () => {
    const f = await makeFlight();
    const all = await follower(f.id);
    await follower(f.id, { delays: false });
    const first = await callProgram(f.id, PROGRAM);
    assertEquals(first.status, 200);
    assertEquals(first.out.kinds, ["airport_program"]);
    const sent = first.apns.alerts();
    assertEquals(sent.map((c) => c.token), [all.alert]);
    assertEquals(sent[0].body.kind, "airport_program");
    assertEquals(sent[0].body.eventId, null);
    assertEquals(sent[0].body.aps.alert.title, "Ground delay program at SFO");
    assertEquals(
      sent[0].headers["apns-collapse-id"],
      `${f.id}:airport_program`,
    );
    // No Live Activity update for a program.
    assertEquals(first.apns.calls.length, 1);
    const again = await callProgram(f.id, PROGRAM);
    assertEquals([again.out.kinds, again.apns.calls.length], [[], 0]);
  },
);

test(db, "a malformed program is refused", async () => {
  const f = await makeFlight();
  const bad = await callProgram(f.id, { ...PROGRAM, kind: "deicing" });
  assertEquals(bad.status, 400);
  const none = await callProgram(crypto.randomUUID(), PROGRAM);
  assertEquals(none.status, 404);
});
