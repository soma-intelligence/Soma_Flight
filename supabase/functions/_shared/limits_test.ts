import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { AeroApi } from "./aeroapi.ts";
import { ApiError } from "./errors.ts";
import { dailyCap, DEFAULT_DAILY_CAP_USD, usageCounter } from "./limits.ts";
import { testDb } from "./test_util.ts";

const db = await testDb();
// A day far in the past, so real counters are never touched.
const DAY = new Date("1999-02-03T12:00:00Z");

async function spent(): Promise<{ calls: number; cost: number }> {
  const { data, error } = await db.from("usage_counters")
    .select("calls, estimated_cost").eq("day", "1999-02-03");
  if (error) throw error;
  return (data ?? []).reduce(
    (a, r) => ({
      calls: a.calls + r.calls,
      cost: Math.round((a.cost + Number(r.estimated_cost)) * 1e4) / 1e4,
    }),
    { calls: 0, cost: 0 },
  );
}

Deno.test({
  name:
    "the daily cap refuses paid calls once spent, keeps free ones, and counts nothing refused",
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    await db.from("usage_counters").delete().eq("day", "1999-02-03");
    try {
      const count = usageCounter(db, () => DAY, 0.015);
      await count("/flights/{ident}"); // 0.005
      await count("/flights/{id}/position"); // 0.015, exactly the cap
      const e = await assertRejects(() => count("/flights/{ident}"), ApiError);
      assertEquals([e.code, e.status], ["provider_unavailable", 503]);
      await count("/alerts/{id}"); // free: alert deletes stay possible
      assertEquals(await spent(), { calls: 3, cost: 0.015 });

      // Through the client: the refused request never reaches the provider.
      let fetched = 0;
      const api = new AeroApi(
        "k",
        (() => {
          fetched++;
          return Promise.resolve(new Response("{}"));
        }) as typeof fetch,
        count,
      );
      await assertRejects(() => api.flightsByIdent("AF84"), ApiError);
      assertEquals(fetched, 0);
    } finally {
      await db.from("usage_counters").delete().eq("day", "1999-02-03");
    }
  },
});

Deno.test("dailyCap reads AEROAPI_DAILY_CAP_USD with a default", () => {
  assertEquals(dailyCap(undefined), DEFAULT_DAILY_CAP_USD);
  assertEquals(dailyCap(""), DEFAULT_DAILY_CAP_USD);
  assertEquals(dailyCap("abc"), DEFAULT_DAILY_CAP_USD);
  assertEquals(dailyCap("-1"), DEFAULT_DAILY_CAP_USD);
  assertEquals(dailyCap("12.5"), 12.5);
  assertEquals(dailyCap("0"), 0);
  assertEquals(DEFAULT_DAILY_CAP_USD, 50);
});
