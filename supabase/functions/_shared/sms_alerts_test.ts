import { assert, assertEquals } from "jsr:@std/assert@1";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { Alert, AlertCategory } from "./alerts.ts";
import {
  canText,
  checkCode,
  hashCode,
  MAX_ATTEMPTS,
  newCode,
  normalisePhone,
  planSms,
  SMS_FLAG,
  smsEnabled,
  smsHook,
  type SmsRow,
  type SmsSender,
  smsText,
  wantsSms,
} from "./sms_alerts.ts";

const gate: Alert = {
  kind: "gate_change",
  category: "gates",
  key: "gate_change:K40",
  side: "departure",
  from: "K38",
  to: "K40",
};
const text = { title: "AF 84 gate change", body: "Now gate K40, was K38." };
const NOW = new Date("2026-11-03T18:00:00Z");

function row(over: Partial<SmsRow> = {}): SmsRow {
  return {
    user_id: "u1",
    phone_e164: "+14155550100",
    code_hash: null,
    code_expires_at: null,
    attempts: 0,
    verified_at: "2026-10-31T10:00:00Z",
    enabled: true,
    opted_out_at: null,
    ...over,
  };
}

const noneMuted = () =>
  new Map<AlertCategory, Set<string>>([["gates", new Set()], [
    "delays",
    new Set(),
  ]]);

Deno.test("the flag is off unless the secret is exactly true", () => {
  assertEquals(smsEnabled(() => undefined), false);
  assertEquals(smsEnabled(() => "1"), false);
  assertEquals(smsEnabled(() => "TRUE"), false);
  assertEquals(smsEnabled((n) => (n === SMS_FLAG ? "true" : undefined)), true);
});

Deno.test("phone numbers read as E.164", () => {
  assertEquals(normalisePhone("+1 (415) 555-0100"), "+14155550100");
  assertEquals(normalisePhone("415 555 0100"), "+14155550100");
  assertEquals(normalisePhone("1-415-555-0100"), "+14155550100");
  assertEquals(normalisePhone("+33 6 12 34 56 78"), "+33612345678");
  assertEquals(normalisePhone("0033 6 12 34 56 78"), "+33612345678");
  assertEquals(normalisePhone("06 12 34 56 78"), null);
  assertEquals(normalisePhone("+0 123"), null);
  assertEquals(normalisePhone("call me"), null);
});

Deno.test("only alerts that change the next step go by text", () => {
  assert(wantsSms(gate));
  assert(
    wantsSms({ kind: "cancel", category: "cancellations", key: "cancel" }),
  );
  assert(
    wantsSms({
      kind: "departure_delay",
      category: "delays",
      key: "d",
      minutes: 30,
    }),
  );
  assert(
    !wantsSms({
      kind: "departure_delay",
      category: "delays",
      key: "d",
      minutes: 20,
    }),
  );
  assert(
    !wantsSms({ kind: "takeoff", category: "takeoff_landing", key: "takeoff" }),
  );
  assert(!wantsSms({ kind: "baggage_belt", category: "baggage", key: "belt" }));
});

Deno.test("codes are six digits and kept only as a hash", async () => {
  assertEquals(newCode(() => new Uint32Array([42])), "000042");
  assertEquals(newCode(() => new Uint32Array([4_294_967_295])), "967295");
  assertEquals(newCode().length, 6);
  const h = await hashCode("+14155550100", "123456", "pepper");
  assert(/^[0-9a-f]{64}$/.test(h));
  assert(h !== await hashCode("+14155550100", "123456", "other"));
});

Deno.test("a code checks against its hash, its expiry and the tries", async () => {
  const hash = await hashCode("+14155550100", "123456", "p");
  const pending = row({
    verified_at: null,
    enabled: false,
    code_hash: hash,
    code_expires_at: "2026-11-03T18:05:00Z",
  });
  assertEquals(await checkCode(pending, "123456", "p", NOW), "ok");
  assertEquals(await checkCode(pending, "654321", "p", NOW), "wrong");
  assertEquals(await checkCode(pending, "12345", "p", NOW), "wrong");
  assertEquals(
    await checkCode(pending, "123456", "p", new Date("2026-11-03T18:05:00Z")),
    "expired",
  );
  assertEquals(
    await checkCode({ ...pending, attempts: MAX_ATTEMPTS }, "123456", "p", NOW),
    "locked",
  );
  assertEquals(await checkCode(row(), "123456", "p", NOW), "none");
});

Deno.test("only a verified, switched on, not stopped number gets texts", () => {
  assert(canText(row()));
  assert(!canText(row({ verified_at: null })));
  assert(!canText(row({ enabled: false })));
  assert(!canText(row({ opted_out_at: "2026-11-01T00:00:00Z" })));
  assert(!canText(row({ phone_e164: null })));
});

