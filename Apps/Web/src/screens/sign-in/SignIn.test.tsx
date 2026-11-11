// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";

const signInWithOtp = vi.fn();
vi.mock("@/data/client", () => ({ getSupabase: () => ({ auth: { signInWithOtp } }) }));

import { SignIn } from "./SignIn";

afterEach(() => {
  cleanup();
  signInWithOtp.mockReset();
});

describe("SignIn", () => {
  it("sends signInWithOtp with emailRedirectTo origin + /auth/callback, then shows Check your email", async () => {
    signInWithOtp.mockResolvedValue({ error: null });
    render(<SignIn />);
    fireEvent.change(screen.getByLabelText("Email address"), { target: { value: " a@b.co " } });
    fireEvent.click(screen.getByRole("button", { name: "Email Me a Sign-In Link" }));
    await waitFor(() => expect(screen.getByText("Check your email")).toBeTruthy());
    expect(signInWithOtp).toHaveBeenCalledWith({
      email: "a@b.co",
      options: { emailRedirectTo: `${window.location.origin}/auth/callback` },
    });
    expect(screen.getByText(/We sent a sign-in link to a@b.co/)).toBeTruthy();
  });

  it("keeps the button disabled for an invalid address", () => {
    render(<SignIn />);
    fireEvent.change(screen.getByLabelText("Email address"), { target: { value: "nope" } });
    expect((screen.getByRole("button", { name: "Email Me a Sign-In Link" }) as HTMLButtonElement).disabled).toBe(true);
  });

  it("shows the failure line when the link did not go out", async () => {
    signInWithOtp.mockResolvedValue({ error: new Error("x") });
    render(<SignIn />);
    fireEvent.change(screen.getByLabelText("Email address"), { target: { value: "a@b.co" } });
    fireEvent.click(screen.getByRole("button", { name: "Email Me a Sign-In Link" }));
    await waitFor(() => expect(screen.getByText(/The link didn't go out/)).toBeTruthy());
  });
});
