import { assert, assertEquals } from "jsr:@std/assert@1";
import { parse as parseToml } from "jsr:@std/toml@1";
import { makeUser, test, testDb, trackFlightId } from "../_shared/test_util.ts";
import { type Deps, handler, MAX_BODY_BYTES } from "./handler.ts";

const db = await testDb();
const SECRET = "test-secret-value";
const gateFixture = JSON.parse(
  await Deno.readTextFile(
    new URL("../_shared/fixtures/alert_gate_change.json", import.meta.url),
  ),
);
const departureFixture = JSON.parse(
  await Deno.readTextFile(
    new URL("../_shared/fixtures/alert_departure.json", import.meta.url),
  ),
);

function fakePush() {
  const calls: [string, string][] = [];
  return {
    calls,
    fail: false,
    push(flightId: string, eventId: string) {
      calls.push([flightId, eventId]);
      return this.fail
        ? Promise.reject(new Error("apns down"))
        : Promise.resolve();
    },
  };
}

function deps(
  p: ReturnType<typeof fakePush>,
  ...configured: [string | undefined] | []
): Deps {
  const secret = configured.length ? configured[0] : SECRET;
  return { db, secret: () => secret, push: (f, e) => p.push(f, e) };
}

function post(body: string, secret: string | null = SECRET): Request {
  const q = secret === null ? "" : `?secret=${encodeURIComponent(secret)}`;
  return new Request(`http://localhost/aeroapi-webhook${q}`, {
    method: "POST",
    body,
  });
}

const tags: string[] = [];
function tag(): string {
  const t = crypto.randomUUID().slice(0, 8).toUpperCase();
  tags.push(t);
  return t;
}

/** A delivery from a fixture with a unique fa_flight_id (so bodies and flights never collide). */
function delivery(
  fixture: Record<string, unknown>,
  faFlightId: string,
  flight: Record<string, unknown> = {},
  top: Record<string, unknown> = {},
): string {
  const f = fixture.flight as Record<string, unknown>;
  return JSON.stringify({
    ...fixture,
    ...top,
    flight: { ...f, fa_flight_id: faFlightId, ...flight },
  });
}

/** A followed flight (one user follows it). Returns ids. */
async function followedFlight(over: Record<string, unknown> = {}) {
  const t = tag();
  const providerId = `WHT${t}-1793600000-schedule-1p`;
  const { data, error } = await db.from("flights").insert({
    provider_id: providerId,
    ident: `WH${t}`,
    origin_icao: "LFPG",
    destination_icao: "KSFO",
    scheduled_out: "2026-11-03T22:30:00Z",
    scheduled_in: "2026-11-04T09:00:00Z",
    estimated_out: "2026-11-03T22:30:00Z",
    estimated_in: "2026-11-04T09:00:00Z",
    status: "scheduled",
    ...over,
  }).select("id").single();
  if (error) throw error;
  trackFlightId(data.id);
  const user = await makeUser(db);
  const f = await db.from("user_flights").insert({
    user_id: user,
    flight_id: data.id,
  });
  if (f.error) throw f.error;
  return { id: data.id as string, providerId };
}

async function inboxCount(): Promise<number> {
  const { count, error } = await db.from("webhook_inbox").select("id", {
    count: "exact",
    head: true,
  });
  if (error) throw error;
  return count ?? 0;
}

async function eventsOf(flightId: string) {
  const { data, error } = await db.from("flight_events").select("*").eq(
    "flight_id",
    flightId,
  );
  if (error) throw error;
  return data ?? [];
}

async function usage(): Promise<{ calls: number; cost: number } | null> {
  const day = new Date().toISOString().slice(0, 10);
  const { data, error } = await db.from("usage_counters").select("*").eq(
    "day",
    day,
  ).eq("endpoint", "alert_delivery").maybeSingle();
  if (error) throw error;
  return data ? { calls: data.calls, cost: Number(data.estimated_cost) } : null;
}

