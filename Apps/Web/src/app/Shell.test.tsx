// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Routes, useLocation, type InitialEntry } from "react-router";
import { QueryClientProvider } from "@tanstack/react-query";
import { makeQueryClient } from "./query";
import { shellRoutes } from "./routes";

// The shell's screens read My Flights and a flight through the data layer: no server in these tests.
const mocks = vi.hoisted(() => ({
  fetchMyFlights: vi.fn(async (): Promise<unknown[]> => []),
  subscribeFlights: vi.fn((_ids: string[], _cb: unknown) => () => {}),
}));
vi.mock("@/data/flights", async (original) => ({
  ...(await original<typeof import("@/data/flights")>()),
  fetchMyFlights: () => mocks.fetchMyFlights(),
  fetchFlight: async () => null,
}));
vi.mock("@/data/realtime", () => ({
  subscribeFlights: (ids: string[], cb: unknown) => mocks.subscribeFlights(ids, cb),
}));

// A window whose width the test sets; matchMedia answers from it and tells listeners when it moves.
let width = 1024;
const listeners = new Set<() => void>();
function setWidth(w: number) {
  width = w;
  act(() => listeners.forEach((l) => l()));
}

beforeEach(() => {
  width = 1024;
  listeners.clear();
  window.matchMedia = ((query: string) => {
    const min = Number(/min-width:\s*(\d+)px/.exec(query)?.[1] ?? 0);
    return {
      get matches() {
        return width >= min;
      },
      media: query,
      onchange: null,
      addEventListener: (_: string, l: () => void) => listeners.add(l),
      removeEventListener: (_: string, l: () => void) => listeners.delete(l),
      addListener: (l: () => void) => listeners.add(l),
      removeListener: (l: () => void) => listeners.delete(l),
      dispatchEvent: () => true,
    } as unknown as MediaQueryList;
  }) as typeof window.matchMedia;
});

afterEach(cleanup);

function Where() {
  const l = useLocation();
  return (
    <>
      <output data-testid="where">{l.pathname}</output>
      <output data-testid="search">{l.search}</output>
    </>
  );
}

/** The flight card open on `id`, if any. */
const card = (id: string) => document.querySelector(`[data-flight-id="${id}"]`);

function setup(entries: InitialEntry[], index = entries.length - 1) {
  return render(
    <QueryClientProvider client={makeQueryClient()}>
      <MemoryRouter initialEntries={entries} initialIndex={index}>
        <Routes>{shellRoutes((el) => el)}</Routes>
        <Where />
      </MemoryRouter>
    </QueryClientProvider>,
  );
}

