// In-flight texts: who gets which text, the window, one text per alert, the switches. Fake sender and
// in-memory database: no network, no local stack.
import { assert, assertEquals } from "jsr:@std/assert@1";
import type { Alert, AlertCategory, AlertFlight } from "./alerts.ts";
import {
  inFlightWindow,
  onwardLine,
  planSms,
  smsHook,
  type SmsRow,
  type SmsSender,
  wantsInFlight,
} from "./sms_alerts.ts";
import { claimOnce, fakeDb } from "./sms_test_db.ts";

const FLIGHT_ID = "f0000000-0000-4000-8000-000000000001";
const flight: AlertFlight = {
  ident: "AF84",
  status: "en_route",
  scheduled_out: "2026-11-03T12:00:00Z",
  estimated_out: "2026-11-03T12:10:00Z",
  actual_out: "2026-11-03T12:12:00Z",
  scheduled_in: "2026-11-03T23:00:00Z",
  estimated_in: "2026-11-03T23:20:00Z",
  actual_in: null,
};
const AIRBORNE = new Date("2026-11-03T18:00:00Z");

const landing: Alert = {
  kind: "landing",
  category: "takeoff_landing",
  key: "landing",
};
const belt: Alert = {
  kind: "baggage_belt",
  category: "baggage",
  key: "baggage_belt:d1",
  to: "7",
};
const arrivalGate: Alert = {
  kind: "gate_change",
  category: "gates",
  key: "gate_change:arrival:d1",
  side: "arrival",
  from: "K38",
  to: "K40",
};
const diversion: Alert = {
  kind: "diversion",
  category: "cancellations",
  key: "diversion:d1",
  to: "LAX",
};
const text = { title: "AF 84 landed", body: "Landed at SFO at 3:20 PM." };

function row(over: Partial<SmsRow> = {}): SmsRow {
  return {
    user_id: "u1",
    phone_e164: "+14155550100",
    code_hash: null,
    code_expires_at: null,
    attempts: 0,
    verified_at: "2026-10-31T10:00:00Z",
    enabled: false,
    opted_out_at: null,
    in_flight: true,
    ...over,
  };
}

const allOn = () => new Map<AlertCategory, Set<string>>();

function sender(): SmsSender & {
  sent: { to: string; text: string; key?: string }[];
} {
  const sent: { to: string; text: string; key?: string }[] = [];
  return {
    sent,
    send(to, t, o) {
      sent.push({ to, text: t, key: o?.idempotencyKey });
      return Promise.resolve({ ok: true });
    },
  };
}

Deno.test("on board, only what matters before the door opens goes by text", () => {
  assert(wantsInFlight(landing));
  assert(wantsInFlight(belt));
  assert(wantsInFlight(arrivalGate));
  assert(wantsInFlight(diversion));
  assert(
    wantsInFlight({ kind: "connection_at_risk", category: "delays", key: "c" }),
  );
  assert(
    wantsInFlight({
      kind: "terminal_change",
      category: "gates",
      key: "t",
      side: "arrival",
    }),
  );
  assert(
    wantsInFlight({
      kind: "arrival_delay",
      category: "delays",
      key: "a",
      minutes: 15,
    }),
  );
  assert(
    !wantsInFlight({
      kind: "arrival_delay",
      category: "delays",
      key: "a",
      minutes: 10,
    }),
  );
  assert(
    !wantsInFlight({
      kind: "arrival_delay",
      category: "delays",
      key: "a",
      minutes: 0,
    }),
    "back on time stays push only",
  );
  assert(!wantsInFlight({ ...arrivalGate, side: "departure" }));
  assert(
    !wantsInFlight({
      kind: "takeoff",
      category: "takeoff_landing",
      key: "takeoff",
    }),
  );
  assert(
    !wantsInFlight({
      kind: "departure_delay",
      category: "delays",
      key: "d",
      minutes: 60,
    }),
  );
});

Deno.test("the window runs from boarding to half an hour after the gate", () => {
  const scheduled: AlertFlight = {
    ...flight,
    status: "scheduled",
    actual_out: null,
  };
  assert(
    !inFlightWindow(scheduled, new Date("2026-11-03T11:20:00Z")),
    "before boarding",
  );
  assert(
    inFlightWindow(scheduled, new Date("2026-11-03T11:30:00Z")),
    "boarding: 45 min before the best departure",
  );
  assert(inFlightWindow(flight, AIRBORNE));
  const atGate = {
    ...flight,
    status: "arrived",
    actual_in: "2026-11-03T23:15:00Z",
  };
  assert(
    inFlightWindow(atGate, new Date("2026-11-03T23:40:00Z")),
    "the belt after the gate",
  );
  assert(!inFlightWindow(atGate, new Date("2026-11-03T23:50:00Z")));
  assert(
    inFlightWindow(flight, new Date("2026-11-04T02:00:00Z")),
    "a long hold before the gate",
  );
  assert(!inFlightWindow(flight, new Date("2026-11-04T03:00:00Z")));
  assert(!inFlightWindow({ ...flight, status: "canceled" }, AIRBORNE));
});

