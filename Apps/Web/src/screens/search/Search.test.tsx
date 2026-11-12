// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClientProvider } from "@tanstack/react-query";
import { MemoryRouter, Route, Routes, useLocation } from "react-router";
import { makeQueryClient } from "@/app/query";
import { shellRoutes } from "@/app/routes";
import { ApiError } from "@/data/api";

// A plain function, not vi.fn: vitest 5 fails a test whose vi.fn returned a promise that rejected.
let impl: (...a: unknown[]) => unknown = () => undefined;
const calls: unknown[][] = [];
const callFunction = Object.assign((...a: unknown[]) => { calls.push(a); return impl(...a); }, {
  mockReset: () => { impl = () => undefined; calls.length = 0; },
  mockResolvedValue: (v: unknown) => { impl = () => Promise.resolve(v); },
  mockImplementation: (f: (...a: unknown[]) => unknown) => { impl = f; },
});
vi.mock("@/data/api", async (original) => ({
  ...(await original<typeof import("@/data/api")>()),
  callFunction: (...a: unknown[]) => callFunction(...a),
}));
vi.mock("@/data/flights", async (original) => ({
  ...(await original<typeof import("@/data/flights")>()),
  fetchMyFlights: async () => [],
  fetchFlight: async () => null,
  useFakes: () => false,
}));

import { Search } from "./Search";

const wire = (id: string, ident: string) => ({
  id,
  provider_id: `p-${id}`,
  ident,
  operator: null,
  origin_icao: "KSFO",
  destination_icao: "KJFK",
  status: "scheduled",
  scheduled_out: new Date(Date.now() + 3600_000).toISOString(),
  scheduled_in: new Date(Date.now() + 7 * 3600_000).toISOString(),
  updated_at: new Date().toISOString(),
});

const day = (offset: number) => {
  const d = new Date();
  d.setDate(d.getDate() + offset);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
};

function Where() {
  return <output data-testid="where">{useLocation().pathname}</output>;
}

function show() {
  return render(
    <QueryClientProvider client={makeQueryClient()}>
      <MemoryRouter initialEntries={["/search"]}>
        <Routes>
          <Route path="search" element={<Search />} />
          <Route path="*" element={null} />
        </Routes>
        <Where />
      </MemoryRouter>
    </QueryClientProvider>,
  );
}

const field = () => screen.getByRole("textbox", { name: "Flight number" }) as HTMLInputElement;
const type = (v: string) => fireEvent.change(field(), { target: { value: v } });

beforeEach(() => callFunction.mockReset());

/** Every call fails with `e`. */
function failWith(e: Error) {

  callFunction.mockImplementation(() => new Promise((_, reject) => setTimeout(() => reject(e), 0)));
}
afterEach(cleanup);

