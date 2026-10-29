import { assert, assertEquals } from "jsr:@std/assert@1";
import { makeUser, test, testDb, trackFlightId } from "../_shared/test_util.ts";
import { ALERT_BATCH, handler } from "./handler.ts";

const db = await testDb();

const b64 = (o: object) =>
  btoa(JSON.stringify(o)).replace(/=+$/, "").replace(/\+/g, "-").replace(
    /\//g,
    "_",
  );
const jwt = (role: string) => `${b64({ alg: "HS256" })}.${b64({ role })}.sig`;
const SERVICE_KEY = jwt("service_role");

function fakeAero() {
  const calls = { del: [] as number[], create: 0 };
  return {
    calls,
    failFor: new Set<number>(),
    createAlert() {
      calls.create++;
      return Promise.resolve(Math.floor(Math.random() * 1e9));
    },
    deleteAlert(id: number) {
      if (this.failFor.has(id)) {
        return Promise.reject(new Error("provider down"));
      }
      calls.del.push(id);
      return Promise.resolve();
    },
  };
}

let alertSeq = 700_000_000 + Math.floor(Math.random() * 1e6) * 10;

async function makeFlight(
  alert: boolean,
): Promise<{ id: string; alert: number | null }> {
  const tag = crypto.randomUUID().slice(0, 8).toUpperCase();
  const alertId = alert ? ++alertSeq : null;
  const { data, error } = await db.from("flights").insert({
    provider_id: `MNT${tag}-1793600000-schedule-1p`,
    ident: `MN${tag}`,
    origin_icao: "LFPG",
    destination_icao: "KSFO",
    scheduled_out: "2026-11-03T22:30:00Z",
    status: "arrived",
    alert_id: alertId,
  }).select("id").single();
  if (error) throw error;
  trackFlightId(data.id);
  return { id: data.id, alert: alertId };
}

const alertOf = async (id: string) =>
  (await db.from("flights").select("alert_id").eq("id", id).single()).data
    ?.alert_id ?? null;

function call(
  aero: ReturnType<typeof fakeAero>,
  mode: string | null,
  opts: { method?: string; bearer?: string | null } = {},
) {
  const url = `http://localhost/maintenance${mode ? `?mode=${mode}` : ""}`;
  const bearer = opts.bearer === undefined ? SERVICE_KEY : opts.bearer;
  return handler(
    new Request(url, {
      method: opts.method ?? "POST",
      headers: bearer ? { authorization: `Bearer ${bearer}` } : {},
    }),
    { db, aero: () => aero, serviceKey: () => SERVICE_KEY },
  );
}

test(db, "rejects callers without the service role key", async () => {
  const aero = fakeAero();
  assertEquals((await call(aero, "alerts", { bearer: null })).status, 401);
  assertEquals(
    (await call(aero, "alerts", { bearer: jwt("anon") })).status,
    401,
  );
  assertEquals(
    (await call(aero, "alerts", { bearer: jwt("authenticated") })).status,
    401,
  );
  assertEquals(aero.calls.del.length, 0);
});

test(db, "POST only, and mode must be alerts or prune", async () => {
  const aero = fakeAero();
  assertEquals((await call(aero, "alerts", { method: "GET" })).status, 405);
  assertEquals((await call(aero, null)).status, 400);
  const bad = await call(aero, "everything");
  assertEquals(bad.status, 400);
  assertEquals((await bad.json()).error.code, "invalid_request");
});

