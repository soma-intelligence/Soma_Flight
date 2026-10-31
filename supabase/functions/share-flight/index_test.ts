import { assert, assertEquals } from "jsr:@std/assert@1";
import { hashToken, TOKEN_RE } from "../_shared/share.ts";
import {
  fakeVerifier,
  loadIndexHandler,
  makeUser,
  test,
  testDb,
  trackFlightId,
} from "../_shared/test_util.ts";
import { handler, SHARE_MAX_PER_HOUR } from "./handler.ts";

const db = await testDb();
const NOW = new Date("2026-11-03T08:00:00Z");
const URL_ = "http://localhost/share-flight";

/** A flight arriving at `arrival`, tracked for cleanup. */
async function flight(arrival = "2026-11-03T20:55:00Z"): Promise<string> {
  const r = await db.from("flights").insert({
    provider_id: `share-${crypto.randomUUID()}`,
    ident: "AF84",
    operator: "AF",
    origin_icao: "LFPG",
    destination_icao: "KSFO",
    scheduled_out: "2026-11-03T09:35:00Z",
    scheduled_in: arrival,
  }).select("id").single();
  if (r.error) throw r.error;
  trackFlightId(r.data.id);
  return r.data.id;
}

async function follow(user: string, id: string) {
  const r = await db.from("user_flights").insert({
    user_id: user,
    flight_id: id,
  });
  if (r.error) throw r.error;
}

function call(
  user: string,
  method: string,
  opts: { body?: unknown; flight?: string; now?: Date; token?: () => string } =
    {},
) {
  const url = opts.flight ? `${URL_}?flight_id=${opts.flight}` : URL_;
  return handler(
    new Request(url, {
      method,
      headers: {
        authorization: `Bearer ${user}`,
        "content-type": "application/json",
      },
      body: opts.body === undefined ? undefined : JSON.stringify(opts.body),
    }),
    {
      db,
      verifier: fakeVerifier,
      now: () => opts.now ?? NOW,
      token: opts.token,
    },
  );
}

test(
  db,
  "a follower gets a new link that expires 24 hours after arrival",
  async () => {
    const user = await makeUser(db);
    const id = await flight();
    await follow(user, id);
    const res = await call(user, "POST", { body: { flight_id: id } });
    assertEquals(res.status, 200);
    const body = await res.json();
    assertEquals(body.expires_at, "2026-11-04T20:55:00.000Z");
    const m = /^https:\/\/somalabs\.me\/f\/(.+)$/.exec(body.url);
    assert(m && TOKEN_RE.test(m[1]), body.url);
    // Stored by hash, tied to the flight and the sharer.
    const row = await db.from("flight_shares").select(
      "token_hash, flight_id, user_id, revoked_at",
    )
      .eq("token_hash", await hashToken(m[1])).single();
    assertEquals(row.data, {
      token_hash: await hashToken(m[1]),
      flight_id: id,
      user_id: user,
      revoked_at: null,
    });
    // Each share is a new token.
    const again = await (await call(user, "POST", { body: { flight_id: id } }))
      .json();
    assert(again.url !== body.url);
  },
);

test(db, "a Passport flight can be shared too", async () => {
  const user = await makeUser(db);
  const id = await flight();
  const p = await db.from("past_flights").insert({
    user_id: user,
    flight_id: id,
    date: "2026-11-03",
  });
  if (p.error) throw p.error;
  assertEquals(
    (await call(user, "POST", { body: { flight_id: id } })).status,
    200,
  );
});

test(db, "a flight the caller does not hold answers unknown", async () => {
  const owner = await makeUser(db);
  const stranger = await makeUser(db);
  const id = await flight();
  await follow(owner, id);
  const res = await call(stranger, "POST", { body: { flight_id: id } });
  assertEquals(res.status, 404);
  assertEquals((await res.json()).error.code, "not_found");
  const missing = await call(stranger, "POST", {
    body: { flight_id: crypto.randomUUID() },
  });
  assertEquals(missing.status, 404);
  await missing.body?.cancel();
});

test(db, "a flight down for 24 hours can no longer be shared", async () => {
  const user = await makeUser(db);
  const id = await flight("2026-11-02T07:00:00Z");
  await follow(user, id);
  const res = await call(user, "POST", { body: { flight_id: id } });
  assertEquals(res.status, 409);
  assertEquals((await res.json()).error.code, "out_of_window");
});

