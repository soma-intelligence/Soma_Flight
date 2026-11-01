import { assert, assertEquals } from "jsr:@std/assert@1";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import {
  fakeVerifier,
  makeUser,
  test,
  testDb,
  trackFlightId,
} from "../_shared/test_util.ts";
import { ensureAlert } from "../_shared/follow.ts";
import {
  archivedAvatarPath,
  avatarPath,
  AVATARS_BUCKET,
  handler,
} from "./handler.ts";

const db = await testDb();

function fakeAero() {
  const calls = { del: [] as number[] };
  let next = Math.floor(Math.random() * 1e9);
  return {
    calls,
    failDelete: false,
    createAlert() {
      return Promise.resolve(++next);
    },
    deleteAlert(id: number) {
      if (this.failDelete) return Promise.reject(new Error("provider down"));
      calls.del.push(id);
      return Promise.resolve();
    },
  };
}

async function makeFlight(): Promise<string> {
  const tag = crypto.randomUUID().slice(0, 8).toUpperCase();
  const { data, error } = await db.from("flights").insert({
    provider_id: `TST${tag}-1793600000-schedule-1p`,
    ident: `TS${tag}`,
    origin_icao: "LFPG",
    destination_icao: "KSFO",
    scheduled_out: "2026-11-03T22:30:00Z",
    scheduled_in: "2026-11-04T09:00:00Z",
    status: "scheduled",
  }).select("id").single();
  if (error) throw error;
  trackFlightId(data.id);
  return data.id;
}

function req(user: string | null, method = "POST"): Request {
  return new Request("http://localhost/delete-account", {
    method,
    headers: user ? { authorization: `Bearer ${user}` } : {},
  });
}

const alertOf = async (id: string) =>
  (await db.from("flights").select("alert_id").eq("id", id).single()).data
    ?.alert_id;

const count = async (table: string, user: string) =>
  (await db.from(table).select("*", { count: "exact", head: true }).eq(
    "user_id",
    user,
  )).count;

/** Follows a flight the way follow-flight does: row first, then the shared alert. */
async function follow(
  aero: ReturnType<typeof fakeAero>,
  user: string,
  flight: string,
) {
  const r = await db.from("user_flights").insert({
    user_id: user,
    flight_id: flight,
  });
  if (r.error) throw r.error;
  await ensureAlert(db, aero, flight);
}

async function seed(user: string, flight: string) {
  for (
    const r of [
      await db.from("past_flights").insert({
        user_id: user,
        date: "2026-01-01",
        ident: "AF84",
        // An archived row: client rows must carry a route (migration 20261030000013).
        source: "archive",
      }),
      await db.from("push_tokens").insert([
        { user_id: user, token: `t-${crypto.randomUUID()}`, kind: "alert" },
        {
          user_id: user,
          token: `t-${crypto.randomUUID()}`,
          kind: "live_activity",
          flight_id: flight,
        },
      ]),
      await db.from("profiles").update({
        display_name: "Ada Lovelace",
        first_name: "Ada",
        last_name: "Lovelace",
        avatar_path: avatarPath(user),
        onboarded_at: new Date().toISOString(),
      }).eq("user_id", user),
      await db.storage.from(AVATARS_BUCKET).upload(
        avatarPath(user),
        new Blob([new Uint8Array([0xff, 0xd8, 0xff, 0xd9])], {
          type: "image/jpeg",
        }),
        { contentType: "image/jpeg", upsert: true },
      ),
    ]
  ) if (r.error) throw r.error;
}

