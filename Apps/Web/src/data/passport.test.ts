import { readFile } from "node:fs/promises";
import path from "node:path";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ApiError } from "./api";

const insertSelect = vi.fn();
const insert = vi.fn((_body: unknown) => ({ select: insertSelect }));
const deleteSelect = vi.fn();
const eq = vi.fn((_c: string, _v: string) => ({ select: deleteSelect }));
const del = vi.fn(() => ({ eq }));
const order = vi.fn();
const select = vi.fn((_cols: string) => ({ order }));
const from = vi.fn((_t: string) => ({ select, insert, delete: del }));
let fakes = false;

vi.mock("./client", () => ({ getSupabase: () => ({ from }) }));
vi.mock("./flights", () => ({ useFakes: () => fakes }));

import { computePassport, initCore, type CorePastFlight } from "@/core/flightcore";
import { airportDir } from "@/test/airportDir";
import {
  addPastFlight,
  decodePastFlight,
  deletePastFlight,
  exportFileName,
  fetchPastFlights,
  noonAt,
  pastFlightsCsv,
  pastFlightsJson,
  toCore,
  validateNewFlight,
  type PastFlight,
} from "./passport";

const root = path.join(import.meta.dirname, "../../../..");
await initCore(await readFile(path.join(import.meta.dirname, "../core/pkg/flightcore_wasm_bg.wasm")));

const row = {
  id: "aaaaaaaa-0000-4000-8000-000000000001",
  date: "2025-03-14T20:00:00+00:00",
  ident: "UA1",
  origin_icao: "KSFO",
  destination_icao: "KJFK",
  airline: "United",
  aircraft_type: "B739",
  registration: null,
  seat: "23A",
  distance_km: 4150,
  block_minutes: 330,
  delay_minutes: 5,
  status: "completed",
  origin_tz: "America/Los_Angeles",
  origin_country: "US",
  destination_country: "US",
  source: "manual",
};

function past(over: Partial<PastFlight> = {}): PastFlight {
  return { ...decodePastFlight(row), ...over };
}

beforeEach(() => {
  vi.clearAllMocks();
  fakes = false;
});

describe("decodePastFlight", () => {
  it("reads a row into camelCase with a Date", () => {
    const f = past();
    expect(f.date).toEqual(new Date("2025-03-14T20:00:00Z"));
    expect(f.originIcao).toBe("KSFO");
    expect(f.distanceKm).toBe(4150);
    expect(f.registration).toBeNull();
    expect(f.source).toBe("manual");
  });
  it("rejects a row without an id or a date", () => {
    expect(() => decodePastFlight({ ...row, id: undefined })).toThrow();
    expect(() => decodePastFlight({ ...row, date: "nope" })).toThrow();
  });
});

describe("passport stats", () => {
  it("toCore + computePassport match a core/fixtures/passport.json case", async () => {
    const fx = JSON.parse(await readFile(path.join(root, "core/fixtures/passport.json"), "utf8"));
    const c = fx.cases.find((x: { name: string }) => x.name === "year_filter_2025");
    const asRows = (c.flights as CorePastFlight[]).map((f, i) =>
      decodePastFlight({
        id: `bbbbbbbb-0000-4000-8000-${String(i).padStart(12, "0")}`,
        date: new Date(f.departed_at * 1000).toISOString(),
        ident: f.ident,
        origin_icao: f.origin_icao,
        destination_icao: f.destination_icao,
        airline: f.airline,
        aircraft_type: f.aircraft_type,
        distance_km: f.distance_km,
        block_minutes: f.block_minutes,
        delay_minutes: f.delay_minutes,
        status: f.status,
        origin_tz: f.tz,
        source: "manual",
      }),
    );
    expect(computePassport(toCore(asRows, airportDir), c.year)).toEqual(c.expected);
  });

  it("toCore takes the zone from the row, then the airport, then UTC, and fills countries from airports", () => {
    const [a, b] = toCore(
      [
        past({ originTz: null, originCountry: null, destinationCountry: null }),
        past({ originTz: null, originIcao: "ZZZZ", destinationIcao: "YYYY", originCountry: null }),
      ],
      airportDir,
    );
    expect(a.tz).toBe("America/Los_Angeles");
    expect(a.origin_country).toBe("US");
    expect(a.destination_country).toBe("US");
    expect(b.tz).toBe("UTC");
    expect(a.departed_at).toBe(Date.parse("2025-03-14T20:00:00Z") / 1000);
  });
});

