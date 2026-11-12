// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { MemoryRouter, Route, Routes } from "react-router";
import { ApiError } from "@/data/api";
import { defaultPrefs, type NotificationColumn, type NotificationPrefs } from "@/data/settings";

const signOut = vi.fn<() => Promise<void>>();
vi.mock("@/app/session", () => ({
  signOut: () => signOut(),
  useSession: () => ({ session: { user: { email: "quentin@example.com" } }, loading: false }),
}));

const fetchNotificationPrefs = vi.fn<() => Promise<NotificationPrefs>>();
const setNotificationPref = vi.fn<(c: NotificationColumn, on: boolean) => Promise<void>>();
const deleteAccount = vi.fn<() => Promise<void>>();
const saveDisplayName = vi.fn<(n: string) => Promise<void>>();
vi.mock("@/data/settings", async (orig) => ({
  ...(await orig<typeof import("@/data/settings")>()),
  fetchNotificationPrefs: () => fetchNotificationPrefs(),
  setNotificationPref: (c: NotificationColumn, on: boolean) => setNotificationPref(c, on),
  deleteAccount: () => deleteAccount(),
  saveDisplayName: (n: string) => saveDisplayName(n),
}));
vi.mock("@/data/friends", async (orig) => ({
  ...(await orig<typeof import("@/data/friends")>()),
  fetchFriendsMe: () =>
    Promise.resolve({ friendCode: "K7M2X9QP", sharingPaused: false, displayName: "Quentin", emoji: null }),
}));

import { Settings } from "./Settings";

function setup() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={["/settings"]}>
        <Routes>
          <Route path="/" element={<p>home</p>} />
          <Route path="/settings" element={<Settings />} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>,
  );
}

/** A switch once the preferences have loaded (they are disabled until then). */
async function loadedSwitch(name: RegExp): Promise<HTMLElement> {
  const sw = await screen.findByRole("switch", { name });
  await waitFor(() => expect((sw as HTMLButtonElement).disabled).toBe(false));
  return sw;
}

beforeEach(() => {
  // The server's row: a write changes it, a refetch reads it.
  const row = defaultPrefs();
  fetchNotificationPrefs.mockImplementation(() => Promise.resolve({ ...row }));
  setNotificationPref.mockImplementation((c, on) => {
    row[c] = on;
    return Promise.resolve();
  });
  deleteAccount.mockResolvedValue();
  saveDisplayName.mockResolvedValue();
});

