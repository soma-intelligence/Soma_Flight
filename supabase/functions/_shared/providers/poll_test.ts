// The polling plan (pure) and one polling run on the local stack, with a fake status provider.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { ApiError } from "../errors.ts";
import { makeUser, test, testDb, trackFlightId } from "../test_util.ts";
import {
  alertFields,
  type Candidate,
  changes,
  CORE_POINTS,
  dailyPace,
  duePoint,
  EXTENDED_POINTS,
  flightsPerDay,
  pollTimes,
  runPoll,
} from "./poll.ts";
import { FREE_TIER, memoryQuota } from "./quota.ts";
import type { FlightRef, ProviderFlight, StatusProvider } from "./types.ts";
import { blankRow } from "./common.ts";

const D = Date.parse("2026-11-03T20:00:00Z");
const A = Date.parse("2026-11-04T06:00:00Z");
const plan = {
  scheduled_out: new Date(D).toISOString(),
  estimated_out: null,
  scheduled_in: new Date(A).toISOString(),
  estimated_in: null,
  status: "scheduled",
};
const at = (ms: number) => new Date(ms);
const MIN = 60_000;

Deno.test("poll points sit around departure and arrival, core ladder of four", () => {
  assertEquals(
    pollTimes(plan, CORE_POINTS).map((x) => new Date(x.at).toISOString()),
    [
      "2026-11-03T18:00:00.000Z",
      "2026-11-03T20:15:00.000Z",
      "2026-11-04T05:30:00.000Z",
      "2026-11-04T06:20:00.000Z",
    ],
  );
  assertEquals(pollTimes(plan, EXTENDED_POINTS).length, 8);
  // An estimate moves the points; an unknown arrival leaves only departure points.
  const moved = {
    ...plan,
    estimated_out: "2026-11-03T21:00:00Z",
    scheduled_in: null,
  };
  assertEquals(
    pollTimes(moved, CORE_POINTS).map((x) => x.point.rank),
    [1, 2],
  );
});

Deno.test("a point is due once, after it passes, within the catch-up window", () => {
  assertEquals(duePoint(plan, null, at(D - 180 * MIN)), null);
  assertEquals(duePoint(plan, null, at(D - 119 * MIN))?.point.rank, 1);
  const polled = new Date(D - 119 * MIN).toISOString();
  assertEquals(duePoint(plan, polled, at(D - 100 * MIN)), null);
  assertEquals(duePoint(plan, polled, at(D + 20 * MIN))?.point.rank, 2);
  // 35 minutes after D+15 the point is skipped (too old to matter).
  assertEquals(duePoint(plan, polled, at(D + 50 * MIN)), null);
  assertEquals(
    duePoint({ ...plan, status: "arrived" }, null, at(A + 20 * MIN)),
    null,
  );
});

Deno.test("quota math: followed flights a day each tier supports", () => {
  const free = FREE_TIER.aviationstack;
  assertEquals(flightsPerDay(free, 0.7, 4).toFixed(2), "0.58");
  assertEquals(
    flightsPerDay({ period: "month", limit: 10_000 }, 0.7, 4).toFixed(1),
    "58.3",
  );
  assertEquals(
    flightsPerDay({ period: "month", limit: 10_000 }, 0.7, 8).toFixed(1),
    "29.2",
  );
  assertEquals(
    flightsPerDay({ period: "month", limit: 4_000 }, 0.7, 4).toFixed(1),
    "23.3",
  );
  assertEquals(flightsPerDay(FREE_TIER.flightlabs, 0.7, 4).toFixed(2), "0.29");
  assertEquals(dailyPace(free, 0.7), 2);
  assertEquals(dailyPace({ period: "month", limit: 10_000 }, 0.7), 233);
  assertEquals(dailyPace({ period: "day", limit: 400 }, 0.7), 280);
});

function candidate(over: Partial<Candidate> = {}): Candidate {
  return {
    id: "f",
    provider_id: "p",
    ident: "AF84",
    operator: "AF",
    origin_icao: "KSFO",
    origin_iata: "SFO",
    destination_icao: "LFPG",
    destination_iata: "CDG",
    scheduled_out: "2026-11-03T23:40:00.000Z",
    scheduled_in: null,
    estimated_out: null,
    estimated_in: null,
    actual_out: null,
    actual_off: null,
    actual_on: null,
    actual_in: null,
    gate_origin: null,
    gate_destination: null,
    terminal_origin: null,
    terminal_destination: null,
    baggage_belt: null,
    aircraft_type: null,
    registration: null,
    status: "scheduled",
    updated_at: "2026-11-03T00:00:00Z",
    last_polled_at: null,
    ...over,
  };
}

Deno.test("only answers that change something reach the database", () => {
  const row = blankRow(
    "aviationstack:AFR84:KSFO:2026-11-03",
    "AF84",
    new Date(),
  );
  row.scheduled_out = "2026-11-03T23:40:00Z";
  row.status = "scheduled";
  const same = alertFields(row);
  assertEquals(changes(candidate(), same), false);
  assertEquals(
    changes(candidate(), alertFields({ ...row, gate_origin: "A3" })),
    true,
  );
  assertEquals(
    changes(candidate(), alertFields({ ...row, status: "canceled" })),
    true,
  );
  // A status behind the stored one is not a change (the merge never moves backwards).
  assertEquals(
    changes(
      candidate({ status: "en_route" }),
      alertFields({ ...row, status: "scheduled" }),
    ),
    false,
  );
  assertEquals(alertFields({ ...row, status: "unknown" }).status, undefined);
  assertEquals(alertFields({ ...row, baggage_belt: "4" }).baggage_belt, "4");
});

