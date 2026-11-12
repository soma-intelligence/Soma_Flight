import { readFile } from "node:fs/promises";
import path from "node:path";
import { beforeAll, describe, expect, it } from "vitest";
import { initCore } from "@/core/flightcore";
import type { Flight } from "@/data/types";
import { parseAirports } from "./airports";
import { globeContent } from "./content";

const lookup = parseAirports("KJFK\tJFK\tKennedy\tNew York\tUS\t40.6398\t-73.7789\tx\nEGLL\tLHR\tHeathrow\tLondon\tGB\t51.47\t-0.4543\tx\n");
const now = new Date("2026-11-11T12:00:00Z");

function flight(over: Partial<Flight>): Flight {
  return {
    id: "f1", providerId: "p", ident: "BA1", operator: null,
    originIcao: "KJFK", originIata: "JFK", destinationIcao: "EGLL", destinationIata: "LHR",
    scheduledOut: now, scheduledIn: now, estimatedOut: null, estimatedIn: null, scheduledOff: null,
    scheduledOn: null, estimatedOff: null, estimatedOn: null, actualOut: null, actualOff: null,
    actualOn: null, actualIn: null, gateOrigin: null, gateDestination: null, terminalOrigin: null,
    terminalDestination: null, baggageBelt: null, aircraftType: null, registration: null,
    status: "scheduled", position: null, updatedAt: now, ...over,
  };
}

beforeAll(async () => {
  await initCore(await readFile(path.join(import.meta.dirname, "../../core/pkg/flightcore_wasm_bg.wasm")));
});

describe("globeContent", () => {
  it("draws one route per flight with both airports known", () => {
    const c = globeContent(
      [flight({ id: "a" }), flight({ id: "b", destinationIcao: "ZZZZ" }), flight({ id: "c" })],
      now,
      lookup,
    );
    expect(c.routes).toHaveLength(2);
    expect(c.routes[0][0]).toEqual({ lat: 40.6398, lon: -73.7789 });
    expect(c.airports.map((a) => a.code).sort()).toEqual(["JFK", "LHR"]);
  });

  it("a flight with no position puts no plane", () => {
    expect(globeContent([flight({})], now, lookup).planes).toEqual([]);
  });

  it("puts a plane at a fresh position with its heading", () => {
    const position = { lat: 50, lon: -30, altitudeFt: null, groundSpeedKt: null, heading: 82, at: now };
    const c = globeContent([flight({ id: "x", status: "en_route", position })], now, lookup);
    expect(c.planes).toEqual([{ id: "x", at: { lat: 50, lon: -30 }, heading: 82 }]);
  });
});