describe("Search", () => {
  it("has a field and the three date chips, today picked", () => {
    show();
    expect(field()).toBeTruthy();
    expect(screen.getByRole("radio", { name: "Today" }).getAttribute("aria-checked")).toBe("true");
    expect(screen.getByRole("radio", { name: "Tomorrow" }).getAttribute("aria-checked")).toBe("false");
    expect(screen.getByRole("radio", { name: "Yesterday" }).getAttribute("aria-checked")).toBe("false");
  });

  it("looks the typed number up on the picked day and lists the flights", async () => {
    callFunction.mockResolvedValue({ flights: [wire("a1", "AF84"), wire("a2", "AF84")] });
    show();
    type("air france 84");
    await waitFor(() => expect(screen.getAllByTestId("flight-row")).toHaveLength(2));
    expect(calls[0]).toEqual(["flight-lookup", { body: { ident: "AF84", date: day(0) } }]);
    fireEvent.click(screen.getByRole("radio", { name: "Tomorrow" }));
    await waitFor(() =>
      expect(calls.at(-1)).toEqual(["flight-lookup", { body: { ident: "AF84", date: day(1) } }]),
    );
  });

  it("asks nothing for text that is no flight number", () => {
    show();
    type("paris");
    expect(calls).toHaveLength(0);
  });

  it("arrows move through the results and Enter opens the flight", async () => {
    callFunction.mockResolvedValue({ flights: [wire("a1", "AF84"), wire("a2", "AF84")] });
    show();
    type("af84");
    await waitFor(() => expect(screen.getAllByTestId("flight-row")).toHaveLength(2));
    const items = () => screen.getAllByTestId("search-result");
    expect(items()[0].getAttribute("aria-current")).toBe("true");
    fireEvent.keyDown(field(), { key: "ArrowDown" });
    expect(items()[1].getAttribute("aria-current")).toBe("true");
    fireEvent.keyDown(field(), { key: "ArrowDown" });
    expect(items()[1].getAttribute("aria-current")).toBe("true");
    fireEvent.keyDown(field(), { key: "ArrowUp" });
    expect(items()[0].getAttribute("aria-current")).toBe("true");
    fireEvent.keyDown(field(), { key: "ArrowDown" });
    fireEvent.keyDown(field(), { key: "Enter" });
    expect(screen.getByTestId("where").textContent).toBe("/flight/a2");
  });

  it("a click opens the flight", async () => {
    callFunction.mockResolvedValue({ flights: [wire("a1", "AF84")] });
    show();
    type("af84");
    await waitFor(() => screen.getByTestId("flight-row"));
    fireEvent.click(screen.getByTestId("flight-row"));
    expect(screen.getByTestId("where").textContent).toBe("/flight/a1");
  });

  it("out_of_window shows the app's date copy", async () => {
    failWith(new ApiError("out_of_window", 400));
    show();
    type("af84");
    const al = await screen.findByRole("alert");
    expect(al.textContent).toContain(
      "Flights can be searched from 10 days back to 2 days ahead. Pick another date.",
    );
  });

  it.each([
    ["rate_limited", "Too many searches. Try again in a few minutes."],
    ["provider_unavailable", "Flight data is temporarily unavailable. Showing the last update."],
  ] as const)("%s shows the app's error copy and keeps the query", async (code, copy) => {
    failWith(new ApiError(code, code === "rate_limited" ? 429 : 503));
    show();
    type("af 84");
    fireEvent.click(screen.getByRole("radio", { name: "Yesterday" }));
    expect((await screen.findByRole("alert")).textContent).toContain(copy);
    expect(field().value).toBe("af 84");
    expect(screen.getByRole("radio", { name: "Yesterday" }).getAttribute("aria-checked")).toBe("true");
    expect(screen.queryAllByTestId("flight-row")).toHaveLength(0);
  });

  it("an empty answer says no flight was found", async () => {
    callFunction.mockResolvedValue({ flights: [] });
    show();
    type("af84");
    expect((await screen.findByText(/No flight found/)).textContent).toContain("No flight found. Check the number and date.");
  });
});

describe("Command K", () => {
  it("opens Search from My Flights, and Escape closes it", async () => {
    render(
      <QueryClientProvider client={makeQueryClient()}>
        <MemoryRouter initialEntries={["/"]}>
          <Routes>{shellRoutes((el) => el)}</Routes>
          <Where />
        </MemoryRouter>
      </QueryClientProvider>,
    );
    expect(screen.getByTestId("where").textContent).toBe("/");
    act(() => {
      fireEvent.keyDown(window, { key: "k", metaKey: true });
    });
    expect(screen.getByTestId("where").textContent).toBe("/search");
    await waitFor(() => expect(screen.getByRole("textbox", { name: "Flight number" })).toBeTruthy());
    act(() => {
      fireEvent.keyDown(window, { key: "Escape" });
    });
    await waitFor(() => expect(screen.getByTestId("where").textContent).toBe("/"));
    act(() => {
      fireEvent.keyDown(window, { key: "K", ctrlKey: true });
    });
    expect(screen.getByTestId("where").textContent).toBe("/search");
  });
});

