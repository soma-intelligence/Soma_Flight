// @vitest-environment jsdom
import { readFile } from "node:fs/promises";
import path from "node:path";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { QueryClientProvider } from "@tanstack/react-query";
import { makeQueryClient } from "@/app/query";
import { initCore } from "@/core/flightcore";
import { airportDir } from "@/test/airportDir";
import type { PastFlight } from "@/data/passport";

const fetchPastFlights = vi.fn<() => Promise<PastFlight[]>>();
const addPastFlight = vi.fn();
const deletePastFlight = vi.fn<(id: string) => Promise<void>>();
const downloadExport = vi.fn();

vi.mock("@/data/passport", async (orig) => ({
  ...(await orig<typeof import("@/data/passport")>()),
  fetchPastFlights: () => fetchPastFlights(),
  addPastFlight: (...a: unknown[]) => addPastFlight(...a),
  deletePastFlight: (id: string) => deletePastFlight(id),
  downloadExport: (...a: unknown[]) => downloadExport(...a),
}));
let detailFails = false;
vi.mock("@/core/flightcore", async (orig) => {
  const real = await orig<typeof import("@/core/flightcore")>();
  return {
    ...real,
    computePassportDetail: (...a: Parameters<typeof real.computePassportDetail>) => {
      if (detailFails) throw new Error("core");
      return real.computePassportDetail(...a);
    },
  };
});
vi.mock("@/ui/airports", async (orig) => ({
  ...(await orig<typeof import("@/ui/airports")>()),
  useAirports: () => airportDir,
}));

import { Passport } from "./Passport";

beforeAll(async () => {
  await initCore(await readFile(path.join(import.meta.dirname, "../../core/pkg/flightcore_wasm_bg.wasm")));
});

function pf(n: number, iso: string, ident: string, from: string, to: string, km: number, over: Partial<PastFlight> = {}): PastFlight {
  return {
    id: `dddddddd-0000-4000-8000-${String(n).padStart(12, "0")}`,
    date: new Date(iso),
    ident,
    originIcao: from,
    destinationIcao: to,
    airline: null,
    aircraftType: null,
    registration: null,
    seat: null,
    distanceKm: km,
    blockMinutes: 60,
    delayMinutes: 0,
    status: "completed",
    originTz: "UTC",
    seatClass: null,
    reason: null,
    bookingCode: null,
    notes: null,
    originCountry: null,
    destinationCountry: null,
    airMinutes: null,
    seatPosition: null,
    source: "manual",
    arrivalDelayMinutes: null,
    departureDelayMinutes: null,
    ...over,
  };
}

const FLIGHTS = [
  pf(1, "2025-03-10T12:00:00Z", "AF83", "LFPG", "KSFO", 8950),
  pf(2, "2026-01-10T12:00:00Z", "UA1", "KSFO", "KJFK", 4150),
  pf(3, "2026-06-10T12:00:00Z", "BA286", "EGLL", "KSFO", 8620),
];

function show() {
  return render(
    <QueryClientProvider client={makeQueryClient()}>
      <Passport />
    </QueryClientProvider>,
  );
}

beforeEach(() => {
  vi.clearAllMocks();
  fetchPastFlights.mockResolvedValue([...FLIGHTS]);
  deletePastFlight.mockResolvedValue();
});
afterEach(cleanup);

const stat = (label: string) => screen.getByText(label).parentElement!.textContent!;