Deno.test("the plan: in-flight mode, the flight switch, the categories, and one text per user", () => {
  const rows = [
    row({ user_id: "air" }),
    row({
      user_id: "ground",
      in_flight: false,
      enabled: true,
      phone_e164: "+14155550102",
    }),
    row({ user_id: "switch", in_flight: false, phone_e164: "+14155550103" }),
    row({ user_id: "off_here", phone_e164: "+14155550104" }),
    row({ user_id: "stopped", opted_out_at: "2026-11-01T00:00:00Z" }),
    row({ user_id: "muted", phone_e164: "+14155550105" }),
  ];
  const users = new Set(rows.map((r) => r.user_id));
  const muted = new Map<AlertCategory, Set<string>>([[
    "takeoff_landing",
    new Set(["muted"]),
  ]]);
  const switches = new Map([["switch", true], ["off_here", false]]);
  const plan = planSms(landing, text, users, rows, muted, {
    open: true,
    switches,
  });
  assertEquals(plan.map((m) => m.userId).sort(), ["air", "switch"]);
  assert(plan.every((m) => m.mode === "in_flight" && m.key === "landing"));
  // Closed window: landing is not a Text Me Too alert, so nobody.
  assertEquals(
    planSms(landing, text, users, rows, muted, { open: false, switches }),
    [],
  );
  // A diversion is in both lists: Text Me Too users get it, in-flight users get it once.
  const div = planSms(diversion, text, users, rows, new Map(), {
    open: true,
    switches,
  });
  assertEquals(div.map((m) => m.userId).sort(), [
    "air",
    "ground",
    "muted",
    "switch",
  ]);
  assertEquals(div.find((m) => m.userId === "ground")!.mode, "standard");
});

Deno.test("the landing text carries the onward connection", () => {
  const line = onwardLine("AF 85", "tight", 55, "K40", "3:10 PM");
  assertEquals(
    line,
    "Next: AF 85 from gate K40 at 3:10 PM, 55m to connect, tight.",
  );
  assertEquals(
    onwardLine("AF 85", "at_risk", null, null, null),
    "Next: AF 85, at risk.",
  );
  const plan = planSms(landing, text, new Set(["u1"]), [row()], allOn(), {
    open: true,
    switches: new Map(),
    notes: new Map([["u1", line]]),
  });
  assertEquals(
    plan[0].text,
    "Soma Flight: AF 84 landed. Landed at SFO at 3:20 PM. Next: AF 85 from gate K40 at 3:10 PM, 55m to connect, tight. Reply STOP to stop.",
  );
  assert(plan[0].text.length < 300);
});

function seeded(
  rows: SmsRow[],
  prefs: { user_id: string; in_flight: boolean }[] = [],
) {
  return fakeDb(
    {
      sms_alerts: rows as unknown as Record<string, unknown>[],
      sms_flight_prefs: prefs.map((p) => ({ ...p, flight_id: FLIGHT_ID })),
    },
    { claim_sms: claimOnce() },
  );
}

Deno.test("the hook texts in-flight users in the window, once per alert even when retried", async () => {
  const db = seeded([row()]);
  const s = sender();
  const deps = { db: db.client, sender: s, enabled: () => true };
  const ctx = { flightId: FLIGHT_ID, flight, now: AIRBORNE };
  const first = await smsHook(deps, belt, text, new Set(["u1"]), allOn(), ctx);
  assertEquals(first, { sent: 1, failed: 0, deduped: 0 });
  assertEquals(s.sent[0].key, `${FLIGHT_ID}:u1:baggage_belt:d1`);
  // push-sender retried (or a second path delivered the same alert): no second text.
  const again = await smsHook(deps, belt, text, new Set(["u1"]), allOn(), ctx);
  assertEquals(again, { sent: 0, failed: 0, deduped: 1 });
  assertEquals(s.sent.length, 1);
  // After the window, nothing.
  const late = await smsHook(deps, landing, text, new Set(["u1"]), allOn(), {
    ...ctx,
    now: new Date("2026-11-05T00:00:00Z"),
  });
  assertEquals(late.skipped, "nothing_to_send");
});

Deno.test("a flight switch turns texts on for one flight with the account mode off, and off the other way", async () => {
  const s = sender();
  const on = seeded([row({ in_flight: false })], [{
    user_id: "u1",
    in_flight: true,
  }]);
  const ctx = { flightId: FLIGHT_ID, flight, now: AIRBORNE };
  assertEquals(
    (await smsHook(
      { db: on.client, sender: s, enabled: () => true },
      arrivalGate,
      text,
      new Set(["u1"]),
      allOn(),
      ctx,
    )).sent,
    1,
  );
  const off = seeded([row()], [{ user_id: "u1", in_flight: false }]);
  assertEquals(
    (await smsHook(
      { db: off.client, sender: s, enabled: () => true },
      arrivalGate,
      text,
      new Set(["u1"]),
      allOn(),
      ctx,
    )).sent,
    0,
  );
});

Deno.test("the onward connection is read only for an in-flight landing text", async () => {
  let asked = 0;
  const onward = () => {
    asked++;
    return Promise.resolve(
      new Map([["u1", "Next: AF 85 from gate K40, 55m to connect, tight."]]),
    );
  };
  const s = sender();
  const db = seeded([row()]);
  const ctx = { flightId: FLIGHT_ID, flight, now: AIRBORNE, onward };
  await smsHook(
    { db: db.client, sender: s, enabled: () => true },
    belt,
    text,
    new Set(["u1"]),
    allOn(),
    ctx,
  );
  assertEquals(asked, 0);
  await smsHook(
    { db: db.client, sender: s, enabled: () => true },
    landing,
    text,
    new Set(["u1"]),
    allOn(),
    ctx,
  );
  assertEquals(asked, 1);
  assert(s.sent[1].text.includes("Next: AF 85 from gate K40"));
  // Flag off: nothing read, nothing asked, nothing sent.
  const r = await smsHook(
    { db: db.client, sender: s, enabled: () => false },
    landing,
    text,
    new Set(["u1"]),
    allOn(),
    ctx,
  );
  assertEquals(r.skipped, "disabled");
  assertEquals(asked, 1);
});
