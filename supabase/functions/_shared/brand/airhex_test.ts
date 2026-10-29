import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  AIRHEX_API,
  AIRHEX_CONTENT,
  AirhexLogoProvider,
  md5Hex,
} from "./airhex.ts";
import { type ProviderFile, ProviderUnavailable } from "./logo_provider.ts";

const KEY = "test-key-not-a-real-licence";
const DIR = new URL("../fixtures/airhex/", import.meta.url);
const read = (n: string) => Deno.readFile(new URL(n, DIR));
const text = (n: string) => Deno.readTextFile(new URL(n, DIR));

type Reply = { status?: number; type?: string; body?: Uint8Array | string };
interface Rig {
  provider: AirhexLogoProvider;
  urls: string[];
}

/** Replays the recorded files by path; anything not recorded is a 404. */
async function rig(
  overrides: Record<string, Reply> = {},
  fail?: (path: string) => number | undefined,
): Promise<Rig> {
  const files: Record<string, Reply> = {
    [`${AIRHEX_API}/airlines.json`]: {
      type: "application/json",
      body: await text("airlines.json"),
    },
    [`${AIRHEX_API}/airlines/UA/colors.json`]: {
      type: "application/json",
      body: await text("colors_UA.json"),
    },
    [`${AIRHEX_API}/airlines/AF/colors.json`]: {
      type: "application/json",
      body: await text("colors_AF.json"),
    },
    [`${AIRHEX_CONTENT}/airlines_UA_512_512_r.svg`]: {
      type: "image/svg+xml",
      body: await read("logo_UA.svg"),
    },
    [`${AIRHEX_CONTENT}/airlines_UA_512_512_t.svg`]: {
      type: "image/svg+xml",
      body: await read("tail_UA.svg"),
    },
    [`${AIRHEX_CONTENT}/airlines_AF_512_512_r.png`]: {
      type: "image/png",
      body: await read("logo_AF_512.png"),
    },
    ...overrides,
  };
  const urls: string[] = [];
  const fetchFn = ((input: string | URL | Request) => {
    const u = new URL(String(input));
    urls.push(u.toString());
    const path = `${u.origin}${u.pathname}`;
    const forced = fail?.(path);
    if (forced) return Promise.resolve(new Response("x", { status: forced }));
    // The dark variant is a query on the same path; recorded under its own key.
    const key = u.searchParams.get("variant") === "dark"
      ? `${path}#dark`
      : path;
    const r = files[key];
    if (!r) return Promise.resolve(new Response("nope", { status: 404 }));
    return Promise.resolve(
      new Response(r.body as BodyInit, {
        status: r.status ?? 200,
        headers: { "content-type": r.type ?? "application/octet-stream" },
      }),
    );
  }) as typeof fetch;
  return { provider: new AirhexLogoProvider(KEY, fetchFn), urls };
}

Deno.test("parsesList", async () => {
  const { provider } = await rig();
  const list = await provider.list();
  assertEquals(
    list.map((a) => a.icao),
    ["UAL", "AFR", "QQQ", "BAD"], // TOOLONG is not an ICAO code and is dropped
  );
  assertEquals(list[0], { icao: "UAL", iata: "UA", name: "United Airlines" });
  assertEquals(list.find((a) => a.icao === "BAD")!.iata, null);
});

Deno.test("prefersVectorElsePngAtLeast192", async () => {
  const { provider, urls } = await rig();
  const svg = (await provider.logo("UAL", "logo")) as ProviderFile | null;
  assertEquals(svg?.format, "svg");
  assertEquals(svg?.width, null);
  assertEquals(svg?.version.length, 16);
  const png = (await provider.logo("AFR", "logo")) as ProviderFile | null;
  assertEquals(png?.format, "png");
  assertEquals(png?.width, 512); // the largest size offered
  assert(png!.width! >= 192);
  assert(urls.some((u) => u.includes("airlines_AF_512_512_r.png")));
  // A provider that offers only small rasters gives nothing rather than a blurry logo.
  const small = await rig({
    [`${AIRHEX_API}/airlines.json`]: {
      type: "application/json",
      body: JSON.stringify({
        sizes: [64, 128],
        airlines: [{ icao: "AFR", iata: "AF", name: "Air France" }],
      }),
    },
  });
  assertEquals(await small.provider.logo("AFR", "logo"), null);
});

Deno.test("readsDarkVariantWhenOffered", async () => {
  const { provider, urls } = await rig({
    [`${AIRHEX_CONTENT}/airlines_UA_512_512_r.svg#dark`]: {
      type: "image/svg+xml",
      body: await read("logo_UA_dark.svg"),
    },
  });
  const dark = (await provider.logo("UAL", "logo_dark")) as ProviderFile | null;
  assertEquals(dark?.format, "svg");
  assert(urls.some((u) => u.includes("variant=dark")));
  const light = (await provider.logo("UAL", "logo")) as ProviderFile | null;
  assert(dark!.version !== light!.version);
  // Air France does not offer one: no request, no file.
  const before = urls.length;
  assertEquals(await provider.logo("AFR", "logo_dark"), null);
  assertEquals(urls.length, before);
});

