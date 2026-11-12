// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, useLocation } from "react-router";

const loadMapKit = vi.fn();
vi.mock("./loadMapKit", () => ({ loadMapKit: (...a: unknown[]) => loadMapKit(...a) }));
vi.mock("@/data/api", () => ({ callFunction: vi.fn() }));

import { Globe } from "./Globe";

function Where() {
  return <output data-testid="where">{useLocation().pathname}</output>;
}
function setup() {
  return render(
    <MemoryRouter initialEntries={["/"]}>
      <Globe />
      <Where />
    </MemoryRouter>,
  );
}

beforeEach(() => {
  loadMapKit.mockReset();
  sessionStorage.clear();
});
afterEach(cleanup);

describe("Globe", () => {
  it("shows Retry when loadMapKit rejects and calls it again on click", async () => {
    loadMapKit.mockRejectedValue(new Error("no token"));
    setup();
    const retry = await screen.findByRole("button", { name: "Retry" });
    expect(loadMapKit).toHaveBeenCalledTimes(1);
    fireEvent.click(retry);
    await waitFor(() => expect(loadMapKit).toHaveBeenCalledTimes(2));
  });

  it("keeps the control tower button in the fallback and opens Airports", async () => {
    loadMapKit.mockRejectedValue(new Error("no token"));
    setup();
    await screen.findByRole("button", { name: "Retry" });
    fireEvent.click(screen.getByRole("button", { name: "Airports" }));
    expect(screen.getByTestId("where").textContent).toBe("/airports");
  });

  it("in fakes mode never loads MapKit and still shows the fallback", async () => {
    sessionStorage.setItem("sf.fakes", "1");
    setup();
    expect(await screen.findByRole("button", { name: "Retry" })).toBeTruthy();
    expect(loadMapKit).not.toHaveBeenCalled();
    expect(screen.getByRole("button", { name: "Airports" })).toBeTruthy();
  });
});
