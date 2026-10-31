// The Linq client for texts (iMessage, then RCS, then SMS, picked by Linq per recipient), written against
// Linq's public Partner API v3 docs (docs.linqapp.com, read 2026-10-31):
// - send: POST {base}/chats with `from` (our line), `to` [number] and `message.parts` [{type: "text"}].
//   Linq keys a chat on the line and the recipients, so the same request reuses the existing chat. The
//   `message.idempotency_key` stops a retry from sending twice. Errors come as { error: { status, code,
//   message, retry_after? }, trace_id }.
// - inbound: webhooks signed the Standard Webhooks way: HMAC-SHA256 over "{webhook-id}.{webhook-timestamp}.
//   {body}" with the base64 secret after "whsec_", base64 in `webhook-signature` as "v1,<sig>" (several may
//   be listed, space separated), refused past 5 minutes. Delivery is at least once: dedupe on `event_id`.
//   `message.received` carries the sender in data.sender_handle.handle (webhook version 2026-02-03) or
//   data.from (2025-01-01), the words in data.parts (or data.message.parts).
//
// Secrets: LINQ_API_KEY (bearer token, issued by a Linq representative), LINQ_FROM_NUMBER (the line, E.164),
// LINQ_WEBHOOK_SECRET (the subscription's signing secret). Without the key the sender refuses to send.
// Logs carry the HTTP status, Linq's error code and trace id, never the number or the words.
import type { SmsSender } from "./sms_alerts.ts";
import { safeEqual } from "./apns.ts";

export const LINQ_BASE = "https://api.linqapp.com/api/partner/v3";
/** How long a webhook timestamp stays acceptable (Linq's own advice: 5 minutes). */
export const WEBHOOK_TOLERANCE_S = 5 * 60;
/** Longest wait before the one retry, whatever `retry_after` asks. */
const MAX_RETRY_WAIT_MS = 2000;

export interface LinqOptions {
  apiKey?: string;
  from?: string;
  baseUrl?: string;
  fetchFn?: typeof fetch;
  /** Waits before the retry; tests pass a no-op. */
  sleep?: (ms: number) => Promise<void>;
}

export type LinqResult = { ok: boolean; status: number; reason?: string };

/** `SmsSender` over Linq. Retries once on a 429, a 5xx or a network failure, with the same idempotency key. */
export class LinqSender implements SmsSender {
  readonly #key: string;
  readonly #from: string;
  readonly #base: string;
  readonly #fetch: typeof fetch;
  readonly #sleep: (ms: number) => Promise<void>;

  constructor(opts: LinqOptions = {}) {
    this.#key = opts.apiKey ?? "";
    this.#from = opts.from ?? "";
    this.#base = opts.baseUrl ?? LINQ_BASE;
    this.#fetch = opts.fetchFn ?? fetch;
    this.#sleep = opts.sleep ??
      ((ms) => new Promise((r) => setTimeout(r, ms)));
  }

  /** False without a key or a line: `send` then refuses before any request. */
  get configured(): boolean {
    return this.#key !== "" && /^\+[1-9][0-9]{7,14}$/.test(this.#from);
  }

  async send(
    to: string,
    text: string,
    opts: { idempotencyKey?: string } = {},
  ): Promise<LinqResult> {
    if (!this.configured) {
      console.error(
        "linq: refused, LINQ_API_KEY or LINQ_FROM_NUMBER is not set",
      );
      return { ok: false, status: 0, reason: "not_configured" };
    }
    if (!/^\+[1-9][0-9]{7,14}$/.test(to) || text === "") {
      return { ok: false, status: 0, reason: "invalid_request" };
    }
    const body = JSON.stringify({
      from: this.#from,
      to: [to],
      message: {
        parts: [{ type: "text", value: text }],
        idempotency_key: opts.idempotencyKey ?? crypto.randomUUID(),
      },
    });
    let last: LinqResult = { ok: false, status: 0 };
    for (let attempt = 0; attempt < 2; attempt++) {
      let res: Response;
      try {
        res = await this.#fetch(`${this.#base}/chats`, {
          method: "POST",
          headers: {
            authorization: `Bearer ${this.#key}`,
            "content-type": "application/json",
          },
          body,
        });
      } catch {
        last = { ok: false, status: 0, reason: "network" };
        console.error(
          `linq: send failed attempt=${attempt + 1} reason=network`,
        );
        if (attempt === 0) await this.#sleep(500);
        continue;
      }
      if (res.ok) {
        await res.body?.cancel();
        return { ok: true, status: res.status };
      }
      const err = await readError(res);
      last = { ok: false, status: res.status, reason: err.code };
      console.error(
        `linq: send failed attempt=${
          attempt + 1
        } status=${res.status} code=${err.code} trace=${err.trace}`,
      );
      const retryable = res.status === 429 || res.status >= 500;
      if (!retryable || attempt === 1) break;
      await this.#sleep(
        Math.min(MAX_RETRY_WAIT_MS, (err.retryAfter ?? 0.5) * 1000),
      );
    }
    return last;
  }
}

