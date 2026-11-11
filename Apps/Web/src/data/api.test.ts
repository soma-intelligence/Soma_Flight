import { describe, expect, it, vi } from "vitest";

const invoke = vi.fn();
vi.mock("./client", () => ({ getSupabase: () => ({ functions: { invoke } }) }));

import { ApiError, apiErrorFrom, callFunction } from "./api";

const cases: [number, string][] = [
  [401, "unauthorized"],
  [400, "invalid_request"],
  [404, "not_found"],
  [429, "rate_limited"],
  [403, "plan_limit"],
  [400, "out_of_window"],
  [503, "provider_unavailable"],
];

describe("apiErrorFrom", () => {
  it("maps each contract code and status", () => {
    for (const [status, code] of cases) {
      const e = apiErrorFrom(status, { error: { code, message: "m" } });
      expect(e).toBeInstanceOf(ApiError);
      expect(e.code).toBe(code);
      expect(e.status).toBe(status);
    }
  });

  it("turns an unknown code into provider_unavailable", () => {
    expect(apiErrorFrom(418, { error: { code: "teapot" } }).code).toBe("provider_unavailable");
  });

  it("falls back on the status when the body is not the backend's", () => {
    expect(apiErrorFrom(401, "<html>").code).toBe("unauthorized");
    expect(apiErrorFrom(404, null).code).toBe("not_found");
    expect(apiErrorFrom(429, undefined).code).toBe("rate_limited");
    expect(apiErrorFrom(502, {}).code).toBe("provider_unavailable");
  });
});

describe("callFunction", () => {
  it("returns data and passes method, query and body", async () => {
    invoke.mockResolvedValueOnce({ data: { ok: true }, error: null });
    const out = await callFunction<{ ok: boolean }>("follow-flight", {
      method: "POST",
      query: { a: "1" },
      body: { flightId: "x" },
    });
    expect(out).toEqual({ ok: true });
    expect(invoke).toHaveBeenCalledWith("follow-flight?a=1", { method: "POST", body: { flightId: "x" } });
  });

  it("throws ApiError built from an http error response", async () => {
    const response = new Response(JSON.stringify({ error: { code: "rate_limited", message: "slow" } }), { status: 429 });
    invoke.mockResolvedValueOnce({ data: null, error: Object.assign(new Error("http"), { context: response }) });
    await expect(callFunction("flight-lookup", { method: "POST", body: {} })).rejects.toMatchObject({
      code: "rate_limited",
      status: 429,
    });
  });

  it("maps a network failure to provider_unavailable", async () => {
    invoke.mockResolvedValueOnce({ data: null, error: new Error("Failed to fetch") });
    await expect(callFunction("flight-lookup", {})).rejects.toMatchObject({ code: "provider_unavailable" });
  });
});
