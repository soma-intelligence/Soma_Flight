// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

type Init = { authorizationCallback: (done: (t: string) => void) => void };

let scripts: HTMLScriptElement[];
let events: string[];
let initCalls: Init[];

beforeEach(() => {
  vi.resetModules();
  scripts = [];
  events = [];
  initCalls = [];
  delete window.mapkit;
  vi.spyOn(document.head, "appendChild").mockImplementation(<T extends Node>(n: T): T => {
    scripts.push(n as unknown as HTMLScriptElement);
    events.push("script");
    return n;
  });
});
afterEach(() => vi.restoreAllMocks());

function installFakeMapKit() {
  window.mapkit = { init: (o: Init) => initCalls.push(o) } as never;
}

describe("loadMapKit", () => {
  it("fetches the token before inserting the script, and inserts it once across two calls", async () => {
    const { loadMapKit, MAPKIT_SRC } = await import("./loadMapKit");
    const fetchToken = vi.fn(async () => {
      events.push("token");
      return "t1";
    });
    const a = loadMapKit(fetchToken);
    const b = loadMapKit(fetchToken);
    await vi.waitFor(() => expect(scripts).toHaveLength(1));
    expect(events).toEqual(["token", "script"]);
    expect(scripts[0].src).toBe(MAPKIT_SRC);
    installFakeMapKit();
    scripts[0].onload?.(new Event("load"));
    expect(await a).toBe(await b);
    expect(scripts).toHaveLength(1);
    expect(fetchToken).toHaveBeenCalledTimes(1);
  });

  it("does not insert the script when the token fetch fails, and a retry fetches again", async () => {
    const { loadMapKit } = await import("./loadMapKit");
    const fetchToken = vi.fn().mockRejectedValueOnce(new Error("503")).mockResolvedValue("t");
    await expect(loadMapKit(fetchToken)).rejects.toThrow("503");
    expect(scripts).toHaveLength(0);
    const again = loadMapKit(fetchToken);
    await vi.waitFor(() => expect(scripts).toHaveLength(1));
    installFakeMapKit();
    scripts[0].onload?.(new Event("load"));
    await again;
    expect(fetchToken).toHaveBeenCalledTimes(2);
  });

  it("clears its state when the script fails to load, so a retry inserts the script again", async () => {
    const { loadMapKit } = await import("./loadMapKit");
    const fetchToken = vi.fn(async () => "t");
    const first = loadMapKit(fetchToken);
    await vi.waitFor(() => expect(scripts).toHaveLength(1));
    scripts[0].onerror?.(new Event("error"));
    await expect(first).rejects.toThrow();
    const second = loadMapKit(fetchToken);
    await vi.waitFor(() => expect(scripts).toHaveLength(2));
    installFakeMapKit();
    scripts[1].onload?.(new Event("load"));
    await second;
  });

  it("hands the first token to done, then fetches again on later authorization calls", async () => {
    const { loadMapKit } = await import("./loadMapKit");
    const fetchToken = vi.fn().mockResolvedValueOnce("first").mockResolvedValueOnce("second");
    const p = loadMapKit(fetchToken);
    await vi.waitFor(() => expect(scripts).toHaveLength(1));
    installFakeMapKit();
    scripts[0].onload?.(new Event("load"));
    await p;
    const done = vi.fn();
    initCalls[0].authorizationCallback(done);
    expect(done).toHaveBeenLastCalledWith("first");
    expect(fetchToken).toHaveBeenCalledTimes(1);
    initCalls[0].authorizationCallback(done);
    await vi.waitFor(() => expect(done).toHaveBeenLastCalledWith("second"));
    expect(fetchToken).toHaveBeenCalledTimes(2);
  });
});
