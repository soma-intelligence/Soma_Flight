import { describe, expect, it } from "vitest";
import { readConfig } from "./config";

const KEY = "publishable-test-key";

describe("readConfig", () => {
  it("production without URL returns null", () => {
    expect(readConfig({ VITE_SUPABASE_PUBLISHABLE_KEY: KEY }, true)).toBeNull();
  });
  it("production without key returns null", () => {
    expect(readConfig({ VITE_SUPABASE_URL: "https://x.supabase.co" }, true)).toBeNull();
  });
  it("production with http URL returns null", () => {
    expect(
      readConfig({ VITE_SUPABASE_URL: "http://x.supabase.co", VITE_SUPABASE_PUBLISHABLE_KEY: KEY }, true),
    ).toBeNull();
  });
  it("development accepts http://127.0.0.1:58321", () => {
    expect(
      readConfig({ VITE_SUPABASE_URL: "http://127.0.0.1:58321", VITE_SUPABASE_PUBLISHABLE_KEY: KEY }, false),
    ).toEqual({ url: "http://127.0.0.1:58321", key: KEY });
  });
  it("production with https URL and key returns both", () => {
    expect(
      readConfig({ VITE_SUPABASE_URL: "https://x.supabase.co", VITE_SUPABASE_PUBLISHABLE_KEY: KEY }, true),
    ).toEqual({ url: "https://x.supabase.co", key: KEY });
  });
});
