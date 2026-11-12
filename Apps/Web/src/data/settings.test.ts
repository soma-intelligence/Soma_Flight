// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const getSession = vi.fn();
const limit = vi.fn();
const select = vi.fn(() => ({ limit }));
const upsert = vi.fn();
const eq = vi.fn();
const update = vi.fn(() => ({ eq }));
const from = vi.fn(() => ({ select, upsert, update }));
const callFunction = vi.fn();

vi.mock("./client", () => ({ getSupabase: () => ({ from, auth: { getSession } }) }));
vi.mock("./api", async (orig) => ({ ...(await orig<typeof import("./api")>()), callFunction: (...a: unknown[]) => callFunction(...a) }));

import {
  applyAppearance,
  deleteAccount,
  fetchNotificationPrefs,
  readAppearance,
  readUnits,
  saveDisplayName,
  setNotificationPref,
  writeAppearance,
  writeUnits,
} from "./settings";

beforeEach(() => {
  vi.clearAllMocks();
  getSession.mockResolvedValue({ data: { session: { user: { id: "u-1" } } } });
});
afterEach(() => {
  localStorage.clear();
  document.documentElement.removeAttribute("data-theme");
});

describe("notification preferences", () => {
  it("no row means every category is on", async () => {
    limit.mockResolvedValueOnce({ data: [], error: null });
    const p = await fetchNotificationPrefs();
    expect(from).toHaveBeenCalledWith("notification_preferences");
    expect(Object.values(p).every((v) => v === true)).toBe(true);
    expect(p.baggage).toBe(true);
  });

  it("reads the row's columns over the defaults", async () => {
    limit.mockResolvedValueOnce({ data: [{ user_id: "u-1", baggage: false, delays: true }], error: null });
    const p = await fetchNotificationPrefs();
    expect(p.baggage).toBe(false);
    expect(p.gates).toBe(true);
  });

  it("writing a category upserts the user's row with that column", async () => {
    upsert.mockResolvedValueOnce({ error: null });
    await setNotificationPref("baggage", false);
    expect(upsert).toHaveBeenCalledTimes(1);
    const [row, opts] = upsert.mock.calls[0] as unknown as [Record<string, unknown>, { onConflict: string }];
    expect(row).toMatchObject({ user_id: "u-1", baggage: false });
    expect(typeof row.updated_at).toBe("string");
    expect(opts).toEqual({ onConflict: "user_id" });
  });

  it("a refused write throws an ApiError", async () => {
    upsert.mockResolvedValueOnce({ error: { code: "42501", message: "no" } });
    await expect(setNotificationPref("gates", true)).rejects.toMatchObject({ name: "ApiError" });
  });
});

describe("appearance and units (per browser)", () => {
  it("appearance defaults to system and sets data-theme only for light or dark", () => {
    expect(readAppearance()).toBe("system");
    writeAppearance("dark");
    expect(localStorage.getItem("sf.appearance")).toBe("dark");
    expect(document.documentElement.getAttribute("data-theme")).toBe("dark");
    writeAppearance("system");
    expect(document.documentElement.hasAttribute("data-theme")).toBe(false);
    expect(localStorage.getItem("sf.appearance")).toBe("system");
    localStorage.setItem("sf.appearance", "nonsense");
    expect(readAppearance()).toBe("system");
    localStorage.setItem("sf.appearance", "light");
    applyAppearance();
    expect(document.documentElement.getAttribute("data-theme")).toBe("light");
  });

  it("survives blocked storage", () => {
    const spy = vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
      throw new Error("blocked");
    });
    expect(readAppearance()).toBe("system");
    expect(readUnits()).toEqual({ distance: "km", clock: "h24" });
    spy.mockRestore();
    const set = vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
      throw new Error("blocked");
    });
    expect(() => writeAppearance("dark")).not.toThrow();
    expect(document.documentElement.getAttribute("data-theme")).toBe("dark");
    set.mockRestore();
  });

  it("units keep distance and clock, and fall back on junk", () => {
    expect(readUnits()).toEqual({ distance: "km", clock: "h24" });
    writeUnits({ distance: "mi", clock: "h12" });
    expect(readUnits()).toEqual({ distance: "mi", clock: "h12" });
    localStorage.setItem("sf.units", "{bad");
    expect(readUnits()).toEqual({ distance: "km", clock: "h24" });
  });
});

describe("profile and account", () => {
  it("saves the display name on the user's profile row", async () => {
    eq.mockResolvedValueOnce({ error: null });
    await saveDisplayName("  Maya ");
    expect(from).toHaveBeenCalledWith("profiles");
    expect(update).toHaveBeenCalledWith({ display_name: "Maya" });
    expect(eq).toHaveBeenCalledWith("user_id", "u-1");
  });

  it("maps a refused name (23514) to invalid_request", async () => {
    eq.mockResolvedValueOnce({ error: { code: "23514", message: "profiles_display_name_check" } });
    await expect(saveDisplayName("x")).rejects.toMatchObject({ code: "invalid_request" });
  });

  it("deletes the account through the delete-account function", async () => {
    callFunction.mockResolvedValueOnce({ ok: true });
    await deleteAccount();
    expect(callFunction).toHaveBeenCalledWith("delete-account", { method: "POST", body: {} });
  });
});
