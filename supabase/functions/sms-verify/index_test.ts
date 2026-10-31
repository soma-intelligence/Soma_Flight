// sms-verify over the in-memory database: no local stack, no network, a fake sender.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { handler } from "./handler.ts";
import { fakeDb } from "../_shared/sms_test_db.ts";
import type { SmsSender } from "../_shared/sms_alerts.ts";

const U1 = "11111111-0000-4000-8000-000000000001";
const U2 = "11111111-0000-4000-8000-000000000002";
const FLIGHT = "22222222-0000-4000-8000-000000000001";
const NOW = new Date("2026-11-03T18:00:00Z");

const verifier = {
  auth: {
    getUser: (jwt: string) =>
      Promise.resolve(
        jwt === "bad"
          ? { data: { user: null }, error: { message: "bad" } }
          : { data: { user: { id: jwt } }, error: null },
      ),
  },
};

function sender(
  ok = true,
): SmsSender & { sent: { to: string; text: string }[] } {
  const sent: { to: string; text: string }[] = [];
  return {
    sent,
    send(to, text) {
      sent.push({ to, text });
      return Promise.resolve({ ok });
    },
  };
}

function setup(opts: { enabled?: boolean; codes?: () => boolean } = {}) {
  const f = fakeDb({ user_flights: [{ user_id: U1, flight_id: FLIGHT }] }, {
    sms_code_allowed: () => (opts.codes ?? (() => true))(),
  });
  const s = sender();
  const call = async (user: string | null, body: unknown) => {
    const res = await handler(
      new Request("http://localhost/sms-verify", {
        method: "POST",
        headers: user ? { authorization: `Bearer ${user}` } : {},
        body: JSON.stringify(body),
      }),
      {
        db: f.client,
        verifier,
        sender: s,
        enabled: () => opts.enabled ?? true,
        pepper: () => "pepper",
        now: () => NOW,
      },
    );
    return { status: res.status, body: await res.json() };
  };
  const row = () => f.tables.get("sms_alerts")?.find((r) => r.user_id === U1);
  return { f, s, call, row };
}

/** The six digits the fake sender got. */
const codeIn = (text: string) => /code: ([0-9]{6})/.exec(text)![1];

Deno.test("sms-verify needs a user", async () => {
  const { call } = setup();
  assertEquals((await call(null, { action: "status" })).status, 401);
  assertEquals((await call("bad", { action: "status" })).status, 401);
});

Deno.test("while the flag is off only status and forget answer, and nothing is sent", async () => {
  const { call, s } = setup({ enabled: false });
  const st = await call(U1, { action: "status" });
  assertEquals(st.status, 200);
  assertEquals(st.body.available, false);
  assertEquals(
    (await call(U1, { action: "start", phone: "+14155550100" })).status,
    503,
  );
  assertEquals((await call(U1, { action: "forget" })).status, 200);
  assertEquals(s.sent, []);
});

Deno.test("start texts a code, keeps only its hash, check verifies and switches Text Me Too on", async () => {
  const { call, s, row } = setup();
  const started = await call(U1, { action: "start", phone: "(415) 555-0100" });
  assertEquals(started.status, 200);
  assertEquals(started.body.pending, true);
  assertEquals(s.sent.length, 1);
  assertEquals(s.sent[0].to, "+14155550100");
  assert(s.sent[0].text.endsWith("Reply STOP to stop."));
  const code = codeIn(s.sent[0].text);
  assert(
    !JSON.stringify(row()).includes(code),
    "the code itself is never stored",
  );
  assertEquals(row()!.verified_at, null);

  const wrong = await call(U1, {
    action: "check",
    code: code === "000000" ? "111111" : "000000",
  });
  assertEquals(wrong.body.result, "wrong");
  assertEquals(wrong.body.triesLeft, 4);
  const ok = await call(U1, { action: "check", code });
  assertEquals(ok.body.result, "ok");
  assertEquals(ok.body.verified, true);
  assertEquals(ok.body.enabled, true);
  assertEquals(row()!.code_hash, null);
});

Deno.test("five wrong codes lock the number until a new code", async () => {
  const { call, s } = setup();
  await call(U1, { action: "start", phone: "+14155550100" });
  const code = codeIn(s.sent[0].text);
  const other = code === "999999" ? "888888" : "999999";
  for (let i = 0; i < 5; i++) await call(U1, { action: "check", code: other });
  assertEquals(
    (await call(U1, { action: "check", code })).body.result,
    "locked",
  );
});

Deno.test("an expired code does not verify", async () => {
  const { call, s, row } = setup();
  await call(U1, { action: "start", phone: "+14155550100" });
  row()!.code_expires_at = "2026-11-03T17:59:00Z";
  assertEquals(
    (await call(U1, { action: "check", code: codeIn(s.sent[0].text) })).body
      .result,
    "expired",
  );
});

Deno.test("codes are rate limited and a number verified elsewhere is refused", async () => {
  const limited = setup({ codes: () => false });
  const r = await limited.call(U1, { action: "start", phone: "+14155550100" });
  assertEquals(r.status, 429);
  assertEquals(limited.s.sent, []);

  const { call, f, s } = setup();
  f.tables.set("sms_alerts", [{
    user_id: U2,
    phone_e164: "+14155550100",
    verified_at: "2026-11-01T00:00:00Z",
    enabled: true,
    in_flight: false,
    opted_out_at: null,
    attempts: 0,
    code_hash: null,
    code_expires_at: null,
  }]);
  assertEquals(
    (await call(U1, { action: "start", phone: "+14155550100" })).status,
    409,
  );
  assertEquals(s.sent, []);
  assertEquals(
    (await call(U1, { action: "start", phone: "06 12" })).status,
    400,
  );
});

Deno.test("the switches need a verified number; the flight switch needs a follow", async () => {
  const { call, s } = setup();
  assertEquals(
    (await call(U1, { action: "settings", inFlight: true })).status,
    409,
  );
  await call(U1, { action: "start", phone: "+14155550100" });
  await call(U1, { action: "check", code: codeIn(s.sent[0].text) });
  const on = await call(U1, {
    action: "settings",
    inFlight: true,
    enabled: false,
  });
  assertEquals(on.body.inFlight, true);
  assertEquals(on.body.enabled, false);

  assertEquals(
    (await call(U1, { action: "flight", flightId: FLIGHT, inFlight: false }))
      .body.flightInFlight,
    false,
  );
  const st = await call(U1, { action: "status", flightId: FLIGHT });
  assertEquals(st.body.flightInFlight, false);
  await call(U1, { action: "flight", flightId: FLIGHT, inFlight: null });
  assertEquals(
    (await call(U1, { action: "status", flightId: FLIGHT })).body
      .flightInFlight,
    null,
  );
  assertEquals(
    (await call(U1, {
      action: "flight",
      flightId: "22222222-0000-4000-8000-000000000009",
      inFlight: true,
    })).status,
    404,
  );
});

Deno.test("forget deletes the row", async () => {
  const { call, s, row } = setup();
  await call(U1, { action: "start", phone: "+14155550100" });
  await call(U1, { action: "check", code: codeIn(s.sent[0].text) });
  const gone = await call(U1, { action: "forget" });
  assertEquals(gone.body.phone, null);
  assertEquals(row(), undefined);
});