describe("Passport", () => {
  it("shows the stats from the core for all time", async () => {
    show();
    await screen.findByText("All-Time Soma Flight Passport");
    await waitFor(() => expect(stat("Flights")).toContain("3"));
    expect(stat("Distance")).toContain("21,720 km");
    expect(stat("Airports")).toContain("4");
    expect(stat("Countries")).toContain("3");
    expect(stat("Flight time")).toContain("3h");
  });

  it("lists the past flights newest first", async () => {
    show();
    const list = await screen.findByRole("list", { name: "Past flights" });
    const idents = within(list).getAllByRole("listitem").map((li) => li.getAttribute("data-ident"));
    expect(idents).toEqual(["BA286", "UA1", "AF83"]);
  });

  it("the year switch filters stats and list", async () => {
    show();
    await screen.findByText("All-Time Soma Flight Passport");
    fireEvent.click(screen.getByRole("button", { name: "2026" }));
    await screen.findByText("2026 Soma Flight Passport");
    await waitFor(() => expect(stat("Flights")).toContain("2"));
    expect(stat("Distance")).toContain("12,770 km");
    const list = screen.getByRole("list", { name: "Past flights" });
    expect(within(list).getAllByRole("listitem")).toHaveLength(2);
    fireEvent.click(screen.getByRole("button", { name: "All-Time" }));
    await waitFor(() => expect(stat("Flights")).toContain("3"));
  });

  it("deletes a flight after the app's confirmation", async () => {
    show();
    const list = await screen.findByRole("list", { name: "Past flights" });
    fireEvent.click(within(list).getByRole("button", { name: "Delete UA1 KSFO to KJFK" }));
    const dialog = await screen.findByRole("alertdialog");
    expect(within(dialog).getByText("Delete this flight from your history?")).toBeTruthy();
    expect(deletePastFlight).not.toHaveBeenCalled();
    fetchPastFlights.mockResolvedValue(FLIGHTS.filter((f) => f.ident !== "UA1"));
    fireEvent.click(within(dialog).getByRole("button", { name: "Delete Flight" }));
    await waitFor(() => expect(deletePastFlight).toHaveBeenCalledWith(FLIGHTS[1]!.id));
    await waitFor(() => expect(within(screen.getByRole("list", { name: "Past flights" })).getAllByRole("listitem")).toHaveLength(2));
  });

  it("Cancel on the confirmation deletes nothing", async () => {
    show();
    const list = await screen.findByRole("list", { name: "Past flights" });
    fireEvent.click(within(list).getByRole("button", { name: "Delete UA1 KSFO to KJFK" }));
    fireEvent.click(within(await screen.findByRole("alertdialog")).getByRole("button", { name: "Cancel" }));
    expect(screen.queryByRole("alertdialog")).toBeNull();
    expect(deletePastFlight).not.toHaveBeenCalled();
  });

  it("a refused delete says so and keeps the flight", async () => {
    deletePastFlight.mockRejectedValue(new Error("no"));
    show();
    const list = await screen.findByRole("list", { name: "Past flights" });
    fireEvent.click(within(list).getByRole("button", { name: "Delete UA1 KSFO to KJFK" }));
    fireEvent.click(within(await screen.findByRole("alertdialog")).getByRole("button", { name: "Delete Flight" }));
    await screen.findByText("Couldn't delete this flight. Try again later.");
    expect(within(screen.getByRole("list", { name: "Past flights" })).getAllByRole("listitem")).toHaveLength(3);
  });

  it("adds a past flight from number, day, from and to", async () => {
    addPastFlight.mockResolvedValue(FLIGHTS[0]);
    show();
    await screen.findByRole("list", { name: "Past flights" });
    fireEvent.click(screen.getByRole("button", { name: "Add Past Flight" }));
    const form = await screen.findByRole("dialog", { name: "Add Past Flight" });
    fireEvent.change(within(form).getByLabelText("Flight number"), { target: { value: "ua 990" } });
    fireEvent.change(within(form).getByLabelText("Day"), { target: { value: "2026-11-01" } });
    fireEvent.change(within(form).getByLabelText("From"), { target: { value: "sfo" } });
    fireEvent.change(within(form).getByLabelText("To"), { target: { value: "jfk" } });
    fireEvent.click(within(form).getByRole("button", { name: "Save" }));
    await waitFor(() =>
      expect(addPastFlight).toHaveBeenCalledWith({ ident: "ua 990", day: "2026-11-01", from: "sfo", to: "jfk" }, airportDir),
    );
    await waitFor(() => expect(screen.queryByRole("dialog", { name: "Add Past Flight" })).toBeNull());
  });

  it("the add form shows the app's line under a field that does not read and does not save", async () => {
    show();
    await screen.findByRole("list", { name: "Past flights" });
    fireEvent.click(screen.getByRole("button", { name: "Add Past Flight" }));
    const form = await screen.findByRole("dialog", { name: "Add Past Flight" });
    fireEvent.click(within(form).getByRole("button", { name: "Save" }));
    expect(await within(form).findByText("Pick the airport you left from.")).toBeTruthy();
    expect(within(form).getByText("Pick the airport you flew to.")).toBeTruthy();
    expect(addPastFlight).not.toHaveBeenCalled();
  });

  it("exports CSV and JSON of every past flight", async () => {
    show();
    await screen.findByRole("list", { name: "Past flights" });
    fireEvent.click(screen.getByRole("button", { name: "Export CSV" }));
    fireEvent.click(screen.getByRole("button", { name: "Export JSON" }));
    expect(downloadExport).toHaveBeenNthCalledWith(1, "csv", [...FLIGHTS].reverse());
    expect(downloadExport).toHaveBeenNthCalledWith(2, "json", [...FLIGHTS].reverse());
  });

  it("shows a dash, not dots, when the core fails", async () => {
    detailFails = true;
    show();
    await screen.findByText("All-Time Soma Flight Passport");
    await waitFor(() => expect(stat("Countries")).toContain("-"));
    expect(screen.queryByText("...")).toBeNull();
    detailFails = false;
  });

  it("shows the app's line for a refused save", async () => {
    addPastFlight.mockRejectedValue(Object.assign(new Error("x"), { code: "invalid_request" }));
    show();
    await screen.findByRole("list", { name: "Past flights" });
    fireEvent.click(screen.getByRole("button", { name: "Add Past Flight" }));
    const form = await screen.findByRole("dialog", { name: "Add Past Flight" });
    fireEvent.change(within(form).getByLabelText("From"), { target: { value: "sfo" } });
    fireEvent.change(within(form).getByLabelText("To"), { target: { value: "jfk" } });
    fireEvent.click(within(form).getByRole("button", { name: "Save" }));
    expect(await within(form).findByText("This flight could not be saved.")).toBeTruthy();
  });

  it("invites the first flight when there is none", async () => {
    fetchPastFlights.mockResolvedValue([]);
    show();
    await screen.findByText("Your passport starts here");
    expect(screen.getByText("Past flights you add or import collect stamps here.")).toBeTruthy();
    expect(screen.getByRole("button", { name: "Add Past Flight" })).toBeTruthy();
  });

  it("a failed load shows the banner with Try again", async () => {
    fetchPastFlights.mockRejectedValue(Object.assign(new Error("x"), { code: "provider_unavailable" }));
    show();
    const alert = await screen.findByRole("alert", {}, { timeout: 4000 });
    fetchPastFlights.mockResolvedValue([...FLIGHTS]);
    fireEvent.click(within(alert).getByRole("button", { name: "Try again" }));
    await screen.findByText("All-Time Soma Flight Passport");
  });
});
