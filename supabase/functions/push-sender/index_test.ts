import { assert, assertEquals } from "jsr:@std/assert@1";
import { exportPKCS8, generateKeyPair } from "npm:jose@5";
import { makeUser, test, testDb, trackFlightId } from "../_shared/test_util.ts";
import { type ApnsConfig, handler, SEND_CONCURRENCY } from "./handler.ts";

const db = await testDb();
const { privateKey } = await generateKeyPair("ES256", { extractable: true });
const P8 = await exportPKCS8(privateKey);
const CFG: ApnsConfig = {
  teamId: "TEAMTEST01",
  keyId: "KEYTEST001",
  p8: P8,
  bundleId: "me.soma.flight",
  sandbox: false,
};

const b64 = (o: object) =>
  btoa(JSON.stringify(o)).replace(/=+$/, "").replace(/\+/g, "-").replace(
    /\//g,
    "_",
  );
const jwt = (role: string) => `${b64({ alg: "HS256" })}.${b64({ role })}.sig`;

const SERVICE_KEY = jwt("service_role");

interface Call {
  url: string;
  headers: Record<string, string>;
  // deno-lint-ignore no-explicit-any
  body: Record<string, any>;
  token: string;
}

function fakeApns(
  respond: (token: string) => Response | Promise<Response> = () =>
    new Response(null, { status: 200 }),
) {
  const calls: Call[] = [];
  let live = 0, peak = 0;
  const fn = (async (url: string, init: RequestInit) => {
    live++;
    peak = Math.max(peak, live);
    await new Promise((r) => setTimeout(r, 3));
    live--;
    const token = url.split("/").pop()!;
    calls.push({
      url,
      headers: init.headers as Record<string, string>,
      body: JSON.parse(init.body as string),
      token,
    });
    return respond(token);
  }) as unknown as typeof fetch;
  return { calls, fn, peak: () => peak };
}

const hex = (n: number) => n.toString(16).padStart(8, "0").repeat(8);
let seq = Math.floor(Math.random() * 1e6) * 100;
const newToken = () => hex(++seq);

async function makeFlight(over: Record<string, unknown> = {}): Promise<string> {
  const tag = crypto.randomUUID().slice(0, 8).toUpperCase();
  const { data, error } = await db.from("flights").insert({
    provider_id: `PSH${tag}-1793600000-schedule-1p`,
    ident: "AF84",
    origin_icao: "LFPG",
    origin_iata: "CDG",
    destination_icao: "KSFO",
    destination_iata: "SFO",
    scheduled_out: "2026-11-03T22:30:00Z",
    scheduled_in: "2026-11-04T09:00:00Z",
    gate_origin: "K36",
    status: "scheduled",
    ...over,
  }).select("id").single();
  if (error) throw error;
  trackFlightId(data.id);
  return data.id;
}

async function makeEvent(flightId: string, kind: string, payload: object = {}) {
  const { data, error } = await db.from("flight_events").insert({
    flight_id: flightId,
    provider_event_id: `t-${crypto.randomUUID()}`,
    kind,
    payload,
  }).select("id").single();
  if (error) throw error;
  return data.id as string;
}

async function follow(userId: string, flightId: string, notify = true) {
  const r = await db.from("user_flights").insert({
    user_id: userId,
    flight_id: flightId,
    notify,
  });
  if (r.error) throw r.error;
}

async function addToken(
  userId: string,
  kind: "alert" | "live_activity",
  flightId?: string,
) {
  const token = newToken();
  const r = await db.from("push_tokens").insert({
    user_id: userId,
    token,
    kind,
    flight_id: kind === "live_activity" ? flightId : null,
  });
  if (r.error) throw r.error;
  return token;
}

let clock = "2026-11-03T23:00:00Z";

function call(
  flightId: string,
  eventId: string,
  apns: ReturnType<typeof fakeApns>,
  role = "service_role",
  cfg: ApnsConfig | null = CFG,
  serviceKey: string = SERVICE_KEY,
) {
  return handler(
    new Request("http://localhost/push-sender", {
      method: "POST",
      headers: { authorization: `Bearer ${jwt(role)}` },
      body: JSON.stringify({ flightId, eventId }),
    }),
    {
      db,
      config: () => cfg ?? undefined,
      serviceKey: () => serviceKey,
      fetchFn: apns.fn,
      now: () => new Date(clock),
    },
  );
}

