import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import { buildReference, generate } from "./build_reference_seed.ts";

const AIRLINES_HEAD = "icao,iata,name,callsign,alliance,country,color_primary,color_secondary,phone,website,x,facebook\n";
const TYPES_HEAD = "icao_type,family,manufacturer,name\n";
const COUNTRIES_HEAD = "iso2,name,region\n";

const okAirline = "UAL,UA,United Airlines,UNITED,star_alliance,US,#0033A0,,,https://www.united.com,,\n";
const okType = "A320,a320,Airbus,Airbus A320\n";
const okCountry = "FR,France,europe\n";

function input(over: { airlines?: string; types?: string; countries?: string } = {}) {
  return {
    airlines: AIRLINES_HEAD + (over.airlines ?? okAirline),
    aircraftTypes: TYPES_HEAD + (over.types ?? okType),
    countries: COUNTRIES_HEAD + (over.countries ?? okCountry),
  };
}

Deno.test("builds the sql and the three json files", () => {
  const out = buildReference(input());
  assertEquals(JSON.parse(out.airlinesJson)[0], {
    icao: "UAL", iata: "UA", name: "United Airlines", callsign: "UNITED", alliance: "star_alliance",
    country: "US", colorPrimary: "#0033A0", colorSecondary: "", phone: "", website: "https://www.united.com",
    x: "", facebook: "",
  });
  assertEquals(JSON.parse(out.aircraftTypesJson)[0], {
    icaoType: "A320", family: "a320", manufacturer: "Airbus", name: "Airbus A320",
  });
  assertEquals(JSON.parse(out.countriesJson)[0], { iso2: "FR", name: "France", region: "europe" });
  // UAL is a livery seed row: its colours are locked against the provider sync.
  if (!out.sql.includes("'UAL', 'UA', 'United Airlines'") || !out.sql.includes("'locked'")) {
    throw new Error("UAL row must carry colors_source locked");
  }
});

Deno.test("rejects duplicate icao", () => {
  assertThrows(
    () => buildReference(input({ airlines: okAirline + okAirline })),
    Error,
    "duplicate icao UAL",
  );
});

Deno.test("rejects duplicate icao_type and iso2", () => {
  assertThrows(() => buildReference(input({ types: okType + okType })), Error, "duplicate icao_type A320");
  assertThrows(() => buildReference(input({ countries: okCountry + okCountry })), Error, "duplicate iso2 FR");
});

Deno.test("rejects bad colour", () => {
  assertThrows(
    () => buildReference(input({ airlines: "UAL,UA,United Airlines,UNITED,star_alliance,US,0033A0,,,,,\n" })),
    Error,
    "bad colour",
  );
  assertThrows(
    () => buildReference(input({ airlines: "UAL,UA,United Airlines,UNITED,star_alliance,US,#0033A0,#12345,,,,\n" })),
    Error,
    "bad colour",
  );
});

Deno.test("rejects unknown family", () => {
  assertThrows(() => buildReference(input({ types: "A320,a321,Airbus,Airbus A320\n" })), Error, "unknown family a321");
});

Deno.test("rejects unknown region", () => {
  assertThrows(() => buildReference(input({ countries: "FR,France,antarctica\n" })), Error, "unknown region antarctica");
});

Deno.test("rejects names with @ or longer than 40 characters", () => {
  assertThrows(() => buildReference(input({ countries: "FR,France@en,europe\n" })), Error, "must not contain @");
  assertThrows(
    () => buildReference(input({ countries: `FR,${"x".repeat(41)},europe\n` })),
    Error,
    "longer than 40",
  );
  assertThrows(
    () => buildReference(input({ airlines: "UAL,UA,United@en,UNITED,,US,#0033A0,,,,,\n" })),
    Error,
    "must not contain @",
  );
});

