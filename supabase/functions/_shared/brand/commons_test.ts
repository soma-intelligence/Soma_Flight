import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { CommonsLogoProvider, DEFAULT_COMMONS_BASE } from "./commons.ts";
import {
  contentVersion,
  type ProviderFile,
  ProviderUnavailable,
} from "./logo_provider.ts";
import { validateFile } from "./validate.ts";

// Three real entries (UAL, DAL as SVG, OMA as a 192 px PNG) copied from assets/logos/commons, plus
// the Delta symbol (symbols.DAL, symbol/DAL.svg).
const FIXTURE = new URL("../fixtures/commons/", import.meta.url);

Deno.test("commons: lists the manifest's airlines in ICAO order", async () => {
  const p = new CommonsLogoProvider(FIXTURE);
  assertEquals(await p.list(), [
    { icao: "DAL", iata: "DL", name: "Delta Air Lines" },
    { icao: "OMA", iata: "WY", name: "Oman Air" },
    { icao: "UAL", iata: "UA", name: "United Airlines" },
  ]);
});

Deno.test("commons: serves the SVG with a content version and no etag", async () => {
  const p = new CommonsLogoProvider(FIXTURE);
  const f = (await p.logo("UAL", "logo")) as ProviderFile | null;
  assert(f);
  assertEquals(f.format, "svg");
  assertEquals(f.width, null);
  assertEquals(f.etag, null);
  const bytes = await Deno.readFile(new URL("UAL.svg", FIXTURE));
  assertEquals(f.bytes, bytes);
  assertEquals(f.version, await contentVersion(bytes));
});

Deno.test("commons: a PNG carries its pixel width", async () => {
  const f = (await new CommonsLogoProvider(FIXTURE).logo("OMA", "logo")) as
    | ProviderFile
    | null;
  assert(f);
  assertEquals(f.format, "png");
  assertEquals(f.width, 192);
});

Deno.test("commons: no dark logo, no tail, no colours, unknown airline is null", async () => {
  const p = new CommonsLogoProvider(FIXTURE);
  assertEquals(await p.logo("UAL", "logo_dark"), null);
  assertEquals(await p.logo("UAL", "tail_logo"), null);
  assertEquals(await p.logo("ZZZ", "logo"), null);
  assertEquals(await p.colors("UAL"), null);
});

Deno.test("commons: 'logo' is the symbol when there is one, 'wordmark' is always the wordmark", async () => {
  const p = new CommonsLogoProvider(FIXTURE);
  const read = (n: string) => Deno.readFile(new URL(n, FIXTURE));
  const logo = (await p.logo("DAL", "logo")) as ProviderFile;
  assertEquals(logo.bytes, await read("symbol/DAL.svg"));
  assertEquals(
    logo.version,
    await contentVersion(await read("symbol/DAL.svg")),
  );
  const word = (await p.logo("DAL", "wordmark")) as ProviderFile;
  assertEquals(word.bytes, await read("DAL.svg"));
  assert(logo.version !== word.version);
  // No symbol: both kinds are the wordmark.
  const ual = await read("UAL.svg");
  assertEquals(((await p.logo("UAL", "logo")) as ProviderFile).bytes, ual);
  assertEquals(((await p.logo("UAL", "wordmark")) as ProviderFile).bytes, ual);
  assertEquals(await p.logo("ZZZ", "wordmark"), null);
  // The port's kind list is unchanged: the sync asks for 'logo' only.
  assertEquals(p.kinds, ["logo"]);
});

Deno.test("commons: the unchanged check follows the served mark", async () => {
  const p = new CommonsLogoProvider(FIXTURE);
  const symbol = (await p.logo("DAL", "logo")) as ProviderFile;
  const word = (await p.logo("DAL", "wordmark")) as ProviderFile;
  const known = (version: string) => ({
    known: { etag: null, version, format: "svg" },
  });
  assertEquals(await p.logo("DAL", "logo", known(symbol.version)), "unchanged");
  // A row that still holds the wordmark is replaced by the symbol.
  const next = await p.logo("DAL", "logo", known(word.version));
  assert(next && next !== "unchanged");
  assertEquals(next.version, symbol.version);
});

Deno.test("commons: a symbol entry must name its own file under symbol/", async () => {
  const manifest = JSON.parse(
    await Deno.readTextFile(new URL("manifest.json", FIXTURE)),
  );
  for (
    const file of [
      "DAL.svg",
      "symbol/UAL.svg",
      "../DAL.svg",
      "symbol/png/DAL.png",
    ]
  ) {
    const m = structuredClone(manifest);
    m.symbols.DAL.file = file;
    const fetchFn = ((input: string | URL | Request) =>
      String(input).endsWith("manifest.json")
        ? Promise.resolve(new Response(JSON.stringify(m)))
        : fetch(input)) as typeof fetch;
    const p = new CommonsLogoProvider(FIXTURE, fetchFn);
    await assertRejects(
      () =>
        p.logo("DAL", "logo"),
      Error,
      "names",
    );
    // The wordmark is unaffected.
    assert(await p.logo("DAL", "wordmark"));
  }
});

