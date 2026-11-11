import { assert, assertEquals } from "jsr:@std/assert@1";
import { jwtVerify } from "npm:jose@5";
import type { TokenVerifier } from "../_shared/auth.ts";
import { ApiError } from "../_shared/errors.ts";
import { handler } from "./handler.ts";

const NOW = new Date("2026-11-11T12:00:00Z");
const pair = await crypto.subtle.generateKey(
  { name: "ECDSA", namedCurve: "P-256" },
  true,
  ["sign", "verify"],
);
const pkcs8 = new Uint8Array(
  await crypto.subtle.exportKey("pkcs8", pair.privateKey),
);
const pem = `-----BEGIN PRIVATE KEY-----\n${
  btoa(String.fromCharCode(...pkcs8))
}\n-----END PRIVATE KEY-----`;
const secrets = { keyId: "KEY123", teamId: "TEAM456", privateKey: pem };

const verify: TokenVerifier = {
  auth: {
    getUser: (jwt) =>
      Promise.resolve(
        jwt === "good"
          ? { data: { user: { id: "user-1" } }, error: null }
          : { data: { user: null }, error: { message: "bad" } },
      ),
  },
};

function get(token: string | null, origin?: string): Request {
  const headers: Record<string, string> = {};
  if (token) headers.authorization = `Bearer ${token}`;
  if (origin) headers.origin = origin;
  return new Request("http://localhost/mapkit-token", { headers });
}

function deps(over: Partial<Parameters<typeof handler>[1]> = {}) {
  const rateCalls: unknown[][] = [];
  return {
    rateCalls,
    d: {
      verify,
      rate: (...a: unknown[]) => {
        rateCalls.push(a);
        return Promise.resolve();
      },
      now: () => NOW,
      secrets,
      ...over,
    } as Parameters<typeof handler>[1],
  };
}

Deno.test("no JWT answers 401 unauthorized", async () => {
  const res = await handler(get(null), deps().d);
  assertEquals(res.status, 401);
  assertEquals((await res.json()).error.code, "unauthorized");
});

Deno.test("missing secrets answer 503 provider_unavailable with no token", async () => {
  const res = await handler(get("good"), deps({ secrets: null }).d);
  assertEquals(res.status, 503);
  const body = await res.json();
  assertEquals(body.error.code, "provider_unavailable");
  assertEquals(body.token, undefined);
});

Deno.test("a signed-in GET returns an ES256 JWT", async () => {
  const { d, rateCalls } = deps();
  const res = await handler(get("good", "http://localhost:5173"), d);
  assertEquals(res.status, 200);
  const { token, expiresAt } = await res.json();
  const [h] = token.split(".");
  const header = JSON.parse(atob(h.replace(/-/g, "+").replace(/_/g, "/")));
  assertEquals(header, { alg: "ES256", kid: "KEY123", typ: "JWT" });
  const { payload } = await jwtVerify(token, pair.publicKey, {
    currentDate: NOW,
  });
  assertEquals(payload.iss, "TEAM456");
  assertEquals(payload.iat, Math.floor(NOW.getTime() / 1000));
  assertEquals(payload.exp, Math.floor(NOW.getTime() / 1000) + 1800);
  assertEquals(payload.origin, "http://localhost:5173");
  assertEquals(expiresAt, new Date(NOW.getTime() + 1800_000).toISOString());
  assertEquals(rateCalls[0].slice(0, 4), ["user-1", "mapkit-token", 30, 60]);
});

Deno.test("an Origin outside webOrigins() answers 400 invalid_request", async () => {
  const res = await handler(get("good", "https://evil.example"), deps().d);
  assertEquals(res.status, 400);
  const body = await res.json();
  assertEquals(body.error.code, "invalid_request");
  assertEquals(body.token, undefined);
});

Deno.test("a rate_limited ApiError from rate answers 429", async () => {
  const res = await handler(
    get("good"),
    deps({
      rate: () => Promise.reject(new ApiError("rate_limited", 429, "Too many")),
    }).d,
  );
  assertEquals(res.status, 429);
  assert((await res.json()).error.code === "rate_limited");
});
