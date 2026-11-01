// airport-weather without a database or the network: fetch, the airports table and the FAA feed are
// fakes. Covers the batch request, the per-airport cache, NOAA down (stale, then null), FAA programs
// only at US airports, the words, the headers and the request checks.
import { assert, assertEquals } from "jsr:@std/assert@1";
import type { AirportRow } from "../_shared/airport_codes.ts";
import type { Program } from "../_shared/faa_nas.ts";
import {
  type Answer,
  CACHE_CONTROL,
  CACHE_TTL_MS,
  type Deps,
  handler,
  MAX_AIRPORTS,
  newestByStation,
  STALE_MAX_MS,
  toConditions,
  WeatherCache,
} from "./handler.ts";

const NOW = new Date("2026-10-31T20:10:00Z");
const ROWS: AirportRow[] = [
  { icao: "KSFO", iata: "SFO", country: "US" },
  { icao: "KAUS", iata: "AUS", country: "US" },
  { icao: "EGLL", iata: "LHR", country: "GB" },
];

const verifier = {
  auth: {
    getUser: (jwt: string) =>
      Promise.resolve(
        jwt === "bad"
          ? { data: { user: null }, error: { message: "bad" } }
          : { data: { user: { id: jwt } }, error: null },
      ),
  },
};

const kaus = JSON.parse(
  Deno.readTextFileSync(
    new URL("../_shared/fixtures/metar_kaus.json", import.meta.url),
  ),
)[0];
const ksfo = {
  icaoId: "KSFO",
  obsTime: Math.floor(NOW.getTime() / 1000) - 600,
  temp: 17,
  dewp: 11,
  wdir: 290,
  wspd: 9,
  wgst: null,
  visib: "10+",
  altim: 1016,
  rawOb: "METAR KSFO 312000Z 29009KT 10SM FEW012 SCT200 17/11 A3001",
  clouds: [{ cover: "FEW", base: 1200 }, { cover: "SCT", base: 20000 }],
  fltCat: "VFR",
};
const older = { ...ksfo, obsTime: ksfo.obsTime - 3600, temp: 3 };

/** A fake NOAA that answers `list` (null: a 502) and keeps the URLs it was asked. */
function noaa(list: unknown[] | null) {
  const f = {
    urls: [] as string[],
    agents: [] as string[],
    list,
    fn: ((input: string | URL | Request, init?: RequestInit) => {
      f.urls.push(String(input));
      f.agents.push(new Headers(init?.headers).get("user-agent") ?? "");
      return Promise.resolve(
        f.list === null
          ? new Response("down", { status: 502 })
          : new Response(JSON.stringify(f.list), {
            headers: { "content-type": "application/json" },
          }),
      );
    }) as typeof fetch,
  };
  return f;
}

const program: Program = {
  airport: "SFO",
  kind: "ground_delay",
  reason: "low clouds",
  reason_raw: "WEATHER / LOW CEILINGS",
  average_minutes: 47,
  trend: null,
  extension: null,
  starts_at: "2026-10-31T16:00:00Z",
  ends_at: "2026-11-01T03:59:00Z",
  updated_at: "2026-10-31T16:05:44Z",
  advisory_url: null,
};

function deps(over: Partial<Deps> = {}): Deps {
  return {
    verifier,
    now: () => NOW,
    airports: (codes) =>
      Promise.resolve(
        ROWS.filter((r) => codes.includes(r.icao) || codes.includes(r.iata!)),
      ),
    faa: () =>
      Promise.resolve({
        programs: [program],
        fetched_at: NOW.toISOString(),
        stale: false,
      }),
    cache: new WeatherCache(),
    ...over,
  };
}

async function ask(query: string, d: Deps, token = "user-1") {
  const res = await handler(
    new Request(`http://localhost/airport-weather?${query}`, {
      headers: token ? { authorization: `Bearer ${token}` } : {},
    }),
    d,
  );
  return {
    status: res.status,
    headers: res.headers,
    body: await res.json() as Answer & { error?: { code: string } },
  };
}