test(db, "deletes user rows and keeps profile marked deleted", async () => {
  const user = await makeUser(db);
  const other = await makeUser(db);
  const flight = await makeFlight();
  const aero = fakeAero();
  await follow(aero, user, flight);
  await seed(user, flight);
  await seed(other, flight);
  for (const u of [user, other]) {
    const r = await db.from("rate_events").insert([
      { user_id: u, endpoint: "follow-flight" },
      { user_id: u, endpoint: "flight-lookup" },
    ]);
    if (r.error) throw r.error;
  }

  const res = await handler(req(user), { db, aero, verifier: fakeVerifier });
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { ok: true });

  for (const t of ["user_flights", "past_flights", "push_tokens"]) {
    assertEquals(await count(t, user), 0, t);
  }
  const p = await db.from("profiles").select("*").eq("user_id", user).single();
  assertEquals(p.data?.status, "deleted");
  assertEquals(p.data?.display_name, null);
  assertEquals(
    [
      p.data?.first_name,
      p.data?.last_name,
      p.data?.avatar_path,
      p.data?.onboarded_at,
    ],
    [null, null, null, null],
  );
  const photos = await db.storage.from(AVATARS_BUCKET).list(user);
  assertEquals((photos.data ?? []).map((f) => f.name), [], "the photo is gone");
  const archived = await db.storage.from(AVATARS_BUCKET).list(`deleted/${user}`);
  assertEquals(
    (archived.data ?? []).map((f) => f.name),
    ["avatar.jpg"],
    "the photo is kept in the archive folder",
  );
  await db.storage.from(AVATARS_BUCKET).remove([archivedAvatarPath(user)]);
  const kept = await db.storage.from(AVATARS_BUCKET).list(other);
  assertEquals(
    (kept.data ?? []).map((f) => f.name),
    ["avatar.jpg"],
    "another user's photo stays",
  );
  assert((await db.auth.admin.getUserById(user)).error !== null);
  const events = await db.from("rate_events").select("endpoint").eq(
    "user_id",
    user,
  );
  assertEquals((events.data ?? []).map((e) => e.endpoint), ["delete-account"]);
  assertEquals(await count("rate_events", other), 2);
  // Another user's rows and profile are untouched.
  assertEquals(await count("past_flights", other), 1);
  assertEquals(await count("push_tokens", other), 2);
  const o = await db.from("profiles").select("*").eq("user_id", other)
    .single();
  assertEquals(o.data?.status, "active");
  assertEquals(o.data?.display_name, "Ada Lovelace");
  await db.storage.from(AVATARS_BUCKET).remove([avatarPath(other)]);
});

test(
  db,
  "sole follower deletion drops the alert; shared flight keeps alert",
  async () => {
    const [a, b, _c] = [
      await makeUser(db),
      await makeUser(db),
      await makeUser(db),
    ];
    const solo = await makeFlight();
    const shared = await makeFlight();
    const aero = fakeAero();
    await follow(aero, a, solo);
    await follow(aero, a, shared);
    await follow(aero, b, shared);
    const soloAlert = await alertOf(solo);
    const sharedAlert = await alertOf(shared);
    assert(soloAlert !== null && sharedAlert !== null);

    const res = await handler(req(a), { db, aero, verifier: fakeVerifier });
    assertEquals(res.status, 200);
    assertEquals(aero.calls.del, [Number(soloAlert)]);
    assertEquals(await alertOf(solo), null);
    assertEquals(await alertOf(shared), sharedAlert);

    // The last follower leaving later releases the shared alert too.
    assertEquals(
      (await handler(req(b), { db, aero, verifier: fakeVerifier })).status,
      200,
    );
    assertEquals(await alertOf(shared), null);
    assertEquals(aero.calls.del.length, 2);
  },
);

test(db, "no JWT returns 401", async () => {
  const aero = fakeAero();
  const res = await handler(req(null), { db, aero, verifier: fakeVerifier });
  assertEquals(res.status, 401);
  assertEquals((await res.json()).error.code, "unauthorized");
  assertEquals(
    (await handler(req("bad"), { db, aero, verifier: fakeVerifier })).status,
    401,
  );
});