/** Runs fn, then deletes the inbox rows it made and restores today's alert_delivery counter. */
function wtest(name: string, fn: () => Promise<void>): void {
  test(db, name, async () => {
    const baseline = await db.from("webhook_inbox").select("id").order("id", {
      ascending: false,
    }).limit(1);
    const lastId = (baseline.data?.[0]?.id as number | undefined) ?? 0;
    const before = await usage();
    const day = new Date().toISOString().slice(0, 10);
    try {
      await fn();
    } finally {
      await db.from("webhook_inbox").delete().gt("id", lastId);
      const q = db.from("usage_counters");
      if (before === null) {
        await q.delete().eq("day", day).eq("endpoint", "alert_delivery");
      } else {
        await q.update({ calls: before.calls, estimated_cost: before.cost })
          .eq("day", day).eq("endpoint", "alert_delivery");
      }
    }
  });
}

wtest("wrong secret returns 401 and writes nothing", async () => {
  const p = fakePush();
  const { providerId } = await followedFlight();
  const n = await inboxCount();
  const u = await usage();
  const body = delivery(gateFixture, providerId, { gate_origin: "K99" });
  for (const secret of ["nope", "", null]) {
    const res = await handler(post(body, secret), deps(p));
    assertEquals(res.status, 401);
  }
  assertEquals(await inboxCount(), n);
  assertEquals(await usage(), u);
  assertEquals(p.calls.length, 0);
});

wtest(
  "missing WEBHOOK_SECRET rejects every request (fail closed)",
  async () => {
    const p = fakePush();
    const { providerId } = await followedFlight();
    const n = await inboxCount();
    const body = delivery(gateFixture, providerId);
    for (const configured of [undefined, ""]) {
      for (const given of ["", "undefined", SECRET]) {
        const res = await handler(post(body, given), deps(p, configured));
        assertEquals(res.status, 401);
      }
    }
    assertEquals(await inboxCount(), n);
  },
);

wtest(
  "gate change updates flights.gate_origin and inserts one event",
  async () => {
    const p = fakePush();
    const { id, providerId } = await followedFlight();
    const u0 = await usage();
    const res = await handler(
      post(delivery(gateFixture, providerId, { gate_origin: "K42" })),
      deps(p),
    );
    assertEquals(res.status, 200);
    const { data } = await db.from("flights").select(
      "gate_origin, terminal_origin",
    ).eq("id", id).single();
    assertEquals(data, { gate_origin: "K42", terminal_origin: "2E" });
    const events = await eventsOf(id);
    assertEquals(events.length, 1);
    assertEquals(events[0].kind, "gate_change");
    assertEquals(events[0].provider_event_id.length, 64);
    assertEquals(events[0].payload.changes.gate_origin.to, "K42");
    assertEquals(p.calls, [[id, events[0].id]]);
    const u1 = await usage();
    assertEquals((u1?.calls ?? 0) - (u0?.calls ?? 0), 1);
    assertEquals(
      Math.round(((u1?.cost ?? 0) - (u0?.cost ?? 0)) * 1e4) / 1e4,
      0.02,
    );
    const inbox = await db.from("webhook_inbox").select("*").order("id", {
      ascending: false,
    }).limit(1).single();
    assert(inbox.data?.processed_at);
    assertEquals(inbox.data?.error, null);
  },
);

wtest(
  "same body twice yields one event, one push call and one cost",
  async () => {
    const p = fakePush();
    const { id, providerId } = await followedFlight();
    const u0 = await usage();
    const body = delivery(gateFixture, providerId);
    const a = await handler(post(body), deps(p));
    const b = await handler(post(body), deps(p));
    assertEquals([a.status, b.status], [200, 200]);
    assertEquals((await eventsOf(id)).length, 1);
    assertEquals(p.calls.length, 1);
    const u1 = await usage();
    assertEquals((u1?.calls ?? 0) - (u0?.calls ?? 0), 1);
  },
);

