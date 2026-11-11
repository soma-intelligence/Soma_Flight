import { describe, expect, it } from "vitest";
import { clientUrl } from "./client";

const cfg = { url: "https://x.supabase.co", key: "k" };

describe("clientUrl", () => {
  it("uses the proxy in development when VITE_SUPABASE_PROXY=1", () => {
    expect(clientUrl(cfg, { VITE_SUPABASE_PROXY: "1" }, "http://localhost:5173", true)).toBe("http://localhost:5173/sb");
  });
  it("uses the configured url otherwise", () => {
    expect(clientUrl(cfg, {}, "http://localhost:5173", true)).toBe(cfg.url);
    expect(clientUrl(cfg, { VITE_SUPABASE_PROXY: "0" }, "http://localhost:5173", true)).toBe(cfg.url);
  });
  it("ignores the proxy flag in production", () => {
    expect(clientUrl(cfg, { VITE_SUPABASE_PROXY: "1" }, "https://flight.somalabs.me", false)).toBe(cfg.url);
  });
});
