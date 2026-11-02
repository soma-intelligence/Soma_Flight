import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  decodeProtectedHeader,
  exportPKCS8,
  generateKeyPair,
  jwtVerify,
} from "npm:jose@5";
import {
  appleClientSecret,
  type AppleConfig,
  appleConfigFromEnv,
  appleRevoker,
} from "./apple.ts";
import { ApiError } from "./errors.ts";

const { privateKey, publicKey } = await generateKeyPair("ES256", {
  extractable: true,
});
const config: AppleConfig = {
  teamId: "TEAM123456",
  keyId: "KEY1234567",
  privateKey: await exportPKCS8(privateKey),
  clientId: "me.somalabs.flight",
};

/** A fetch that answers from `replies` in order and records each request's url and form. */
function fakeFetch(replies: Response[]) {
  const calls: { url: string; form: URLSearchParams }[] = [];
  const f = (input: string | URL | Request, init?: RequestInit) => {
    calls.push({
      url: String(input),
      form: new URLSearchParams(String(init?.body)),
    });
    return Promise.resolve(replies.shift()!);
  };
  return { calls, f: f as typeof fetch };
}

const ok = (body: unknown) =>
  new Response(JSON.stringify(body), { status: 200 });

Deno.test("the client secret is an ES256 JWT Apple accepts", async () => {
  const jwt = await appleClientSecret(config, 1_000_000);
  assertEquals(decodeProtectedHeader(jwt), { alg: "ES256", kid: "KEY1234567" });
  const { payload } = await jwtVerify(jwt, publicKey, {
    currentDate: new Date(1_000_000_000),
  });
  assertEquals(payload.iss, "TEAM123456");
  assertEquals(payload.sub, "me.somalabs.flight");
  assertEquals(payload.aud, "https://appleid.apple.com");
  assertEquals(payload.exp! - payload.iat!, 300);
});

Deno.test("revoke exchanges the code, then revokes the refresh token", async () => {
  const { calls, f } = fakeFetch([
    ok({ refresh_token: "r-1", access_token: "a-1" }),
    new Response("", { status: 200 }),
  ]);
  await appleRevoker(config, f, () => 1_000_000).revoke("code-1");
  assertEquals(calls.map((c) => c.url), [
    "https://appleid.apple.com/auth/token",
    "https://appleid.apple.com/auth/revoke",
  ]);
  assertEquals(calls[0].form.get("grant_type"), "authorization_code");
  assertEquals(calls[0].form.get("code"), "code-1");
  assertEquals(calls[0].form.get("client_id"), "me.somalabs.flight");
  assertEquals(calls[1].form.get("token"), "r-1");
  assertEquals(calls[1].form.get("token_type_hint"), "refresh_token");
});

Deno.test("an expired or reused code is a 400 the app can retry", async () => {
  const { f } = fakeFetch([
    new Response(JSON.stringify({ error: "invalid_grant" }), { status: 400 }),
  ]);
  const e = await assertRejects(
    () => appleRevoker(config, f).revoke("old"),
    ApiError,
  );
  assertEquals([e.code, e.status], ["invalid_request", 400]);
});

Deno.test("a failed revoke is reported, never ignored", async () => {
  const { f } = fakeFetch([
    ok({ access_token: "a-1" }),
    new Response("", { status: 503 }),
  ]);
  const e = await assertRejects(
    () => appleRevoker(config, f).revoke("c"),
    ApiError,
  );
  assertEquals([e.code, e.status], ["provider_unavailable", 502]);
});

Deno.test("config needs the team, key id and key; the client id defaults to the app", () => {
  const env = (vals: Record<string, string>) => (n: string) => vals[n];
  assertEquals(
    appleConfigFromEnv(env({ APPLE_TEAM_ID: "T", APPLE_SIGNIN_KEY_ID: "K" })),
    null,
  );
  const c = appleConfigFromEnv(
    env({
      APPLE_TEAM_ID: "T",
      APPLE_SIGNIN_KEY_ID: "K",
      APPLE_SIGNIN_PRIVATE_KEY: "a\\nb",
    }),
  );
  assertEquals(c, {
    teamId: "T",
    keyId: "K",
    privateKey: "a\nb",
    clientId: "me.somalabs.flight",
  });
});