test(
  db,
  "status says whether the caller shares the flight, and Stop Sharing revokes every link",
  async () => {
    const user = await makeUser(db);
    const other = await makeUser(db);
    const id = await flight();
    await follow(user, id);
    await follow(other, id);
    assertEquals(await (await call(user, "GET", { flight: id })).json(), {
      active: false,
      expires_at: null,
    });
    await (await call(user, "POST", { body: { flight_id: id } })).body
      ?.cancel();
    await (await call(user, "POST", { body: { flight_id: id } })).body
      ?.cancel();
    await (await call(other, "POST", { body: { flight_id: id } })).body
      ?.cancel();
    assertEquals(await (await call(user, "GET", { flight: id })).json(), {
      active: true,
      expires_at: "2026-11-04T20:55:00.000Z",
    });
    assertEquals(await (await call(user, "DELETE", { flight: id })).json(), {
      revoked: 2,
    });
    assertEquals(await (await call(user, "GET", { flight: id })).json(), {
      active: false,
      expires_at: null,
    });
    // Someone else's share of the same flight is untouched.
    assertEquals(
      (await (await call(other, "GET", { flight: id })).json()).active,
      true,
    );
    // Stopping twice is harmless.
    assertEquals(await (await call(user, "DELETE", { flight: id })).json(), {
      revoked: 0,
    });
  },
);

test(db, "an expired share reads as not sharing", async () => {
  const user = await makeUser(db);
  const id = await flight();
  await follow(user, id);
  await (await call(user, "POST", { body: { flight_id: id } })).body?.cancel();
  const later = new Date("2026-11-04T21:00:00Z");
  assertEquals(
    await (await call(user, "GET", { flight: id, now: later })).json(),
    {
      active: false,
      expires_at: null,
    },
  );
});

test(db, "bad requests and bad tokens are refused", async () => {
  const user = await makeUser(db);
  const bad = await call(user, "POST", { body: { flight_id: "nope" } });
  assertEquals(bad.status, 400);
  await bad.body?.cancel();
  const noId = await call(user, "GET");
  assertEquals(noId.status, 400);
  await noId.body?.cancel();
  const put = await call(user, "PUT");
  assertEquals(put.status, 405);
  await put.body?.cancel();
  const anon = await call("bad", "POST", {
    body: { flight_id: crypto.randomUUID() },
  });
  assertEquals(anon.status, 401);
  await anon.body?.cancel();
});

test(db, "calls are rate limited per user", async () => {
  const user = await makeUser(db);
  const id = await flight();
  for (let i = 0; i < SHARE_MAX_PER_HOUR; i++) {
    await (await call(user, "GET", { flight: id })).body?.cancel();
  }
  const res = await call(user, "GET", { flight: id });
  assertEquals(res.status, 429);
  await res.body?.cancel();
});

// MARK: Contract files: what SupabaseFlightShareService decodes in Swift

const CONTRACT_DIR = new URL("./contract/", import.meta.url);

/** Compares to contract/<name>.json; UPDATE_CONTRACT=1 rewrites it from the handler's answer. */
async function checkContract(name: string, actual: unknown) {
  const url = new URL(`${name}.json`, CONTRACT_DIR);
  const text = JSON.stringify(actual, null, 2) + "\n";
  if (Deno.env.get("UPDATE_CONTRACT") === "1") {
    await Deno.mkdir(CONTRACT_DIR, { recursive: true });
    await Deno.writeTextFile(url, text);
    return;
  }
  assertEquals(
    JSON.parse(await Deno.readTextFile(url)),
    JSON.parse(text),
    `contract/${name}.json is out of date: run with UPDATE_CONTRACT=1`,
  );
}

test(db, "contract examples match the handler's answers", async () => {
  const user = await makeUser(db);
  const id = await flight();
  await follow(user, id);
  const token = () => "C0ntractExampleT0kenC0ntractExampleT0kenABC";
  assert(TOKEN_RE.test(token()));
  await checkContract(
    "created",
    await (await call(user, "POST", { body: { flight_id: id }, token })).json(),
  );
  await checkContract(
    "active",
    await (await call(user, "GET", { flight: id })).json(),
  );
  await checkContract(
    "stopped",
    await (await call(user, "DELETE", { flight: id })).json(),
  );
  await checkContract(
    "inactive",
    await (await call(user, "GET", { flight: id })).json(),
  );
});

test(db, "index.ts starts and answers", async () => {
  const serve = await loadIndexHandler(
    new URL("./index.ts", import.meta.url).href,
  );
  const res = await serve(new Request(URL_, { method: "POST" }));
  assertEquals(res.status, 401);
  await res.body?.cancel();
});
