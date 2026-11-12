import { describe, expect, it } from "vitest";
import type { Flight, FlightStatus } from "@/data/types";
import { ua990 } from "@/ui/testFlight";
import { groupMyFlights, isLive, isOver } from "./groups";

const now = new Date(1_793_000_000 * 1000);
const H = 3600_000;

/** LandedFlightsTests.flight: arrived `minutes` ago, eleven hours after it left. */
function landed(status: FlightStatus, arrivedAgo: number | null, ident = "AF84", id = ident): Flight {
  const inn = arrivedAgo === null ? null : new Date(now.getTime() - arrivedAgo * 60_000);
  const out = inn ? new Date(inn.getTime() - 11 * H) : null;
  const flown = status !== "canceled" && status !== "scheduled";
  const at = (base: Date | null, min: number) => (base ? new Date(base.getTime() + min * 60_000) : null);
  return ua990({
    id,
    ident,
    status,
    scheduledOut: out,
    scheduledIn: at(inn, -20),
    actualOut: flown ? at(out, 10) : null,
    actualOff: flown ? at(out, 25) : null,
    actualOn: flown ? at(inn, -8) : null,
    actualIn: flown ? inn : null,
  });
}

function at(id: string, status: FlightStatus, outH: number | null): Flight {
  return ua990({
    id,
    status,
    scheduledOut: outH === null ? null : new Date(now.getTime() + outH * H),
    scheduledIn: outH === null ? null : new Date(now.getTime() + (outH + 5) * H),
  });
}

const titles = (g: ReturnType<typeof groupMyFlights>) => g.map((x) => x.title);
const ids = (g: ReturnType<typeof groupMyFlights>, title: string) =>
  g.find((x) => x.title === title)?.rows.map((f) => f.id) ?? [];

describe("isOver (LandedFlightsTests.overAnHourAfterTheGate)", () => {
  it("an hour after the gate, canceled an hour after it was due, never while scheduled", () => {
    expect(isOver(landed("arrived", 30), now)).toBe(false);
    expect(isOver(landed("arrived", 61), now)).toBe(true);
    expect(isOver(landed("landed", 90), now)).toBe(true);
    expect(isOver(landed("diverted", 120), now)).toBe(true);
    expect(isOver(landed("canceled", 90), now)).toBe(true);
    expect(isOver(landed("scheduled", 600), now)).toBe(false);
    expect(isOver(landed("arrived", null), now)).toBe(false);
  });
});

describe("isLive (MyFlightsStore.isLive)", () => {
  it("departed and en route only", () => {
    expect(isLive(at("a", "departed", -1))).toBe(true);
    expect(isLive(at("a", "en_route", -1))).toBe(true);
    for (const s of ["scheduled", "landed", "arrived", "canceled", "diverted", "unknown"] as const) {
      expect(isLive(at("a", s, -1))).toBe(false);
    }
  });
});

describe("groupMyFlights (MyFlightsView.groups)", () => {
  it("leaves out what is over (LandedFlightsTests.myFlightsLeavesOutWhatIsOver)", () => {
    const over = landed("arrived", 90, "AF84");
    const fresh = landed("arrived", 20, "AF66");
    const g = groupMyFlights([over, fresh], now);
    expect(g.flatMap((x) => x.rows).map((f) => f.id)).toEqual([fresh.id]);
  });

  it("in the air, upcoming, recent in that order; empty groups left out", () => {
    const g = groupMyFlights(
      [at("r", "landed", -3), at("u2", "scheduled", 30), at("l", "en_route", -2), at("u1", "unknown", 2)],
      now,
    );
    expect(titles(g)).toEqual(["In the Air", "Upcoming", "Recent"]);
    expect(ids(g, "In the Air")).toEqual(["l"]);
    expect(ids(g, "Upcoming")).toEqual(["u1", "u2"]);
    expect(ids(g, "Recent")).toEqual(["r"]);
    expect(titles(groupMyFlights([at("u", "scheduled", 2)], now))).toEqual(["Upcoming"]);
    expect(groupMyFlights([], now)).toEqual([]);
  });

  it("canceled and diverted go to Recent until they are over", () => {
    const g = groupMyFlights([at("c", "canceled", 3), at("d", "diverted", -1)], now);
    expect(titles(g)).toEqual(["Recent"]);
    expect(ids(g, "Recent")).toEqual(["d", "c"]);
  });

  it("rows sort by scheduled out, ties by id, soonest first", () => {
    const g = groupMyFlights(
      [at("b", "scheduled", 5), at("a", "scheduled", 5), at("c", "scheduled", 1), at("z", "en_route", -1), at("y", "departed", -2)],
      now,
    );
    expect(ids(g, "Upcoming")).toEqual(["c", "a", "b"]);
    expect(ids(g, "In the Air")).toEqual(["y", "z"]);
  });

  // Review Focus 1
  it("a null scheduled_out sorts last in Upcoming", () => {
    const g = groupMyFlights([at("n", "scheduled", null), at("late", "scheduled", 400), at("soon", "scheduled", 1)], now);
    expect(ids(g, "Upcoming")).toEqual(["soon", "late", "n"]);
    const two = groupMyFlights([at("n2", "scheduled", null), at("n1", "scheduled", null)], now);
    expect(ids(two, "Upcoming")).toEqual(["n1", "n2"]);
  });
});