async function readError(
  res: Response,
): Promise<{ code: string; trace: string; retryAfter?: number }> {
  try {
    const j = await res.json();
    const e = j?.error ?? {};
    return {
      code: String(e.code ?? "unknown"),
      trace: String(j?.trace_id ?? "none"),
      retryAfter: typeof e.retry_after === "number" ? e.retry_after : undefined,
    };
  } catch {
    return { code: "unreadable", trace: "none" };
  }
}

/** The sender from the secrets, or undefined when the key is missing (the hook then sends nothing). */
export function linqFromEnv(
  get: (name: string) => string | undefined = (n) => Deno.env.get(n),
): LinqSender | undefined {
  const s = new LinqSender({
    apiKey: get("LINQ_API_KEY") ?? "",
    from: get("LINQ_FROM_NUMBER") ?? "",
  });
  return s.configured ? s : undefined;
}

// MARK: Webhooks

const b64 = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes));

function fromB64(s: string): Uint8Array<ArrayBuffer> | null {
  try {
    return Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
  } catch {
    return null;
  }
}

/** The Standard Webhooks signature of `body` for `secret` ("whsec_..." or bare base64). */
export async function webhookSignature(
  secret: string,
  id: string,
  timestamp: string,
  body: string,
): Promise<string | null> {
  const raw = fromB64(secret.replace(/^whsec_/, ""));
  if (!raw || raw.length === 0) return null;
  const key = await crypto.subtle.importKey(
    "raw",
    raw,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(`${id}.${timestamp}.${body}`),
  );
  return b64(new Uint8Array(mac));
}

/**
 * Whether a webhook request is Linq's: its three headers present, its timestamp within
 * WEBHOOK_TOLERANCE_S of `now`, and one of its v1 signatures equal (constant time) to ours.
 */
export async function verifyWebhook(
  headers: Headers,
  body: string,
  secret: string | undefined,
  now: Date,
): Promise<boolean> {
  if (!secret) return false;
  const id = headers.get("webhook-id");
  const ts = headers.get("webhook-timestamp");
  const sigs = headers.get("webhook-signature");
  if (!id || !ts || !sigs || !/^[0-9]{1,12}$/.test(ts)) return false;
  if (Math.abs(now.getTime() / 1000 - Number(ts)) > WEBHOOK_TOLERANCE_S) {
    return false;
  }
  const want = await webhookSignature(secret, id, ts, body);
  if (!want) return false;
  for (const s of sigs.split(" ")) {
    const [v, sig] = s.split(",", 2);
    if (v === "v1" && sig && await safeEqual(sig, want)) return true;
  }
  return false;
}

export interface InboundText {
  eventId: string;
  from: string;
  text: string;
}

/** A `message.received` event's sender and words; null for every other event or an unreadable one. */
export function readInbound(payload: unknown): InboundText | null {
  if (!payload || typeof payload !== "object") return null;
  const p = payload as Record<string, unknown>;
  if (p.event_type !== "message.received" || typeof p.event_id !== "string") {
    return null;
  }
  const d = (p.data ?? {}) as Record<string, unknown>;
  if (d.direction !== undefined && d.direction !== "inbound") return null;
  const sender = (d.sender_handle ?? d.from_handle) as
    | Record<string, unknown>
    | undefined;
  const from = typeof sender?.handle === "string"
    ? sender.handle
    : typeof d.from === "string"
    ? d.from
    : null;
  if (!from || sender?.is_me === true) return null;
  const message = (d.message ?? {}) as Record<string, unknown>;
  const parts = (Array.isArray(d.parts) ? d.parts : message.parts) as
    | unknown[]
    | undefined;
  const text = (parts ?? [])
    .map((x) => x as Record<string, unknown>)
    .filter((x) => x.type === "text" && typeof x.value === "string")
    .map((x) => x.value as string)
    .join(" ");
  return { eventId: p.event_id, from, text };
}