const tokensLeft = async (tokens: string[]) => {
  const { data } = await db.from("push_tokens").select("token").in(
    "token",
    tokens,
  );
  return (data ?? []).map((r) => r.token as string);
};

test(
  db,
  "push-sender rejects anon, authenticated and missing callers with 401",
  async () => {
    const f = await makeFlight();
    const e = await makeEvent(f, "departure");
    const apns = fakeApns();
    for (const role of ["anon", "authenticated"]) {
      const res = await call(f, e, apns, role);
      assertEquals(res.status, 401);
      await res.body?.cancel();
    }
    const none = await handler(
      new Request("http://localhost/push-sender", {
        method: "POST",
        body: JSON.stringify({ flightId: f, eventId: e }),
      }),
      {
        db,
        config: () => CFG,
        fetchFn: apns.fn,
        serviceKey: () => SERVICE_KEY,
      },
    );
    assertEquals(none.status, 401);
    await none.body?.cancel();
    assertEquals(apns.calls.length, 0);
  },
);

test(db, "push-sender validates input and unknown events", async () => {
  const apns = fakeApns();
  const f = await makeFlight();
  const other = await makeFlight();
  const eOther = await makeEvent(other, "departure");
  const bad = await handler(
    new Request("http://localhost/push-sender", {
      method: "POST",
      headers: { authorization: `Bearer ${jwt("service_role")}` },
      body: JSON.stringify({ flightId: "x", eventId: "y" }),
    }),
    { db, config: () => CFG, fetchFn: apns.fn, serviceKey: () => SERVICE_KEY },
  );
  assertEquals(bad.status, 400);
  await bad.body?.cancel();
  const mismatch = await call(f, eOther, apns);
  assertEquals(mismatch.status, 404);
  await mismatch.body?.cancel();
  const unconfigured = await call(f, eOther, apns, "service_role", null);
  assertEquals(unconfigured.status, 503);
  await unconfigured.body?.cancel();
});

test(db, "push-sender skips users with notify false", async () => {
  const f = await makeFlight();
  const [on, off] = [await makeUser(db), await makeUser(db)];
  await follow(on, f, true);
  await follow(off, f, false);
  const tOn = await addToken(on, "alert");
  const tOff = await addToken(off, "alert");
  const e = await makeEvent(f, "gate_change", {
    changes: { gate_origin: { from: "K30", to: "K36" } },
  });
  const apns = fakeApns();
  const res = await call(f, e, apns);
  assertEquals(res.status, 200);
  const out = await res.json();
  assertEquals(out.alerts.sent, 1);
  assertEquals(apns.calls.map((c) => c.token), [tOn]);
  assert(!apns.calls.some((c) => c.token === tOff));
  const c = apns.calls[0];
  assertEquals(c.url, `https://api.push.apple.com/3/device/${tOn}`);
  assertEquals(c.headers["apns-push-type"], "alert");
  assertEquals(c.headers["apns-topic"], "me.soma.flight");
  assertEquals(c.headers["apns-priority"], "10");
  assertEquals(c.headers["apns-collapse-id"], e);
  assertEquals(c.body.aps.alert.title, "AF84 gate change");
  assert(c.body.aps.alert.body.includes("K36"));
  assertEquals(c.body.flightId, f);
});

test(
  db,
  "push-sender does not alert users who do not follow the flight",
  async () => {
    const f = await makeFlight();
    const stranger = await makeUser(db);
    await addToken(stranger, "alert");
    const e = await makeEvent(f, "departure");
    const apns = fakeApns();
    const res = await call(f, e, apns);
    await res.body?.cancel();
    assertEquals(apns.calls.length, 0);
  },
);

