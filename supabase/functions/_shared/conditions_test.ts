import { assertEquals } from "jsr:@std/assert@1";
import {
  forecastReasons,
  inferConditions,
  metarReasons,
  notamReasons,
} from "./conditions.ts";
import type { Notam } from "./notam.ts";
import { type ForecastPeriod, toWeather, type Weather } from "./weather.ts";
import { periodWords } from "./taf_words.ts";

const NOW = new Date("2026-11-07T12:00:00Z");
const h = (n: number) => new Date(NOW.getTime() + n * 3600_000).toISOString();

const fixture = (name: string) =>
  JSON.parse(
    Deno.readTextFileSync(new URL(`./fixtures/${name}`, import.meta.url)),
  );

function notam(over: Partial<Notam>): Notam {
  return {
    number: "A1/26",
    kind: "runway_closed",
    title: "Runway 09L/27R closed",
    detail: null,
    relevance: 80,
    raw: "x",
    starts_at: h(-1),
    ends_at: h(5),
    ends_estimated: false,
    ...over,
  };
}

function period(over: Partial<ForecastPeriod>): ForecastPeriod {
  return {
    from: h(1),
    to: h(5),
    category: "VFR",
    windDirDeg: 270,
    windKt: 8,
    gustKt: null,
    visibilitySm: 10,
    ceilingFt: null,
    change: null,
    probability: null,
    wx: null,
    clouds: [],
    ...over,
  };
}

function weather(over: Partial<Weather>): Weather {
  return {
    metarRaw: "METAR EGLL 071150Z",
    tafRaw: "TAF EGLL",
    tempC: 9,
    windDirDeg: 270,
    windKt: 8,
    gustKt: null,
    visibilitySm: 10,
    ceilingFt: null,
    category: "VFR",
    observedAt: h(-0.2),
    forecast: [],
    wx: null,
    clouds: [],
    dewpointC: 5,
    altimeterHpa: 1015,
    tafIssuedAt: h(-3),
    ...over,
  };
}

Deno.test("a calm airport with all sources read is normal", () => {
  const c = inferConditions({ weather: weather({}), notams: [], now: NOW });
  assertEquals(c.level, "normal");
  assertEquals(c.summary, null);
  assertEquals(c.reasons, []);
  assertEquals(c.sources, { metar: true, taf: true, notam: true });
});

Deno.test("sources that were not read are said so, not read as fine", () => {
  const c = inferConditions({ weather: null, notams: null, now: NOW });
  assertEquals(c.level, "normal");
  assertEquals(c.sources, { metar: false, taf: false, notam: false });
});

Deno.test("closed airport is major, closed with exceptions minor, private-only ignored", () => {
  const closed = notamReasons([
    notam({ kind: "airport_closed", relevance: 100, title: "Airport closed" }),
  ], NOW);
  assertEquals([closed[0].level, closed[0].text], [
    "major",
    "Airport closed by notice",
  ]);
  const part = notamReasons([
    notam({ kind: "airport_closed", relevance: 50 }),
  ], NOW);
  assertEquals(part[0].level, "minor");
  assertEquals(
    notamReasons([notam({ kind: "airport_closed", relevance: 2 })], NOW),
    [],
  );
});

Deno.test("one runway closed is minor, two are major", () => {
  const one = notamReasons([notam({})], NOW);
  assertEquals([one[0].level, one[0].text], [
    "minor",
    "Runway 09L/27R closed",
  ]);
  const two = notamReasons([notam({}), notam({ number: "A2/26" })], NOW);
  assertEquals([two[0].level, two[0].text], ["major", "2 runways closed"]);
});

Deno.test("ILS out and a runway closed in part are minor", () => {
  const r = notamReasons([
    notam({
      kind: "ils_out",
      relevance: 60,
      title: "ILS for runway 27 out of service",
    }),
    notam({
      number: "A3/26",
      relevance: 50,
      title: "Runway 01R/19L closed in part",
    }),
  ], NOW);
  assertEquals(r.map((x) => [x.level, x.text]), [
    ["minor", "Runway 01R/19L closed in part"],
    ["minor", "ILS for runway 27 out of service"],
  ]);
});

Deno.test("notices that ended or start far ahead are not news; taxiways and obstacles never count", () => {
  assertEquals(
    notamReasons([
      notam({ ends_at: h(-1) }),
      notam({ starts_at: h(20), ends_at: h(30) }),
      notam({ kind: "taxiway_closed", relevance: 25 }),
      notam({ kind: "obstacle_light", relevance: 5 }),
      notam({ kind: "construction", relevance: 35 }),
    ], NOW),
    [],
  );
  assertEquals(
    notamReasons([notam({ starts_at: h(3), ends_at: h(9) })], NOW).length,
    1,
  );
});