Deno.test("one batch request decodes every airport, in the asked order", async () => {
  const f = noaa([kaus, ksfo, older]);
  const r = await ask("airports=SFO,AUS,LHR", deps({ fetchFn: f.fn }));
  assertEquals(r.status, 200);
  assertEquals(f.urls.length, 1);
  assert(f.urls[0].includes("ids=KSFO%2CKAUS%2CEGLL"), f.urls[0]);
  assert(f.agents[0].startsWith("SomaFlight/"), "polite User-Agent");
  assertEquals(r.headers.get("cache-control"), CACHE_CONTROL);
  assertEquals(r.body.airports.map((a) => a.icao), ["KSFO", "KAUS", "EGLL"]);
  const sfo = r.body.airports[0].weather!;
  assertEquals(sfo.category, "VFR");
  assertEquals(sfo.temp_c, 17, "the newest observation wins");
  assertEquals(sfo.wind_kt, 9);
  assertEquals(
    sfo.condition,
    "Partly cloudy",
    "the thickest layer (SCT) decides",
  );
  assertEquals(sfo.summary, "Partly cloudy with light winds.");
  const aus = r.body.airports[1].weather!;
  assertEquals(aus.category, "IFR");
  assertEquals(aus.ceiling_ft, 900);
  assertEquals(aus.condition, "Light rain");
  assertEquals(aus.wind_dir_deg, null, "variable wind has no direction");
  assertEquals(r.body.airports[2].weather, null, "no METAR for LHR");
});

Deno.test("FAA programs only at US airports, filtered per airport", async () => {
  const r = await ask("airports=SFO,AUS,LHR", deps({ fetchFn: noaa([]).fn }));
  assertEquals(r.body.airports[0].faa?.programs.map((p) => p.kind), [
    "ground_delay",
  ]);
  assertEquals(r.body.airports[1].faa?.programs, []);
  assertEquals(r.body.airports[2].faa, null);
});

Deno.test("no FAA call for a list without US airports; a failed feed leaves faa null", async () => {
  let calls = 0;
  const r = await ask(
    "airports=LHR",
    deps({
      fetchFn: noaa([]).fn,
      faa: () => {
        calls++;
        return Promise.reject(new Error("down"));
      },
    }),
  );
  assertEquals(calls, 0);
  assertEquals(r.status, 200);
  const down = await ask(
    "airports=SFO",
    deps({ fetchFn: noaa([]).fn, faa: () => Promise.reject(new Error("x")) }),
  );
  assertEquals(down.status, 200);
  assertEquals(down.body.airports[0].faa, null);
});

Deno.test("kept answers are reused for 10 minutes, airports without a METAR too", async () => {
  const cache = new WeatherCache();
  const f = noaa([ksfo]);
  await ask("airports=SFO,LHR", deps({ fetchFn: f.fn, cache }));
  await ask(
    "airports=SFO,LHR",
    deps({ fetchFn: f.fn, cache, now: () => new Date(NOW.getTime() + 60_000) }),
  );
  assertEquals(f.urls.length, 1, "second read is from the cache");
  await ask(
    "airports=SFO,AUS",
    deps({ fetchFn: f.fn, cache, now: () => new Date(NOW.getTime() + 60_000) }),
  );
  assertEquals(f.urls.length, 2);
  assert(f.urls[1].includes("ids=KAUS&"), "only the missing airport is asked");
  await ask(
    "airports=SFO",
    deps({
      fetchFn: f.fn,
      cache,
      now: () => new Date(NOW.getTime() + CACHE_TTL_MS + 1),
    }),
  );
  assertEquals(f.urls.length, 3, "expired entries are asked again");
});

