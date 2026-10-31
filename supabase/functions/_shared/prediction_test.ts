import { assert, assertEquals } from "jsr:@std/assert@1";
import { type Alert, type AlertFlight, emptyHistory } from "./alerts.ts";
import { alertText } from "./alert_copy.ts";
import { predictDelay, predictGate } from "./flightcore.ts";
import {
  boardSignal,
  type Cached,
  delayInputOf,
  historySignal,
  inboundSignal,
  predictedDelay,
  predictedDelayAlert,
  type PredictionCaches,
  type PredictionFlight,
  weatherSignal,
} from "./prediction.ts";

const NOW = new Date("2026-11-03T20:30:00Z");
const at = (iso: string) => new Date(iso).toISOString();

const flight: PredictionFlight = {
  id: "f1",
  provider_id: "AFR84-1",
  ident: "AF84",
  status: "scheduled",
  origin_icao: "KSFO",
  origin_iata: "SFO",
  destination_icao: "LFPG",
  destination_iata: "CDG",
  scheduled_out: "2026-11-03T22:30:00Z",
  scheduled_in: "2026-11-04T17:30:00Z",
  estimated_out: "2026-11-03T22:30:00Z",
  estimated_in: "2026-11-04T17:30:00Z",
  actual_out: null,
  actual_in: null,
  aircraft_type: "B77W",
};

/** The inbound leg's row: lands 22:00 at SFO, so a 777 (60 min turn) is ready 30 min late. */
const inbound: AlertFlight = {
  ident: "AF83",
  status: "en_route",
  origin_icao: "LFPG",
  destination_icao: "KSFO",
  scheduled_out: "2026-11-03T11:00:00Z",
  scheduled_in: "2026-11-03T21:30:00Z",
  estimated_out: null,
  estimated_in: "2026-11-03T22:00:00Z",
  actual_out: "2026-11-03T11:30:00Z",
  actual_in: null,
};

const cached = (payload: Record<string, unknown>, ageMin = 5): Cached => ({
  payload,
  fetchedAt: new Date(NOW.getTime() - ageMin * 60_000).toISOString(),
});

function caches(
  over: Partial<Record<string, Cached | null>> = {},
): PredictionCaches {
  return {
    inbound: () => Promise.resolve(over.inbound ?? null),
    forecast: () => Promise.resolve(over.forecast ?? null),
    snapshot: (icao, kind) => Promise.resolve(over[`${icao}:${kind}`] ?? null),
  };
}

Deno.test("predictDelay through wasm: late inbound, high confidence", () => {
  const p = predictDelay({
    status: "scheduled",
    scheduledOut: 1_800_000_000,
    estimatedOut: null,
    now: 1_799_990_000,
    aircraftType: "A320",
    originCode: "SFO",
    destinationCode: "CDG",
    inbound: { arrival: 1_800_000_000 - 600, departed: true },
    history: null,
    board: null,
    originWeather: null,
    destinationWeather: null,
  });
  assertEquals(p, {
    minutes: 25,
    reason: "lateInbound",
    confidence: "high",
    reasonTitle: "Late inbound aircraft",
    summary: "Likely 25 min late: inbound aircraft running late",
  });
});

Deno.test("predictGate through wasm", () => {
  const days = [1, 2, 3, 4, 5, 6].map((d) => ({
    day: `2026-10-2${d}`,
    gate: "B22",
    terminal: "2",
  }));
  days.push({ day: "2026-10-27", gate: "B24", terminal: "2" });
  const g = predictGate(days, [], "AF");
  assertEquals(g?.label, "B22");
  assertEquals(g?.detail, "Used 6 of the last 7 days");
  assertEquals(predictGate([], [], null), null);
});

Deno.test("inboundSignal: the live row first, then a recent cached chain", () => {
  const now = NOW.getTime();
  assertEquals(inboundSignal(flight, inbound, null, now), {
    arrival: Date.parse("2026-11-03T22:00:00Z") / 1000,
    departed: true,
  });
  // A leg into another airport is not this flight's plane.
  assertEquals(
    inboundSignal(flight, { ...inbound, destination_icao: "KLAX" }, null, now),
    null,
  );
  const chain = cached({
    legs: [{
      id: "x",
      ident: "AF83",
      origin_iata: "CDG",
      destination_iata: "SFO",
      scheduled_out: "2026-11-03T11:00:00Z",
      scheduled_in: "2026-11-03T21:30:00Z",
      status: "scheduled",
      delay_minutes: 40,
    }],
  });
  assertEquals(inboundSignal(flight, null, chain, now), {
    arrival: Date.parse("2026-11-03T22:10:00Z") / 1000,
    departed: false,
  });
  // An old chain describes a plane that may have moved on.
  assertEquals(
    inboundSignal(flight, null, {
      ...chain,
      fetchedAt: at("2026-11-03T19:00:00Z"),
    }, now),
    null,
  );
});

