// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClientProvider } from "@tanstack/react-query";
import { MemoryRouter, Route, Routes } from "react-router";
import { makeQueryClient } from "@/app/query";
import { ApiError } from "@/data/api";
import type { Flight, FollowedFlight } from "@/data/types";
import { ua990 } from "@/test/flight";

const fetchFlight = vi.fn<(id: string) => Promise<Flight | null>>();
const fetchMyFlights = vi.fn<() => Promise<FollowedFlight[]>>();
const followFlight = vi.fn<(i: { flightId: string }) => Promise<void>>();
const unfollowFlight = vi.fn<(id: string) => Promise<void>>();

vi.mock("@/data/flights", () => ({
  myFlightsKey: ["myFlights"],
  flightKey: (id: string) => ["flight", id],
  fetchFlight: (id: string) => fetchFlight(id),
  fetchMyFlights: () => fetchMyFlights(),
  followFlight: (i: { flightId: string }) => followFlight(i),
  unfollowFlight: (id: string) => unfollowFlight(id),
  useFakes: () => false,
}));
vi.mock("@/data/realtime", () => ({ subscribeFlights: () => () => {} }));

import { FlightCard } from "./FlightCard";
import { countdown, countdownCaption, distanceText, estimate, landedCaption, statusTone, timetableRows } from "./facts";

const d = (s: string) => new Date(s);
const SFO = "America/Los_Angeles";
const CDG = "Europe/Paris";

function show(id: string) {
  return render(
    <QueryClientProvider client={makeQueryClient()}>
      <MemoryRouter initialEntries={[`/flight/${id}`]}>
        <Routes>
          <Route path="/flight/:id" element={<FlightCard />} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>,
  );
}

beforeEach(() => {
  vi.clearAllMocks();
  fetchMyFlights.mockResolvedValue([]);
});
afterEach(cleanup);

describe("FlightCard", () => {
  it("shows the flight's number and route", async () => {
    const f = ua990();
    fetchFlight.mockResolvedValue(f);
    show(f.id);
    expect(await screen.findByText(/^UA 990 · FRI, 30 OCT$/)).toBeTruthy();
    expect(await screen.findByRole("heading", { name: "San Francisco to Paris" })).toBeTruthy();
    expect(screen.getByText("Detailed Timetable")).toBeTruthy();
    expect(fetchFlight).toHaveBeenCalledWith(f.id);
  });

  it("Follow calls follow-flight and the button turns to Stop following", async () => {
    const f = ua990();
    fetchFlight.mockResolvedValue(f);
    // The server now lists the follow, as user_flights would.
    followFlight.mockImplementation(async () => {
      fetchMyFlights.mockResolvedValue([{ createdAt: new Date(), flight: f }]);
    });
    show(f.id);
    fireEvent.click(await screen.findByRole("button", { name: "Follow" }));
    await waitFor(() => expect(followFlight).toHaveBeenCalledWith({ flightId: f.id }));
    expect(await screen.findByRole("button", { name: "Stop Following" })).toBeTruthy();

    unfollowFlight.mockImplementation(async () => {
      fetchMyFlights.mockResolvedValue([]);
    });
    fireEvent.click(screen.getByRole("button", { name: "Stop Following" }));
    await waitFor(() => expect(unfollowFlight).toHaveBeenCalledWith(f.id));
    expect(await screen.findByRole("button", { name: "Follow" })).toBeTruthy();
  });

  it("plan_limit shows the app's free plan copy", async () => {
    const f = ua990();
    fetchFlight.mockResolvedValue(f);
    followFlight.mockRejectedValue(new ApiError("plan_limit", 403));
    show(f.id);
    fireEvent.click(await screen.findByRole("button", { name: "Follow" }));
    expect(await screen.findByText("You can follow up to 3 flights at a time.")).toBeTruthy();
    expect(screen.getByRole("button", { name: "Follow" })).toBeTruthy();
  });

  it("shows the airline's name and its IATA code from airlines.json", async () => {
    const f = ua990();
    fetchFlight.mockResolvedValue(f);
    show(f.id);
    expect(await screen.findByText("United Airlines · Scheduled")).toBeTruthy();
  });

  it("Follow stays disabled until the follows are in, and after they fail to load", async () => {
    const f = ua990();
    fetchFlight.mockResolvedValue(f);
    let release: (v: FollowedFlight[]) => void = () => {};
    fetchMyFlights.mockReturnValue(new Promise((r) => (release = r)));
    show(f.id);
    const button = await screen.findByRole("button", { name: "Follow" });
    expect((button as HTMLButtonElement).disabled).toBe(true);
    release([{ createdAt: new Date(), flight: f }]);
    const stop = await screen.findByRole("button", { name: "Stop Following" });
    expect((stop as HTMLButtonElement).disabled).toBe(false);
    cleanup();

    fetchMyFlights.mockClear();
    fetchMyFlights.mockRejectedValue(new ApiError("provider_unavailable", 500));
    show(f.id);
    // Settled: the first try and its one retry have failed, and the button is still disabled.
    await waitFor(() => expect(fetchMyFlights).toHaveBeenCalledTimes(2), { timeout: 4000 });
    await waitFor(() => expect(screen.getByRole("button", { name: "Follow" })).toBeTruthy());
    expect((screen.getByRole("button", { name: "Follow" }) as HTMLButtonElement).disabled).toBe(true);
  });

  it("the foot sits over a fade, and the scroll content keeps room for it so the last row scrolls clear", async () => {
    const f = ua990();
    fetchFlight.mockResolvedValue(f);
    show(f.id);
    await screen.findByRole("button", { name: "Follow" });
    const foot = screen.getByTestId("follow-foot");
    const content = screen.getByTestId("card-scroll-content");
    // The foot is not inside the scroller: it floats over it, and the scroller's content pads for it.
    expect(content.contains(foot)).toBe(false);
    expect(foot.firstElementChild?.getAttribute("style")).toContain("linear-gradient");
    const pad = parseFloat(content.style.paddingBottom);
    const footHeight = 8 + 52 + 16;
    expect(pad).toBeGreaterThanOrEqual(footHeight);
  });

  it("an unknown id shows not found copy", async () => {
    fetchFlight.mockResolvedValue(null);
    show("00000000-0000-4000-8000-00000000dead");
    expect(await screen.findByText("No flight found. Check the number and date.")).toBeTruthy();
    expect(screen.getByRole("button", { name: "Close" })).toBeTruthy();
    expect(screen.queryByRole("button", { name: "Follow" })).toBeNull();
  });
});