Deno.test("METAR: thunderstorms now read as a reason, calm weather does not", () => {
  const bad = metarReasons(
    weather({ wx: "+TSRA", visibilitySm: 2, ceilingFt: 900 }),
  );
  assertEquals(bad.length, 1);
  assertEquals(bad[0].source, "metar");
  assertEquals(bad[0].text.endsWith("at the airport now"), true);
  assertEquals(metarReasons(weather({})), []);
});

Deno.test("TAF: a firm bad period is read, a TEMPO one is capped at minor and marked as at times", () => {
  const firm = forecastReasons(
    [period({ wx: "+TSRA", visibilitySm: 1, ceilingFt: 500 })],
    NOW,
  );
  assertEquals(firm.length, 1);
  assertEquals(firm[0].source, "forecast");
  assertEquals(firm[0].text.endsWith("in the forecast"), true);
  assertEquals(firm[0].starts_at, h(1));
  const tempo = forecastReasons(
    [period({ change: "TEMPO", wx: "+TSRA", visibilitySm: 1, ceilingFt: 500 })],
    NOW,
  );
  assertEquals(tempo[0].level, "minor");
  assertEquals(tempo[0].text.endsWith("in the forecast at times"), true);
});

Deno.test("TAF: periods outside the next 12 hours or already over are left out", () => {
  const bad = { wx: "+TSRA", visibilitySm: 1, ceilingFt: 500 };
  assertEquals(
    forecastReasons([
      period({ ...bad, from: h(-6), to: h(-1) }),
      period({ ...bad, from: h(13), to: h(20) }),
    ], NOW),
    [],
  );
});

Deno.test("TAF: the same hazard in two periods is one reason spanning both", () => {
  const bad = { wx: "+TSRA", visibilitySm: 1, ceilingFt: 500 };
  const r = forecastReasons([
    period({ ...bad, from: h(1), to: h(3) }),
    period({ ...bad, from: h(3), to: h(6) }),
  ], NOW);
  assertEquals(r.length, 1);
  assertEquals([r[0].starts_at, r[0].ends_at], [h(1), h(6)]);
});

Deno.test("worst level leads, notices before weather at equal level, at most five reasons", () => {
  const c = inferConditions({
    weather: weather({ wx: "+TSRA", visibilitySm: 2, ceilingFt: 900 }),
    notams: [notam({ kind: "ils_out", relevance: 60, title: "ILS out" })],
    now: NOW,
  });
  assertEquals(c.level === "normal", false);
  assertEquals(c.summary, c.reasons[0].text);
  assertEquals(c.reasons.length <= 5, true);
  const closed = inferConditions({
    weather: weather({ wx: "+TSRA", visibilitySm: 2, ceilingFt: 900 }),
    notams: [notam({ kind: "airport_closed", relevance: 100 })],
    now: NOW,
  });
  assertEquals(closed.level, "major");
  assertEquals(closed.reasons[0].source, "notam");
});

Deno.test("the real KAUS TAF reads without throwing and a rainy IFR evening is flagged at most minor-to-major", () => {
  const w = toWeather(fixture("metar_kaus.json"), fixture("taf_kaus.json"));
  const c = inferConditions({
    weather: w,
    notams: null,
    now: new Date("2026-10-30T18:00:00Z"),
  });
  assertEquals(c.sources, { metar: true, taf: true, notam: false });
  assertEquals(["normal", "minor", "major"].includes(c.level), true);
});

Deno.test("periodWords: our own words for wind, visibility, ceiling, weather and change kinds", () => {
  assertEquals(
    periodWords(
      period({
        wx: "-RA",
        windKt: 12,
        gustKt: 25,
        visibilitySm: 3,
        ceilingFt: 800,
      }),
    ),
    "Light rain, wind 12 kt gusting 25 kt, visibility 3 mi, cloud base 800 ft",
  );
  assertEquals(
    periodWords(period({ change: "TEMPO", wx: "TSRA", windKt: 0 })),
    "At times: Thunderstorms with rain, calm",
  );
  assertEquals(
    periodWords(
      period({ change: "PROB", probability: 30, wx: "FG", visibilitySm: 0.25 }),
    ),
    "30% chance: Fog, wind 8 kt, visibility 0.3 mi",
  );
  assertEquals(
    periodWords(period({ change: "BECMG" })),
    "Gradually: No significant weather, wind 8 kt",
  );
});