Deno.test("readsBrandColors", async () => {
  const { provider } = await rig();
  assertEquals(await provider.colors("UAL"), {
    primary: "#0033A0",
    secondary: "#1B1B1B",
  });
  assertEquals(await provider.colors("AFR"), {
    primary: "#002157",
    secondary: null,
  });
  assertEquals(await provider.colors("QQQ"), null); // 404 on the colours endpoint
  const bad = await rig({
    [`${AIRHEX_API}/airlines/UA/colors.json`]: {
      type: "application/json",
      body: '{"primary":"blue"}',
    },
  });
  assertEquals(await bad.provider.colors("UAL"), null);
});

Deno.test("sendsKeyAsDocumented", async () => {
  const { provider, urls } = await rig();
  await provider.list();
  await provider.logo("UAL", "tail_logo");
  await provider.colors("UAL");
  const md5 = await md5Hex(KEY);
  assertEquals(md5.length, 32);
  assert(urls.length >= 3);
  for (const u of urls) {
    assertEquals(new URL(u).searchParams.get("md5apikey"), md5);
    assert(!u.includes(KEY), "the key is never sent in clear");
  }
});

Deno.test("404IsNull", async () => {
  const { provider } = await rig();
  assertEquals(await provider.logo("QQQ", "logo"), null);
  assertEquals(await provider.logo("QQQ", "tail_logo"), null);
  assertEquals(await provider.logo("ZZZ", "logo"), null); // not listed
  assertEquals(await provider.logo("BAD", "logo"), null); // listed without an IATA code
});

Deno.test("5xxThrowsProviderUnavailable", async () => {
  const bad = await rig({}, (p) => p.includes("/logos/") ? 503 : undefined);
  await assertRejects(
    () => bad.provider.logo("UAL", "logo"),
    ProviderUnavailable,
  );
  const limited = await rig({}, (p) => p.includes("/colors") ? 429 : undefined);
  await assertRejects(
    () => limited.provider.colors("UAL"),
    ProviderUnavailable,
  );
  const listDown = await rig(
    {},
    (p) => p.endsWith("airlines.json") ? 500 : undefined,
  );
  await assertRejects(() => listDown.provider.list(), ProviderUnavailable);
});

Deno.test("conditionalFetchSendsIfNoneMatchAndAnswers304AsUnchanged", async () => {
  const seen: { url: string; inm: string | null }[] = [];
  const base = await rig();
  const catalog = await base.provider.list(); // warm nothing; separate provider below
  assert(catalog.length > 0);
  const listBody = await text("airlines.json");
  const fetchFn = ((input: string | URL | Request, init?: RequestInit) => {
    const u = new URL(String(input));
    const inm = new Headers(init?.headers).get("if-none-match");
    seen.push({ url: u.pathname, inm });
    if (u.pathname.endsWith("airlines.json")) {
      return Promise.resolve(new Response(listBody));
    }
    return Promise.resolve(new Response(null, { status: inm ? 304 : 200 }));
  }) as typeof fetch;
  const p = new AirhexLogoProvider(KEY, fetchFn);
  const got = await p.logo("UAL", "logo", {
    known: { etag: '"e1"', version: "v", format: "svg" },
  });
  assertEquals(got, "unchanged");
  const logoCalls = seen.filter((s) => s.url.includes("/logos/"));
  assertEquals(logoCalls.length, 1, "no second request for the raster");
  assertEquals(logoCalls[0].inm, '"e1"');
  assert(logoCalls[0].url.endsWith(".svg"));
  // A stored raster goes straight to the raster URL.
  const png = await p.logo("AFR", "logo", {
    known: { etag: '"e2"', version: "v", format: "png" },
  });
  assertEquals(png, "unchanged");
  assert(seen.at(-1)!.url.endsWith(".png"));
});

Deno.test("errorsNeverCarryTheDigest", async () => {
  const listBody = await text("airlines.json");
  const fetchFn = ((input: string | URL | Request) => {
    const u = String(input);
    if (u.includes("airlines.json")) {
      return Promise.resolve(new Response(listBody));
    }
    return Promise.reject(
      new TypeError(`error sending request for url (${u})`),
    );
  }) as typeof fetch;
  const p = new AirhexLogoProvider(KEY, fetchFn);
  const md5 = await md5Hex(KEY);
  const e = await assertRejects(
    () => p.logo("UAL", "logo"),
    ProviderUnavailable,
  );
  assert(!e.message.includes(md5), e.message);
  assert(e.message.includes("REDACTED"));
});