describe("fetchPastFlights", () => {
  it("reads past_flights newest first and skips a bad row", async () => {
    order.mockResolvedValueOnce({ data: [row, { id: "bad" }], error: null });
    const out = await fetchPastFlights();
    expect(from).toHaveBeenCalledWith("past_flights");
    expect(select.mock.calls[0]![0]).toContain("origin_icao");
    expect(order).toHaveBeenCalledWith("date", { ascending: false });
    expect(out).toHaveLength(1);
  });
  it("throws an ApiError when the read fails", async () => {
    order.mockResolvedValueOnce({ data: null, error: { code: "PGRST301", message: "jwt" } });
    await expect(fetchPastFlights()).rejects.toMatchObject({ code: "unauthorized" });
  });
});

describe("deletePastFlight", () => {
  it("deletes the row by id", async () => {
    deleteSelect.mockResolvedValueOnce({ data: [{ id: row.id }], error: null });
    await deletePastFlight(row.id);
    expect(from).toHaveBeenCalledWith("past_flights");
    expect(eq).toHaveBeenCalledWith("id", row.id);
  });
  it("reports a delete that matched no row as not_found", async () => {
    deleteSelect.mockResolvedValueOnce({ data: [], error: null });
    await expect(deletePastFlight(row.id)).rejects.toBeInstanceOf(ApiError);
    deleteSelect.mockResolvedValueOnce({ data: [], error: null });
    await expect(deletePastFlight(row.id)).rejects.toMatchObject({ code: "not_found" });
  });
  it("fakes mode removes the row from the local list only", async () => {
    fakes = true;
    const before = await fetchPastFlights();
    const victim = before[0]!;
    await deletePastFlight(victim.id);
    const after = await fetchPastFlights();
    expect(after.map((f) => f.id)).not.toContain(victim.id);
    expect(after).toHaveLength(before.length - 1);
    expect(from).not.toHaveBeenCalled();
  });
});

describe("addPastFlight", () => {
  it("inserts a manual row the contract accepts, noon at the origin, derived columns null, no user_id", async () => {
    insertSelect.mockResolvedValueOnce({ data: [row], error: null });
    const out = await addPastFlight({ ident: "ua 1", day: "2025-03-14", from: "sfo", to: "KJFK" }, airportDir);
    const body = insert.mock.calls[0]![0] as Record<string, unknown>;
    expect(body).toMatchObject({
      ident: "UA1",
      origin_icao: "KSFO",
      destination_icao: "KJFK",
      date: "2025-03-14T19:00:00.000Z",
      source: "manual",
      status: "completed",
      delay_minutes: 0,
      distance_km: null,
      origin_tz: null,
      origin_country: null,
      destination_country: null,
    });
    expect(body).not.toHaveProperty("user_id");
    expect(body.id).toMatch(/^[0-9a-f-]{36}$/);
    expect(out.ident).toBe("UA1");
  });
  it("fakes mode adds to the local list only", async () => {
    fakes = true;
    const out = await addPastFlight({ ident: "AF84", day: "2025-06-01", from: "CDG", to: "SFO" }, airportDir);
    expect(out.originIcao).toBe("LFPG");
    expect(out.source).toBe("manual");
    expect((await fetchPastFlights()).map((f) => f.id)).toContain(out.id);
    expect(insert).not.toHaveBeenCalled();
  });
});