Deno.test("the text names the app, stays short and says how to stop", () => {
  assertEquals(
    smsText(text),
    "Soma Flight: AF 84 gate change. Now gate K40, was K38. Reply STOP to stop.",
  );
  const long = smsText({ title: "T", body: "x".repeat(1000) });
  assert(long.length <= 300);
  assert(long.endsWith("… Reply STOP to stop."));
});

Deno.test("the plan keeps followers who can text and have the category on", () => {
  const rows = [
    row({ user_id: "u1" }),
    row({ user_id: "u2", phone_e164: "+14155550102" }),
    row({ user_id: "u3", enabled: false }),
    row({ user_id: "stranger" }),
  ];
  const muted = noneMuted();
  muted.get("gates")!.add("u2");
  const plan = planSms(gate, text, new Set(["u1", "u2", "u3"]), rows, muted);
  assertEquals(plan.map((m) => m.userId), ["u1"]);
  assertEquals(plan[0].to, "+14155550100");
  assertEquals(plan[0].kind, "gate_change");
  assertEquals(
    planSms(
      { kind: "takeoff", category: "takeoff_landing", key: "t" },
      text,
      new Set(["u1"]),
      rows,
      muted,
    ),
    [],
  );
});

/** A database that fails the test when touched, and one that answers sms_alerts reads. */
function db(
  rows: SmsRow[] | "forbidden",
): { client: SupabaseClient; reads: number } {
  const state = { reads: 0 };
  const client = {
    from(table: string) {
      if (rows === "forbidden") throw new Error(`read ${table} while disabled`);
      assertEquals(table, "sms_alerts");
      state.reads++;
      const q = {
        select: () => q,
        in: (_c: string, ids: string[]) => {
          q.ids = ids;
          return q;
        },
        eq: () =>
          Promise.resolve({
            data: rows.filter((r) => q.ids.includes(r.user_id)),
            error: null,
          }),
        ids: [] as string[],
      };
      return q;
    },
  } as unknown as SupabaseClient;
  return {
    client,
    get reads() {
      return state.reads;
    },
  };
}

function sender(
  ok = true,
): SmsSender & { sent: { to: string; text: string }[] } {
  const sent: { to: string; text: string }[] = [];
  return {
    sent,
    send(to: string, t: string) {
      sent.push({ to, text: t });
      return Promise.resolve({ ok });
    },
  };
}

Deno.test("the hook does nothing while the flag is off, even with a sender", async () => {
  const s = sender();
  const off = await smsHook(
    { db: db("forbidden").client, sender: s, enabled: () => false },
    gate,
    text,
    new Set(["u1"]),
    noneMuted(),
  );
  assertEquals(off, { sent: 0, failed: 0, skipped: "disabled" });
  assertEquals(s.sent, []);
  // As push-sender ships: no deps at all.
  assertEquals(
    (await smsHook(undefined, gate, text, new Set(["u1"]), noneMuted()))
      .skipped,
    "disabled",
  );
});

Deno.test("the hook needs a sender even with the flag on", async () => {
  const r = await smsHook(
    { db: db("forbidden").client, enabled: () => true },
    gate,
    text,
    new Set(["u1"]),
    noneMuted(),
  );
  assertEquals(r.skipped, "no_sender");
});

Deno.test("with the flag on and a sender, the hook texts the planned followers", async () => {
  const s = sender();
  const d = db([
    row({ user_id: "u1" }),
    row({ user_id: "u2", opted_out_at: "2026-11-01T00:00:00Z" }),
  ]);
  const r = await smsHook(
    { db: d.client, sender: s, enabled: () => true },
    gate,
    text,
    new Set(["u1", "u2"]),
    noneMuted(),
  );
  assertEquals(r, { sent: 1, failed: 0 });
  assertEquals(s.sent.map((m) => m.to), ["+14155550100"]);
  assertEquals(d.reads, 1);
  const failing = await smsHook(
    { db: db([row()]).client, sender: sender(false), enabled: () => true },
    gate,
    text,
    new Set(["u1"]),
    noneMuted(),
  );
  assertEquals(failing, { sent: 0, failed: 1 });
});

Deno.test("an alert not worth a text never reads the table", async () => {
  const r = await smsHook(
    { db: db("forbidden").client, sender: sender(), enabled: () => true },
    { kind: "landing", category: "takeoff_landing", key: "landing" },
    text,
    new Set(["u1"]),
    noneMuted(),
  );
  assertEquals(r.skipped, "nothing_to_send");
});
