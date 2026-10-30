// Replays every case of core/fixtures/*.json through the WASM wrapper, with the
// same semantics as core/flightcore/tests/fixtures.rs.
import {
  computeAircraftStats,
  computePassport,
  computePassportDetail,
  computeStats,
  distanceKm,
  flightCategory,
  greatCircle,
} from "./flightcore.ts";
import type { Coord } from "./flightcore.ts";

function fixture(name: string) {
  const url = new URL(`../../../core/fixtures/${name}.json`, import.meta.url);
  // deno-lint-ignore no-explicit-any
  return JSON.parse(Deno.readTextFileSync(url)) as any;
}

function assert(cond: boolean, msg: string) {
  if (!cond) throw new Error(msg);
}

function deepEqual(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (typeof a !== "object" || typeof b !== "object" || !a || !b) return false;
  if (Array.isArray(a) !== Array.isArray(b)) return false;
  const ka = Object.keys(a);
  const kb = Object.keys(b);
  if (ka.length !== kb.length) return false;
  return ka.every((k) =>
    Object.hasOwn(b, k) &&
    deepEqual(
      (a as Record<string, unknown>)[k],
      (b as Record<string, unknown>)[k],
    )
  );
}

Deno.test("geo fixture: meta", () => {
  const m = fixture("geo").meta;
  assert(m.radius_km === 6371.0088, "radius");
  assert(m.invariants.segments_zero_clamps_to === 1, "clamp");
});

Deno.test("geo fixture: distances", () => {
  const g = fixture("geo");
  assert(g.distance_km.length > 0, "no distance cases");
  for (const c of g.distance_km) {
    const d = distanceKm(c.a, c.b);
    assert(
      Math.abs(d - c.expected) <= c.tolerance,
      `${c.name}: ${d} vs ${c.expected}`,
    );
  }
});

Deno.test("geo fixture: great circles", () => {
  const g = fixture("geo");
  const maxDelta: number = g.meta.invariants.neighbour_lon_delta_lt;
  const clamp: number = g.meta.invariants.segments_zero_clamps_to;
  assert(g.great_circle.length > 0, "no great circle cases");
  for (const c of g.great_circle) {
    const n = c.name;
    const p: Coord[] = greatCircle(c.a, c.b, c.segments);
    assert(p.length === c.expected_len, `${n}: len ${p.length}`);
    assert(p.length === Math.max(c.segments, clamp) + 1, `${n}: clamp`);
    assert(deepEqual(p[0], c.a), `${n}: first`);
    const last = p[p.length - 1];
    assert(last.lat === c.b.lat, `${n}: last lat`);
    const k = (last.lon - c.b.lon) / 360;
    assert(Math.abs(k - Math.round(k)) < 1e-9, `${n}: end lon not b mod 360`);
    for (let i = 1; i < p.length; i++) {
      assert(
        Math.abs(p[i].lon - p[i - 1].lon) < maxDelta,
        `${n}: neighbour jump at ${i}`,
      );
    }
    if (c.expected_last_lon != null) {
      assert(
        Math.abs(last.lon - c.expected_last_lon) < 1e-3,
        `${n}: last lon ${last.lon}`,
      );
    }
    for (const s of c.samples ?? []) {
      const q = p[s.index];
      assert(
        Math.abs(q.lat - s.lat) <= s.tolerance,
        `${n}[${s.index}] lat ${q.lat}`,
      );
      assert(
        Math.abs(q.lon - s.lon) <= s.tolerance,
        `${n}[${s.index}] lon ${q.lon}`,
      );
    }
    if (c.all_equal_a) {
      assert(p.every((q) => deepEqual(q, c.a)), `${n}: not all equal a`);
    }
  }
});

Deno.test("delay fixture: cases", () => {
  const f = fixture("delay_stats");
  const tol: number = f.meta.rules.avg_delay_tolerance;
  assert(f.cases.length > 0, "no delay cases");
  for (const c of f.cases) {
    const got = computeStats(c.rows);
    assert(!Number.isNaN(got.avgDelayMinutes), `${c.name}: NaN`);
    assert(
      Math.abs(got.avgDelayMinutes - c.expected.avgDelayMinutes) <= tol,
      `${c.name}: avg ${got.avgDelayMinutes} vs ${c.expected.avgDelayMinutes}`,
    );
    const g = { ...got, avgDelayMinutes: 0 };
    const e = { ...c.expected, avgDelayMinutes: 0 };
    assert(
      deepEqual(g, e),
      `${c.name}: ${JSON.stringify(g)} vs ${JSON.stringify(e)}`,
    );
  }
});

Deno.test("category fixture: cases", () => {
  const f = fixture("category");
  assert(f.cases.length > 0, "no category cases");
  for (const c of f.cases) {
    assert(
      flightCategory(c.ceiling_ft, c.visibility_sm) === c.expected,
      `${c.name}: ${
        flightCategory(c.ceiling_ft, c.visibility_sm)
      } vs ${c.expected}`,
    );
  }
});

Deno.test("passport fixture: cases", () => {
  const f = fixture("passport");
  assert(f.cases.length >= 20, "too few passport cases");
  for (const c of f.cases) {
    const got = computePassport(c.flights, c.year ?? undefined);
    assert(
      deepEqual(got, c.expected),
      `${c.name}: ${JSON.stringify(got)} vs ${JSON.stringify(c.expected)}`,
    );
  }
});