wtest(
  "two simultaneous identical deliveries yield one event and one push",
  async () => {
    const p = fakePush();
    const { id, providerId } = await followedFlight();
    const body = delivery(gateFixture, providerId);
    const res = await Promise.all([
      handler(post(body), deps(p)),
      handler(post(body), deps(p)),
    ]);
    assertEquals(res.map((r) => r.status), [200, 200]);
    assertEquals((await eventsOf(id)).length, 1);
    assertEquals(p.calls.length, 1);
  },
);

wtest("malformed body keeps inbox row with error and returns 200", async () => {
  const p = fakePush();
  const n = await inboxCount();
  const res = await handler(post("{not json"), deps(p));
  assertEquals(res.status, 200);
  assertEquals(await inboxCount(), n + 1);
  const row = await db.from("webhook_inbox").select("*").order("id", {
    ascending: false,
  }).limit(1).single();
  assert(row.data?.error?.includes("malformed"));
  assert(row.data?.processed_at); // not replayable
  assertEquals(p.calls.length, 0);
});

wtest(
  "valid JSON of the wrong shape keeps inbox row with error and returns 200",
  async () => {
    const p = fakePush();
    const res = await handler(
      post(JSON.stringify({ hello: "world" })),
      deps(p),
    );
    assertEquals(res.status, 200);
    const row = await db.from("webhook_inbox").select("*").order("id", {
      ascending: false,
    }).limit(1).single();
    assertEquals(row.data?.error, "invalid alert shape");
    assertEquals(p.calls.length, 0);
  },
);

wtest("oversize body returns 413 and stores nothing", async () => {
  const p = fakePush();
  const n = await inboxCount();
  const big = JSON.stringify({ pad: "x".repeat(MAX_BODY_BYTES + 10) });
  const res = await handler(post(big), deps(p));
  assertEquals(res.status, 413);
  // Also when the length is not declared up front (chunked body).
  const stream = new Request(
    "http://localhost/aeroapi-webhook?secret=" + SECRET,
    {
      method: "POST",
      body: new ReadableStream({
        start(c) {
          c.enqueue(new Uint8Array(MAX_BODY_BYTES));
          c.enqueue(new Uint8Array(10));
          c.close();
        },
      }),
      // @ts-ignore duplex is required for stream bodies
      duplex: "half",
    },
  );
  assertEquals((await handler(stream, deps(p))).status, 413);
  assertEquals(await inboxCount(), n);
  assertEquals(p.calls.length, 0);
});

wtest(
  "delivery for a flight nobody follows: inbox noted, no event, no push, cost recorded",
  async () => {
    const p = fakePush();
    const t = tag();
    // Same ident, other day: the flights row exists (a lookup made it) but has no follower.
    const other = await db.from("flights").insert({
      provider_id: `WHT${t}-1793700000-schedule-9p`,
      ident: `WH${t}`,
      status: "scheduled",
    }).select("id").single();
    if (other.error) throw other.error;
    trackFlightId(other.data.id);
    const u0 = await usage();
    const cases = [
      `WHT${t}-1793700000-schedule-9p`, // row without followers
      `WHT${tag()}-1793800000-schedule-1p`, // no row at all
    ];
    for (const faId of cases) {
      const res = await handler(
        post(delivery(gateFixture, faId, { gate_origin: "Z1" })),
        deps(p),
      );
      assertEquals(res.status, 200);
    }
    assertEquals((await eventsOf(other.data.id)).length, 0);
    const row = await db.from("flights").select("gate_origin").eq(
      "id",
      other.data.id,
    ).single();
    assertEquals(row.data?.gate_origin, null);
    assertEquals(p.calls.length, 0);
    const inbox = await db.from("webhook_inbox").select("*").order("id", {
      ascending: false,
    }).limit(2);
    for (const r of inbox.data ?? []) {
      assert(r.processed_at);
      assert(r.note.includes("no followed flight"));
      assertEquals(r.error, null);
    }
    const u1 = await usage();
    assertEquals((u1?.calls ?? 0) - (u0?.calls ?? 0), 2);
  },
);

