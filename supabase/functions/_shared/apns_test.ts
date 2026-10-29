import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  decodeJwt,
  decodeProtectedHeader,
  exportPKCS8,
  generateKeyPair,
  jwtVerify,
} from "npm:jose@5";
import {
  alertCopy,
  apnsHost,
  apnsJwt,
  delayMinutes,
  evictApnsJwt,
  isBadDeviceToken,
  isDeadToken,
  mapLimit,
  safeEqual,
  sendApns,
} from "./apns.ts";

const { privateKey, publicKey } = await generateKeyPair("ES256", {
  extractable: true,
});
const P8 = await exportPKCS8(privateKey);

const flight = {
  ident: "AF84",
  status: "scheduled" as const,
  scheduled_out: "2026-11-03T22:30:00Z",
  scheduled_in: "2026-11-04T09:00:00Z",
  estimated_out: null,
  estimated_in: null,
  actual_out: null,
  gate_origin: "K36",
  gate_destination: "B22",
  origin_iata: "CDG",
  origin_icao: "LFPG",
  destination_iata: "SFO",
  destination_icao: "KSFO",
  baggage_belt: null,
};

Deno.test("apnsJwt has ES256 header with kid and iss", async () => {
  const jwt = await apnsJwt("TEAM123456", "KEY1234567", P8, 1_000_000);
  const header = decodeProtectedHeader(jwt);
  assertEquals(header.alg, "ES256");
  assertEquals(header.kid, "KEY1234567");
  const { payload } = await jwtVerify(jwt, publicKey, {
    currentDate: new Date(1_000_000_000),
  });
  assertEquals(payload.iss, "TEAM123456");
  assertEquals(payload.iat, 1_000_000);
});

Deno.test("apnsJwt is cached for 50 minutes, then renewed", async () => {
  const a = await apnsJwt("T", "K", P8, 2_000_000);
  assertEquals(await apnsJwt("T", "K", P8, 2_000_000 + 49 * 60), a);
  const b = await apnsJwt("T", "K", P8, 2_000_000 + 51 * 60);
  assert(b !== a);
});

Deno.test("apnsJwt rejects a bad key", async () => {
  await assertRejects(() => apnsJwt("T2", "K2", "not a key", 1));
});

Deno.test("alertCopy gate_change names the new gate", () => {
  const c = alertCopy("gate_change", flight)!;
  assertEquals(c.title, "AF84 gate change");
  assert(c.body.includes("K36"));
  const arrived = alertCopy("gate_change", {
    ...flight,
    status: "en_route",
    actual_out: "2026-11-03T22:40:00Z",
  })!;
  assert(arrived.body.includes("B22"));
  const moved = alertCopy("gate_change", flight, {
    payload: { changes: { gate_destination: { from: "B20", to: "B24" } } },
  })!;
  assert(moved.body.includes("B24"));
});

Deno.test("alertCopy delay needs 15 minutes", () => {
  const ten = { ...flight, estimated_out: "2026-11-03T22:40:00Z" };
  assertEquals(alertCopy("delay", ten), null);
  const c = alertCopy("delay", {
    ...flight,
    estimated_out: "2026-11-03T23:15:00Z",
  }, {
    originTz: "Europe/Paris",
  })!;
  assertEquals(c.title, "AF84 delayed");
  assert(c.body.includes("12:15 AM"), c.body);
  assert(c.body.includes("45 min"));
  // The event payload wins over the row.
  assertEquals(
    alertCopy("delay", ten, { payload: { delay_minutes: 20 } })!.title,
    "AF84 delayed",
  );
  assertEquals(
    alertCopy("delay", flight, { payload: { delay_minutes: 14 } }),
    null,
  );
  assertEquals(delayMinutes(flight), null);
  assertEquals(alertCopy("delay", flight), null);
});

Deno.test("alertCopy: position gets no alert, others do, no dashes", () => {
  assertEquals(alertCopy("position", flight), null);
  for (const k of ["departure", "arrival", "cancel", "diversion"] as const) {
    const c = alertCopy(k, { ...flight, baggage_belt: "4" })!;
    assert(c.title.startsWith("AF84 "), c.title);
    assert(
      !new RegExp(
        `[${String.fromCharCode(0x2013)}${String.fromCharCode(0x2014)}]`,
      ).test(c.title + c.body),
    );
  }
  assert(
    alertCopy("arrival", { ...flight, baggage_belt: "4" })!.body.includes(
      "belt 4",
    ),
  );
});

