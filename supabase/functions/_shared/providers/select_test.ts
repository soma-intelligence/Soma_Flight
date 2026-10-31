// Provider selection from secrets, and the quota rules and counter. No network, no database.
import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { ApiError } from "../errors.ts";
import {
  memoryQuota,
  OPENSKY_ACCOUNT_CREDITS,
  periodStart,
  pollShare,
  quotaCounter,
  quotaRule,
} from "./quota.ts";
import { chosen, isProduction, selectProviders } from "./select.ts";

const envOf = (vars: Record<string, string>) => (n: string) => vars[n];
const noDb = {} as SupabaseClient;

Deno.test("unset selection secrets keep AeroAPI; unsupported values select none", () => {
  const env = envOf({});
  assertEquals([
    chosen("status", env),
    chosen("board", env),
    chosen("position", env),
  ], [
    "aeroapi",
    "aeroapi",
    "aeroapi",
  ]);
  assertEquals(
    chosen("status", envOf({ STATUS_PROVIDER: " Aviationstack " })),
    "aviationstack",
  );
  assertEquals(
    chosen("position", envOf({ POSITION_PROVIDER: "opensky" })),
    "opensky",
  );
  // OpenSky has no status or board, and a typo never reaches a provider.
  assertEquals(chosen("status", envOf({ STATUS_PROVIDER: "opensky" })), "none");
  assertEquals(chosen("board", envOf({ BOARD_PROVIDER: "opensky" })), "none");
  assertEquals(
    chosen("status", envOf({ STATUS_PROVIDER: "flightaware" })),
    "none",
  );
});

Deno.test("a selected provider without its key answers 503 on use, not at start", async () => {
  const p = selectProviders(noDb, {
    env: envOf({
      STATUS_PROVIDER: "aviationstack",
      BOARD_PROVIDER: "flightlabs",
    }),
    charge: () => memoryQuota(10),
  });
  assertEquals(p.names, {
    status: "aviationstack",
    board: "flightlabs",
    position: "aeroapi",
  });
  assertEquals(p.status.name, "aviationstack");
  const e = await assertRejects(
    () => p.status.flightsByIdent("AF84", new Date(), new Date()),
    ApiError,
  );
  assertEquals([e.code, e.status, e.message], [
    "provider_unavailable",
    503,
    "aviationstack is not configured",
  ]);
  await assertRejects(
    () => p.board.boardFlights("KSFO", "departures"),
    ApiError,
    "flightlabs",
  );
});

Deno.test("none refuses status and boards, and knows no position", async () => {
  const p = selectProviders(noDb, {
    env: envOf({
      STATUS_PROVIDER: "none",
      BOARD_PROVIDER: "none",
      POSITION_PROVIDER: "none",
    }),
  });
  const e = await assertRejects(
    () => p.board.boardFlights("KSFO", "arrivals"),
    ApiError,
  );
  assertEquals(e.status, 503);
  assertEquals(
    await p.position.position({ provider_id: "x", callsign: "AFR84" }),
    null,
  );
  assertEquals(
    await p.status.flightStatus({
      provider_id: "x",
      ident: "AF84",
      operator: null,
      origin_icao: null,
      origin_iata: null,
      destination_icao: null,
      scheduled_out: null,
    }),
    null,
  );
});

Deno.test("an http Aviationstack base is refused on the hosted project", async () => {
  const fetchFn =
    (() => Promise.reject(new Error("must not be called"))) as typeof fetch;
  const vars = {
    STATUS_PROVIDER: "aviationstack",
    AVIATIONSTACK_KEY: "k",
    AVIATIONSTACK_BASE_URL: "http://api.aviationstack.com/v1",
    AVIATIONSTACK_ALLOW_HTTP: "true",
  };
  const hosted = selectProviders(noDb, {
    env: envOf({ ...vars, SUPABASE_URL: "https://abcd.supabase.co" }),
    fetchFn,
    charge: () => memoryQuota(10),
  });
  await assertRejects(
    () => hosted.status.flightsByIdent("AF84", new Date(), new Date()),
    ApiError,
    "not configured",
  );
  // Locally it goes out over http once allowed.
  let seen = "";
  const local = selectProviders(noDb, {
    env: envOf({ ...vars, SUPABASE_URL: "http://127.0.0.1:58321" }),
    fetchFn: ((u: string) => {
      seen = String(u);
      return Promise.resolve(new Response('{"data":[]}'));
    }) as unknown as typeof fetch,
    charge: () => memoryQuota(10),
  });
  await local.status.flightsByIdent("AF84", new Date(), new Date());
  assertEquals(
    seen.startsWith("http://api.aviationstack.com/v1/flights?"),
    true,
  );
});

