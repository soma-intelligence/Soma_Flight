// LinqSender and the webhook helpers against a fake fetch: no network.
import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  LINQ_BASE,
  linqFromEnv,
  LinqSender,
  readInbound,
  verifyWebhook,
  webhookSignature,
} from "./linq.ts";

type Call = { url: string; init: RequestInit };

function fetchOf(...responses: (Response | "throw")[]) {
  const calls: Call[] = [];
  const fn = (url: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(url), init: init ?? {} });
    const r = responses.shift() ?? new Response("{}", { status: 200 });
    return r === "throw"
      ? Promise.reject(new Error("offline"))
      : Promise.resolve(r);
  };
  return { fn: fn as typeof fetch, calls };
}

const noSleep = () => Promise.resolve();
const LINE = "+12055550100";

Deno.test("without a key or a line the sender refuses before any request", async () => {
  const f = fetchOf();
  const s = new LinqSender({ apiKey: "", from: LINE, fetchFn: f.fn });
  assertEquals(s.configured, false);
  assertEquals((await s.send("+14155550100", "hi")).reason, "not_configured");
  assertEquals(
    new LinqSender({ apiKey: "k", from: "", fetchFn: f.fn }).configured,
    false,
  );
  assertEquals(f.calls.length, 0);
  assertEquals(linqFromEnv(() => undefined), undefined);
  assert(
    linqFromEnv((
      n,
    ) => (n === "LINQ_API_KEY"
      ? "k"
      : n === "LINQ_FROM_NUMBER"
      ? LINE
      : undefined)
    ),
  );
});

Deno.test("a send posts one chat request as Linq's docs describe", async () => {
  const f = fetchOf(
    new Response(JSON.stringify({ chat: { id: "c" } }), { status: 201 }),
  );
  const s = new LinqSender({
    apiKey: "secret-key",
    from: LINE,
    fetchFn: f.fn,
    sleep: noSleep,
  });
  const r = await s.send("+14155550100", "Soma Flight: hi.", {
    idempotencyKey: "k1",
  });
  assertEquals(r.ok, true);
  assertEquals(f.calls.length, 1);
  assertEquals(f.calls[0].url, `${LINQ_BASE}/chats`);
  const h = new Headers(f.calls[0].init.headers);
  assertEquals(h.get("authorization"), "Bearer secret-key");
  assertEquals(JSON.parse(f.calls[0].init.body as string), {
    from: LINE,
    to: ["+14155550100"],
    message: {
      parts: [{ type: "text", value: "Soma Flight: hi." }],
      idempotency_key: "k1",
    },
  });
});

Deno.test("a 429 or 5xx is retried once with the same key; a 4xx is not; nothing private is logged", async () => {
  const logs: string[] = [];
  const orig = console.error;
  console.error = (...a: unknown[]) => logs.push(a.join(" "));
  try {
    const busy = fetchOf(
      new Response(
        JSON.stringify({
          error: { status: 429, code: 1007, retry_after: 1 },
          trace_id: "t",
        }),
        { status: 429 },
      ),
      new Response("{}", { status: 200 }),
    );
    const s = new LinqSender({
      apiKey: "k",
      from: LINE,
      fetchFn: busy.fn,
      sleep: noSleep,
    });
    assertEquals(
      (await s.send("+14155550100", "secret words", { idempotencyKey: "same" }))
        .ok,
      true,
    );
    assertEquals(busy.calls.length, 2);
    assertEquals(
      JSON.parse(busy.calls[1].init.body as string).message.idempotency_key,
      "same",
    );

    const bad = fetchOf(
      new Response(JSON.stringify({ error: { status: 400, code: 1001 } }), {
        status: 400,
      }),
    );
    const r = await new LinqSender({
      apiKey: "k",
      from: LINE,
      fetchFn: bad.fn,
      sleep: noSleep,
    })
      .send("+14155550100", "secret words");
    assertEquals(r, { ok: false, status: 400, reason: "1001" });
    assertEquals(bad.calls.length, 1);

    const down = fetchOf("throw", "throw");
    assertEquals(
      (await new LinqSender({
        apiKey: "k",
        from: LINE,
        fetchFn: down.fn,
        sleep: noSleep,
      })
        .send("+14155550100", "secret words")).reason,
      "network",
    );
    assertEquals(down.calls.length, 2);
  } finally {
    console.error = orig;
  }
  assert(logs.length > 0);
  for (const l of logs) {
    assert(
      !l.includes("4155550100") && !l.includes("secret words"),
      "logs carry no number or text",
    );
  }
});

Deno.test("webhook signatures follow Standard Webhooks", async () => {
  const secret = `whsec_${btoa("signing")}`;
  const now = new Date("2026-11-03T18:00:00Z");
  const ts = String(now.getTime() / 1000);
  const body = '{"event_type":"message.received"}';
  const sig = await webhookSignature(secret, "id1", ts, body);
  const h = (s: string, t = ts) =>
    new Headers({
      "webhook-id": "id1",
      "webhook-timestamp": t,
      "webhook-signature": s,
    });
  assert(await verifyWebhook(h(`v1,${sig}`), body, secret, now));
  assert(
    await verifyWebhook(h(`v1,bogus v1,${sig}`), body, secret, now),
    "any listed signature may match",
  );
  assert(!(await verifyWebhook(h(`v1,${sig}`), body + " ", secret, now)));
  assert(
    !(await verifyWebhook(
      h(`v1,${sig}`, String(Number(ts) - 301)),
      body,
      secret,
      now,
    )),
  );
  assert(!(await verifyWebhook(h(`v1,${sig}`), body, undefined, now)));
});

Deno.test("only inbound received messages are read", () => {
  assertEquals(
    readInbound({
      event_type: "message.received",
      event_id: "e1",
      data: {
        direction: "inbound",
        sender_handle: { handle: "+14155550100", is_me: false },
        parts: [{ type: "text", value: "STOP" }, { type: "media", url: "x" }],
      },
    }),
    { eventId: "e1", from: "+14155550100", text: "STOP" },
  );
  assertEquals(
    readInbound({ event_type: "message.sent", event_id: "e2", data: {} }),
    null,
  );
  assertEquals(
    readInbound({
      event_type: "message.received",
      event_id: "e3",
      data: { sender_handle: { handle: "+1", is_me: true } },
    }),
    null,
  );
});
