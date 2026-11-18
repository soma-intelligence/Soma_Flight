import { assertEquals } from "jsr:@std/assert@1";
import { isServiceCaller } from "./auth.ts";

function jwt(role: string): string {
  const enc = (o: unknown) =>
    btoa(JSON.stringify(o)).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
  return `${enc({ alg: "HS256", typ: "JWT" })}.${enc({ role })}.sig`;
}

function req(bearer?: string): Request {
  return new Request("https://x/functions/v1/maintenance", {
    method: "POST",
    headers: bearer ? { authorization: `Bearer ${bearer}` } : {},
  });
}

Deno.test("isServiceCaller: the runtime key passes", async () => {
  assertEquals(await isServiceCaller(req("sb_secret_abc"), "sb_secret_abc"), true);
  assertEquals(await isServiceCaller(req("sb_secret_xyz"), "sb_secret_abc"), false);
  assertEquals(await isServiceCaller(req(), "sb_secret_abc"), false);
});

Deno.test("isServiceCaller: pg_cron's legacy service_role JWT passes through SERVICE_ROLE_JWT", async () => {
  const legacy = jwt("service_role");
  Deno.env.delete("SERVICE_ROLE_JWT");
  assertEquals(await isServiceCaller(req(legacy), "sb_secret_abc"), false, "unknown without the secret");
  Deno.env.set("SERVICE_ROLE_JWT", legacy);
  try {
    assertEquals(await isServiceCaller(req(legacy), "sb_secret_abc"), true);
    assertEquals(await isServiceCaller(req("sb_secret_abc"), "sb_secret_abc"), true, "the runtime key still passes");
  } finally {
    Deno.env.delete("SERVICE_ROLE_JWT");
  }
});

Deno.test("isServiceCaller: a matching JWT still needs the service_role claim", async () => {
  const anon = jwt("anon");
  Deno.env.set("SERVICE_ROLE_JWT", anon);
  try {
    assertEquals(await isServiceCaller(req(anon), undefined), false);
  } finally {
    Deno.env.delete("SERVICE_ROLE_JWT");
  }
});