Deno.test("production is anything but a local stack", () => {
  assertEquals(isProduction(envOf({})), true);
  assertEquals(
    isProduction(envOf({ SUPABASE_URL: "https://x.supabase.co" })),
    true,
  );
  assertEquals(
    isProduction(envOf({ SUPABASE_URL: "http://kong:8000" })),
    false,
  );
  assertEquals(
    isProduction(envOf({ SUPABASE_URL: "http://127.0.0.1:58321" })),
    false,
  );
});

Deno.test("quota rules: free tiers, overrides, an OpenSky account, the poll share", () => {
  assertEquals(quotaRule("aviationstack", envOf({})), {
    period: "month",
    limit: 100,
  });
  assertEquals(quotaRule("flightlabs", envOf({})), {
    period: "month",
    limit: 50,
  });
  assertEquals(quotaRule("opensky", envOf({})), { period: "day", limit: 400 });
  assertEquals(
    quotaRule(
      "opensky",
      envOf({ OPENSKY_CLIENT_ID: "a", OPENSKY_CLIENT_SECRET: "b" }),
    ).limit,
    OPENSKY_ACCOUNT_CREDITS,
  );
  assertEquals(
    quotaRule("aviationstack", envOf({ AVIATIONSTACK_MONTHLY_QUOTA: "10000" }))
      .limit,
    10000,
  );
  assertEquals(
    quotaRule("aviationstack", envOf({ AVIATIONSTACK_MONTHLY_QUOTA: "-3" }))
      .limit,
    100,
  );
  assertEquals(
    quotaRule("flightlabs", envOf({ FLIGHTLABS_MONTHLY_QUOTA: "lots" })).limit,
    50,
  );
  assertEquals(pollShare(envOf({})), 0.7);
  assertEquals(pollShare(envOf({ POLL_QUOTA_SHARE: "0.5" })), 0.5);
  assertEquals(pollShare(envOf({ POLL_QUOTA_SHARE: "2" })), 0.7);
  const at = new Date("2026-10-31T23:59:00Z");
  assertEquals([periodStart("day", at), periodStart("month", at)], [
    "2026-10-31",
    "2026-10-01",
  ]);
});

Deno.test("the poll selection shrinks each ceiling to the poll share", async () => {
  const limits: Record<string, number> = {};
  const p = selectProviders(noDb, {
    env: envOf({ STATUS_PROVIDER: "aviationstack", AVIATIONSTACK_KEY: "k" }),
    forPoll: true,
    fetchFn: (() =>
      Promise.resolve(new Response('{"data":[]}'))) as unknown as typeof fetch,
    charge: (provider, limit) => {
      limits[provider] = limit;
      return memoryQuota(limit);
    },
  });
  // Built on first use.
  await p.status.flightsByIdent("AF84", new Date(), new Date());
  assertEquals(limits.aviationstack, 70);
});

Deno.test("quotaCounter passes the period and refuses with a 503 when the database says no", async () => {
  const calls: Record<string, unknown>[] = [];
  let allow = true;
  const db = {
    rpc(name: string, args: Record<string, unknown>) {
      calls.push({ name, ...args });
      return Promise.resolve({ data: allow, error: null });
    },
  } as unknown as SupabaseClient;
  const charge = quotaCounter(
    db,
    "aviationstack",
    { period: "month", limit: 100 },
    () => new Date("2026-10-31T10:00:00Z"),
    70,
  );
  await charge(1);
  assertEquals(calls[0], {
    name: "charge_provider_quota",
    p_provider: "aviationstack",
    p_period: "2026-10-01",
    p_units: 1,
    p_limit: 70,
  });
  allow = false;
  const e = await assertRejects(() => charge(1), ApiError);
  assertEquals([e.code, e.status, e.message], [
    "provider_unavailable",
    503,
    "Monthly provider quota reached",
  ]);
  // A counter outage refuses too: a free tier is never overrun blind.
  const down = quotaCounter(
    {
      rpc: () => Promise.resolve({ data: null, error: { message: "down" } }),
    } as unknown as SupabaseClient,
    "opensky",
    { period: "day", limit: 400 },
  );
  await assertRejects(() => down(1), ApiError, "Quota counter unavailable");
});
