import { assertEquals } from "jsr:@std/assert@1";
import { webOrigins, withCors } from "./cors.ts";

const ORIGINS = ["https://flight.somalabs.me", "http://localhost:5173"];

function req(method: string, origin?: string): Request {
  return new Request("http://localhost/fn", {
    method,
    headers: origin ? { origin } : {},
  });
}

function spy() {
  let calls = 0;
  const handler = () => {
    calls++;
    return new Response(JSON.stringify({ ok: true }), {
      status: 201,
      headers: { "content-type": "application/json" },
    });
  };
  return { handler, calls: () => calls };
}

Deno.test("OPTIONS from an allowed origin answers 204", async () => {
  const s = spy();
  const res = await withCors(s.handler, ORIGINS)(
    req("OPTIONS", "http://localhost:5173"),
  );
  assertEquals(res.status, 204);
  assertEquals(
    res.headers.get("access-control-allow-origin"),
    "http://localhost:5173",
  );
  assertEquals(
    res.headers.get("access-control-allow-headers"),
    "authorization, x-client-info, apikey, content-type",
  );
  assertEquals(
    res.headers.get("access-control-allow-methods"),
    "GET, POST, DELETE, OPTIONS",
  );
  assertEquals(res.headers.get("access-control-max-age"), "600");
  assertEquals(res.headers.get("vary"), "Origin");
  assertEquals(s.calls(), 0);
});

Deno.test("a POST from an allowed origin keeps the handler's status and body and adds Allow-Origin", async () => {
  const s = spy();
  const res = await withCors(s.handler, ORIGINS)(
    req("POST", "https://flight.somalabs.me"),
  );
  assertEquals(res.status, 201);
  assertEquals(await res.json(), { ok: true });
  assertEquals(
    res.headers.get("access-control-allow-origin"),
    "https://flight.somalabs.me",
  );
  assertEquals(res.headers.get("content-type"), "application/json");
  assertEquals(s.calls(), 1);
});

Deno.test("an origin not in the list gets no Allow-Origin header", async () => {
  const s = spy();
  const res = await withCors(s.handler, ORIGINS)(
    req("POST", "https://evil.example"),
  );
  assertEquals(res.status, 201);
  assertEquals(await res.json(), { ok: true });
  assertEquals(res.headers.get("access-control-allow-origin"), null);
});

Deno.test("a request with no Origin (the apps) is passed through untouched", async () => {
  const s = spy();
  const res = await withCors(s.handler, ORIGINS)(req("POST"));
  assertEquals(res.status, 201);
  assertEquals(await res.json(), { ok: true });
  assertEquals(res.headers.get("access-control-allow-origin"), null);
  assertEquals(res.headers.get("vary"), null);
});

Deno.test("webOrigins() defaults and splits WEB_ORIGINS on commas", () => {
  const prev = Deno.env.get("WEB_ORIGINS");
  try {
    Deno.env.delete("WEB_ORIGINS");
    assertEquals(webOrigins(), [
      "https://flight.somalabs.me",
      "http://localhost:5173",
    ]);
    Deno.env.set("WEB_ORIGINS", "https://a.example , http://b.example:3000");
    assertEquals(webOrigins(), ["https://a.example", "http://b.example:3000"]);
  } finally {
    if (prev === undefined) Deno.env.delete("WEB_ORIGINS");
    else Deno.env.set("WEB_ORIGINS", prev);
  }
});
