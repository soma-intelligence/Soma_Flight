// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import { MemoryRouter, Routes, useLocation, type InitialEntry } from "react-router";
import { shellRoutes } from "./routes";

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
  return <output data-testid="where">{l.pathname}</output>;
}

function setup(entries: InitialEntry[], index = entries.length - 1) {
  return render(
    <MemoryRouter initialEntries={entries} initialIndex={index}>
      <Routes>{shellRoutes((el) => el)}</Routes>
      <Where />
    </MemoryRouter>,
  );
}

describe("Shell", () => {
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
});
