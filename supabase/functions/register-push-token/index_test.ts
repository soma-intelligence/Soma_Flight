import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  fakeVerifier,
  makeUser,
  test,
  testDb,
  trackFlightId,
  userClient,
} from "../_shared/test_util.ts";
import { handler } from "./handler.ts";

const db = await testDb();
let seq = Math.floor(Math.random() * 1e6) * 100;
const newToken = () => (++seq).toString(16).padStart(8, "0").repeat(8);

async function makeFlight(): Promise<string> {
  const tag = crypto.randomUUID().slice(0, 8).toUpperCase();
  const { data, error } = await db.from("flights").insert({
    provider_id: `REG${tag}-1793600000-schedule-1p`,
    ident: "AF84",
    status: "scheduled",
  }).select("id").single();
  if (error) throw error;
  trackFlightId(data.id);
  return data.id;
}

function post(user: string | null, body: unknown, method = "POST") {
  return handler(
    new Request("http://localhost/register-push-token", {
      method,
      headers: user ? { authorization: `Bearer ${user}` } : {},
      body: method === "GET" ? undefined : JSON.stringify(body),
    }),
    { db, verifier: fakeVerifier },
  );
}

const rows = async (token: string) =>
  (await db.from("push_tokens").select("*").eq("token", token)).data ?? [];

test(db, "register-push-token needs a user", async () => {
  const res = await post(null, {
    token: newToken(),
    kind: "alert",
    platform: "ios",
  });
  assertEquals(res.status, 401);
  await res.body?.cancel();
  const bad = await post("bad", {
    token: newToken(),
    kind: "alert",
    platform: "ios",
  });
  assertEquals(bad.status, 401);
  await bad.body?.cancel();
});

test(db, "register-push-token stores an alert token", async () => {
  const u = await makeUser(db);
  const token = newToken().toUpperCase();
  const res = await post(u, { token, kind: "alert", platform: "ios" });
  assertEquals(res.status, 200);
  await res.body?.cancel();
  const r = await rows(token.toLowerCase());
  assertEquals(r.length, 1);
  assertEquals(r[0].user_id, u);
  assertEquals(r[0].flight_id, null);
  // Same device registers again: still one row.
  await (await post(u, { token, kind: "alert", platform: "ios" })).body
    ?.cancel();
  assertEquals((await rows(token.toLowerCase())).length, 1);
});

test(db, "register-push-token moves a token to the new account", async () => {
  const [a, b] = [await makeUser(db), await makeUser(db)];
  const token = newToken();
  await (await post(a, { token, kind: "alert", platform: "ios" })).body
    ?.cancel();
  assertEquals((await rows(token))[0].user_id, a);
  const res = await post(b, { token, kind: "alert", platform: "ios" });
  assertEquals(res.status, 200);
  await res.body?.cancel();
  const r = await rows(token);
  assertEquals(r.length, 1);
  assertEquals(r[0].user_id, b);
});

test(db, "register-push-token validates the body", async () => {
  const u = await makeUser(db);
  const f = await makeFlight();
  const cases: unknown[] = [
    { token: "zz".repeat(32), kind: "alert", platform: "ios" },
    { token: "ab12", kind: "alert", platform: "ios" },
    { token: "abc".repeat(21) + "ab", kind: "alert", platform: "ios" }, // odd length
    { token: newToken(), kind: "other", platform: "ios" },
    { token: newToken(), kind: "alert", platform: "android" },
    { token: newToken(), kind: "live_activity", platform: "ios" },
    {
      token: newToken(),
      kind: "live_activity",
      flightId: "nope",
      platform: "ios",
    },
    { token: newToken(), kind: "alert", flightId: f, platform: "ios" },
  ];
  for (const c of cases) {
    const res = await post(u, c);
    assertEquals(res.status, 400, JSON.stringify(c));
    await res.body?.cancel();
  }
  const get = await post(u, {}, "GET");
  assertEquals(get.status, 405);
  await get.body?.cancel();
});

test(
  db,
  "a user cannot register a live_activity token for a flight they do not follow",
  async () => {
    const [a, b] = [await makeUser(db), await makeUser(db)];
    const f = await makeFlight();
    const r = await db.from("user_flights").insert({
      user_id: a,
      flight_id: f,
    });
    if (r.error) throw r.error;
    const token = newToken();
    const denied = await post(b, {
      token,
      kind: "live_activity",
      flightId: f,
      platform: "ios",
    });
    assertEquals(denied.status, 404);
    await denied.body?.cancel();
    assertEquals((await rows(token)).length, 0);
    const ok = await post(a, {
      token,
      kind: "live_activity",
      flightId: f,
      platform: "ios",
    });
    assertEquals(ok.status, 200);
    await ok.body?.cancel();
    const row = (await rows(token))[0];
    assertEquals(row.user_id, a);
    assertEquals(row.flight_id, f);
    // b cannot take it over for a flight b does not follow either.
    const steal = await post(b, {
      token,
      kind: "live_activity",
      flightId: f,
      platform: "ios",
    });
    assertEquals(steal.status, 404);
    await steal.body?.cancel();
    assertEquals((await rows(token))[0].user_id, a);
  },
);

test(db, "clients cannot write push_tokens directly", async () => {
  const [a, b] = [await makeUser(db), await makeUser(db)];
  const client = await userClient(db, a);
  const token = newToken();
  const ins = await client.from("push_tokens").insert({
    user_id: a,
    token,
    kind: "alert",
  });
  assert(ins.error, "direct insert must fail");
  assertEquals(ins.error!.code, "42501");
  // Taking over a token that exists is blocked too.
  await (await post(b, { token, kind: "alert", platform: "ios" })).body
    ?.cancel();
  const upd = await client.from("push_tokens").update({ user_id: a }).eq(
    "token",
    token,
  );
  assert(upd.error, "direct update must fail");
  assertEquals((await rows(token))[0].user_id, b);
  // Reading and deleting own tokens still works.
  await (await post(a, { token: newToken(), kind: "alert", platform: "ios" }))
    .body?.cancel();
  const mine = await client.from("push_tokens").select("token");
  assertEquals(mine.data?.length, 1);
  const del = await client.from("push_tokens").delete().eq("user_id", a);
  assertEquals(del.error, null);
  assertEquals(
    (await client.from("push_tokens").select("token")).data?.length,
    0,
  );
});
