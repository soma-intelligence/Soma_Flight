import { ApiError, callFunction } from "./api";
import { getSupabase } from "./client";
import { pgError, useFakes } from "./flights";

export const notificationPrefsKey = ["notificationPrefs"] as const;

/** The `notification_preferences` columns the app switches (docs/api-contract.md). */
export const NOTIFICATION_COLUMNS = [
  "delays",
  "gates",
  "takeoff_landing",
  "boarding",
  "aircraft",
  "baggage",
  "cancellations",
  "favorite_airports",
] as const;
export type NotificationColumn = (typeof NOTIFICATION_COLUMNS)[number];
export type NotificationPrefs = Record<NotificationColumn, boolean>;

/** Every category on: what an account with no row has. */
export function defaultPrefs(): NotificationPrefs {
  return Object.fromEntries(NOTIFICATION_COLUMNS.map((c) => [c, true])) as NotificationPrefs;
}

/** The user's categories. No row means all on. */
export async function fetchNotificationPrefs(): Promise<NotificationPrefs> {
  if (useFakes() && import.meta.env.DEV) {
    const { fakeNotificationPrefs } = await import("@/fakes/friends");
    return { ...defaultPrefs(), ...fakeNotificationPrefs() };
  }
  const { data, error } = await getSupabase().from("notification_preferences").select("*").limit(1);
  if (error) throw pgError(error);
  const row = ((data ?? []) as Record<string, unknown>[])[0];
  const out = defaultPrefs();
  if (row) for (const c of NOTIFICATION_COLUMNS) if (typeof row[c] === "boolean") out[c] = row[c];
  return out;
}

/** Writes one category: an upsert on `user_id`, as the app does (the first change makes the row). */
export async function setNotificationPref(column: NotificationColumn, on: boolean): Promise<void> {
  if (useFakes() && import.meta.env.DEV) {
    const { setFakeNotificationPref } = await import("@/fakes/friends");
    setFakeNotificationPref(column, on);
    return;
  }
  const supabase = getSupabase();
  const { data } = await supabase.auth.getSession();
  const uid = data.session?.user.id;
  if (!uid) throw new ApiError("unauthorized", 401);
  const { error } = await supabase
    .from("notification_preferences")
    .upsert({ user_id: uid, [column]: on, updated_at: new Date().toISOString() }, { onConflict: "user_id" });
  if (error) throw pgError(error);
}

/** Saves the name friends see on the user's profile row. */
export async function saveDisplayName(name: string): Promise<void> {
  if (useFakes() && import.meta.env.DEV) return;
  const supabase = getSupabase();
  const { data } = await supabase.auth.getSession();
  const uid = data.session?.user.id;
  if (!uid) throw new ApiError("unauthorized", 401);
  const { error } = await supabase.from("profiles").update({ display_name: name.trim() }).eq("user_id", uid);
  if (error) throw pgError(error);
}

/** Deletes the account (the `delete-account` function). Never called in fakes mode: the screen skips it. */
export async function deleteAccount(): Promise<void> {
  await callFunction("delete-account", { method: "POST", body: {} });
}

// ---- Per-browser conveniences (the app keeps these on the device too) ----

export const APPEARANCE_KEY = "sf.appearance";
export const UNITS_KEY = "sf.units";

export type Appearance = "system" | "light" | "dark";
export type Units = { distance: "km" | "mi"; clock: "h24" | "h12" };
const DEFAULT_UNITS: Units = { distance: "km", clock: "h24" };

function read(key: string): string | null {
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
}
function write(key: string, value: string): void {
  try {
    localStorage.setItem(key, value);
  } catch {
    /* storage blocked: the choice holds for this page only */
  }
}

export function readAppearance(): Appearance {
  const v = read(APPEARANCE_KEY);
  return v === "light" || v === "dark" ? v : "system";
}

/** Sets `data-theme` on `<html>`; system leaves the attribute off so the OS decides. */
export function applyAppearance(value: Appearance = readAppearance()): void {
  const root = document.documentElement;
  if (value === "system") root.removeAttribute("data-theme");
  else root.setAttribute("data-theme", value);
}

export function writeAppearance(value: Appearance): void {
  write(APPEARANCE_KEY, value);
  applyAppearance(value);
}

export function readUnits(): Units {
  try {
    const v = JSON.parse(read(UNITS_KEY) ?? "null") as Partial<Units> | null;
    return {
      distance: v?.distance === "mi" ? "mi" : "km",
      clock: v?.clock === "h12" ? "h12" : "h24",
    };
  } catch {
    return { ...DEFAULT_UNITS };
  }
}

export function writeUnits(units: Units): void {
  write(UNITS_KEY, JSON.stringify(units));
}
