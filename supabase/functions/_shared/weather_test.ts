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

Deno.test("fetchWeather returns the app's Weather shape for KAUS", async () => {
  const seen: { url: string; ua: string | null }[] = [];
  const w = await fetchWeather("KAUS", fakeFetch(METAR, TAF, seen));
  assertEquals(seen.map((s) => s.url).sort(), [
    "https://aviationweather.gov/api/data/metar?ids=KAUS&format=json",
    "https://aviationweather.gov/api/data/taf?ids=KAUS&format=json",
  ]);
  assert(seen.every((s) => s.ua === WEATHER_USER_AGENT));

  assertEquals(w.metarRaw.startsWith("SPECI KAUS 291744Z VRB03KT 10SM"), true);
  assertEquals(w.observedAt, "2026-10-29T17:44:00.000Z");
  assertEquals(w.windDirDeg, null); // VRB has no direction
  assertEquals(w.windKt, 3);
  assertEquals(w.gustKt, null);
  assertEquals(w.visibilitySm, 10); // "10+" in the feed
  assertEquals(w.ceilingFt, 900); // lowest of BKN009 BKN026 BKN046 OVC130
  assertEquals(w.category, "IFR");
  assertEquals(w.tempC, 21.7);
  assertEquals(w.tafRaw?.startsWith("TAF KAUS 291730Z"), true);
  assertEquals(w.forecast.length, 5);
  assertEquals(w.forecast[0], {
    from: "2026-10-29T18:00:00.000Z",
    to: "2026-10-29T21:00:00.000Z",
    category: "MVFR",
    windDirDeg: 100,
    windKt: 3,
    gustKt: null,
    visibilitySm: 6, // "6+"
    ceilingFt: 2500,
  });
  assertEquals(w.forecast[4].ceilingFt, 900);
  assertEquals(w.forecast[4].visibilitySm, 3);
  assertEquals(w.forecast[4].category, "IFR");
});

Deno.test("fetchWeather keeps direction and gusts, calm wind has no direction", async () => {
  const metar = structuredClone(METAR);
  metar[0].wdir = 240;
  metar[0].wspd = 18;
  metar[0].wgst = 28;
  const w = await fetchWeather("KAUS", fakeFetch(metar));
  assertEquals([w.windDirDeg, w.windKt, w.gustKt], [240, 18, 28]);
  metar[0].wdir = 0;
  metar[0].wspd = 0;
  metar[0].wgst = null;
  const calm = await fetchWeather("KAUS", fakeFetch(metar));
  assertEquals([calm.windDirDeg, calm.windKt, calm.gustKt], [null, 0, null]);
});

Deno.test("fetchWeather takes the newest METAR and TAF, whatever the order", async () => {
  const older = structuredClone(METAR[0]);
  older.obsTime -= 3600;
  older.rawOb = "METAR KAUS OLD";
  const olderTaf = structuredClone(TAF[0]);
  olderTaf.issueTime = "2026-10-29T11:30:00.000Z";
  olderTaf.rawTAF = "TAF OLD";
  const w = await fetchWeather(
    "KAUS",
    fakeFetch([older, METAR[0]], [olderTaf, TAF[0]]),
  );
  assertEquals(w.metarRaw.startsWith("SPECI KAUS"), true);
  assertEquals(w.tafRaw?.startsWith("TAF KAUS"), true);
});

Deno.test("fetchWeather: a failed METAR is 503 even when the TAF works", async () => {
  const err = await assertRejects(
    () => fetchWeather("KAUS", fakeFetch(null, TAF)),
    ApiError,
  );
  assertEquals([err.code, err.status], ["provider_unavailable", 503]);
});

Deno.test("fetchWeather: a missing TAF is an empty forecast, no METAR is 404", async () => {
  const noTaf = await fetchWeather("KAUS", fakeFetch(METAR, null));
  assertEquals([noTaf.tafRaw, noTaf.forecast], [null, []]);
  const none = await assertRejects(
    () => fetchWeather("KAUS", fakeFetch([], [])),
    ApiError,
  );
  assertEquals([none.code, none.status], ["not_found", 404]);
});

Deno.test("fetchWeather: no visibility falls back to the feed category, else unusable", async () => {
  const metar = structuredClone(METAR);
  metar[0].visib = null;
  assertEquals((await fetchWeather("KAUS", fakeFetch(metar))).category, "IFR");
  delete metar[0].fltCat;
  await assertRejects(() => fetchWeather("KAUS", fakeFetch(metar)), ApiError);
});

Deno.test("forecast periods without a time or a category are left out", async () => {
  const taf = structuredClone(TAF);
  taf[0].fcsts[1].timeTo = null;
  taf[0].fcsts[2].visib = null;
  const w = await fetchWeather("KAUS", fakeFetch(METAR, taf));
  assertEquals(w.forecast.length, 3);
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