Deno.test("rejects IATA not 2 characters, bad icao and unknown alliance", () => {
  assertThrows(
    () => buildReference(input({ airlines: "UAL,UAL,United Airlines,UNITED,star_alliance,US,#0033A0,,,,,\n" })),
    Error,
    "IATA must be 2 characters",
  );
  assertThrows(
    () => buildReference(input({ airlines: "UA,UA,United Airlines,UNITED,,US,#0033A0,,,,,\n" })),
    Error,
    "bad icao",
  );
  assertThrows(
    () => buildReference(input({ airlines: "UAL,UA,United Airlines,UNITED,galaxy,US,#0033A0,,,,,\n" })),
    Error,
    "unknown alliance galaxy",
  );
});

Deno.test("output is sorted whatever the input order", () => {
  const a = "RYR,FR,Ryanair,RYANAIR,,IE,#073590,,,,,\n";
  const x = buildReference(input({ airlines: okAirline + a }));
  const y = buildReference(input({ airlines: a + okAirline }));
  assertEquals(x, y);
  assertEquals(JSON.parse(x.airlinesJson).map((r: { icao: string }) => r.icao), ["RYR", "UAL"]);
});

Deno.test("output is stable: two runs are byte-identical and match the committed files", async () => {
  const dir1 = await Deno.makeTempDir();
  const dir2 = await Deno.makeTempDir();
  try {
    const files = (d: string) => ({
      sql: `${d}/seed.sql`, airlinesJson: `${d}/airlines.json`,
      aircraftTypesJson: `${d}/aircraft_types.json`, countriesJson: `${d}/countries.json`,
    });
    await generate(files(dir1));
    await generate(files(dir2));
    for (const f of Object.values(files(dir1))) {
      const name = f.slice(dir1.length);
      assertEquals(await Deno.readTextFile(f), await Deno.readTextFile(dir2 + name), `${name} differs between runs`);
    }
    // The committed outputs are what the script writes now.
    const root = new URL("../../", import.meta.url).pathname;
    const res = "Packages/FlightKit/Sources/FlightKit/Resources/Reference";
    assertEquals(
      await Deno.readTextFile(`${dir1}/seed.sql`),
      await Deno.readTextFile(`${root}supabase/migrations/20261030000003_reference_seed.sql`),
      "seed migration is out of date, run build_reference_seed.ts",
    );
    for (const [src, dst] of [["airlines.json", "airlines.json"], ["aircraft_types.json", "aircraft_types.json"], ["countries.json", "countries.json"]]) {
      assertEquals(await Deno.readTextFile(`${dir1}/${src}`), await Deno.readTextFile(`${root}${res}/${dst}`), `${dst} is out of date`);
    }
  } finally {
    await Deno.remove(dir1, { recursive: true });
    await Deno.remove(dir2, { recursive: true });
  }
});

Deno.test("the committed seed covers what the plan requires", async () => {
  const root = new URL("../../", import.meta.url).pathname;
  const out = buildReference({
    airlines: await Deno.readTextFile(`${root}supabase/seed/airlines.csv`),
    aircraftTypes: await Deno.readTextFile(`${root}supabase/seed/aircraft_types.csv`),
    countries: await Deno.readTextFile(`${root}supabase/seed/country_regions.csv`),
  });
  const airlines = JSON.parse(out.airlinesJson) as { icao: string; alliance: string }[];
  const have = new Set(airlines.map((a) => a.icao));
  for (const c of "UAL DLH AFR ACA TRA TVF BEL FLE RYR AAL ASA DAL FFT JBU NKS SWA".split(" ")) {
    if (!have.has(c)) throw new Error(`missing airline ${c}`);
  }
  for (const a of ["star_alliance", "oneworld", "skyteam"]) {
    if (airlines.filter((x) => x.alliance === a).length < 10) throw new Error(`too few ${a} members`);
  }
  if (JSON.parse(out.aircraftTypesJson).length < 70) throw new Error("fewer than 70 aircraft types");
  if (JSON.parse(out.countriesJson).length !== 250) throw new Error("countries: 249 ISO codes plus XK");
});