test(db, "wrong method returns 405", async () => {
  const user = await makeUser(db);
  const res = await handler(req(user, "GET"), {
    db,
    aero: fakeAero(),
    verifier: fakeVerifier,
  });
  assertEquals(res.status, 405);
  assert((await db.auth.admin.getUserById(user)).error === null);
});

test(
  db,
  "provider delete failure keeps alert_id and still deletes the account",
  async () => {
    const user = await makeUser(db);
    const flight = await makeFlight();
    const aero = fakeAero();
    await follow(aero, user, flight);
    const alert = await alertOf(flight);
    assert(alert !== null);
    aero.failDelete = true;

    const res = await handler(req(user), { db, aero, verifier: fakeVerifier });
    assertEquals(res.status, 200);
    assertEquals(await alertOf(flight), alert); // left for the sweep
    assertEquals(await count("user_flights", user), 0);
    assert((await db.auth.admin.getUserById(user)).error !== null);
  },
);

test(
  db,
  "auth delete failure returns 500, data stays erased, retry finishes",
  async () => {
    const user = await makeUser(db);
    const flight = await makeFlight();
    const aero = fakeAero();
    await follow(aero, user, flight);
    await seed(user, flight);

    let fail = true;
    const flaky = new Proxy(db, {
      get(target, prop, recv) {
        if (prop !== "auth") return Reflect.get(target, prop, recv);
        return {
          ...target.auth,
          admin: {
            deleteUser: (id: string) =>
              fail
                ? Promise.resolve({
                  data: { user: null },
                  error: { message: "auth down", status: 500 },
                })
                : target.auth.admin.deleteUser(id),
          },
        };
      },
    }) as SupabaseClient;

    const first = await handler(req(user), {
      db: flaky,
      aero,
      verifier: fakeVerifier,
    });
    assertEquals(first.status, 500);
    assertEquals((await first.json()).error.code, "provider_unavailable");
    for (const t of ["user_flights", "past_flights", "push_tokens"]) {
      assertEquals(await count(t, user), 0, t);
    }
    assertEquals(
      (await db.from("profiles").select("status").eq("user_id", user).single())
        .data?.status,
      "deleted",
    );
    assert((await db.auth.admin.getUserById(user)).error === null);

    fail = false;
    const retry = await handler(req(user), {
      db: flaky,
      aero,
      verifier: fakeVerifier,
    });
    assertEquals(retry.status, 200);
    assert((await db.auth.admin.getUserById(user)).error !== null);
  },
);

test(db, "second call after deletion does not fail", async () => {
  const user = await makeUser(db);
  const d = { db, aero: fakeAero(), verifier: fakeVerifier };
  assertEquals((await handler(req(user), d)).status, 200);
  // Same handler, user already gone: nothing left to do, still ok.
  assertEquals((await handler(req(user), d)).status, 200);
  assertEquals(
    (await db.from("profiles").select("status").eq("user_id", user).single())
      .data?.status,
    "deleted",
  );
});

test(
  db,
  "a valid JWT of a just deleted user is rejected, not a 500",
  async () => {
    const user = await makeUser(db);
    const client = await (await import("../_shared/test_util.ts")).userClient(
      db,
      user,
    );
    const token = (await client.auth.getSession()).data.session!.access_token;
    const d = { db, aero: fakeAero(), verifier: db };
    assertEquals((await handler(req(token), d)).status, 200);
    const again = await handler(req(token), d);
    assertEquals(again.status, 401);
    assertEquals((await again.json()).error.code, "unauthorized");
  },
);

test(db, "rate limited to 5 per hour", async () => {
  const user = await makeUser(db);
  const d = { db, aero: fakeAero(), verifier: fakeVerifier };
  for (let i = 0; i < 5; i++) {
    assertEquals((await handler(req(user), d)).status, 200, `call ${i + 1}`);
  }
  const res = await handler(req(user), d);
  assertEquals(res.status, 429);
  assertEquals((await res.json()).error.code, "rate_limited");
});
