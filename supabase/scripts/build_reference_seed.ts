// Usage:
//   deno run -A supabase/scripts/build_reference_seed.ts
//
// Reads supabase/seed/{airlines,aircraft_types,country_regions}.csv and writes
//   supabase/migrations/20261030000003_reference_seed.sql   (airlines and aircraft_types rows)
//   Packages/FlightKit/Sources/FlightKit/Resources/Reference/{airlines,aircraft_types,countries}.json
// The output is sorted by key and formatted the same way every run, so a second run changes nothing.
// It fails with a message on a duplicate key, a bad hex colour, an unknown family, region or alliance,
// an IATA code that is not 2 characters, or an ICAO code that is not 3 capital letters.

export const FAMILIES = [
  "a220", "a320", "a330", "a350", "a380", "b737", "b737max", "b747", "b757", "b767", "b777", "b787",
  "ejet", "crj", "atr", "other",
] as const;
export const REGIONS = [
  "europe", "north_america", "central_america", "caribbean", "south_america", "africa", "middle_east",
  "asia", "oceania",
] as const;
export const ALLIANCES = ["star_alliance", "oneworld", "skyteam"] as const;
/** Livery seed airlines (Task 12): the provider colour sync never overwrites these rows. */
export const LOCKED = new Set(["UAL", "AFR", "RYR"]);

const AIRLINE_COLUMNS = [
  "icao", "iata", "name", "callsign", "alliance", "country", "color_primary", "color_secondary", "phone",
  "website", "x", "facebook",
];

export interface ReferenceInput {
  airlines: string;
  aircraftTypes: string;
  countries: string;
}
export interface ReferenceOutput {
  sql: string;
  airlinesJson: string;
  aircraftTypesJson: string;
  countriesJson: string;
}

function parseCsv(text: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let field = "";
  let quoted = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quoted) {
      if (c === '"' && text[i + 1] === '"') { field += '"'; i++; }
      else if (c === '"') quoted = false;
      else field += c;
    } else if (c === '"') quoted = true;
    else if (c === ",") { row.push(field); field = ""; }
    else if (c === "\n" || c === "\r") {
      if (c === "\r" && text[i + 1] === "\n") i++;
      row.push(field); field = "";
      if (row.length > 1 || row[0] !== "") rows.push(row);
      row = [];
    } else field += c;
  }
  if (field !== "" || row.length) { row.push(field); rows.push(row); }
  return rows;
}

/** Rows as objects keyed by the header, which must be exactly `columns`. */
function table(text: string, columns: string[], file: string): Record<string, string>[] {
  const rows = parseCsv(text);
  if (rows.length === 0 || rows[0].join(",") !== columns.join(",")) {
    throw new Error(`${file}: header must be ${columns.join(",")}`);
  }
  return rows.slice(1).map((r, i) => {
    if (r.length !== columns.length) throw new Error(`${file}: line ${i + 2} has ${r.length} fields, want ${columns.length}`);
    return Object.fromEntries(columns.map((c, j) => [c, r[j].trim()]));
  });
}

const byKey = (key: string) => (a: Record<string, string>, b: Record<string, string>) =>
  a[key] < b[key] ? -1 : a[key] > b[key] ? 1 : 0;

function unique(rows: Record<string, string>[], key: string) {
  const seen = new Set<string>();
  for (const r of rows) {
    if (seen.has(r[key])) throw new Error(`duplicate ${key} ${r[key]}`);
    seen.add(r[key]);
  }
}

const sql = (s: string) => s === "" ? "null" : `'${s.replaceAll("'", "''")}'`;
const camel = (s: string) => s.replace(/_([a-z])/g, (_, c) => c.toUpperCase());

function json(rows: Record<string, string>[], keys: string[]): string {
  const lines = rows.map((r) => "  " + JSON.stringify(Object.fromEntries(keys.map((k) => [camel(k), r[k]]))));
  return `[\n${lines.join(",\n")}\n]\n`;
}

/** Names reach the app as they are: no Wikidata language tag, no formal long forms. */
function checkName(key: string, name: string) {
  if (name === "") throw new Error(`${key}: name is required`);
  if (name.includes("@")) throw new Error(`${key}: name must not contain @ (${name})`);
  if (name.length > 40) throw new Error(`${key}: name is longer than 40 characters (${name})`);
}

