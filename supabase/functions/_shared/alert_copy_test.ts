import { assert, assertEquals } from "jsr:@std/assert@1";
import { alertText, clock, displayIdent, span } from "./alert_copy.ts";
import {
  type Alert,
  type AlertFlight,
  type AlertKind,
  CATEGORY,
} from "./alerts.ts";

const flight: AlertFlight = {
  ident: "AF84",
  status: "scheduled",
  origin_icao: "LFPG",
  origin_iata: "CDG",
  destination_icao: "KSFO",
  destination_iata: "SFO",
  scheduled_out: "2026-11-03T22:30:00Z",
  scheduled_in: "2026-11-04T09:00:00Z",
  estimated_out: "2026-11-03T22:55:00Z",
  estimated_in: "2026-11-04T09:20:00Z",
  actual_out: null,
  actual_off: null,
  actual_on: null,
  actual_in: null,
  gate_origin: "K36",
  gate_destination: "B22",
  baggage_belt: "4",
};
const ctx = { originTz: "Europe/Paris", destinationTz: "America/Los_Angeles" };

const alert = (kind: AlertKind, more: Partial<Alert> = {}): Alert => ({
  kind,
  category: CATEGORY[kind],
  key: kind,
  ...more,
});
const text = (a: Alert, f: AlertFlight = flight) => alertText(a, f, ctx);

Deno.test("displayIdent and span follow the app", () => {
  assertEquals(displayIdent("AF84"), "AF 84");
  assertEquals(displayIdent("B6717"), "B6 717");
  assertEquals(displayIdent("EJM444"), "EJM 444");
  assertEquals(displayIdent("U21234"), "U2 1234");
  assertEquals(displayIdent("AF"), "AF");
  assertEquals(span(25), "25m");
  assertEquals(span(70), "1h 10m");
  assertEquals(span(120), "2h");
  assertEquals(span(-20), "20m");
  assertEquals(clock("2026-11-03T22:55:00Z", "Europe/Paris"), "11:55 PM");
  assertEquals(clock("2026-11-03T22:55:00Z", null), "10:55 PM UTC");
  assertEquals(clock("2026-11-03T22:55:00Z", "Not/AZone"), "10:55 PM UTC");
});

Deno.test("delays: minutes in the title, local times in the body", () => {
  assertEquals(
    text(alert("departure_delay", { minutes: 25, to: "2026-11-03T22:55:00Z" })),
    {
      title: "AF 84 is now 25m late",
      body: "Now departs from CDG at 11:55 PM instead of 11:30 PM.",
    },
  );
  assertEquals(
    text(alert("departure_delay", { minutes: 0, to: "2026-11-03T22:30:00Z" })),
    { title: "AF 84 is back on time", body: "Departs from CDG at 11:30 PM." },
  );
  assertEquals(
    text(alert("arrival_delay", { minutes: 80, to: "2026-11-04T10:20:00Z" })),
    {
      title: "AF 84 now arrives 1h 20m late",
      body: "Now arrives at SFO at 2:20 AM instead of 1:00 AM.",
    },
  );
  assertEquals(
    text(alert("arrival_delay", { minutes: 2, to: "2026-11-04T09:02:00Z" }))
      .title,
    "AF 84 now arrives on time",
  );
  assertEquals(
    text(alert("schedule_change", {
      side: "departure",
      from: "2026-11-03T22:30:00Z",
      to: "2026-11-03T23:30:00Z",
    })),
    {
      title: "AF 84 schedule changed",
      body:
        "The airline moved it: now departs from CDG at 12:30 AM, was 11:30 PM.",
    },
  );
  assertEquals(
    text(
      alert("inbound_late", { minutes: 20, to: "2026-11-03T22:20:00Z" }),
      flight,
    ),
    {
      title: "AF 84 inbound plane is late",
      body:
        "The plane for this flight arrives at CDG at 11:20 PM, too late for the 11:30 PM departure. Expect a delay.",
    },
  );
  assert(
    alertText(alert("inbound_late", { to: "2026-11-03T22:20:00Z" }), flight, {
      ...ctx,
      inbound: { ...flight, ident: "AF83" },
    }).body.startsWith("AF 83, the plane for this flight,"),
  );
});