test(
  db,
  "410 deletes the token, BadDeviceToken only on a second strike",
  async () => {
    const f = await makeFlight();
    const users = [
      await makeUser(db),
      await makeUser(db),
      await makeUser(db),
      await makeUser(db),
    ];
    for (const u of users) await follow(u, f);
    const [gone, bad, boom, fine] = await Promise.all(
      users.map((u) => addToken(u, "alert")),
    );
    const logs: string[] = [];
    const origErr = console.error;
    console.error = (...a: unknown[]) => logs.push(a.join(" "));
    const respond = (t: string) =>
      t === gone
        ? Response.json({ reason: "Unregistered" }, { status: 410 })
        : t === bad
        ? Response.json({ reason: "BadDeviceToken" }, { status: 400 })
        : t === boom
        ? Response.json({ reason: "InternalServerError" }, { status: 500 })
        : new Response(null, { status: 200 });
    let first, second;
    try {
      first = await (await call(
        f,
        await makeEvent(f, "departure"),
        fakeApns(respond),
      )).json();
      assertEquals(
        (await tokensLeft([gone, bad, boom, fine])).sort(),
        [bad, boom, fine].sort(),
      );
      const strike = await db.from("push_tokens").select("bad_count").eq(
        "token",
        bad,
      ).single();
      assertEquals(strike.data?.bad_count, 1);
      second =
        await (await call(f, await makeEvent(f, "arrival"), fakeApns(respond)))
          .json();
    } finally {
      console.error = origErr;
    }
    assertEquals(first.alerts, { sent: 1, failed: 3, removed: 1 });
    assertEquals(second.alerts.removed, 1);
    assertEquals(
      (await tokensLeft([bad, boom, fine])).sort(),
      [boom, fine].sort(),
    );
    const text = logs.join("\n");
    assert(text.includes("status=500") && text.includes("InternalServerError"));
    for (const secret of [gone, bad, boom, fine, "bearer"]) {
      assert(!text.includes(secret));
    }
  },
);

test(
  db,
  "BadDeviceToken for every token logs a sandbox mismatch and deletes nothing",
  async () => {
    const f = await makeFlight();
    const u = await makeUser(db);
    await follow(u, f);
    const tokens = [
      await addToken(u, "alert"),
      await addToken(u, "alert"),
      await addToken(u, "alert"),
    ];
    await db.from("push_tokens").update({ bad_count: 1 }).in("token", tokens);
    const logs: string[] = [];
    const origErr = console.error;
    console.error = (...a: unknown[]) => logs.push(a.join(" "));
    try {
      const apns = fakeApns(() =>
        Response.json({ reason: "BadDeviceToken" }, { status: 400 })
      );
      const out = await (await call(f, await makeEvent(f, "departure"), apns))
        .json();
      assertEquals(out.alerts, { sent: 0, failed: 3, removed: 0 });
    } finally {
      console.error = origErr;
    }
    assertEquals((await tokensLeft(tokens)).length, 3);
    assert(logs.join("\n").includes("APNS_SANDBOX mismatch"));
  },
);

test(db, "a token re-registered during the send survives a 410", async () => {
  const f = await makeFlight();
  const [a, b] = [await makeUser(db), await makeUser(db)];
  await follow(a, f);
  const token = await addToken(a, "alert");
  const apns = fakeApns(async () => {
    await db.from("push_tokens").update({
      user_id: b,
      updated_at: new Date(Date.now() + 1000).toISOString(),
    }).eq("token", token);
    return Response.json({ reason: "Unregistered" }, { status: 410 });
  });
  const out = await (await call(f, await makeEvent(f, "departure"), apns))
    .json();
  assertEquals(out.alerts.failed, 1);
  assertEquals((await tokensLeft([token])).length, 1);
});

test(
  db,
  "a rejected provider token stops the batch and drops the cached JWT",
  async () => {
    const f = await makeFlight();
    const u = await makeUser(db);
    await follow(u, f);
    const ins = await db.from("push_tokens").insert(
      Array.from(
        { length: 40 },
        () => ({ user_id: u, token: newToken(), kind: "alert" }),
      ),
    );
    if (ins.error) throw ins.error;
    const reject = () =>
      Response.json({ reason: "ExpiredProviderToken" }, { status: 403 });
    const origErr = console.error;
    console.error = () => {};
    const a1 = fakeApns(reject);
    let out;
    try {
      out = await (await call(f, await makeEvent(f, "departure"), a1)).json();
    } finally {
      console.error = origErr;
    }
    assertEquals(out.alerts.sent, 0);
    assertEquals(out.alerts.failed, 40);
    assert(a1.calls.length < 40, `sent ${a1.calls.length}`);
    const a2 = fakeApns();
    clock = "2026-11-03T23:05:00Z";
    try {
      await (await call(f, await makeEvent(f, "arrival"), a2)).body?.cancel();
    } finally {
      clock = "2026-11-03T23:00:00Z";
    }
    const iat = (c: Call) =>
      JSON.parse(
        atob(
          c.headers.authorization.split(".")[1].replace(/-/g, "+").replace(
            /_/g,
            "/",
          ),
        ),
      ).iat;
    assert(iat(a2.calls[0]) > iat(a1.calls[0]), "cached JWT was reused");
  },
);

