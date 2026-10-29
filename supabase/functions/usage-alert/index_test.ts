import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { testDb } from "../_shared/test_util.ts";
import { DEFAULT_THRESHOLD_USD, handler, RESEND_URL } from "./handler.ts";

const db = await testDb();

const b64 = (o: object) =>
  btoa(JSON.stringify(o)).replace(/=+$/, "").replace(/\+/g, "-").replace(
    /\//g,
    "_",
  );
const jwt = (role: string) => `${b64({ alg: "HS256" })}.${b64({ role })}.sig`;
const SERVICE_KEY = jwt("service_role");
const RESEND_KEY = "re_test_secret_value";

interface Sent {
  url: string;
  headers: Record<string, string>;
  // deno-lint-ignore no-explicit-any
  body: any;
}

function fakeResend(status = 200) {
  const sent: Sent[] = [];
  const state = { status };
  const fn = ((url: string, init: RequestInit) => {
    sent.push({
      url,
      headers: init.headers as Record<string, string>,
      body: JSON.parse(init.body as string),
    });
    return Promise.resolve(
      new Response(JSON.stringify({ id: "email-1" }), { status: state.status }),
    );
  }) as unknown as typeof fetch;
  return { sent, fn, state };
}

// Each test uses its own day far in the past, so real counters are never touched.
let dayBase = Date.UTC(2001, 0, 1) +
  Math.floor(Math.random() * 3000) * 86_400_000;
function freshDay(): { day: string; now: Date } {
  dayBase += 86_400_000;
  const day = new Date(dayBase).toISOString().slice(0, 10);
  return { day, now: new Date(dayBase + 86_400_000 + 8 * 3600_000) };
}

async function spend(day: string, rows: [string, number, number][]) {
  const r = await db.from("usage_counters").insert(
    rows.map(([endpoint, calls, estimated_cost]) => ({
      day,
      endpoint,
      calls,
      estimated_cost,
    })),
  );
  if (r.error) throw r.error;
}

async function clear(day: string) {
  await db.from("usage_counters").delete().eq("day", day);
  await db.from("usage_alerts").delete().eq("day", day);
}

function env(over: Record<string, string | undefined> = {}) {
  const vars: Record<string, string | undefined> = {
    RESEND_API_KEY: RESEND_KEY,
    OWNER_EMAIL: "owner@test.local",
    ...over,
  };
  return (n: string) => vars[n];
}

function call(
  now: Date,
  resend: ReturnType<typeof fakeResend>,
  opts: {
    bearer?: string | null;
    env?: (n: string) => string | undefined;
    method?: string;
  } = {},
) {
  const bearer = opts.bearer === undefined ? SERVICE_KEY : opts.bearer;
  return handler(
    new Request("http://localhost/usage-alert", {
      method: opts.method ?? "POST",
      headers: bearer ? { authorization: `Bearer ${bearer}` } : {},
    }),
    {
      db,
      fetchFn: resend.fn,
      now: () => now,
      env: opts.env ?? env(),
      serviceKey: () => SERVICE_KEY,
    },
  );
}

function utest(name: string, fn: (day: string, now: Date) => Promise<void>) {
  Deno.test({
    name,
    sanitizeOps: false,
    sanitizeResources: false,
    fn: async () => {
      const { day, now } = freshDay();
      try {
        await fn(day, now);
      } finally {
        await clear(day);
      }
    },
  });
}

utest("rejects callers without the service role key", async (_day, now) => {
  const resend = fakeResend();
  assertEquals((await call(now, resend, { bearer: null })).status, 401);
  assertEquals((await call(now, resend, { bearer: jwt("anon") })).status, 401);
  assertEquals((await call(now, resend, { method: "GET" })).status, 405);
  assertEquals(resend.sent.length, 0);
});

utest("below the threshold: no email", async (day, now) => {
  await spend(day, [["flights_ident", 100, 5], ["alert_delivery", 50, 19.99]]);
  const resend = fakeResend();
  const res = await call(now, resend);
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.day, day);
  assertEquals(body.total, 24.99);
  assertEquals(body.threshold, DEFAULT_THRESHOLD_USD);
  assertEquals(body.sent, false);
  assertEquals(resend.sent.length, 0);
});

