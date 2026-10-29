// POST /usage-alert. Service role only: pg_cron calls it daily at 08:00 UTC through pg_net.
// Sums yesterday's (UTC) usage_counters.estimated_cost. Above USAGE_ALERT_USD (default 25) it emails
// OWNER_EMAIL once through Resend. The day is claimed in usage_alerts before sending, so parallel or
// repeated runs send at most one email a day; a failed send releases the claim for the next run.
// The email carries the day, the totals and the per-endpoint breakdown, never a key or token.
// Answer: { ok, day, total, threshold, sent, alreadySent? }.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { isServiceCaller } from "../_shared/auth.ts";
import { ApiError, errorResponse, json } from "../_shared/errors.ts";

export const DEFAULT_THRESHOLD_USD = 25;
export const RESEND_URL = "https://api.resend.com/emails";
const DEFAULT_FROM = "Soma Flight <alerts@somalabs.me>";

export interface Deps {
  db: SupabaseClient;
  fetchFn?: typeof fetch;
  now?: () => Date;
  /** Reads RESEND_API_KEY, OWNER_EMAIL, USAGE_ALERT_USD, USAGE_ALERT_FROM. Defaults to the env. */
  env?: (name: string) => string | undefined;
  serviceKey?: () => string | undefined;
}

interface Counter {
  endpoint: string;
  calls: number;
  estimated_cost: number | string;
}

function yesterdayUtc(now: Date): string {
  return new Date(now.getTime() - 86_400_000).toISOString().slice(0, 10);
}

function threshold(raw: string | undefined): number {
  const n = Number(raw);
  return raw && Number.isFinite(n) && n >= 0 ? n : DEFAULT_THRESHOLD_USD;
}

function emailText(day: string, total: number, limit: number, rows: Counter[]) {
  const lines = rows
    .map((r) => ({ ...r, cost: Number(r.estimated_cost) }))
    .sort((a, b) => b.cost - a.cost)
    .map((r) => `- ${r.endpoint}: ${r.calls} calls, $${r.cost.toFixed(2)}`);
  return [
    `Estimated AeroAPI spend for ${day} (UTC): $${total.toFixed(2)}.`,
    `The alert threshold is $${limit.toFixed(2)}.`,
    "",
    "By endpoint:",
    ...lines,
  ].join("\n");
}

export async function handler(req: Request, deps: Deps): Promise<Response> {
  try {
    if (req.method !== "POST") {
      throw new ApiError("invalid_request", 405, "Use POST");
    }
    const env = deps.env ?? ((n: string) => Deno.env.get(n) || undefined);
    const key = (deps.serviceKey ?? (() => env("SUPABASE_SERVICE_ROLE_KEY")))();
    if (!(await isServiceCaller(req, key))) {
      throw new ApiError("unauthorized", 401, "Service role only");
    }
    const { db } = deps;
    const day = yesterdayUtc((deps.now ?? (() => new Date()))());
    const counters = await db.from("usage_counters")
      .select("endpoint, calls, estimated_cost").eq("day", day);
    if (counters.error) {
      throw new Error(`usage read failed: ${counters.error.message}`);
    }
    const rows = (counters.data ?? []) as Counter[];
    const total = Math.round(
      rows.reduce((s, r) => s + Number(r.estimated_cost), 0) * 10_000,
    ) / 10_000;
    const limit = threshold(env("USAGE_ALERT_USD"));
    if (total <= limit) {
      return json({ ok: true, day, total, threshold: limit, sent: false });
    }

    const apiKey = env("RESEND_API_KEY");
    const owner = env("OWNER_EMAIL");
    if (!apiKey || !owner) {
      console.error("usage-alert: RESEND_API_KEY or OWNER_EMAIL is not set");
      throw new ApiError(
        "provider_unavailable",
        503,
        "Email is not configured",
      );
    }

    const claim = await db.from("usage_alerts").insert({ day, total });
    if (claim.error) {
      if (claim.error.code === "23505") {
        return json({
          ok: true,
          day,
          total,
          threshold: limit,
          sent: false,
          alreadySent: true,
        });
      }
      throw new Error(`usage alert claim failed: ${claim.error.message}`);
    }

    let sent = false;
    try {
      const res = await (deps.fetchFn ?? fetch)(RESEND_URL, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          authorization: `Bearer ${apiKey}`,
          "idempotency-key": `usage-alert-${day}`,
        },
        body: JSON.stringify({
          from: env("USAGE_ALERT_FROM") ?? DEFAULT_FROM,
          to: [owner],
          subject: `Soma Flight: AeroAPI spend $${total.toFixed(2)} on ${day}`,
          text: emailText(day, total, limit, rows),
        }),
      });
      sent = res.ok;
      if (!res.ok) console.error(`usage-alert: resend status=${res.status}`);
      await res.body?.cancel();
    } catch (e) {
      console.error("usage-alert: resend request failed", (e as Error).name);
    }
    if (!sent) {
      const undo = await db.from("usage_alerts").delete().eq("day", day);
      if (undo.error) {
        console.error(
          `usage-alert: claim release failed: ${undo.error.message}`,
        );
      }
      throw new ApiError("provider_unavailable", 503, "Email send failed");
    }
    return json({ ok: true, day, total, threshold: limit, sent: true });
  } catch (e) {
    return errorResponse(e);
  }
}