Deno.test("sendApns sets the headers and sandbox host", async () => {
  let seen: { url: string; init: RequestInit } | undefined;
  const f = ((url: string, init: RequestInit) => {
    seen = { url, init };
    return Promise.resolve(new Response(null, { status: 200 }));
  }) as unknown as typeof fetch;
  const r = await sendApns("ab12", { aps: {} }, {
    pushType: "liveactivity",
    topic: "me.soma.flight.push-type.liveactivity",
    sandbox: true,
    jwt: "JWT",
    priority: 5,
    expiration: 123,
  }, f);
  assertEquals(r, { ok: true, status: 200 });
  assertEquals(seen!.url, "https://api.sandbox.push.apple.com/3/device/ab12");
  const h = seen!.init.headers as Record<string, string>;
  assertEquals(h["apns-push-type"], "liveactivity");
  assertEquals(h["apns-topic"], "me.soma.flight.push-type.liveactivity");
  assertEquals(h["apns-priority"], "5");
  assertEquals(h["apns-expiration"], "123");
  assertEquals(h.authorization, "bearer JWT");
  assertEquals(apnsHost(false), "api.push.apple.com");
});

Deno.test("sendApns reports reasons and survives network errors", async () => {
  const gone = (() =>
    Promise.resolve(
      Response.json({ reason: "BadDeviceToken" }, { status: 400 }),
    )) as unknown as typeof fetch;
  const o = {
    pushType: "alert" as const,
    topic: "t",
    sandbox: false,
    jwt: "j",
  };
  const r = await sendApns("ab", {}, o, gone);
  assertEquals(r, { ok: false, status: 400, reason: "BadDeviceToken" });
  assert(isBadDeviceToken(r));
  assert(!isDeadToken(r)); // needs a second strike
  assert(isDeadToken({ ok: false, status: 400, reason: "Unregistered" }));
  assert(isDeadToken({ ok: false, status: 410 }));
  assert(
    !isDeadToken({ ok: false, status: 403, reason: "InvalidProviderToken" }),
  );
  const down =
    (() => Promise.reject(new TypeError("boom"))) as unknown as typeof fetch;
  assertEquals((await sendApns("ab", {}, o, down)).status, 0);
});

Deno.test("mapLimit caps concurrency and isolates failures", async () => {
  let live = 0, peak = 0;
  const res = await mapLimit([...Array(25).keys()], 10, async (n) => {
    live++;
    peak = Math.max(peak, live);
    await new Promise((r) => setTimeout(r, 5));
    live--;
    if (n === 3) throw new Error("x");
    return n;
  });
  assertEquals(peak, 10);
  assertEquals(res.filter((r) => r.status === "rejected").length, 1);
  assertEquals(res.filter((r) => r.status === "fulfilled").length, 24);
});

Deno.test("sendApns retries once on 429 and 503 only", async () => {
  const o = {
    pushType: "alert" as const,
    topic: "t",
    sandbox: false,
    jwt: "j",
    retryDelayMs: 0,
  };
  for (const code of [429, 503]) {
    let n = 0;
    const f = (() =>
      Promise.resolve(
        ++n === 1
          ? Response.json({ reason: "ServiceUnavailable" }, { status: code })
          : new Response(null, { status: 200 }),
      )) as unknown as typeof fetch;
    assertEquals((await sendApns("ab", {}, o, f)).ok, true);
    assertEquals(n, 2);
  }
  let n = 0;
  const always = (() => {
    n++;
    return Promise.resolve(
      Response.json({ reason: "InternalServerError" }, { status: 500 }),
    );
  }) as unknown as typeof fetch;
  assertEquals((await sendApns("ab", {}, o, always)).status, 500);
  assertEquals(n, 1);
  n = 0;
  const down = (() => {
    n++;
    return Promise.resolve(Response.json({}, { status: 503 }));
  }) as unknown as typeof fetch;
  assertEquals((await sendApns("ab", {}, o, down)).status, 503);
  assertEquals(n, 2);
});

Deno.test("evictApnsJwt forces a new provider token", async () => {
  const iat = (jwt: string) => decodeJwt(jwt).iat;
  const a = await apnsJwt("TE", "KE", P8, 3_000_000);
  assertEquals(iat(await apnsJwt("TE", "KE", P8, 3_000_600)), iat(a));
  evictApnsJwt("TE", "KE", P8);
  assertEquals(iat(await apnsJwt("TE", "KE", P8, 3_000_600)), 3_000_600);
});

Deno.test("safeEqual compares strings", async () => {
  assert(await safeEqual("abc", "abc"));
  assert(!(await safeEqual("abc", "abd")));
  assert(!(await safeEqual("abc", "abcd")));
});