Deno.test("history, board and weather signals read the cached payloads", () => {
  const now = NOW.getTime();
  assertEquals(
    historySignal(
      cached({
        forecast: { observed: 30, late_percent: 60, average_late_minutes: 35 },
      }),
    ),
    { observed: 30, latePercent: 60, averageLateMinutes: 35 },
  );
  assertEquals(historySignal(cached({ forecast: null })), null);
  assertEquals(
    boardSignal(
      cached({
        departures: { total: 40, delayed15: 20, avgDelayMinutes: 31.5 },
      }),
      now,
    ),
    { total: 40, delayed15: 20, avgDelayMinutes: 31.5 },
  );
  assertEquals(
    boardSignal(
      cached({
        departures: { total: 40, delayed15: 20, avgDelayMinutes: 31.5 },
      }, 45),
      now,
    ),
    null,
  );

  const storm = cached({
    weather: {
      metarRaw: "KSFO 032056Z 28008KT 10SM FEW020 18/12 A3001",
      ceilingFt: null,
      visibilitySm: 10,
      windKt: 8,
      gustKt: null,
      wx: null,
      forecast: [{
        from: "2026-11-03T22:00:00Z",
        to: "2026-11-04T02:00:00Z",
        ceilingFt: 800,
        visibilitySm: 2,
        windKt: 20,
        gustKt: 35,
        wx: "+TSRA",
      }],
    },
  });
  const departure = Date.parse("2026-11-03T22:30:00Z");
  assertEquals(weatherSignal(storm, departure, now)?.level, "severe");
  // Before the TAF period, near now: the calm METAR.
  assertEquals(weatherSignal(storm, now + 30 * 60_000, now)?.level, "none");
  // A day out with no period covering it: nothing.
  assertEquals(weatherSignal(storm, now + 26 * 3_600_000, now), null);
});

Deno.test("delayInputOf and predictedDelay: inbound row plus a busy board", async () => {
  const c = caches({
    "KSFO:stats": cached({
      departures: { total: 40, delayed15: 16, avgDelayMinutes: 20 },
    }),
  });
  const input = await delayInputOf(flight, inbound, c, NOW);
  assertEquals(input?.originCode, "SFO");
  assertEquals(input?.board?.total, 40);
  const a = await predictedDelay(flight, inbound, emptyHistory(), [], c, NOW);
  // 30 from the inbound, a quarter of the board's 20 added.
  assertEquals(a?.kind, "predicted_delay");
  assertEquals(a?.category, "delays");
  assertEquals(a?.minutes, 35);
  assertEquals(a?.reason, "lateInbound");
  const text = alertText(a!, flight);
  assertEquals(text.title, "AF 84 likely 35 min late");
  assertEquals(
    text.body,
    "Inbound aircraft running late. The airline has not changed its departure time yet.",
  );
});

Deno.test("predictedDelay: weather at the origin, from the snapshot alone", async () => {
  const c = caches({
    "KSFO:weather": cached({
      weather: {
        metarRaw: "KSFO 032056Z 25035G48KT 1/2SM +TSRA OVC004 18/17 A2990",
        ceilingFt: 400,
        visibilitySm: 0.5,
        windKt: 35,
        gustKt: 48,
        wx: "+TSRA",
        forecast: [],
      },
    }),
  });
  const a = await predictedDelay(flight, null, emptyHistory(), [], c, NOW);
  assertEquals(a?.reason, "originWeather");
  assertEquals(a?.minutes, 45);
  assertEquals(
    alertText(a!, flight).body,
    "Weather at SFO. The airline has not changed its departure time yet.",
  );
});

Deno.test("predictedDelay: nothing when weak, low, left, or already told", async () => {
  // No signal at all.
  assertEquals(
    await predictedDelay(flight, null, emptyHistory(), [], caches(), NOW),
    null,
  );
  // A history alone is a low confidence hunch: shown in the app, never pushed.
  const often = caches({
    forecast: cached({
      forecast: { observed: 30, late_percent: 80, average_late_minutes: 40 },
    }),
  });
  assertEquals(
    await predictedDelay(flight, null, emptyHistory(), [], often, NOW),
    null,
  );
  // The flight has left.
  assertEquals(
    await predictedDelay(
      { ...flight, status: "departed" },
      inbound,
      emptyHistory(),
      [],
      caches(),
      NOW,
    ),
    null,
  );
  // Sent before, or a departure delay already told.
  const sent = emptyHistory();
  sent.keys.add("predicted_delay");
  assertEquals(
    await predictedDelay(flight, inbound, sent, [], caches(), NOW),
    null,
  );
  const told = emptyHistory();
  told.lastDelay.departure = 20;
  assertEquals(
    await predictedDelay(flight, inbound, told, [], caches(), NOW),
    null,
  );
  // The inbound late alert says it now: no second push about the same plane.
  const late: Alert = {
    kind: "inbound_late",
    category: "delays",
    key: "inbound_late",
  };
  assertEquals(
    await predictedDelay(
      flight,
      inbound,
      emptyHistory(),
      [late],
      caches(),
      NOW,
    ),
    null,
  );
  // A cache that throws costs the alert, never push-sender.
  const broken: PredictionCaches = {
    inbound: () => Promise.reject(new Error("down")),
    forecast: () => Promise.resolve(null),
    snapshot: () => Promise.resolve(null),
  };
  assertEquals(
    await predictedDelay(flight, inbound, emptyHistory(), [], broken, NOW),
    null,
  );
});

Deno.test("predictedDelayAlert: medium and high only", () => {
  const p = {
    minutes: 25,
    reason: "congestion" as const,
    confidence: "medium" as const,
    reasonTitle: "Airport congestion",
    summary: "Likely 25 min late: departures backed up at SFO",
  };
  const a = predictedDelayAlert(p, emptyHistory());
  assert(a);
  assertEquals(a.key, "predicted_delay");
  assertEquals(a.note, p.summary);
  assertEquals(
    predictedDelayAlert({ ...p, confidence: "low" }, emptyHistory()),
    null,
  );
  assertEquals(predictedDelayAlert(null, emptyHistory()), null);
});