wtest(
  "late departure past local midnight still matches by fa_flight_id",
  async () => {
    const p = fakePush();
    // Scheduled 22:30 Paris time on Nov 3 (21:30Z); the plane leaves at 00:20 Paris on Nov 4.
    const { id, providerId } = await followedFlight({
      scheduled_out: "2026-11-03T21:30:00Z",
      estimated_out: "2026-11-03T21:30:00Z",
    });
    const res = await handler(
      post(delivery(departureFixture, providerId, {
        scheduled_out: "2026-11-03T21:30:00Z",
        estimated_out: "2026-11-03T23:20:00Z",
        actual_out: "2026-11-03T23:20:00Z",
        actual_off: "2026-11-03T23:35:00Z",
      })),
      deps(p),
    );
    assertEquals(res.status, 200);
    const events = await eventsOf(id);
    assertEquals(events.length, 1);
    assertEquals(events[0].kind, "departure");
    const row = await db.from("flights").select("status, actual_out").eq(
      "id",
      id,
    ).single();
    assertEquals(row.data?.status, "en_route");
    assertEquals(
      Date.parse(row.data?.actual_out),
      Date.parse("2026-11-03T23:20:00Z"),
    );
    assertEquals(p.calls.length, 1);
  },
);

wtest(
  "estimate change is a delay, unchanged change makes no event, out/off do not duplicate",
  async () => {
    const p = fakePush();
    const { id, providerId } = await followedFlight();
    const delay = delivery(gateFixture, providerId, {
      gate_origin: null,
      terminal_origin: null,
      estimated_out: "2026-11-03T23:10:00Z",
    });
    assertEquals((await handler(post(delay), deps(p))).status, 200);
    const events = await eventsOf(id);
    assertEquals(events.map((e) => e.kind), ["delay"]);

    // Nothing new in this change: no event, no push.
    const same = delivery(gateFixture, providerId, {
      gate_origin: null,
      terminal_origin: null,
      estimated_out: "2026-11-03T23:10:00Z",
    }, { alert_id: 4242002 });
    assertEquals((await handler(post(same), deps(p))).status, 200);
    // A gate-out code with no gate or estimate change adds no event either.
    const out = delivery(gateFixture, providerId, {
      gate_origin: null,
      terminal_origin: null,
      estimated_out: "2026-11-03T23:10:00Z",
    }, { event_code: "out" });
    assertEquals((await handler(post(out), deps(p))).status, 200);
    assertEquals((await eventsOf(id)).length, 1);
    assertEquals(p.calls.length, 1);
  },
);

wtest("cancelled and diverted events set the status", async () => {
  const p = fakePush();
  const a = await followedFlight();
  const b = await followedFlight();
  await handler(
    post(delivery(gateFixture, a.providerId, { cancelled: true }, {
      event_code: "cancelled",
    })),
    deps(p),
  );
  await handler(
    post(delivery(gateFixture, b.providerId, { destination_icao: "KOAK" }, {
      event_code: "diverted",
    })),
    deps(p),
  );
  const rows = await db.from("flights").select("id, status, destination_icao")
    .in("id", [a.id, b.id]);
  const byId = Object.fromEntries((rows.data ?? []).map((r) => [r.id, r]));
  assertEquals(byId[a.id].status, "canceled");
  assertEquals(byId[b.id].status, "diverted");
  assertEquals(byId[b.id].destination_icao, "KOAK");
  assertEquals((await eventsOf(a.id))[0].kind, "cancel");
  assertEquals((await eventsOf(b.id))[0].kind, "diversion");
});