Deno.test("gates, terminals and belts", () => {
  assertEquals(
    text(alert("gate_change", { side: "departure", from: "K36", to: "G91" })),
    {
      title: "Gate changed to G91",
      body: "AF 84 to SFO now departs from gate G91, was K36.",
    },
  );
  assertEquals(text(alert("gate_assigned", { side: "departure", to: "K36" })), {
    title: "Gate K36 assigned",
    body: "AF 84 to SFO departs from gate K36 at CDG.",
  });
  assertEquals(
    text(alert("gate_assigned", { side: "arrival", to: "B22" })).title,
    "Arrival gate B22",
  );
  assertEquals(
    text(alert("gate_change", { side: "arrival", from: "B20", to: "B24" }))
      .body,
    "AF 84 now arrives at gate B24 at SFO, was B20.",
  );
  assertEquals(
    text(alert("gate_change", { side: "departure", to: null })).title,
    "AF 84 gate change",
  );
  assertEquals(
    text(alert("terminal_change", { side: "departure", from: "2E", to: "2F" })),
    {
      title: "Terminal changed to 2F",
      body: "AF 84 to SFO now departs from terminal 2F, was 2E.",
    },
  );
  assertEquals(text(alert("baggage_belt", { to: "4" })), {
    title: "Bags on belt 4",
    body: "Bags from AF 84 come out on belt 4 at SFO.",
  });
  assertEquals(
    text(alert("baggage_belt", { from: "4", to: "7" })).title,
    "Baggage belt changed to 7",
  );
});

Deno.test("milestones, cancel, reinstated, diversion", () => {
  assertEquals(text(alert("departed", { to: "2026-11-03T22:41:00Z" })), {
    title: "AF 84 left the gate",
    body: "Pushed back from CDG at 11:41 PM.",
  });
  assertEquals(text(alert("takeoff", { to: "2026-11-03T22:58:00Z" })), {
    title: "AF 84 took off",
    body: "Took off from CDG at 11:58 PM. Arrives SFO at 1:20 AM.",
  });
  assertEquals(text(alert("landing", { to: "2026-11-04T08:50:00Z" })), {
    title: "AF 84 landed",
    body: "Landed at SFO at 12:50 AM. Heading to gate B22.",
  });
  assertEquals(text(alert("arrived")), {
    title: "AF 84 arrived at the gate",
    body: "At gate B22 at SFO. Bags on belt 4.",
  });
  assertEquals(text(alert("cancel")), {
    title: "AF 84 canceled",
    body: "The flight from CDG to SFO was canceled.",
  });
  assertEquals(text(alert("reinstated")), {
    title: "AF 84 is back on the schedule",
    body:
      "The airline reinstated the flight from CDG to SFO. Departs at 11:55 PM.",
  });
  assertEquals(text(alert("diversion", { from: "KSFO", to: "KOAK" })), {
    title: "AF 84 diverted to KOAK",
    body: "The flight is landing at KOAK instead of KSFO.",
  });
  assertEquals(text(alert("diversion")).title, "AF 84 diverted");
});

Deno.test("every kind has short copy without dashes", () => {
  const dash = new RegExp(
    `[${String.fromCharCode(0x2013)}${String.fromCharCode(0x2014)}]`,
  );
  for (const k of Object.keys(CATEGORY) as AlertKind[]) {
    for (
      const f of [flight, {
        ...flight,
        origin_iata: null,
        origin_icao: null,
        estimated_out: null,
      }]
    ) {
      const t = alertText(
        alert(k, { to: "X1", minutes: 30, side: "departure" }),
        f,
        {},
      );
      assert(t.title.length > 0 && t.title.length <= 60, `${k}: ${t.title}`);
      assert(t.body.length > 0 && t.body.length <= 178, `${k}: ${t.body}`);
      assert(!dash.test(t.title + t.body), k);
      assert(
        !t.body.includes("undefined") && !t.title.includes("undefined"),
        `${k}: ${t.title} ${t.body}`,
      );
      assert(
        !t.body.includes("null") && !t.title.includes("null"),
        `${k}: ${t.title} ${t.body}`,
      );
    }
  }
});
