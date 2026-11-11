// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router";

const exchangeCodeForSession = vi.fn();
const getSession = vi.fn();
vi.mock("@/data/client", () => ({
  getSupabase: () => ({ auth: { exchangeCodeForSession, getSession, signInWithOtp: vi.fn() } }),
}));

import { AuthCallback } from "./AuthCallback";
import { RETURN_KEY } from "./session";

function setup(url: string) {
  return render(
    <MemoryRouter initialEntries={[url]}>
      <Routes>
        <Route path="/auth/callback" element={<AuthCallback />} />
        <Route path="*" element={<p>landed</p>} />
        <Route path="/flight/abc" element={<p>flight abc</p>} />
      </Routes>
    </MemoryRouter>,
  );
}

afterEach(() => {
  cleanup();
  sessionStorage.clear();
  exchangeCodeForSession.mockReset();
  getSession.mockReset();
});

describe("AuthCallback", () => {
  it("exchanges the code and navigates to the saved path", async () => {
    exchangeCodeForSession.mockResolvedValue({ error: null });
    sessionStorage.setItem(RETURN_KEY, "/flight/abc");
    setup("/auth/callback?code=c1");
    await waitFor(() => expect(screen.getByText("flight abc")).toBeTruthy());
    expect(exchangeCodeForSession).toHaveBeenCalledWith("c1");
    expect(sessionStorage.getItem(RETURN_KEY)).toBeNull();
  });

  it("goes home when nothing was saved", async () => {
    exchangeCodeForSession.mockResolvedValue({ error: null });
    setup("/auth/callback?code=c1");
    await waitFor(() => expect(screen.getByText("landed")).toBeTruthy());
  });

  it("shows the expired line and the form when the code is missing", () => {
    setup("/auth/callback");
    expect(screen.getByText("This link has expired. Send a new one.")).toBeTruthy();
    expect(screen.getByLabelText("Email address")).toBeTruthy();
    expect(exchangeCodeForSession).not.toHaveBeenCalled();
  });

  it("shows the expired line and the form when the exchange fails (verifier gone)", async () => {
    exchangeCodeForSession.mockResolvedValue({ error: new Error("code verifier not found") });
    getSession.mockResolvedValue({ data: { session: null } });
    setup("/auth/callback?code=c1");
    await waitFor(() => expect(screen.getByText("This link has expired. Send a new one.")).toBeTruthy());
    expect(screen.getByLabelText("Email address")).toBeTruthy();
  });

  it("treats an already stored session as success when the exchange reports an error", async () => {
    exchangeCodeForSession.mockResolvedValue({ error: new Error("already used") });
    getSession.mockResolvedValue({ data: { session: { access_token: "t" } } });
    setup("/auth/callback?code=c1");
    await waitFor(() => expect(screen.getByText("landed")).toBeTruthy());
  });

  it("ignores a #access_token fragment", () => {
    setup("/auth/callback#access_token=abc&refresh_token=def");
    expect(screen.getByText("This link has expired. Send a new one.")).toBeTruthy();
    expect(exchangeCodeForSession).not.toHaveBeenCalled();
  });

  it("does not follow a protocol-relative saved path", async () => {
    exchangeCodeForSession.mockResolvedValue({ error: null });
    sessionStorage.setItem(RETURN_KEY, "//evil.example");
    setup("/auth/callback?code=c1");
    await waitFor(() => expect(screen.getByText("landed")).toBeTruthy());
  });
});
