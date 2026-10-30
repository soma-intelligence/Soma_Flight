// The update event of migration 20261030000012: deliveries that change what an alert is made from
// (take-off, landing, the schedule, an estimate, a reinstated flight) reach push-sender too.
import { assertEquals } from "jsr:@std/assert@1";
import { makeUser, test, testDb, trackFlightId } from "../_shared/test_util.ts";
import { type Deps, handler } from "./handler.ts";

const db = await testDb();
const SECRET = "test-secret-value";
const gateFixture = JSON.parse(
  await Deno.readTextFile(
    new URL("../_shared/fixtures/alert_gate_change.json", import.meta.url),
  ),
);

function setup() {
  const calls: string[] = [];
  const deps: Deps = {
    db,
    secret: () => SECRET,
    push: (_f, e) => {
      calls.push(e);
      return Promise.resolve();
    },
  };
  return { calls, deps };
}

const post = (body: string) =>
  new Request(`http://localhost/aeroapi-webhook?secret=${SECRET}`, {
    method: "POST",
    body,
  });

let alertId = 900000 + Math.floor(Math.random() * 1000) * 50;
/** A gate fixture delivery with no gate news, so only `flight` moves anything. */
const delivery = (
  faFlightId: string,
  code: string,
  flight: Record<string, unknown>,
) =>
  JSON.stringify({
    ...gateFixture,
    event_code: code,
    alert_id: ++alertId,
    flight: {
      ...gateFixture.flight,
      fa_flight_id: faFlightId,
      gate_origin: null,
      terminal_origin: null,
      ...flight,
    },
  });

async function followed(over: Record<string, unknown> = {}) {
  const t = crypto.randomUUID().slice(0, 8).toUpperCase();
  const providerId = `UPD${t}-1793600000-schedule-1p`;
  const { data, error } = await db.from("flights").insert({
    provider_id: providerId,
    ident: `UP${t}`,
    origin_icao: "LFPG",
    destination_icao: "KSFO",
    scheduled_out: "2026-11-03T22:30:00Z",
    scheduled_in: "2026-11-04T09:00:00Z",
    estimated_out: "2026-11-03T22:30:00Z",
    estimated_in: "2026-11-04T09:00:00Z",
    status: "scheduled",
    ...over,
  }).select("id").single();
  if (error) throw error;
  trackFlightId(data.id);
  const u = await makeUser(db);
  const f = await db.from("user_flights").insert({
    user_id: u,
    flight_id: data.id,
  });
  if (f.error) throw f.error;
  return { id: data.id as string, providerId };
}

async function kinds(flightId: string): Promise<string[]> {
  const { data, error } = await db.from("flight_events").select("kind")
    .eq("flight_id", flightId).order("received_at");
  if (error) throw error;
  return (data ?? []).map((r) => r.kind as string);
}

test(
  db,
  "take-off and landing deliveries make update events and pushes",
  async () => {
    const { calls, deps } = setup();
    const { id, providerId } = await followed();
    await handler(
      post(delivery(providerId, "off", {
        actual_out: "2026-11-03T22:41:00Z",
        actual_off: "2026-11-03T22:58:00Z",
        inbound_fa_flight_id: "AFR83-1793500000-schedule-1p",
      })),
      deps,
    );
    await handler(
      post(delivery(providerId, "on", { actual_on: "2026-11-04T08:50:00Z" })),
      deps,
    );
    assertEquals(await kinds(id), ["update", "update"]);
    assertEquals(calls.length, 2);
    const row = await db.from("flights").select("status, inbound_provider_id")
      .eq("id", id).single();
    assertEquals(row.data?.status, "landed");
    assertEquals(row.data?.inbound_provider_id, "AFR83-1793500000-schedule-1p");
  },
);

test(
  db,
  "a schedule move and a 10 minute estimate move are update events, 3 minutes is not",
  async () => {
    const { deps } = setup();
    const { id, providerId } = await followed();
    await handler(
      post(
        delivery(providerId, "change", {
          estimated_out: "2026-11-03T22:33:00Z",
        }),
      ),
      deps,
    );
    assertEquals(await kinds(id), []);
    await handler(
      post(
        delivery(providerId, "change", {
          estimated_out: "2026-11-03T22:43:00Z",
        }),
      ),
      deps,
    );
    await handler(
      post(delivery(providerId, "change", {
        scheduled_out: "2026-11-03T22:50:00Z",
        estimated_out: "2026-11-03T22:50:00Z",
      })),
      deps,
    );
    assertEquals(await kinds(id), ["update", "update"]);
  },
);

test(db, "a filed delivery after a cancel reinstates the flight", async () => {
  const { deps } = setup();
  const { id, providerId } = await followed();
  await handler(
    post(delivery(providerId, "cancelled", { cancelled: true })),
    deps,
  );
  await handler(post(delivery(providerId, "filed", {})), deps);
  assertEquals(await kinds(id), ["cancel", "update"]);
  const ev = await db.from("flight_events").select("payload").eq(
    "flight_id",
    id,
  )
    .eq("kind", "update").single();
  assertEquals(ev.data?.payload.changes.status, {
    from: "canceled",
    to: "scheduled",
  });
});