wtest("a push failure does not fail the webhook", async () => {
  const p = fakePush();
  p.fail = true;
  const { id, providerId } = await followedFlight();
  const res = await handler(post(delivery(gateFixture, providerId)), deps(p));
  assertEquals(res.status, 200);
  assertEquals(p.calls.length, 1);
  assertEquals((await eventsOf(id)).length, 1);
});

wtest("non-POST is rejected", async () => {
  const p = fakePush();
  const res = await handler(
    new Request(`http://localhost/aeroapi-webhook?secret=${SECRET}`),
    deps(p),
  );
  assertEquals(res.status, 405);
});

Deno.test("config.toml turns JWT verification off for aeroapi-webhook", async () => {
  const toml = parseToml(
    await Deno.readTextFile(new URL("../../config.toml", import.meta.url)),
  ) as { functions?: Record<string, { verify_jwt?: boolean }> };
  assertEquals(toml.functions?.["aeroapi-webhook"]?.verify_jwt, false);
});

wtest(
  "delay events: first at 15 min, then every 15 min move either way",
  async () => {
    const p = fakePush();
    const { id, providerId } = await followedFlight();
    const base = Date.parse("2026-11-03T22:30:00Z");
    const send = async (min: number, alertId: number) => {
      const est = new Date(base + min * 60000).toISOString();
      const r = await handler(
        post(delivery(gateFixture, providerId, {
          gate_origin: null,
          terminal_origin: null,
          estimated_out: est,
        }, { alert_id: alertId })),
        deps(p),
      );
      assertEquals(r.status, 200);
    };
    const steps: [number, boolean][] = [[3, false], [16, true], [20, false], [
      32,
      true,
    ], [10, true]];
    let n = 0;
    for (const [min, expectEvent] of steps) {
      await send(min, 5000 + n++);
      assertEquals(
        (await eventsOf(id)).length,
        steps.slice(0, n).filter((s) => s[1]).length,
        `after ${min} min`,
      );
    }
    assertEquals(p.calls.length, 3);
    const events = (await eventsOf(id)).sort((a, b) =>
      a.payload.delay_minutes - b.payload.delay_minutes
    );
    assertEquals(events.map((e) => e.kind), ["delay", "delay", "delay"]);
    assertEquals(events.map((e) => e.payload.delay_minutes), [10, 16, 32]);
    const row = await db.from("flights").select(
      "notified_delay_min, estimated_out",
    ).eq("id", id).single();
    assertEquals(row.data?.notified_delay_min, 10);
  },
);

wtest(
  "an older body cannot undo a cancel, an actual time or a later status",
  async () => {
    const p = fakePush();
    const a = await followedFlight();
    const cancel = delivery(gateFixture, a.providerId, { cancelled: true }, {
      event_code: "cancelled",
    });
    await handler(post(cancel), deps(p));
    const stale = delivery(gateFixture, a.providerId, { gate_origin: "Q1" }, {
      alert_id: 1,
    });
    await handler(post(stale), deps(p));
    const ra = await db.from("flights").select("status").eq("id", a.id)
      .single();
    assertEquals(ra.data?.status, "canceled");

    const b = await followedFlight();
    await handler(
      post(
        delivery(departureFixture, b.providerId, {
          actual_out: "2026-11-03T22:41:00Z",
          actual_off: "2026-11-03T22:58:00Z",
        }),
      ),
      deps(p),
    );
    // Older change: no actuals, an estimate for a leg that already left, and a different actual.
    await handler(
      post(delivery(gateFixture, b.providerId, {
        gate_origin: null,
        terminal_origin: null,
        estimated_out: "2026-11-03T22:20:00Z",
        actual_out: "2026-11-03T22:50:00Z",
      }, { alert_id: 2 })),
      deps(p),
    );
    const rb = await db.from("flights").select(
      "status, actual_out, estimated_out",
    ).eq("id", b.id).single();
    assertEquals(rb.data?.status, "en_route");
    assertEquals(
      Date.parse(rb.data?.actual_out),
      Date.parse("2026-11-03T22:41:00Z"),
    );
    assertEquals(
      Date.parse(rb.data?.estimated_out),
      Date.parse("2026-11-03T22:30:00Z"),
    );
  },
);