test(
  db,
  "alerts: releases alerts of unfollowed flights, keeps followed ones",
  async () => {
    const aero = fakeAero();
    const orphan = await makeFlight(true);
    const followed = await makeFlight(true);
    const none = await makeFlight(false);
    const user = await makeUser(db);
    const f = await db.from("user_flights").insert({
      user_id: user,
      flight_id: followed.id,
    });
    if (f.error) throw f.error;

    const res = await call(aero, "alerts");
    assertEquals(res.status, 200);
    const body = await res.json();
    assertEquals(body.mode, "alerts");
    assert(body.released >= 1);
    assert(aero.calls.del.includes(orphan.alert!));
    assert(!aero.calls.del.includes(followed.alert!));
    assertEquals(await alertOf(orphan.id), null);
    assertEquals(await alertOf(followed.id), followed.alert);
    assertEquals(await alertOf(none.id), null);
    assertEquals(aero.calls.create, 0);
  },
);

test(
  db,
  "alerts: a provider failure keeps alert_id for the next run",
  async () => {
    const aero = fakeAero();
    const stuck = await makeFlight(true);
    aero.failFor.add(stuck.alert!);

    const first = await (await call(aero, "alerts")).json();
    assert(first.kept >= 1);
    assertEquals(await alertOf(stuck.id), stuck.alert);

    aero.failFor.clear();
    const second = await (await call(aero, "alerts")).json();
    assert(second.released >= 1);
    assertEquals(await alertOf(stuck.id), null);
    assert(aero.calls.del.includes(stuck.alert!));
  },
);

test(
  db,
  "alerts: a run is bounded and nothing to do answers zero",
  async () => {
    const aero = fakeAero();
    await call(aero, "alerts"); // drain anything left by earlier runs
    const res = await (await call(aero, "alerts")).json();
    assertEquals(res, {
      ok: true,
      mode: "alerts",
      checked: 0,
      released: 0,
      kept: 0,
    });
    assert(ALERT_BATCH > 0);
  },
);

test(
  db,
  "alerts: no AeroAPI client is built when there is nothing to release",
  async () => {
    await call(fakeAero(), "alerts");
    const res = await handler(
      new Request("http://localhost/maintenance?mode=alerts", {
        method: "POST",
        headers: { authorization: `Bearer ${SERVICE_KEY}` },
      }),
      {
        db,
        aero: () => {
          throw new Error("AeroAPI must not be built");
        },
        serviceKey: () => SERVICE_KEY,
      },
    );
    assertEquals(res.status, 200);
  },
);

test(db, "prune: deletes expired rows and reports counts", async () => {
  const user = await makeUser(db);
  const old = new Date(Date.now() - 3 * 3600_000).toISOString();
  const ins = await db.from("rate_events").insert([
    { user_id: user, endpoint: "mnt-old", at: old },
    { user_id: user, endpoint: "mnt-new", at: new Date().toISOString() },
  ]);
  if (ins.error) throw ins.error;
  const marker = `mnt-${crypto.randomUUID()}`;
  const longAgo = new Date(Date.now() - 31 * 86_400_000).toISOString();
  const inbox = await db.from("webhook_inbox").insert([
    {
      body: { t: marker, done: true },
      received_at: longAgo,
      processed_at: longAgo,
    },
    { body: { t: marker, done: false }, received_at: longAgo },
  ]);
  if (inbox.error) throw inbox.error;
  try {
    const res = await call(fakeAero(), "prune");
    assertEquals(res.status, 200);
    const body = await res.json();
    assertEquals(body.mode, "prune");
    assert(body.pruned.rate_events >= 1);
    assert(body.pruned.webhook_inbox >= 1);
    for (
      const k of [
        "route_cache",
        "airport_snapshots",
        "airport_refresh_leases",
        "flight_events",
      ]
    ) assertEquals(typeof body.pruned[k], "number");
    const left = await db.from("rate_events").select("endpoint").eq(
      "user_id",
      user,
    );
    assertEquals(left.data?.map((r) => r.endpoint), ["mnt-new"]);
    const kept = await db.from("webhook_inbox").select("body").eq(
      "body->>t",
      marker,
    );
    assertEquals(kept.data?.map((r) => r.body.done), [false]);
  } finally {
    await db.from("webhook_inbox").delete().eq("body->>t", marker);
  }
});
