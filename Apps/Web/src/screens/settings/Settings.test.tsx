// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router";

const signOut = vi.fn<() => Promise<void>>();
vi.mock("@/app/session", () => ({ signOut: () => signOut() }));

import { Settings } from "./Settings";

function setup() {
  return render(
    <MemoryRouter initialEntries={["/settings"]}>
      <Routes>
        <Route path="/" element={<p>home</p>} />
        <Route path="/settings" element={<Settings />} />
      </Routes>
    </MemoryRouter>,
  );
}

afterEach(() => {
  cleanup();
  signOut.mockReset();
  sessionStorage.clear();
  window.history.replaceState(null, "", "/");
});

describe("Settings Sign Out", () => {
  it("signs out and goes home", async () => {
    signOut.mockResolvedValue();
    setup();
    fireEvent.click(screen.getByRole("button", { name: "Sign Out" }));
    await waitFor(() => expect(screen.getByText("home")).toBeTruthy());
  });

  it("shows the failure and stays put when signing out fails", async () => {
    signOut.mockRejectedValue(new Error("network"));
    vi.spyOn(console, "error").mockImplementation(() => {});
    setup();
    fireEvent.click(screen.getByRole("button", { name: "Sign Out" }));
    await waitFor(() => expect(screen.getByRole("alert").textContent).toBe("That did not work. Try again."));
    expect(screen.queryByText("home")).toBeNull();
  });

  it("goes home in fakes mode even though there is no session to end", async () => {
    window.history.replaceState(null, "", "/?fakes=1");
    signOut.mockRejectedValue(new Error("no client"));
    setup();
    fireEvent.click(screen.getByRole("button", { name: "Sign Out" }));
    await waitFor(() => expect(screen.getByText("home")).toBeTruthy());
  });
});