Deno.test("commons: a manifest without symbols serves wordmarks (8b layout)", async () => {
  const manifest = JSON.parse(
    await Deno.readTextFile(new URL("manifest.json", FIXTURE)),
  );
  delete manifest.symbols;
  const fetchFn =
    ((input: string | URL | Request) =>
      String(input).endsWith("manifest.json")
        ? Promise.resolve(new Response(JSON.stringify(manifest)))
        : fetch(input)) as typeof fetch;
  const p = new CommonsLogoProvider(FIXTURE, fetchFn);
  const f = (await p.logo("DAL", "logo")) as ProviderFile;
  assertEquals(f.bytes, await Deno.readFile(new URL("DAL.svg", FIXTURE)));
});

Deno.test("commons: bytes that differ from the manifest are refused", async () => {
  const real = fetch;
  const fetchFn = ((input: string | URL | Request) => {
    const u = String(input);
    if (u.endsWith("DAL.svg")) {
      return Promise.resolve(new Response("<svg id='swapped'/>"));
    }
    return real(input);
  }) as typeof fetch;
  const p = new CommonsLogoProvider(FIXTURE, fetchFn);
  await assertRejects(() => p.logo("DAL", "logo"), Error, "sha256");
});

Deno.test("commons: an http base works and a missing manifest is an outage", async () => {
  const seen: string[] = [];
  const fetchFn = (async (input: string | URL | Request) => {
    const u = new URL(String(input));
    seen.push(u.toString());
    if (u.pathname.endsWith("/manifest.json")) {
      return new Response(
        await Deno.readFile(new URL("manifest.json", FIXTURE)),
      );
    }
    if (u.pathname.endsWith("/UAL.svg")) {
      return new Response(await Deno.readFile(new URL("UAL.svg", FIXTURE)));
    }
    return new Response("no", { status: 404 });
  }) as typeof fetch;
  const p = new CommonsLogoProvider(
    "http://host.docker.internal:8787/commons",
    fetchFn,
  );
  assert(await p.logo("UAL", "logo"));
  assertEquals(await p.logo("DAL", "logo"), null); // listed but not served: 404
  assertEquals(
    seen[0],
    "http://host.docker.internal:8787/commons/manifest.json",
  );

  const down = new CommonsLogoProvider(
    "http://x.test/",
    (() =>
      Promise.resolve(new Response("no", { status: 404 }))) as typeof fetch,
  );
  await assertRejects(() => down.list(), ProviderUnavailable);
});

Deno.test("commons: the repo library loads and every file matches the manifest", async () => {
  const p = new CommonsLogoProvider(DEFAULT_COMMONS_BASE);
  const list = await p.list();
  assert(list.length >= 100, `only ${list.length} logos`);
  for (const a of list) {
    const f = (await p.logo(a.icao, "logo")) as ProviderFile | null;
    assert(f, `no file for ${a.icao}`);
  }
});

Deno.test("commons: every repo symbol is served as 'logo' and passes the sync's validation", async () => {
  const manifest = JSON.parse(
    await Deno.readTextFile(new URL("manifest.json", DEFAULT_COMMONS_BASE)),
  );
  const symbols = Object.entries(manifest.symbols ?? {}) as [
    string,
    { kind: string; sha256: string; license: string; author: string | null },
  ][];
  assert(symbols.length >= 6, `only ${symbols.length} symbols`);
  const p = new CommonsLogoProvider(DEFAULT_COMMONS_BASE);
  for (const [icao, e] of symbols) {
    assertEquals(e.kind, "symbol");
    assert(e.license && e.author, `${icao} symbol has no licence or author`);
    const f = (await p.logo(icao, "logo")) as ProviderFile;
    assertEquals(f.version, e.sha256.slice(0, 16), icao);
    const v = await validateFile(f);
    assert(v.ok, `${icao} symbol: ${!v.ok && v.reason}`);
  }
  for (const e of Object.values(manifest.logos) as { kind: string }[]) {
    assertEquals(e.kind, "wordmark");
  }
});

Deno.test("commons: a known current version is answered unchanged without reading the file", async () => {
  const seen: string[] = [];
  const fetchFn = ((input: string | URL | Request) => {
    seen.push(String(input));
    return fetch(input);
  }) as typeof fetch;
  const p = new CommonsLogoProvider(FIXTURE, fetchFn);
  const f = (await p.logo("UAL", "logo")) as ProviderFile;
  seen.length = 0;
  const again = await p.logo("UAL", "logo", {
    known: { etag: null, version: f.version, format: "svg" },
  });
  assertEquals(again, "unchanged");
  assert(!seen.some((u) => u.endsWith("UAL.svg")));
  const stale = await p.logo("UAL", "logo", {
    known: { etag: null, version: "old", format: "svg" },
  });
  assert(stale && stale !== "unchanged");
});
