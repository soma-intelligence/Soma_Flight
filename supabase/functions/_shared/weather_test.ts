import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { ApiError } from "./errors.ts";
import { flightCategory } from "./flightcore.ts";
import {
  ceilingOf,
  fetchWeather,
  parseVisibility,
  WEATHER_USER_AGENT,
} from "./weather.ts";

const fixture = (name: string) =>
  JSON.parse(
    Deno.readTextFileSync(new URL(`./fixtures/${name}`, import.meta.url)),
  );
const METAR = fixture("metar_kaus.json");
const TAF = fixture("taf_kaus.json");

function fakeFetch(
  metar: unknown = METAR,
  taf: unknown = TAF,
  seen: { url: string; ua: string | null }[] = [],
): typeof fetch {
  return ((input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    seen.push({ url, ua: new Headers(init?.headers).get("user-agent") });
    const body = url.includes("/metar?") ? metar : taf;
    if (body === null) {
      return Promise.resolve(new Response("down", { status: 503 }));
    }
    return Promise.resolve(
      new Response(JSON.stringify(body), {
        headers: { "content-type": "application/json" },
      }),
    );
  }) as typeof fetch;
}

Deno.test("flightCategory via the core: FAA thresholds", () => {
  assertEquals(flightCategory(null, 10), "VFR");
  assertEquals(flightCategory(800, 10), "IFR");
  assertEquals(flightCategory(2500, 10), "MVFR");
  assertEquals(flightCategory(300, 0.5), "LIFR");
});

Deno.test("fetchWeather parses the KAUS fixtures", async () => {
  const seen: { url: string; ua: string | null }[] = [];
  const w = await fetchWeather("KAUS", fakeFetch(METAR, TAF, seen));
  assertEquals(seen.map((s) => s.url).sort(), [
    "https://aviationweather.gov/api/data/metar?ids=KAUS&format=json",
    "https://aviationweather.gov/api/data/taf?ids=KAUS&format=json",
  ]);
  assert(seen.every((s) => s.ua === WEATHER_USER_AGENT));

  const m = w.metar!;
  assertEquals(m.raw.startsWith("SPECI KAUS 291744Z VRB03KT 10SM"), true);
  assertEquals(m.observedAt, "2026-10-29T17:44:00.000Z");
  assertEquals(m.windDirection, "VRB");
  assertEquals(m.windKt, 3);
  assertEquals(m.gustKt, null);
  assertEquals(m.visibilitySm, 10); // "10+" in the feed
  assertEquals(m.ceilingFt, 900); // lowest of BKN009 BKN026 BKN046 OVC130
  assertEquals(m.category, "IFR");
  assertEquals(m.weather, "-RA");
  assertEquals(m.clouds.length, 4);

  const t = w.taf!;
  assertEquals(t.raw.startsWith("TAF KAUS 291730Z"), true);
  assertEquals(t.periods.length, 5);
  assertEquals(t.periods[0].windKt, 3);
  assertEquals(t.periods[0].visibilitySm, 6); // "6+"
  assertEquals(t.periods[0].ceilingFt, 2500);
  assertEquals(t.periods[0].category, "MVFR");
  assertEquals(t.periods[1].change, "FM");
  assertEquals(t.periods[4].ceilingFt, 900);
  assertEquals(t.periods[4].visibilitySm, 3);
  assertEquals(t.periods[4].category, "IFR");
});

Deno.test("fetchWeather keeps gusts", async () => {
  const metar = structuredClone(METAR);
  metar[0].wdir = 240;
  metar[0].wspd = 18;
  metar[0].wgst = 28;
  const w = await fetchWeather("KAUS", fakeFetch(metar));
  assertEquals(w.metar!.windDirection, 240);
  assertEquals(w.metar!.windKt, 18);
  assertEquals(w.metar!.gustKt, 28);
});

Deno.test("fetchWeather: a missing TAF is null, both failing is 503", async () => {
  const noTaf = await fetchWeather("KAUS", fakeFetch(METAR, null));
  assertEquals(noTaf.taf, null);
  assertEquals(noTaf.metar?.windKt, 3);
  const empty = await fetchWeather("KAUS", fakeFetch([], []));
  assertEquals(empty, { icao: "KAUS", metar: null, taf: null });
  const err = await assertRejects(
    () => fetchWeather("KAUS", fakeFetch(null, null)),
    ApiError,
  );
  assertEquals(err.code, "provider_unavailable");
  assertEquals(err.status, 503);
});

Deno.test("ceiling is the lowest BKN, OVC or VV layer; few and scattered do not count", () => {
  assertEquals(
    ceilingOf([
      { cover: "FEW", baseFt: 200 },
      { cover: "SCT", baseFt: 400 },
      { cover: "BKN", baseFt: 3000 },
      { cover: "OVC", baseFt: 1200 },
    ]),
    1200,
  );
  assertEquals(ceilingOf([{ cover: "SCT", baseFt: 400 }]), null);
  assertEquals(ceilingOf([{ cover: "BKN", baseFt: 3000 }], 200), 200);
});

Deno.test("visibility strings", () => {
  assertEquals(parseVisibility("10+"), 10);
  assertEquals(parseVisibility("6+"), 6);
  assertEquals(parseVisibility(3), 3);
  assertEquals(parseVisibility("1/2"), 0.5);
  assertEquals(parseVisibility("1 1/2"), 1.5);
  assertEquals(parseVisibility("P6SM"), 6);
  assertEquals(parseVisibility(null), null);
  assertEquals(parseVisibility("abc"), null);
});