/** DetailPart2Tests.full: UA 990 left 7 minutes late, landed 20 minutes late. */
const full = ua990({
  scheduledOff: d("2026-10-30T22:53:00Z"),
  scheduledOn: d("2026-10-31T09:00:00Z"),
  actualOut: d("2026-10-30T22:27:00Z"),
  actualOff: d("2026-10-30T22:45:00Z"),
  actualOn: d("2026-10-31T09:20:00Z"),
  estimatedIn: d("2026-10-31T09:35:00Z"),
  status: "en_route",
});

describe("facts", () => {
  it("timetable rows, full and sparse (DetailPart2Tests.timetableRowsFullAndSparse)", () => {
    const rows = timetableRows(full, SFO, CDG);
    expect(rows.map((r) => r.title)).toEqual([
      "Gate Departure", "Taxi", "Take Off", "Land", "Taxi", "Gate Arrival", "Air Time", "Total Time",
    ]);
    expect(rows.map((r) => r.section)).toEqual(["depart", "depart", "depart", "arrive", "arrive", "arrive", "totals", "totals"]);
    expect(rows.map((r) => r.scheduled)).toEqual(["15:20", "33m", "15:53", "10:00", "15m", "10:15", "10h 07m", "10h 55m"]);
    expect(rows.map((r) => r.other)).toEqual(["15:27", "18m", "15:45", "10:20", "15m", "10:35", "10h 35m", "11h 08m"]);
    expect(rows.map((r) => r.otherLabel)).toEqual([
      "Actual", "Actual", "Actual", "Actual", "Estimated", "Estimated", "Actual", "Estimated",
    ]);
    const sparse = timetableRows(
      ua990({ scheduledOut: null, scheduledIn: null }),
      SFO,
      CDG,
    );
    expect(sparse).toHaveLength(8);
    expect(sparse.every((r) => r.scheduled === "--" && r.other === "--" && r.level === null)).toBe(true);
    expect(sparse.every((r) => r.otherLabel === "Estimated")).toBe(true);
  });

  it("timetable colours (DetailPart2Tests.timetableColours)", () => {
    const rows = timetableRows(full, SFO, CDG);
    expect(rows[0].level).toBe("on-time");
    expect(rows[2].level).toBe("on-time");
    expect(rows[3].level).toBe("late");
    expect(rows[5].level).toBe("late");
    expect([rows[1], rows[4], rows[6], rows[7]].every((r) => r.level === null)).toBe(true);
    const gate = timetableRows({ ...full, actualIn: d("2026-10-31T10:05:00Z") }, SFO, CDG)[5];
    expect(gate.level).toBe("very-late");
    expect(gate.otherLabel).toBe("Actual");
    expect(gate.other).toBe("11:05");
  });

  it("countdown caption names the airline (DetailFacts.countdownCaption)", () => {
    expect(countdownCaption(ua990(), { name: "United Airlines" })).toBe("United Airlines · Scheduled");
    expect(countdownCaption({ ...full }, null)).toBe("In the air");
    expect(countdownCaption(ua990({ status: "arrived" }), { name: "Air France" })).toBe("Air France · At the gate");
  });

  it("landed caption: gate to gate and the distance (DetailFacts.landedCaption)", () => {
    const down = { ...full, status: "arrived" as const, actualIn: d("2026-10-31T09:35:00Z") };
    expect(landedCaption(down, 8965)).toBe("Total 11h 08m · 8,965 km");
    expect(landedCaption(down, 8965, "mi")).toBe("Total 11h 08m · 5,571 mi");
    expect(landedCaption(down, null)).toBe("Total 11h 08m");
    expect(landedCaption(ua990({ scheduledOut: null, scheduledIn: null }), 120)).toBe("120 km");
    expect(landedCaption(ua990({ scheduledOut: null, scheduledIn: null }), null)).toBeNull();
    expect(distanceText(280017)).toBe("280,017 km");
  });

  it("timetable times read --:-- until the airport zones are known", () => {
    const rows = timetableRows(full, null, null, false, false);
    expect(rows[0].scheduled).toBe("--:--");
    expect(rows[0].other).toBe("--:--");
    expect(rows[0].level).toBeNull();
    expect(rows[1].scheduled).toBe("33m");
    expect(timetableRows(ua990({ scheduledOut: null, scheduledIn: null }), null, null, false, false)[0].scheduled).toBe("--");
  });

  it("countdown card wording", () => {
    const f = ua990();
    const out = f.scheduledOut!.getTime();
    expect(countdown(f, new Date(out - 86_400_000))).toBe("Departs in 1 day");
    expect(countdown(f, new Date(out - 3 * 86_400_000))).toBe("Departs in 3 days");
    expect(countdown(f, new Date(out - 125 * 60_000))).toBe("Departs in 2h 05m");
    expect(countdown(f, new Date(out + 1000))).toBe("Departing now");
    expect(countdown({ ...f, status: "en_route" }, new Date(f.scheduledIn!.getTime() - 40 * 60_000))).toBe("Arrives in 40m");
    expect(countdown({ ...f, status: "canceled" }, new Date(out))).toBe("Canceled");
    expect(countdown({ ...f, status: "arrived" }, new Date(out))).toBe("Landed");
  });

  it("status tone: green on time, red late, none before departure", () => {
    expect(statusTone(ua990())).toBeNull();
    expect(statusTone(full)).toBe("very-late");
    expect(statusTone({ ...full, estimatedIn: d("2026-10-31T09:10:00Z"), actualOn: null })).toBe("on-time");
  });

  it("estimate only for a flight in the air that has gone quiet or offline (FlightEstimate.make)", () => {
    const now = d("2026-10-31T04:00:00Z");
    const fresh = { ...full, actualOn: null, updatedAt: d("2026-10-31T03:58:00Z") };
    expect(estimate(fresh, now, true)).toBeNull();
    const stale = estimate({ ...fresh, updatedAt: d("2026-10-31T03:00:00Z") }, now, true);
    expect(stale?.reason).toBe("stale");
    expect(stale!.progress).toBeGreaterThan(0.4);
    expect(stale!.progress).toBeLessThan(0.6);
    expect(estimate(fresh, now, false)?.reason).toBe("offline");
    expect(estimate(ua990(), now, true)).toBeNull();
  });
});