test(db, "push-sender sends many tokens at most 10 at a time", async () => {
  const f = await makeFlight();
  const u = await makeUser(db);
  await follow(u, f);
  const rows = Array.from(
    { length: 25 },
    () => ({ user_id: u, token: newToken(), kind: "alert" }),
  );
  const ins = await db.from("push_tokens").insert(rows);
  if (ins.error) throw ins.error;
  const e = await makeEvent(f, "departure");
  const apns = fakeApns();
  const out = await (await call(f, e, apns)).json();
  assertEquals(out.alerts.sent, 25);
  assert(
    apns.peak() <= SEND_CONCURRENCY && apns.peak() > 1,
    `peak ${apns.peak()}`,
  );
});

test(db, "arrival sends liveactivity end", async () => {
  const f = await makeFlight({
    status: "landed",
    gate_destination: "B22",
    actual_out: "2026-11-03T22:40:00Z",
    actual_in: "2026-11-04T08:50:00Z",
    estimated_in: "2026-11-04T08:50:00Z",
  });
  const u = await makeUser(db);
  await follow(u, f);
  const la = await addToken(u, "live_activity", f);
  const e = await makeEvent(f, "arrival");
  const apns = fakeApns();
  const out = await (await call(f, e, apns)).json();
  assertEquals(out.liveActivities.sent, 1);
  const c = apns.calls.find((x) => x.token === la)!;
  assertEquals(c.headers["apns-push-type"], "liveactivity");
  assertEquals(
    c.headers["apns-topic"],
    "me.soma.flight.push-type.liveactivity",
  );
  assertEquals(c.body.aps.event, "end");
  assertEquals(c.body.aps["content-state"].status, "landed");
  assertEquals(c.body.aps["content-state"].progress, 1);
  assertEquals(c.body.aps["content-state"].gateDestination, "B22");
  assertEquals(c.headers["apns-priority"], "10");
  assertEquals((await tokensLeft([la])).length, 0); // ended activities are forgotten
  assert(c.body.aps["dismissal-date"] > c.body.aps.timestamp);
});

test(
  db,
  "live activity update carries the state, only for that flight and followers",
  async () => {
    const f = await makeFlight({
      status: "en_route",
      actual_out: "2026-11-03T22:30:00Z",
      scheduled_in: "2026-11-04T00:30:00Z",
      estimated_in: "2026-11-04T00:30:00Z",
    });
    const g = await makeFlight();
    const [keeps, left] = [await makeUser(db), await makeUser(db)];
    await follow(keeps, f);
    const laKeeps = await addToken(keeps, "live_activity", f);
    await addToken(keeps, "live_activity", g);
    await addToken(left, "live_activity", f); // does not follow f any more
    const e = await makeEvent(f, "delay", { delay_minutes: 30 });
    const apns = fakeApns();
    const out = await (await call(f, e, apns)).json();
    assertEquals(out.liveActivities.sent, 1);
    assertEquals(apns.calls.length, 1);
    const c = apns.calls[0];
    assertEquals(c.token, laKeeps);
    assertEquals(c.body.aps.event, "update");
    assertEquals(c.headers["apns-priority"], "5"); // a delay is not an immediate kind
    assertEquals((await tokensLeft([laKeeps])).length, 1);
    assertEquals(c.body.aps["dismissal-date"], undefined);
    const s = c.body.aps["content-state"];
    assertEquals(Object.keys(s).sort(), [
      "estimatedIn",
      "estimatedOut",
      "gateDestination",
      "gateOrigin",
      "progress",
      "status",
    ]);
    assertEquals(s.progress, 0.25); // 23:00 is a quarter of the way from 22:30 to 00:30
    assertEquals(s.gateOrigin, "K36");
  },
);

test(
  db,
  "small delays send no alert but still update the Live Activity",
  async () => {
    const f = await makeFlight({ estimated_out: "2026-11-03T22:40:00Z" });
    const u = await makeUser(db);
    await follow(u, f);
    await addToken(u, "alert");
    const la = await addToken(u, "live_activity", f);
    const e = await makeEvent(f, "delay", { delay_minutes: 10 });
    const apns = fakeApns();
    const out = await (await call(f, e, apns)).json();
    assertEquals(out.alerts.sent, 0);
    assertEquals(apns.calls.map((c) => c.token), [la]);
  },
);
