// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, render, screen } from "@testing-library/react";
import { ua990 } from "@/test/flight";

let ready = false;
vi.mock("./airports", () => ({ useAirports: () => () => null, airportsReady: () => ready }));
vi.mock("./airlines", async (original) => {
  const real = await original<typeof import("./airlines")>();
  const dir = real.parseAirlines([{ icao: "UAL", iata: "UA", name: "United Airlines" }]);
  return { ...real, useAirlines: () => dir };
});

import { FlightRow } from "./FlightRow";

afterEach(cleanup);

const SFO = { icao: "KSFO", iata: "SFO", name: "San Francisco International", city: "San Francisco", tz: "America/Los_Angeles", lat: 37.6, lon: -122.4 };
const CDG = { icao: "LFPG", iata: "CDG", name: "Paris Charles de Gaulle", city: "Paris", tz: "Europe/Paris", lat: 49, lon: 2.5 };

function row() {
  return render(
    <FlightRow flight={ua990()} origin={SFO} destination={CDG} now={new Date("2026-10-29T12:00:00Z")} onSelect={() => {}} />,
  );
}

describe("FlightRow", () => {
  it("shows --:-- and no day until the airport table is in", () => {
    ready = false;
    row();
    expect(screen.getAllByText("--:--")).toHaveLength(2);
    expect(screen.queryByText("Fri, Oct 30")).toBeNull();
  });

  it("then the local times, the day, the +1 and the airline's IATA code", () => {
    ready = true;
    row();
    expect(screen.getByText("15:20")).toBeTruthy();
    expect(screen.getByText("10:15")).toBeTruthy();
    expect(screen.getByText("+1")).toBeTruthy();
    expect(screen.getByText("Fri, Oct 30")).toBeTruthy();
    expect(screen.getByText("UA")).toBeTruthy();
  });

  it("reads 12-hour times when the browser's units say so", () => {
    ready = true;
    localStorage.setItem("sf.units", JSON.stringify({ distance: "km", clock: "h12" }));
    try {
      row();
      expect(screen.getByText("3:20 PM")).toBeTruthy();
    } finally {
      localStorage.removeItem("sf.units");
    }
  });
});