utest(
  "above the threshold: one email to the owner, no secrets in it",
  async (day, now) => {
    await spend(day, [["flights_ident", 400, 20], [
      "airports_departures",
      60,
      6.5,
    ]]);
    const resend = fakeResend();
    const res = await call(now, resend);
    assertEquals(res.status, 200);
    assertEquals((await res.json()).sent, true);
    assertEquals(resend.sent.length, 1);
    const mail = resend.sent[0];
    assertEquals(mail.url, RESEND_URL);
    assertEquals(mail.headers.authorization, `Bearer ${RESEND_KEY}`);
    assertEquals(mail.body.to, ["owner@test.local"]);
    assertStringIncludes(mail.body.subject, "$26.50");
    assertStringIncludes(mail.body.text, day);
    assertStringIncludes(mail.body.text, "flights_ident: 400 calls, $20.00");
    const serialized = JSON.stringify(mail.body);
    assert(!serialized.includes(RESEND_KEY));
    assert(!serialized.includes(SERVICE_KEY));
    const row = await db.from("usage_alerts").select("total").eq("day", day)
      .single();
    assertEquals(Number(row.data?.total), 26.5);
  },
);

utest("at most one email a day", async (day, now) => {
  await spend(day, [["flights_ident", 400, 30]]);
  const resend = fakeResend();
  assertEquals((await (await call(now, resend)).json()).sent, true);
  const again = await (await call(now, resend)).json();
  assertEquals(again.sent, false);
  assertEquals(again.alreadySent, true);
  const both = await Promise.all([call(now, resend), call(now, resend)]);
  for (const r of both) assertEquals((await r.json()).sent, false);
  assertEquals(resend.sent.length, 1);
});

utest("a failed send is retried by the next run", async (day, now) => {
  await spend(day, [["flights_ident", 400, 30]]);
  const resend = fakeResend(500);
  const first = await call(now, resend);
  assertEquals(first.status, 503);
  assertEquals((await first.json()).error.code, "provider_unavailable");
  const claim = await db.from("usage_alerts").select("day").eq("day", day);
  assertEquals(claim.data?.length, 0);
  resend.state.status = 200;
  assertEquals((await (await call(now, resend)).json()).sent, true);
  assertEquals(resend.sent.length, 2);
});

utest("missing email config: 503 and nothing claimed", async (day, now) => {
  await spend(day, [["flights_ident", 400, 30]]);
  const resend = fakeResend();
  const res = await call(now, resend, { env: env({ OWNER_EMAIL: undefined }) });
  assertEquals(res.status, 503);
  await res.body?.cancel();
  assertEquals(resend.sent.length, 0);
  const claim = await db.from("usage_alerts").select("day").eq("day", day);
  assertEquals(claim.data?.length, 0);
});

utest(
  "USAGE_ALERT_USD sets the threshold; an invalid value falls back",
  async (day, now) => {
    await spend(day, [["flights_ident", 100, 12]]);
    const resend = fakeResend();
    const low =
      await (await call(now, resend, { env: env({ USAGE_ALERT_USD: "10" }) }))
        .json();
    assertEquals(low.threshold, 10);
    assertEquals(low.sent, true);
    await db.from("usage_alerts").delete().eq("day", day);
    const bad =
      await (await call(now, resend, { env: env({ USAGE_ALERT_USD: "lots" }) }))
        .json();
    assertEquals(bad.threshold, DEFAULT_THRESHOLD_USD);
    assertEquals(bad.sent, false);
  },
);

utest("only yesterday (UTC) counts", async (day, now) => {
  const today = now.toISOString().slice(0, 10);
  await spend(day, [["flights_ident", 1, 1]]);
  await spend(today, [["flights_ident", 999, 500]]);
  try {
    const body = await (await call(now, fakeResend())).json();
    assertEquals(body.day, day);
    assertEquals(body.total, 1);
    assertEquals(body.sent, false);
  } finally {
    await clear(today);
  }
});

utest("sent_at is recorded after a good send", async (day, now) => {
  await spend(day, [["flights_ident", 400, 30]]);
  assertEquals((await (await call(now, fakeResend())).json()).sent, true);
  const row = await db.from("usage_alerts").select("sent_at").eq("day", day)
    .single();
  assert(row.data?.sent_at);
});

utest(
  "a claim left by a crash is taken over after 15 minutes",
  async (day, now) => {
    await spend(day, [["flights_ident", 400, 30]]);
    const resend = fakeResend();
    const recent = new Date(now.getTime() - 5 * 60_000).toISOString();
    const ins = await db.from("usage_alerts").insert({
      day,
      total: 30,
      claimed_at: recent,
    });
    if (ins.error) throw ins.error;
    const busy = await (await call(now, resend)).json();
    assertEquals(busy.sent, false);
    assertEquals(resend.sent.length, 0);

    const old = new Date(now.getTime() - 20 * 60_000).toISOString();
    await db.from("usage_alerts").update({ claimed_at: old }).eq("day", day);
    const taken = await (await call(now, resend)).json();
    assertEquals(taken.sent, true);
    assertEquals(resend.sent.length, 1);
    const again = await (await call(now, resend)).json();
    assertEquals(again.alreadySent, true);
    assertEquals(resend.sent.length, 1);
  },
);
