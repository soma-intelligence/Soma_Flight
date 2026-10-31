// The friends function on a stand-in database: the SQL functions it calls answer from a script, so these
// run without the local stack. The SQL itself (RLS, pairs, single use, codes) is covered by
// supabase/tests/friends_test.sql. The answers in contract/ are checked here and decoded by FriendsTests in
// FlightKit, so the two sides cannot drift apart.
import { assert, assertEquals } from "jsr:@std/assert@1";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { TokenVerifier } from "../_shared/auth.ts";
import { hashToken, TOKEN_RE } from "../_shared/share.ts";
import {
  CODE_TRIES_PER_HOUR,
  FRIENDS_MAX_PER_HOUR,
  handler,
  inviteUrl,
  normalizeCode,
  tokenOf,
} from "./handler.ts";

const USER = "0a0a0a0a-0000-4000-8000-00000000000a";
const FRIEND = "0b0b0b0b-0000-4000-8000-00000000000b";
const INVITATION = "1c1c1c1c-0000-4000-8000-00000000001c";
const TOKEN = "C0ntractExampleT0kenC0ntractExampleT0kenABC";

const verifier: TokenVerifier = {
  auth: {
    getUser: (jwt: string) =>
      Promise.resolve(
        jwt === "good"
          ? { data: { user: { id: USER } }, error: null }
          : { data: { user: null }, error: new Error("bad") },
      ),
  },
};

type Call = { fn: string; args: Record<string, unknown> };
type Answer = { data?: unknown; error?: { message: string } };

/** A database whose rpc answers come from `answers` (by function name); check_rate passes unless told. */
function fakeDb(
  answers: Record<string, Answer | ((args: Record<string, unknown>) => Answer)>,
  rate: Record<string, boolean> = {},
) {
  const calls: Call[] = [];
  const db = {
    rpc(fn: string, args: Record<string, unknown>) {
      calls.push({ fn, args });
      if (fn === "check_rate") {
        return Promise.resolve({
          data: rate[args.p_endpoint as string] ?? true,
          error: null,
        });
      }
      const a = answers[fn];
      const r = typeof a === "function" ? a(args) : a;
      if (!r) {
        return Promise.resolve({
          data: null,
          error: { message: `no answer for ${fn}` },
        });
      }
      return Promise.resolve({ data: r.data ?? null, error: r.error ?? null });
    },
  };
  return { db: db as unknown as SupabaseClient, calls };
}

function post(body: unknown, auth = "good", method = "POST") {
  return new Request("http://localhost/friends", {
    method,
    headers: {
      authorization: `Bearer ${auth}`,
      "content-type": "application/json",
    },
    body: method === "GET"
      ? undefined
      : typeof body === "string"
      ? body
      : JSON.stringify(body),
  });
}

async function contract(name: string): Promise<unknown> {
  return JSON.parse(
    await Deno.readTextFile(
      new URL(`./contract/${name}.json`, import.meta.url),
    ),
  );
}

Deno.test("invite makes a link, sends only the hash and answers the contract", async () => {
  const { db, calls } = fakeDb({
    friend_invite_create: {
      data: [{ id: INVITATION, expires_at: "2026-11-10T08:00:00+00:00" }],
    },
  });
  const res = await handler(post({ action: "invite" }), {
    db,
    verifier,
    token: () => TOKEN,
  });
  assertEquals(res.status, 200);
  assertEquals(await res.json(), await contract("invite"));
  const create = calls.find((c) => c.fn === "friend_invite_create")!;
  assertEquals(create.args, {
    p_user: USER,
    p_token_hash: await hashToken(TOKEN),
    p_ttl_hours: 168,
  });
  assert(
    !JSON.stringify(calls).includes(TOKEN),
    "the token itself never reaches the database",
  );
});

Deno.test("each invite is a new random token", async () => {
  const { db } = fakeDb({
    friend_invite_create: {
      data: [{ id: INVITATION, expires_at: "2026-11-10T08:00:00Z" }],
    },
  });
  const a = await (await handler(post({ action: "invite" }), { db, verifier }))
    .json();
  const b = await (await handler(post({ action: "invite" }), { db, verifier }))
    .json();
  assert(a.url !== b.url);
  assert(TOKEN_RE.test(a.url.replace("https://somalabs.me/i/", "")));
});

Deno.test("preview reads the link (bare token or whole URL) and answers the contract", async () => {
  const { db, calls } = fakeDb({
    friend_invite_preview: {
      data: [{ display_name: "Ada", emoji: "🌿", state: "open" }],
    },
  });
  const res = await handler(
    post({ action: "preview", token: `https://somalabs.me/i/${TOKEN}` }),
    { db, verifier },
  );
  assertEquals(await res.json(), await contract("preview"));
  assertEquals(calls.at(-1)!.args.p_token_hash, await hashToken(TOKEN));
  const missing = fakeDb({ friend_invite_preview: { data: [] } });
  const gone = await handler(post({ action: "preview", token: TOKEN }), {
    db: missing.db,
    verifier,
  });
  assertEquals(gone.status, 404);
  assertEquals((await gone.json()).error.code, "not_found");
});

Deno.test("accept and decline answer with the friend or nothing", async () => {
  const { db, calls } = fakeDb({
    friend_invite_respond: (a) => ({ data: a.p_accept ? FRIEND : null }),
  });
  const yes = await handler(post({ action: "accept", token: TOKEN }), {
    db,
    verifier,
  });
  assertEquals(await yes.json(), await contract("accepted"));
  const no = await handler(post({ action: "decline", token: TOKEN }), {
    db,
    verifier,
  });
  assertEquals(await no.json(), { friend_id: null });
  assertEquals(
    calls.filter((c) => c.fn === "friend_invite_respond").map((c) =>
      c.args.p_accept
    ),
    [true, false],
  );
});