Deno.test("NOAA down: kept answers served stale up to an hour, then null", async () => {
  const cache = new WeatherCache();
  await ask("airports=SFO", deps({ fetchFn: noaa([ksfo]).fn, cache }));
  const later = new Date(NOW.getTime() + CACHE_TTL_MS + 1);
  const r = await ask(
    "airports=SFO",
    deps({ fetchFn: noaa(null).fn, cache, now: () => later }),
  );
  assertEquals(r.status, 200);
  assertEquals(r.body.airports[0].weather?.stale, true);
  const old = new Date(NOW.getTime() + STALE_MAX_MS + 1);
  const gone = await ask(
    "airports=SFO",
    deps({ fetchFn: noaa(null).fn, cache, now: () => old }),
  );
  assertEquals(gone.body.airports[0].weather, null);
});

Deno.test("request checks: token, codes, method, rate limit", async () => {
  const f = noaa([]);
  assertEquals(
    (await ask("airports=SFO", deps({ fetchFn: f.fn }), "")).status,
    401,
  );
  assertEquals((await ask("airports=", deps({ fetchFn: f.fn }))).status, 400);
  assertEquals(
    (await ask("airports=S;FO", deps({ fetchFn: f.fn }))).status,
    400,
  );
  const many = Array.from(
    { length: MAX_AIRPORTS + 1 },
    (_, i) => `K${String(i).padStart(3, "0")}`,
  ).join(",");
  assertEquals(
    (await ask(`airports=${many}`, deps({ fetchFn: f.fn }))).status,
    400,
  );
  const limited = await ask(
    "airports=SFO",
    deps({
      fetchFn: f.fn,
      rate: async () => {
        const { ApiError } = await import("../_shared/errors.ts");
        throw new ApiError("rate_limited", 429, "Too many requests");
      },
    }),
  );
  assertEquals(limited.status, 429);
  const post = await handler(
    new Request("http://localhost/airport-weather?airports=SFO", {
      method: "POST",
      headers: { authorization: "Bearer u" },
    }),
    deps({ fetchFn: f.fn }),
  );
  assertEquals(post.status, 405);
  assertEquals(f.urls.length, 0, "no NOAA call for a refused request");
});

Deno.test("decoding: newest per station, gusty winds, obscured sky", () => {
  const m = newestByStation([older, ksfo, { icaoId: null }]);
  assertEquals(m.get("KSFO")?.temp, 17);
  const gusty = toConditions({
    ...ksfo,
    wspd: 18,
    wgst: 31,
    visib: "1/2",
    clouds: [{ cover: "OVX", base: 0 }],
    vertVis: 1,
    rawOb: "METAR KSFO 312000Z 29018G31KT 1/2SM FG VV001 12/12 A2990",
    wxString: "FG",
  })!;
  assertEquals(gusty.category, "LIFR");
  assertEquals(gusty.gust_kt, 31);
  assertEquals(gusty.condition, "Fog");
  assertEquals(gusty.summary, "Fog with gusty winds.");
});

const CONTRACT_DIR = new URL("./contract/", import.meta.url);

/** Compares to contract/<name>.json; UPDATE_CONTRACT=1 rewrites it from the handler's answer. */
async function checkContract(name: string, actual: unknown) {
  const url = new URL(`${name}.json`, CONTRACT_DIR);
  const text = JSON.stringify(actual, null, 2) + "\n";
  if (Deno.env.get("UPDATE_CONTRACT") === "1") {
    await Deno.mkdir(CONTRACT_DIR, { recursive: true });
    await Deno.writeTextFile(url, text);
    return;
  }
  assertEquals(
    JSON.parse(await Deno.readTextFile(url)),
    JSON.parse(text),
    `contract/${name}.json is out of date: run with UPDATE_CONTRACT=1`,
  );
}

Deno.test("contract example matches the handler's answer", async () => {
  const r = await ask(
    "airports=SFO,AUS,LHR",
    deps({ fetchFn: noaa([kaus, ksfo]).fn }),
  );
  await checkContract("list", r.body);
});