afterEach(() => {
  cleanup();
  vi.clearAllMocks();
  signOut.mockReset();
  localStorage.clear();
  document.documentElement.removeAttribute("data-theme");
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

describe("Settings profile, units, appearance", () => {
  it("shows the name and the email", async () => {
    setup();
    const input = (await screen.findByLabelText("Name")) as HTMLInputElement;
    await waitFor(() => expect(input.value).toBe("Quentin"));
    expect(screen.getByText("quentin@example.com")).toBeTruthy();
  });

  it("saves a changed name", async () => {
    setup();
    const input = (await screen.findByLabelText("Name")) as HTMLInputElement;
    await waitFor(() => expect(input.value).toBe("Quentin"));
    fireEvent.change(input, { target: { value: "Q" } });
    fireEvent.click(screen.getByRole("button", { name: "Save" }));
    await waitFor(() => expect(saveDisplayName).toHaveBeenCalledWith("Q"));
  });

  it("limits the name to 40 characters and cannot save an empty one", async () => {
    setup();
    const input = (await screen.findByLabelText("Name")) as HTMLInputElement;
    expect(input.maxLength).toBe(40);
    await waitFor(() => expect(input.value).toBe("Quentin"));
    fireEvent.change(input, { target: { value: "   " } });
    expect(screen.queryByRole("button", { name: "Save" })).toBeNull();
  });

  it("shows the app's line when the database refuses the name (23514)", async () => {
    saveDisplayName.mockRejectedValue(new ApiError("invalid_request", 400, "A value is not accepted here"));
    setup();
    const input = (await screen.findByLabelText("Name")) as HTMLInputElement;
    await waitFor(() => expect(input.value).toBe("Quentin"));
    fireEvent.change(input, { target: { value: "Q" } });
    fireEvent.click(screen.getByRole("button", { name: "Save" }));
    await waitFor(() => expect(screen.getByRole("alert").textContent).toBe("A value is not accepted here"));
  });

  it("keeps units per browser", () => {
    setup();
    fireEvent.click(screen.getByRole("radio", { name: "Miles" }));
    fireEvent.click(screen.getByRole("radio", { name: "12-Hour" }));
    expect(JSON.parse(localStorage.getItem("sf.units")!)).toEqual({ distance: "mi", clock: "h12" });
    expect(screen.getByRole("radio", { name: "Miles" }).getAttribute("aria-checked")).toBe("true");
  });

  it("applies the appearance to the page and remembers it", () => {
    setup();
    fireEvent.click(screen.getByRole("radio", { name: "Dark" }));
    expect(document.documentElement.getAttribute("data-theme")).toBe("dark");
    expect(localStorage.getItem("sf.appearance")).toBe("dark");
    fireEvent.click(screen.getByRole("radio", { name: "System" }));
    expect(document.documentElement.hasAttribute("data-theme")).toBe(false);
  });
});

describe("Settings notifications", () => {
  it("says alerts reach the phone", async () => {
    setup();
    expect((await screen.findByText(/alerts arrive on your phone/i)).textContent).toContain("Soma Flight app");
  });

  it("toggling a preference writes that column", async () => {
    setup();
    const baggage = await loadedSwitch(/Baggage/);
    expect(baggage.getAttribute("aria-checked")).toBe("true");
    fireEvent.click(baggage);
    await waitFor(() => expect(setNotificationPref).toHaveBeenCalledWith("baggage", false));
    expect(screen.getByRole("switch", { name: /Baggage/ }).getAttribute("aria-checked")).toBe("false");
  });

  it("groups the switches as Flight Alerts and Airports", async () => {
    setup();
    await loadedSwitch(/Baggage/);
    const alerts = screen.getByRole("region", { name: "Flight Alerts" });
    expect(within(alerts).getAllByRole("switch")).toHaveLength(7);
    expect(
      within(screen.getByRole("region", { name: "Airports" })).getByRole("switch", { name: /Favorite Airports/ }),
    ).toBeTruthy();
  });

  it("puts a switch back and shows the error when the write fails", async () => {
    setNotificationPref.mockRejectedValue(new ApiError("provider_unavailable", 500));
    setup();
    fireEvent.click(await loadedSwitch(/Gates/));
    await waitFor(() => expect(screen.getByRole("alert")).toBeTruthy());
    expect(screen.getByRole("switch", { name: /Gates/ }).getAttribute("aria-checked")).toBe("true");
  });
});

describe("Settings delete account", () => {
  it("asks for confirmation before calling the function", async () => {
    signOut.mockResolvedValue();
    setup();
    fireEvent.click(screen.getByRole("button", { name: "Delete Account" }));
    const dialog = screen.getByRole("alertdialog");
    expect(dialog.textContent).toContain("Delete your account?");
    expect(dialog.textContent).toContain(
      "Your followed flights and flight history will be removed. This can't be undone.",
    );
    expect(deleteAccount).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
    expect(screen.queryByRole("alertdialog")).toBeNull();
    expect(deleteAccount).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: "Delete Account" }));
    fireEvent.click(within(screen.getByRole("alertdialog")).getByRole("button", { name: "Delete Account" }));
    await waitFor(() => expect(screen.getByText("home")).toBeTruthy());
    expect(deleteAccount).toHaveBeenCalledTimes(1);
    expect(signOut).toHaveBeenCalledTimes(1);
  });

  it("stays signed in and shows the error copy when the function refuses", async () => {
    deleteAccount.mockRejectedValue(new ApiError("provider_unavailable", 503));
    setup();
    fireEvent.click(screen.getByRole("button", { name: "Delete Account" }));
    fireEvent.click(within(screen.getByRole("alertdialog")).getByRole("button", { name: "Delete Account" }));
    await waitFor(() => expect(screen.getByRole("alert").textContent).toContain("You're still signed in."));
    expect(signOut).not.toHaveBeenCalled();
    expect(screen.queryByText("home")).toBeNull();
  });

  it("in fakes mode never calls the function and just signs out", async () => {
    window.history.replaceState(null, "", "/?fakes=1");
    signOut.mockRejectedValue(new Error("no client"));
    setup();
    fireEvent.click(screen.getByRole("button", { name: "Delete Account" }));
    fireEvent.click(within(screen.getByRole("alertdialog")).getByRole("button", { name: "Delete Account" }));
    await waitFor(() => expect(screen.getByText("home")).toBeTruthy());
    expect(deleteAccount).not.toHaveBeenCalled();
  });
});
