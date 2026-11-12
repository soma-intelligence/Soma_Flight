import { describe, expect, it, vi } from "vitest";

vi.mock("@/data/client", () => ({ getSupabase: () => { throw new Error("no server in this test"); } }));

import { makeQueryClient } from "./query";
import { clearCacheOnSignOut } from "./session";

type Listener = (event: string) => void;
function fakeAuth() {
  let listener: Listener = () => {};
  const unsubscribe = vi.fn();
  return {
    emit: (event: string) => listener(event),
    unsubscribe,
    auth: {
      onAuthStateChange: (cb: Listener) => {
        listener = cb;
        return { data: { subscription: { unsubscribe } } };
      },
    },
  };
}

describe("clearCacheOnSignOut", () => {
  it("empties the query cache on SIGNED_OUT only", () => {
    const qc = makeQueryClient();
    const a = fakeAuth();
    const stop = clearCacheOnSignOut(qc, a.auth as never);
    qc.setQueryData(["myFlights"], [{ id: "x" }]);
    a.emit("TOKEN_REFRESHED");
    expect(qc.getQueryData(["myFlights"])).toEqual([{ id: "x" }]);
    a.emit("SIGNED_OUT");
    expect(qc.getQueryData(["myFlights"])).toBeUndefined();
    expect(qc.getQueryCache().getAll()).toHaveLength(0);
    stop();
    expect(a.unsubscribe).toHaveBeenCalled();
  });
});

describe("makeQueryClient", () => {
  it("keeps the cache in memory and reloads lists on focus", () => {
    const q = makeQueryClient().getDefaultOptions().queries;
    expect(q?.refetchOnWindowFocus).toBe(true);
  });
});
