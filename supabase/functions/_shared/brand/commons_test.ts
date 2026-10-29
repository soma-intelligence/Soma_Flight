import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { CommonsLogoProvider, DEFAULT_COMMONS_BASE } from "./commons.ts";
import { contentVersion, ProviderUnavailable } from "./logo_provider.ts";

// Three real entries (UAL, DAL as SVG, OMA as a 192 px PNG) copied from assets/logos/commons.
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
  const f = await p.logo("UAL", "logo");
  assert(f);
  assertEquals(f.format, "svg");
  assertEquals(f.width, null);
  assertEquals(f.etag, null);
  const bytes = await Deno.readFile(new URL("UAL.svg", FIXTURE));
  assertEquals(f.bytes, bytes);
  assertEquals(f.version, await contentVersion(bytes));
});

Deno.test("commons: a PNG carries its pixel width", async () => {
  const f = await new CommonsLogoProvider(FIXTURE).logo("OMA", "logo");
  assert(f);
  assertEquals(f.format, "png");
  assertEquals(f.width, 192);
});

Deno.test("commons: no dark logo, no tail, no colours, unknown airline is null", async () => {
  const p = new CommonsLogoProvider(FIXTURE);
  assertEquals(await p.logo("UAL", "logo_dark"), null);
  assertEquals(await p.logo("UAL", "tail"), null);
  assertEquals(await p.logo("ZZZ", "logo"), null);
  assertEquals(await p.colors("UAL"), null);
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
    const f = await p.logo(a.icao, "logo");
    assert(f, `no file for ${a.icao}`);
  }
});
