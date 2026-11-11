// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router";

let current: { data: { session: unknown } } = { data: { session: null } };
vi.mock("@/data/client", () => ({
  getSupabase: () => ({
    auth: {
      getSession: () => Promise.resolve(current),
      onAuthStateChange: () => ({ data: { subscription: { unsubscribe: () => {} } } }),
    },
  }),
}));

import { AuthGate } from "./AuthGate";
import { RETURN_KEY } from "./session";

function setup(url: string) {
  return render(
    <MemoryRouter initialEntries={[url]}>
      <Routes>
        <Route path="/sign-in" element={<p>sign in page</p>} />
        <Route
          path="*"
          element={
            <AuthGate>
              <p>private</p>
            </AuthGate>
          }
        />
      </Routes>
    </MemoryRouter>,
  );
}

afterEach(() => {
  cleanup();
  sessionStorage.clear();
  window.history.replaceState(null, "", "/");
  current = { data: { session: null } };
});

describe("AuthGate", () => {
  it("sends a signed-out visit to /flight/abc to /sign-in and remembers /flight/abc", async () => {
    setup("/flight/abc");
    await waitFor(() => expect(screen.getByText("sign in page")).toBeTruthy());
    expect(sessionStorage.getItem(RETURN_KEY)).toBe("/flight/abc");
  });

  it("lets a signed-in visit through", async () => {
    current = { data: { session: { access_token: "t" } } };
    setup("/flight/abc");
    await waitFor(() => expect(screen.getByText("private")).toBeTruthy());
  });

  it("lets a visit through without a session when fakes are on (development)", () => {
    window.history.replaceState(null, "", "/?fakes=1");
    setup("/flight/abc");
    expect(screen.getByText("private")).toBeTruthy();
    expect(sessionStorage.getItem(RETURN_KEY)).toBeNull();
  });
});