wtest(
  "a change delivery carrying cancelled=true raises a cancel event",
  async () => {
    const p = fakePush();
    const { id, providerId } = await followedFlight();
    await handler(
      post(delivery(gateFixture, providerId, { cancelled: true })),
      deps(p),
    );
    assertEquals((await eventsOf(id)).map((e) => e.kind), ["cancel"]);
  },
);

wtest(
  "body null and NUL characters are kept as malformed with 200",
  async () => {
    const p = fakePush();
    for (const body of ["null", "[1]", '{"a":"x\\u0000y"}']) {
      assertEquals((await handler(post(body), deps(p))).status, 200, body);
    }
    const rows = await db.from("webhook_inbox").select("error").order("id", {
      ascending: false,
    }).limit(3);
    assertEquals(
      (rows.data ?? []).filter((r) => r.error).length,
      3,
    );
  },
);

wtest(
  "a crash in the transaction leaves nothing and the retry is processed",
  async () => {
    const p = fakePush();
    const { id, providerId } = await followedFlight();
    let fail = true;
    const flaky = new Proxy(db, {
      get(t, prop, r) {
        if (prop === "rpc") {
          return (name: string, args: unknown) =>
            fail && name === "process_alert"
              ? Promise.resolve({ data: null, error: { message: "boom" } })
              : t.rpc(name, args as Record<string, unknown>);
        }
        return Reflect.get(t, prop, r);
      },
    });
    const body = delivery(gateFixture, providerId, { gate_origin: "K77" });
    const u0 = await usage();
    const r1 = await handler(post(body), { ...deps(p), db: flaky });
    assertEquals(r1.status, 500);
    assertEquals((await eventsOf(id)).length, 0);
    assertEquals((await usage())?.calls, u0?.calls);
    const failed = await db.from("webhook_inbox").select("*").order("id", {
      ascending: false,
    }).limit(1).single();
    assert(failed.data?.error && failed.data?.processed_at === null);
    fail = false;
    const r2 = await handler(post(body), deps(p));
    assertEquals(r2.status, 200);
    assertEquals((await eventsOf(id)).length, 1);
    assertEquals(p.calls.length, 1);
    const settled = await db.from("webhook_inbox").select("*").eq(
      "id",
      failed.data!.id,
    ).single();
    assertEquals(settled.data?.error, null);
    assert(settled.data?.processed_at);
  },
);

wtest(
  "identical deliveries for an unfollowed flight at once bill once",
  async () => {
    const p = fakePush();
    const body = delivery(gateFixture, `WHT${tag()}-1793900000-schedule-1p`);
    const u0 = await usage();
    const res = await Promise.all([
      handler(post(body), deps(p)),
      handler(post(body), deps(p)),
      handler(post(body), deps(p)),
    ]);
    assertEquals(res.map((r) => r.status), [200, 200, 200]);
    assertEquals(((await usage())?.calls ?? 0) - (u0?.calls ?? 0), 1);
  },
);

wtest(
  "a wrong secret of the right length is rejected; the previous secret still works",
  async () => {
    const p = fakePush();
    const { providerId } = await followedFlight();
    const body = delivery(gateFixture, providerId);
    assertEquals(
      (await handler(post(body, "x".repeat(SECRET.length)), deps(p))).status,
      401,
    );
    const rotating = { ...deps(p, "new-secret"), previousSecret: () => SECRET };
    assertEquals((await handler(post(body, SECRET), rotating)).status, 200);
    assertEquals(
      (await handler(post(body, "new-secret"), rotating)).status,
      200,
    );
    assertEquals((await handler(post(body, "other"), rotating)).status, 401);
  },
);