// The run against the database: a followed flight two hours before departure.
const db = await testDb();

function fakeStatus(
  answer: (
    ref: FlightRef,
  ) => ProviderFlight | null | Promise<ProviderFlight | null>,
) {
  const asked: FlightRef[] = [];
  const status = {
    name: "aviationstack",
    flightStatus(ref: FlightRef) {
      asked.push(ref);
      return Promise.resolve(answer(ref));
    },
  } as unknown as StatusProvider & { asked: FlightRef[] };
  return Object.assign(status, { asked });
}

async function followed(departIn: number) {
  const user = await makeUser(db, "pro");
  const out = new Date(Date.now() + departIn).toISOString();
  const { data, error } = await db.from("flights").insert({
    provider_id: `aviationstack:AFR84:KSFO:POLL${
      crypto.randomUUID().slice(0, 6)
    }`,
    ident: "AF84",
    operator: "AF",
    origin_icao: "KSFO",
    origin_iata: "SFO",
    destination_icao: "LFPG",
    destination_iata: "CDG",
    scheduled_out: out,
    scheduled_in: new Date(Date.now() + departIn + 10 * 3_600_000)
      .toISOString(),
    status: "scheduled",
  }).select("id, provider_id").single();
  if (error) throw error;
  trackFlightId(data.id);
  const f = await db.from("user_flights").insert({
    user_id: user,
    flight_id: data.id,
  });
  if (f.error) throw f.error;
  return { id: data.id as string, providerId: data.provider_id as string, out };
}

test(
  db,
  "a due flight is polled once; a gate change becomes an event and a push",
  async () => {
    const { id, providerId, out } = await followed(119 * MIN);
    const status = fakeStatus((ref) => {
      const r = blankRow(providerId, "AF84", new Date());
      r.origin_icao = "KSFO";
      r.scheduled_out = ref.scheduled_out;
      r.gate_origin = "A3";
      r.status = "scheduled";
      return r;
    });
    const pushed: string[] = [];
    const deps = {
      db,
      status,
      pace: memoryQuota(10),
      push: (_f: string, e: string) => {
        pushed.push(e);
        return Promise.resolve();
      },
    };
    const first = await runPoll(deps);
    assert(first.due >= 1);
    const mine = status.asked.filter((r) => r.provider_id === providerId);
    assertEquals(mine.length, 1);
    assertEquals(mine[0].ident, "AF84");
    assertEquals(Date.parse(mine[0].scheduled_out!), Date.parse(out));
    const row = await db.from("flights").select("gate_origin").eq("id", id)
      .single();
    assertEquals(row.data?.gate_origin, "A3");
    const ev = await db.from("flight_events").select("id, kind, payload").eq(
      "flight_id",
      id,
    );
    assertEquals(ev.data?.map((e) => e.kind), ["gate_change"]);
    assertEquals(ev.data?.[0].payload.gate, "A3");
    assert(pushed.includes(ev.data![0].id));
    const polled = await db.from("provider_polls").select("provider").eq(
      "flight_id",
      id,
    ).single();
    assertEquals(polled.data?.provider, "aviationstack");

    // Same run window again: already polled for this point, nothing asked.
    status.asked.length = 0;
    await runPoll(deps);
    assertEquals(
      status.asked.filter((r) => r.provider_id === providerId).length,
      0,
    );
    await db.from("webhook_inbox").delete().eq("body->>flight_id", id);
  },
);

test(
  db,
  "an unchanged answer writes nothing, and a spent pace stops the run",
  async () => {
    const { id, providerId } = await followed(119 * MIN);
    const status = fakeStatus((ref) => {
      const r = blankRow(providerId, "AF84", new Date());
      r.scheduled_out = ref.scheduled_out;
      r.status = "scheduled";
      return r;
    });
    const r = await runPoll({
      db,
      status,
      pace: memoryQuota(1000),
      push: () => Promise.resolve(),
    });
    assert(r.polled >= 1);
    const inbox = await db.from("webhook_inbox").select("id").eq(
      "body->>flight_id",
      id,
    );
    assertEquals(inbox.data?.length, 0);

    await db.from("provider_polls").delete().eq("flight_id", id);
    const stopped = await runPoll({
      db,
      status,
      pace: () =>
        Promise.reject(
          new ApiError(
            "provider_unavailable",
            503,
            "Daily polling pace reached",
          ),
        ),
      push: () => Promise.resolve(),
    });
    assertEquals(stopped.stoppedBy, "Daily polling pace reached");
    assertEquals(stopped.polled, 0);
  },
);

test(
  db,
  "a provider quota refusal mid run stops it; other failures skip the flight",
  async () => {
    await followed(119 * MIN);
    const quota = fakeStatus(() => {
      throw new ApiError(
        "provider_unavailable",
        503,
        "Monthly provider quota reached",
      );
    });
    const r = await runPoll({
      db,
      status: quota,
      pace: memoryQuota(100),
      push: () => Promise.resolve(),
    });
    assertEquals(r.stoppedBy, "Monthly provider quota reached");
    await followed(119 * MIN);
    const flaky = fakeStatus(() => {
      throw new ApiError("provider_unavailable", 502, "Provider error 500");
    });
    const r2 = await runPoll({
      db,
      status: flaky,
      pace: memoryQuota(100),
      push: () => Promise.resolve(),
    });
    assertEquals(r2.stoppedBy, null);
    assert(r2.failed >= 1);
  },
);
