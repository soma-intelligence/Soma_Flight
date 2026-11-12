import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, expect, it, vi } from "vitest";

const wasmPath = path.join(import.meta.dirname, "pkg/flightcore_wasm_bg.wasm");
const geo = JSON.parse(
  await readFile(path.join(import.meta.dirname, "../../../../core/fixtures/geo.json"), "utf8"),
);

async function freshCore() {
  vi.resetModules();
  const core = await import("./flightcore");
  await core.initCore(await readFile(wasmPath));
  return core;
}

describe("flightcore wasm", () => {
  it("distanceKm matches core/fixtures (JFK to LHR, SFO to HND, CDG to SFO)", async () => {
    const { distanceKm } = await freshCore();
    for (const c of geo.distance_km) {
      expect(Math.abs(distanceKm(c.a, c.b) - c.expected)).toBeLessThanOrEqual(Math.max(c.tolerance, 0.5));
    }
  });

  it("greatCircle returns segments + 1 points starting at a and ending at b", async () => {
    const { greatCircle } = await freshCore();
    const c = geo.great_circle[0];
    const pts = greatCircle(c.a, c.b, c.segments);
    expect(pts).toHaveLength(c.segments + 1);
    expect(pts[0]).toEqual(c.a);
    expect(pts.at(-1)!.lat).toBeCloseTo(c.b.lat, 6);
    for (const s of c.samples) {
      expect(Math.abs(pts[s.index].lat - s.lat)).toBeLessThan(s.tolerance);
      expect(Math.abs(pts[s.index].lon - s.lon)).toBeLessThan(s.tolerance);
    }
  });

  it("greatCircle surfaces an error as a thrown Error", async () => {
    const { greatCircle } = await freshCore();
    expect(() => greatCircle({ lat: 0, lon: 0 }, { lat: 1, lon: 1 }, 10_000_000)).toThrow(/segments/);
  });

  it("initCore twice loads once", async () => {
    vi.resetModules();
    const spy = vi.spyOn(WebAssembly, "instantiate");
    const core = await import("./flightcore");
    const bytes = await readFile(wasmPath);
    await Promise.all([core.initCore(bytes), core.initCore(bytes)]);
    await core.initCore(bytes);
    expect(spy).toHaveBeenCalledTimes(1);
    spy.mockRestore();
  });

  it("flightCategory reads ceiling and visibility into VFR, MVFR, IFR or LIFR", async () => {
    const { flightCategory } = await freshCore();
    expect(flightCategory(null, 10)).toBe("VFR");
    expect(flightCategory(2500, 10)).toBe("MVFR");
    expect(flightCategory(900, 10)).toBe("IFR");
    expect(flightCategory(300, 0.5)).toBe("LIFR");
  });
});