describe("Shell", () => {
  it("keeps the followed flights live on every tab, not only on My Flights", async () => {
    mocks.fetchMyFlights.mockResolvedValueOnce([
      { createdAt: new Date(), flight: { ...(await import("@/test/flight")).ua990(), id: "abc" } },
    ]);
    setup(["/friends"]);
    await waitFor(() => expect(mocks.subscribeFlights).toHaveBeenCalledWith(["abc"], expect.any(Function)));
  });

  it("shows the Panel at 1024 px and the Sheet at 500 px", () => {
    setup(["/"]);
    expect(screen.getByTestId("panel")).toBeTruthy();
    expect(screen.queryByTestId("sheet")).toBeNull();
    cleanup();
    width = 500;
    setup(["/"]);
    expect(screen.getByTestId("sheet")).toBeTruthy();
    expect(screen.queryByTestId("panel")).toBeNull();
  });

  it("keeps a globe slot behind the panel", () => {
    const { container } = setup(["/"]);
    expect(container.querySelector("[data-globe-slot]")).toBeTruthy();
  });

  it("shows the tab pill with My Flights, Friends, Passport and Search", () => {
    setup(["/"]);
    expect(screen.getByRole("button", { name: "My Flights" }).getAttribute("aria-pressed")).toBe("true");
    expect(screen.getByRole("button", { name: "Friends" })).toBeTruthy();
    expect(screen.getByRole("button", { name: "Passport" })).toBeTruthy();
    expect(screen.getByRole("button", { name: "Search" })).toBeTruthy();
  });

  it("switches tab from the pill", () => {
    setup(["/"]);
    fireEvent.click(screen.getByRole("button", { name: "Friends" }));
    expect(screen.getByTestId("where").textContent).toBe("/friends");
    expect(screen.getByRole("heading", { name: "Friends" })).toBeTruthy();
  });

  it("opens Settings from the profile button", () => {
    setup(["/"]);
    fireEvent.click(screen.getByRole("button", { name: "Settings and profile" }));
    expect(screen.getByTestId("where").textContent).toBe("/settings");
    expect(screen.getByRole("button", { name: "Sign Out" })).toBeTruthy();
  });

  it("keeps an open /flight/x card open when the width crosses 768 px", () => {
    setup(["/", { pathname: "/flight/x", state: { tab: "flights" } }]);
    expect(screen.getByTestId("flight-card")).toBeTruthy();
    setWidth(500);
    expect(screen.getByTestId("sheet")).toBeTruthy();
    expect(screen.getByTestId("flight-card")).toBeTruthy();
    expect(screen.getByTestId("where").textContent).toBe("/flight/x");
    setWidth(1024);
    expect(screen.getByTestId("panel")).toBeTruthy();
    expect(screen.getByTestId("flight-card")).toBeTruthy();
    expect(screen.getByTestId("where").textContent).toBe("/flight/x");
  });

  it("draws the card over its tab's list and goes back to that tab", () => {
    setup(["/friends", { pathname: "/flight/x", state: { tab: "friends" } }]);
    // The tab underneath stays the one the card was opened from.
    expect(screen.getByRole("heading", { name: "Friends", hidden: true })).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "Close" }));
    expect(screen.getByTestId("where").textContent).toBe("/friends");
    expect(screen.getByRole("heading", { name: "Friends" })).toBeTruthy();
  });

  it("closes a card with Escape", () => {
    setup(["/", { pathname: "/airport/KSFO", state: { tab: "flights" } }]);
    fireEvent.keyDown(window, { key: "Escape" });
    expect(screen.getByTestId("where").textContent).toBe("/");
  });

  it("goes to the remembered tab when a card was the first page", () => {
    setup([{ pathname: "/flight/x", state: { tab: "passport" } }]);
    fireEvent.click(screen.getByRole("button", { name: "Close" }));
    expect(screen.getByTestId("where").textContent).toBe("/passport");
  });

  it("steps the sheet up from its grabber, and back to collapsed from the top", () => {
    width = 500;
    setup(["/"]);
    const grabber = screen.getByRole("slider", { name: "Panel height" });
    expect(grabber.getAttribute("aria-valuetext")).toBe("medium");
    fireEvent.click(grabber);
    expect(grabber.getAttribute("aria-valuetext")).toBe("expanded");
    fireEvent.click(grabber);
    expect(grabber.getAttribute("aria-valuetext")).toBe("collapsed");
    fireEvent.keyDown(grabber, { key: "ArrowUp" });
    expect(grabber.getAttribute("aria-valuetext")).toBe("medium");
    fireEvent.keyDown(grabber, { key: "ArrowDown" });
    expect(grabber.getAttribute("aria-valuetext")).toBe("collapsed");
  });

  it("raises a collapsed sheet to medium when a card opens", () => {
    width = 500;
    setup(["/"]);
    const grabber = screen.getByRole("slider", { name: "Panel height" });
    fireEvent.keyDown(grabber, { key: "ArrowDown" });
    expect(grabber.getAttribute("aria-valuetext")).toBe("collapsed");
    fireEvent.click(screen.getByRole("button", { name: "Search" }));
    expect(screen.getByTestId("where").textContent).toBe("/search");
    expect(screen.getByRole("slider", { name: "Panel height" }).getAttribute("aria-valuetext")).toBe("medium");
  });

  it("keeps two stacked cards across 768 px, and Back shows the lower one", async () => {
    setup([
      "/",
      { pathname: "/flight/a", state: { tab: "flights" } },
      { pathname: "/flight/b", state: { tab: "flights" } },
    ]);
    setWidth(500);
    fireEvent.click(screen.getAllByRole("button", { name: "Close" }).at(-1)!);
    expect(screen.getByTestId("where").textContent).toBe("/flight/a");
    await waitFor(() => expect(card("b")).toBeNull());
    expect(card("a")).toBeTruthy();
    expect(screen.getAllByTestId("flight-card")).toHaveLength(1);
  });

  it("shows a card the stack never held when Back returns to it (after a reload)", async () => {
    setup([
      { pathname: "/flight/a", state: { tab: "flights" } },
      { pathname: "/flight/b", state: { tab: "flights" } },
    ]);
    expect(card("a")).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: "Close" }));
    expect(screen.getByTestId("where").textContent).toBe("/flight/a");
    expect(card("a")).toBeTruthy();
    await waitFor(() => expect(card("b")).toBeNull());
  });

  it("keeps the tab's scroll position when the width crosses 768 px", () => {
    const { container } = setup(["/"]);
    const scroller = container.querySelector(".overflow-y-auto")!;
    scroller.scrollTop = 120;
    setWidth(500);
    expect(container.querySelector(".overflow-y-auto")).toBe(scroller);
  });

  it("adds nothing to the query string when it navigates", () => {
    setup(["/?fakes=1"]);
    fireEvent.click(screen.getByRole("button", { name: "Friends" }));
    expect(screen.getByTestId("where").textContent).toBe("/friends");
    expect(screen.getByTestId("search").textContent).toBe("");
  });
});