export function buildReference(input: ReferenceInput): ReferenceOutput {
  const airlines = table(input.airlines, AIRLINE_COLUMNS, "airlines.csv");
  unique(airlines, "icao");
  for (const r of airlines) {
    if (!/^[A-Z]{3}$/.test(r.icao)) throw new Error(`bad icao ${r.icao}`);
    if (r.iata !== "" && r.iata.length !== 2) throw new Error(`${r.icao}: IATA must be 2 characters, got ${r.iata}`);
    checkName(r.icao, r.name);
    if (!/^#[0-9A-Fa-f]{6}$/.test(r.color_primary)) throw new Error(`${r.icao}: bad colour ${r.color_primary}`);
    if (r.color_secondary !== "" && !/^#[0-9A-Fa-f]{6}$/.test(r.color_secondary)) {
      throw new Error(`${r.icao}: bad colour ${r.color_secondary}`);
    }
    if (r.alliance !== "" && !(ALLIANCES as readonly string[]).includes(r.alliance)) {
      throw new Error(`${r.icao}: unknown alliance ${r.alliance}`);
    }
    if (r.country !== "" && !/^[A-Z]{2}$/.test(r.country)) throw new Error(`${r.icao}: bad country ${r.country}`);
  }
  const types = table(input.aircraftTypes, ["icao_type", "family", "manufacturer", "name"], "aircraft_types.csv");
  unique(types, "icao_type");
  for (const r of types) {
    if (!/^[A-Z0-9]{2,4}$/.test(r.icao_type)) throw new Error(`bad icao_type ${r.icao_type}`);
    if (!(FAMILIES as readonly string[]).includes(r.family)) throw new Error(`${r.icao_type}: unknown family ${r.family}`);
    if (r.manufacturer === "") throw new Error(`${r.icao_type}: manufacturer is required`);
    checkName(r.icao_type, r.name);
  }
  const countries = table(input.countries, ["iso2", "name", "region"], "country_regions.csv");
  unique(countries, "iso2");
  for (const r of countries) {
    if (!/^[A-Z]{2}$/.test(r.iso2)) throw new Error(`bad iso2 ${r.iso2}`);
    if (!(REGIONS as readonly string[]).includes(r.region)) throw new Error(`${r.iso2}: unknown region ${r.region}`);
    checkName(r.iso2, r.name);
  }

  airlines.sort(byKey("icao"));
  types.sort(byKey("icao_type"));
  countries.sort(byKey("iso2"));
  for (const r of airlines) {
    r.color_primary = r.color_primary.toUpperCase();
    r.color_secondary = r.color_secondary.toUpperCase();
  }

  const airlineValues = airlines.map((r) =>
    `(${AIRLINE_COLUMNS.map((c) => sql(r[c])).join(", ")}, ${LOCKED.has(r.icao) ? "'locked'" : "'seed'"})`
  );
  const typeValues = types.map((r) => `(${["icao_type", "family", "manufacturer", "name"].map((c) => sql(r[c])).join(", ")})`);
  const out = [
    "-- Generated by supabase/scripts/build_reference_seed.ts from supabase/seed/*.csv. Do not edit.",
    `insert into airlines (${AIRLINE_COLUMNS.join(", ")}, colors_source) values`,
    airlineValues.join(",\n"),
    "on conflict (icao) do nothing;",
    "",
    "insert into aircraft_types (icao_type, family, manufacturer, name) values",
    typeValues.join(",\n"),
    "on conflict (icao_type) do nothing;",
    "",
  ].join("\n");

  return {
    sql: out,
    airlinesJson: json(airlines, AIRLINE_COLUMNS),
    aircraftTypesJson: json(types, ["icao_type", "family", "manufacturer", "name"]),
    countriesJson: json(countries, ["iso2", "name", "region"]),
  };
}

export interface OutputPaths {
  sql: string;
  airlinesJson: string;
  aircraftTypesJson: string;
  countriesJson: string;
}

const root = new URL("../../", import.meta.url).pathname;
export const DEFAULT_PATHS: OutputPaths = {
  sql: `${root}supabase/migrations/20261030000003_reference_seed.sql`,
  airlinesJson: `${root}Packages/FlightKit/Sources/FlightKit/Resources/Reference/airlines.json`,
  aircraftTypesJson: `${root}Packages/FlightKit/Sources/FlightKit/Resources/Reference/aircraft_types.json`,
  countriesJson: `${root}Packages/FlightKit/Sources/FlightKit/Resources/Reference/countries.json`,
};

export async function generate(paths: OutputPaths = DEFAULT_PATHS): Promise<ReferenceOutput> {
  const out = buildReference({
    airlines: await Deno.readTextFile(`${root}supabase/seed/airlines.csv`),
    aircraftTypes: await Deno.readTextFile(`${root}supabase/seed/aircraft_types.csv`),
    countries: await Deno.readTextFile(`${root}supabase/seed/country_regions.csv`),
  });
  for (const key of Object.keys(paths) as (keyof OutputPaths)[]) {
    await Deno.mkdir(paths[key].replace(/\/[^/]*$/, ""), { recursive: true });
    await Deno.writeTextFile(paths[key], out[key]);
  }
  return out;
}

if (import.meta.main) {
  try {
    await generate();
  } catch (e) {
    console.error(`build_reference_seed: ${(e as Error).message}`);
    Deno.exit(1);
  }
}