describe("noonAt", () => {
  it("is noon local time in the zone", () => {
    expect(noonAt("2025-03-14", "America/Los_Angeles").toISOString()).toBe("2025-03-14T19:00:00.000Z");
    expect(noonAt("2025-01-14", "America/Los_Angeles").toISOString()).toBe("2025-01-14T20:00:00.000Z");
    expect(noonAt("2025-03-14", "Asia/Tokyo").toISOString()).toBe("2025-03-14T03:00:00.000Z");
    expect(noonAt("2025-03-14", null).toISOString()).toBe("2025-03-14T12:00:00.000Z");
  });
});

describe("validateNewFlight", () => {
  const now = new Date("2026-11-11T12:00:00Z");
  it("accepts a good flight and normalises it", () => {
    const r = validateNewFlight({ ident: " ua 990 ", day: "2026-11-01", from: "sfo", to: "jfk" }, airportDir, now);
    expect(r).toEqual({ ok: true, value: { ident: "UA990", from: "KSFO", to: "KJFK", day: "2026-11-01" } });
  });
  it("names each field that does not read, with the app's lines", () => {
    const r = validateNewFlight({ ident: "9", day: "2099-01-01", from: "", to: "" }, airportDir, now);
    expect(r).toMatchObject({ ok: false });
    if (r.ok) return;
    expect(r.errors.date).toBe("Pick a day that has already come.");
    expect(r.errors.origin).toBe("Pick the airport you left from.");
    expect(r.errors.destination).toBe("Pick the airport you flew to.");
    expect(r.errors.ident).toBe("A flight number reads like UA990 or AF84.");
  });
  it("refuses the same airport twice", () => {
    const r = validateNewFlight({ ident: "", day: "2026-11-01", from: "SFO", to: "KSFO" }, airportDir, now);
    expect(r).toMatchObject({ ok: false, errors: { sameAirports: "The flight has to land somewhere else." } });
  });
});

describe("export", () => {
  it("CSV header is exactly PastFlightExport.swift's", async () => {
    const swift = await readFile(
      path.join(root, "Packages/FlightKit/Sources/FlightKit/Services/PastFlightExport.swift"),
      "utf8",
    );
    const legacy = /legacyCsvHeader = "([^"]+)"/.exec(swift)![1]!;
    const header = pastFlightsCsv([]).replace(/^﻿/, "");
    expect(header).toBe(`${legacy},arrival_delay_minutes,departure_delay_minutes`);
  });
  it("CSV rows: BOM, CRLF, ISO UTC date, defused text, quoted commas, empty for missing", () => {
    const csv = pastFlightsCsv([
      past({ ident: "=EVIL", airline: 'A, "B"', registration: null, blockMinutes: null }),
    ]);
    expect(csv.startsWith("﻿date,flight,")).toBe(true);
    const lines = csv.slice(1).split("\r\n");
    expect(lines).toHaveLength(2);
    expect(lines[1]).toBe(`2025-03-14T20:00:00Z,'=EVIL,KSFO,KJFK,"A, ""B""",B739,,23A,4150,,5,completed,,`);
  });
  it("JSON is snake_case, sorted keys, no nulls, whole-second UTC dates, trailing newline", () => {
    const text = pastFlightsJson([past()]);
    expect(text.endsWith("\n")).toBe(true);
    const [one] = JSON.parse(text);
    expect(one.date).toBe("2025-03-14T20:00:00Z");
    expect(one.origin_icao).toBe("KSFO");
    expect(one).not.toHaveProperty("registration");
    expect(Object.keys(one)).toEqual([...Object.keys(one)].sort());
  });
  it("names the file after the local day", () => {
    expect(exportFileName("csv", new Date(2026, 10, 11, 9))).toBe("soma-flight-history-2026-11-11.csv");
    expect(exportFileName("json", new Date(2026, 0, 2))).toBe("soma-flight-history-2026-01-02.json");
  });
});