Deno.test("the SQL refusals become the app's error codes", async () => {
  const cases: [string, number, string][] = [
    ["invite_closed", 409, "out_of_window"],
    ["invite_not_found", 404, "not_found"],
    ["friend_self", 400, "invalid_request"],
    ["friend_limit", 403, "plan_limit"],
  ];
  for (const [message, status, code] of cases) {
    const { db } = fakeDb({ friend_invite_respond: { error: { message } } });
    const res = await handler(post({ action: "accept", token: TOKEN }), {
      db,
      verifier,
    });
    assertEquals(res.status, status, message);
    assertEquals((await res.json()).error.code, code);
  }
  const { db } = fakeDb({
    friend_invite_respond: { error: { message: "connection reset" } },
  });
  const res = await handler(post({ action: "accept", token: TOKEN }), {
    db,
    verifier,
  });
  assertEquals(res.status, 500);
  await res.body?.cancel();
});

Deno.test("a code request normalises the code and has its own tighter limit", async () => {
  const { db, calls } = fakeDb({ friend_request_by_code: { data: "sent" } });
  const res = await handler(post({ action: "request", code: " k7m2-x9qp " }), {
    db,
    verifier,
  });
  assertEquals(await res.json(), await contract("requested"));
  assertEquals(calls.find((c) => c.fn === "friend_request_by_code")!.args, {
    p_user: USER,
    p_code: "K7M2X9QP",
  });
  const rates = calls.filter((c) => c.fn === "check_rate").map((
    c,
  ) => [c.args.p_endpoint, c.args.p_max]);
  assertEquals(rates, [["friends", FRIENDS_MAX_PER_HOUR], [
    "friends-code",
    CODE_TRIES_PER_HOUR,
  ]]);

  const limited = fakeDb({ friend_request_by_code: { data: "sent" } }, {
    "friends-code": false,
  });
  const slow = await handler(post({ action: "request", code: "K7M2X9QP" }), {
    db: limited.db,
    verifier,
  });
  assertEquals(slow.status, 429);
  await slow.body?.cancel();
  assert(
    !limited.calls.some((c) => c.fn === "friend_request_by_code"),
    "a limited caller reaches no code",
  );

  const unknown = fakeDb({
    friend_request_by_code: { error: { message: "code_not_found" } },
  });
  const nf = await handler(post({ action: "request", code: "K7M2X9QP" }), {
    db: unknown.db,
    verifier,
  });
  assertEquals(nf.status, 404);
  await nf.body?.cancel();
});

Deno.test("respond, revoke and reset_code answer the contract", async () => {
  const { db } = fakeDb({
    friend_request_respond: { data: true },
    friend_invite_revoke: { data: true },
    friend_code_reset: { data: "K7M2X9QP" },
  });
  const r = await handler(
    post({ action: "respond", invitation_id: INVITATION, accept: true }),
    { db, verifier },
  );
  assertEquals(await r.json(), { answered: true });
  const v = await handler(
    post({ action: "revoke", invitation_id: INVITATION }),
    { db, verifier },
  );
  assertEquals(await v.json(), { revoked: true });
  const c = await handler(post({ action: "reset_code" }), { db, verifier });
  assertEquals(await c.json(), await contract("code"));
});

Deno.test("bad input is refused before the database", async () => {
  const bodies: unknown[] = [
    { action: "explode" },
    { action: "accept", token: "short" },
    { action: "request", code: "ILLEGAL1" },
    { action: "request", code: 12345678 },
    { action: "respond", invitation_id: "nope", accept: true },
    { action: "respond", invitation_id: INVITATION, accept: "yes" },
    { action: "revoke" },
    [],
    "not json",
  ];
  for (const body of bodies) {
    const { db, calls } = fakeDb({});
    const res = await handler(post(body), { db, verifier });
    assertEquals(res.status, 400, JSON.stringify(body));
    await res.body?.cancel();
    assert(calls.every((c) => c.fn === "check_rate"), JSON.stringify(body));
  }
});

Deno.test("signed out, wrong method and the overall limit", async () => {
  const { db, calls } = fakeDb({});
  const anon = await handler(post({ action: "invite" }, "bad"), {
    db,
    verifier,
  });
  assertEquals(anon.status, 401);
  await anon.body?.cancel();
  const get = await handler(post(null, "good", "GET"), { db, verifier });
  assertEquals(get.status, 405);
  await get.body?.cancel();
  assertEquals(calls.length, 0);
  const limited = fakeDb({}, { friends: false });
  const res = await handler(post({ action: "invite" }), {
    db: limited.db,
    verifier,
  });
  assertEquals(res.status, 429);
  await res.body?.cancel();
});

Deno.test("helpers: links, codes and tokens", () => {
  assertEquals(inviteUrl("abc"), "https://somalabs.me/i/abc");
  assertEquals(
    inviteUrl("abc", "https://example.test/x"),
    "https://example.test/x/abc",
  );
  assertEquals(
    inviteUrl("abc", "http://evil.test/"),
    "https://somalabs.me/i/abc",
  );
  assertEquals(normalizeCode("abcd efgh"), "ABCDEFGH");
  assertEquals(normalizeCode("ABCDEFGHI"), null);
  assertEquals(normalizeCode("ABCDEFGU"), null);
  assertEquals(tokenOf(`somaflight://i/${TOKEN}`), TOKEN);
  assertEquals(tokenOf(TOKEN), TOKEN);
  assertEquals(tokenOf("https://somalabs.me/i/"), null);
});