Deno.test("passport detail fixture: cases", () => {
  const f = fixture("passport_detail");
  const r = f.meta.rules;
  assert(r.earth_km === 40_075 && r.moon_km === 384_400, "earth, moon");
  assert(
    r.sun_km === 4_375_250 && r.connection_seconds_lt === 28_800,
    "sun, gap",
  );
  // deno-lint-ignore no-explicit-any
  const names = f.cases.map((c: any) => c.name);
  for (const n of ["empty", "single_flight", "sparse"]) {
    assert(names.includes(n), `missing case ${n}`);
  }
  for (const c of f.cases) {
    const got = computePassportDetail(
      c.flights,
      c.year ?? undefined,
      c.countries,
    );
    assert(
      deepEqual(got, c.expected),
      `${c.name}: ${JSON.stringify(got)} vs ${JSON.stringify(c.expected)}`,
    );
  }
});

Deno.test("aircraft fixture: cases", () => {
  const f = fixture("aircraft");
  // deno-lint-ignore no-explicit-any
  const names = f.cases.map((c: any) => c.name);
  for (
    const n of [
      "empty",
      "single_flight",
      "sparse",
      "single_aircraft",
      "seat_positions_every_layout",
      "unknown_family_seat",
      "decades_with_gap",
      "manufacturer_percent_rounding",
      "no_facts",
      "year_filter",
      "picked_positions_private_crew",
    ]
  ) {
    assert(names.includes(n), `missing case ${n}`);
  }
  for (const c of f.cases) {
    const got = computeAircraftStats(
      c.flights,
      c.year ?? undefined,
      c.types,
      c.facts,
      c.as_of,
    );
    assert(
      deepEqual(got, c.expected),
      `${c.name}: ${JSON.stringify(got)} vs ${JSON.stringify(c.expected)}`,
    );
  }
});

function throwsMessage(fn: () => unknown): string {
  try {
    fn();
  } catch (e) {
    assert(e instanceof Error, "not an Error");
    return (e as Error).message;
  }
  throw new Error("did not throw");
}

function expectError(fn: () => unknown, substring: string) {
  const m = throwsMessage(fn);
  assert(m.includes(substring), `message "${m}" lacks "${substring}"`);
}

Deno.test("malformed input throws Error with a specific message, never aborts", () => {
  // deno-lint-ignore no-explicit-any
  const bad = (v: unknown) => v as any;
  const z = { lat: 0, lon: 0 };
  expectError(() => distanceKm(bad({ lat: "x" }), z), "invalid coord a");
  expectError(() => distanceKm(z, bad(null)), "invalid coord b");
  expectError(() => greatCircle(bad(null), z, 4), "invalid coord a");
  expectError(() => greatCircle(z, bad({}), 4), "invalid coord b");
  expectError(() => greatCircle(z, z, 10_000_000), "invalid segments");
  expectError(() => greatCircle(z, z, -1), "invalid segments");
  expectError(() => greatCircle(z, z, 1.5), "invalid segments");
  expectError(() => computeStats(bad([{ ident: 1 }])), "invalid rows");
  expectError(() => computeStats(bad({})), "invalid rows");
  expectError(() => computePassport(bad("nope")), "invalid flights");
  expectError(() => computePassport([], 2 ** 31), "invalid year");
  expectError(() => computePassport([], 2023.5), "invalid year");
  expectError(
    () => computePassportDetail(bad("nope"), undefined, []),
    "invalid flights",
  );
  expectError(
    () => computePassportDetail([], undefined, bad([{ iso2: "FR" }])),
    "invalid countries",
  );
  expectError(() => computePassportDetail([], 2 ** 31, []), "invalid year");
  expectError(
    () => computeAircraftStats(bad("nope"), undefined, [], [], 0),
    "invalid flights",
  );
  expectError(
    () => computeAircraftStats([], undefined, bad([{ family: 1 }]), [], 0),
    "invalid types",
  );
  expectError(
    () => computeAircraftStats([], undefined, [], bad([{}]), 0),
    "invalid facts",
  );
  expectError(
    () => computeAircraftStats([], undefined, [], [], 1.5),
    "invalid asOf",
  );
  expectError(
    () => computeAircraftStats([], 2 ** 31, [], [], 0),
    "invalid year",
  );
  expectError(() => flightCategory(2 ** 31, 10), "invalid ceilingFt");
  expectError(() => flightCategory(1.5, 10), "invalid ceilingFt");
  expectError(() => flightCategory(null, NaN), "invalid visibilitySm");
  expectError(() => flightCategory(null, Infinity), "invalid visibilitySm");
  // still usable afterwards
  assert(flightCategory(null, 10) === "VFR", "alive after errors");
});

Deno.test("negative visibility is LIFR", () => {
  assert(flightCategory(null, -1) === "LIFR", "negative");
});

Deno.test("unknown timezone and empty input do not panic", () => {
  assert(computeStats([]).total === 0, "empty stats");
  assert(computePassport([]).flights === 0, "empty passport");
  const p = computePassport([{
    departed_at: 1_700_000_000,
    tz: "Not/AZone",
    ident: "X1",
    origin_icao: "KSFO",
    destination_icao: "KLAX",
    airline: null,
    aircraft_type: null,
    distance_km: 500,
    block_minutes: null,
    delay_minutes: 0,
    status: "completed",
  }], 2023);
  assert(p.flights === 1, "unknown tz falls back to UTC");
});
