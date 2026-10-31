// sms-inbound over the in-memory database, with signed requests as Linq sends them.
import { assertEquals } from "jsr:@std/assert@1";
import { handler, keywordOf, STOP_REPLY } from "./handler.ts";
import { fakeDb } from "../_shared/sms_test_db.ts";
import { webhookSignature } from "../_shared/linq.ts";
import type { SmsSender } from "../_shared/sms_alerts.ts";

const SECRET = `whsec_${btoa("a test signing secret")}`;
const NOW = new Date("2026-11-03T18:00:00Z");
const TS = String(NOW.getTime() / 1000);

function received(
  text: string,
  from = "+14155550100",
  id = crypto.randomUUID(),
) {
  return {
    api_version: "v3",
    webhook_version: "2026-02-03",
    event_type: "message.received",
    event_id: id,
    data: {
      direction: "inbound",
      sender_handle: { handle: from, is_me: false, service: "iMessage" },
      parts: [{ type: "text", value: text }],
      service: "iMessage",
    },
  };
}

async function signed(
  payload: unknown,
  opts: { ts?: string; secret?: string } = {},
) {
  const body = JSON.stringify(payload);
  const ts = opts.ts ?? TS;
  const sig = await webhookSignature(opts.secret ?? SECRET, "msg_1", ts, body);
  return new Request("http://localhost/sms-inbound", {
    method: "POST",
    headers: {
      "webhook-id": "msg_1",
      "webhook-timestamp": ts,
      "webhook-signature": `v1,${sig}`,
    },
    body,
  });
}

function setup() {
  const f = fakeDb({
    sms_alerts: [{
      user_id: "u1",
      phone_e164: "+14155550100",
      verified_at: "2026-11-01T00:00:00Z",
      enabled: true,
      in_flight: true,
      opted_out_at: null,
    }],
  });
  const sent: { to: string; text: string }[] = [];
  const sender: SmsSender = {
    send(to, text) {
      sent.push({ to, text });
      return Promise.resolve({ ok: true });
    },
  };
  const run = async (req: Request) => {
    const res = await handler(req, {
      db: f.client,
      sender,
      secret: () => SECRET,
      enabled: () => true,
      now: () => NOW,
    });
    return { status: res.status, body: await res.json() };
  };
  return { f, sent, run, row: () => f.tables.get("sms_alerts")![0] };
}

Deno.test("keywords read as carriers read them", () => {
  assertEquals(keywordOf(" stop "), "stop");
  assertEquals(keywordOf("Unsubscribe."), "stop");
  assertEquals(keywordOf("HELP"), "help");
  assertEquals(keywordOf("start"), "start");
  assertEquals(keywordOf("stop texting me about AF 84"), null);
  assertEquals(keywordOf("is my flight late?"), null);
});

Deno.test("an unsigned, wrongly signed or old request is refused", async () => {
  const { run, row } = setup();
  const plain = new Request("http://localhost/sms-inbound", {
    method: "POST",
    body: JSON.stringify(received("STOP")),
  });
  assertEquals((await run(plain)).status, 401);
  assertEquals(
    (await run(
      await signed(received("STOP"), { secret: `whsec_${btoa("other")}` }),
    )).status,
    401,
  );
  assertEquals(
    (await run(
      await signed(received("STOP"), {
        ts: String(NOW.getTime() / 1000 - 600),
      }),
    )).status,
    401,
  );
  assertEquals(row().enabled, true);
});

Deno.test("STOP switches both modes off, records it and replies once", async () => {
  const { run, row, sent } = setup();
  const payload = received("Stop");
  const r = await run(await signed(payload));
  assertEquals(r.body.keyword, "stop");
  assertEquals(row().enabled, false);
  assertEquals(row().in_flight, false);
  assertEquals(row().opted_out_at, NOW.toISOString());
  assertEquals(sent, [{ to: "+14155550100", text: STOP_REPLY }]);
  // Linq delivers at least once: the same event again changes nothing and sends nothing.
  const again = await run(await signed(payload));
  assertEquals(again.body.duplicate, true);
  assertEquals(sent.length, 1);
});

Deno.test("HELP answers with the support link; other words and other numbers are left alone", async () => {
  const { run, sent, row } = setup();
  await run(await signed(received("help")));
  assertEquals(sent.length, 1);
  assertEquals(sent[0].text.includes("somalabs.me/support"), true);
  const chat = await run(await signed(received("is my flight on time?")));
  assertEquals(chat.body.ignored, "not_a_keyword");
  const stranger = await run(await signed(received("STOP", "+14155550199")));
  assertEquals(stranger.body.ignored, "unknown_number");
  const other = await run(
    await signed({ event_type: "message.delivered", event_id: "e", data: {} }),
  );
  assertEquals(other.body.ignored, "event");
  assertEquals(sent.length, 1);
  assertEquals(row().enabled, true);
});

Deno.test("the 2025-01-01 payload shape is read too", async () => {
  const { run, row } = setup();
  const old = {
    event_type: "message.received",
    event_id: "old-1",
    webhook_version: "2025-01-01",
    data: {
      chat_id: "c",
      from: "+14155550100",
      message: { parts: [{ type: "text", value: "QUIT" }] },
    },
  };
  assertEquals((await run(await signed(old))).body.keyword, "stop");
  assertEquals(row().enabled, false);
});
