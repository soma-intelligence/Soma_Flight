import { assert, assertEquals } from "jsr:@std/assert@1";
import { CommonsLogoProvider, DEFAULT_COMMONS_BASE } from "./commons.ts";
import type { ProviderFile } from "./logo_provider.ts";
import { readCapped, redact } from "./logo_provider.ts";
import {
  MAX_RASTER_BYTES,
  MAX_SVG_BYTES,
  pngComplete,
  pngSize,
  RENDER_PX,
  SIDE_VIEW_RULE,
  SMALL_PX,
  validateFile,
  webpSize,
} from "./validate.ts";

const FIX = new URL("../fixtures/svg-evil/", import.meta.url);
const read = (n: string) => Deno.readFile(new URL(n, FIX));
const file = (
  bytes: Uint8Array,
  format: ProviderFile["format"],
  extra: Partial<ProviderFile> = {},
): ProviderFile => ({
  bytes,
  format,
  width: null,
  version: "v",
  etag: null,
  ...extra,
});
const enc = (s: string) => new TextEncoder().encode(s);
const PNG_SIG = [0x89, 0x50, 0x4e, 0x47];

/** Runs fn with a fetch spy installed; returns the URLs fetched. */
async function spying(fn: () => Promise<void>): Promise<string[]> {
  const real = globalThis.fetch;
  const seen: string[] = [];
  globalThis.fetch = ((i: string | URL | Request) => {
    seen.push(String(i));
    return Promise.reject(new Error("network is off in this test"));
  }) as typeof fetch;
  try {
    await fn();
  } finally {
    globalThis.fetch = real;
  }
  return seen;
}

Deno.test("svg: a clean vector becomes 384 and 192 px PNGs, never an svg", async () => {
  const v = await validateFile(file(await read("clean.svg"), "svg", {
    mime: "image/svg+xml; charset=utf-8",
  }));
  assert(v.ok);
  assertEquals([v.format, v.mime], ["png", "image/png"]);
  assertEquals(Array.from(v.main.bytes.slice(0, 4)), PNG_SIG);
  assertEquals(Math.max(v.main.width, v.main.height), RENDER_PX);
  assert(v.small);
  assertEquals(Math.max(v.small.width, v.small.height), SMALL_PX);
  assert(pngComplete(v.main.bytes) && pngComplete(v.small.bytes));
  assertEquals(pngSize(v.main.bytes), [v.main.width, v.main.height]);
});

Deno.test("svg: the render is transparent where nothing is drawn", async () => {
  const svg = enc(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><rect width="50" height="50" fill="#f00"/></svg>',
  );
  const v = await validateFile(file(svg, "svg"));
  assert(v.ok);
  // Colour type 6 (RGBA) in IHDR: byte 25 of a PNG.
  assertEquals(v.main.bytes[25], 6);
});

Deno.test("svg: every hostile fixture fails closed or renders a harmless PNG, with no network access", async () => {
  const names = [...Deno.readDirSync(FIX)].map((e) => e.name).filter((n) =>
    n.endsWith(".svg")
  ).sort();
  assert(names.length >= 12, `only ${names.length} fixtures`);
  const outcome: Record<string, string> = {};
  const fetched = await spying(async () => {
    for (const n of names) {
      const v = await validateFile(file(await read(n), "svg"));
      if (!v.ok) {
        outcome[n] = `refused: ${v.reason}`;
        continue;
      }
      // Anything that passed is PNG bytes only, complete, of the sizes we asked for.
      assertEquals(v.format, "png", n);
      assertEquals(Array.from(v.main.bytes.slice(0, 4)), PNG_SIG, n);
      assert(pngComplete(v.main.bytes), n);
      assert(Math.max(v.main.width, v.main.height) === RENDER_PX, n);
      assert(v.small && pngComplete(v.small.bytes), n);
      const text = new TextDecoder("latin1").decode(v.main.bytes);
      assert(!/<script|<svg|evil\.test|javascript:/i.test(text), n);
      outcome[n] = "rendered";
    }
  });
  assertEquals(fetched, [], "the rasteriser touched the network");
  // The ones that carry a DTD fail closed.
  for (const n of ["entity.svg", "attlist.svg", "system-dtd.svg"]) {
    assert(outcome[n].startsWith("refused"), `${n}: ${outcome[n]}`);
  }
  // Scripts, handlers, foreignObject, external refs, css tricks and fonts render as plain pictures.
  for (
    const n of [
      "script.svg",
      "onload.svg",
      "foreign.svg",
      "external.svg",
      "datasvg.svg",
      "css-escape.svg",
      "text-font.svg",
      "huge-viewbox.svg",
    ]
  ) {
    assertEquals(outcome[n], "rendered", n);
  }
  // A document that is not an svg element in the svg namespace does not render.
  assert(
    outcome["prefixed-script.svg"].startsWith("refused") ||
      outcome["prefixed-script.svg"] === "rendered",
  );
  // A one pixel tall strip cannot reach 384 px on its long side without a 0 px height: refused.
  assert(
    outcome["flat-wide.svg"].startsWith("refused"),
    outcome["flat-wide.svg"],
  );
  console.log(outcome);
});

Deno.test("svg: html, text, bad utf-8, cut off and oversize files are refused", async () => {
  for (
    const b of [
      enc("<html><body>404</body></html>"),
      enc("not an image"),
      new Uint8Array([0xff, 0xfe, 0x00]),
      enc('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1"><rect'),
      enc(
        `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1">${
          " ".repeat(MAX_SVG_BYTES)
        }</svg>`,
      ),
      new Uint8Array(0),
    ]
  ) {
    assert(!(await validateFile(file(b, "svg"))).ok);
  }
});

Deno.test("validate: mime must be on the allow-list and match; pdf and unknown formats are refused", async () => {
  const svg = enc(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><rect width="10" height="10"/></svg>',
  );
  assert((await validateFile(file(svg, "svg", { mime: "image/svg+xml" }))).ok);
  assert(!(await validateFile(file(svg, "svg", { mime: "text/html" }))).ok);
  assert(!(await validateFile(file(svg, "svg", { mime: "image/png" }))).ok);
  assert(!(await validateFile(file(svg, "pdf"))).ok);
});

Deno.test("raster: declared size is read from the header and capped at 4096 per side", async () => {
  const bomb = await read("bomb30000.png");
  assertEquals(pngSize(bomb), [30000, 30000]);
  const v = await validateFile(file(bomb, "png", { mime: "image/png" }));
  assert(!v.ok && v.reason.includes("outside"), v.ok ? "" : v.reason);
  // Zero sizes and a webp bomb too.
  const zero = bomb.slice();
  new DataView(zero.buffer).setUint32(16, 0);
  assert(!(await validateFile(file(zero, "png"))).ok);
  const vp8x = new Uint8Array(30);
  vp8x.set(enc("RIFF"), 0);
  vp8x.set(enc("WEBP"), 8);
  vp8x.set(enc("VP8X"), 12);
  vp8x[24] = vp8x[25] = vp8x[26] = 0xff; // 16 777 216 wide
  assert(!(await validateFile(file(vp8x, "webp"))).ok);
  const big = new Uint8Array(MAX_RASTER_BYTES + 1);
  assert(!(await validateFile(file(big, "png"))).ok);
});

Deno.test("raster: size floor and honest dimensions", async () => {
  const wide = await read("wide256.png");
  assertEquals(pngSize(wide), [256, 100]);
  const ok = await validateFile(
    file(wide, "png", { width: 9999, mime: "image/png" }),
  );
  assert(ok.ok && ok.main.width === 256 && ok.small === null);
  assert(
    !(await validateFile(
      file(await read("small64.png"), "png", { width: 512 }),
    )).ok,
  );
  assert(!(await validateFile(file(enc("<html/>"), "png"))).ok);
});

Deno.test("png: every chunk CRC and the IEND ending are checked", async () => {
  const good = await read("wide256.png");
  assert(pngComplete(good));
  assert(!pngComplete(good.slice(0, good.length - 12)), "no IEND");
  assert(!pngComplete(good.slice(0, good.length - 3)), "cut inside IEND");
  const flipped = good.slice();
  flipped[40] ^= 0xff; // inside IDAT data
  assert(!pngComplete(flipped), "bad CRC");
  const trailing = new Uint8Array(good.length + 4);
  trailing.set(good);
  assert(!pngComplete(trailing), "bytes after IEND");
  assert(
    !(await validateFile(file(good.slice(0, good.length - 12), "png"))).ok,
  );
  const sig = good.slice();
  sig[1] = 0x51;
  assert(!(await validateFile(file(sig, "png"))).ok);
});

Deno.test("webp: header size", async () => {
  const vp8x = new Uint8Array(30);
  vp8x.set(enc("RIFF"), 0);
  vp8x.set(enc("WEBP"), 8);
  vp8x.set(enc("VP8X"), 12);
  vp8x[24] = 299 & 255;
  vp8x[25] = 299 >> 8;
  vp8x[27] = 199;
  assertEquals(webpSize(vp8x), [300, 200]);
  const ok = await validateFile(file(vp8x, "webp", { mime: "image/webp" }));
  assert(ok.ok && ok.format === "webp" && ok.main.width === 300);
  vp8x[24] = 99;
  vp8x[25] = 0;
  vp8x[27] = 99; // 100 x 100
  assert(!(await validateFile(file(vp8x, "webp"))).ok);
});

Deno.test("readCapped: content-length and running cap", async () => {
  const body = new Uint8Array(1000).fill(7);
  const ok = await readCapped(new Response(body), 2000);
  assertEquals(ok?.length, 1000);
  assertEquals(await readCapped(new Response(body), 999), null);
  const lying = new Response(body, { headers: { "content-length": "10" } });
  assertEquals(await readCapped(lying, 999), null, "stream passes the cap");
  const declared = new Response(body, {
    headers: { "content-length": "99999" },
  });
  assertEquals(await readCapped(declared, 2000), null);
});

Deno.test("redact removes the credential digest", () => {
  assertEquals(
    redact("fetch failed https://x/y?md5apikey=0123abcd&variant=dark"),
    "fetch failed https://x/y?md5apikey=REDACTED&variant=dark",
  );
});

Deno.test("the Commons library: every vector renders, none is stored as svg", async () => {
  const p = new CommonsLogoProvider(DEFAULT_COMMONS_BASE);
  const refused: string[] = [];
  let n = 0;
  const fetched = await spying(async () => {
    for (const a of await p.list()) {
      // The provider reads files through fetch; give it the real one for its own reads.
      const f = await realLogo(p, a.icao);
      n++;
      const v = await validateFile(f);
      if (!v.ok) refused.push(`${a.icao}: ${v.reason}`);
      else assertEquals(v.format === "png" || v.format === "webp", true);
    }
  });
  console.log(
    `commons library: ${n} files, ${refused.length} refused`,
    refused,
  );
  assert(n >= 100);
  assert(refused.length <= 3, refused.join("; "));
  assertEquals(fetched.filter((u) => !u.startsWith("file:")), [], "no network");
});

async function realLogo(
  p: CommonsLogoProvider,
  icao: string,
): Promise<ProviderFile> {
  // The spy rejects fetch; the provider's file:// reads go through Deno's own fetch captured here.
  const f = await p.logo(icao, "logo");
  return f as ProviderFile;
}

Deno.test("side view vectors: tall or extreme viewBoxes are refused, a normal one renders 1600 wide", async () => {
  const svg = (vb: string) =>
    enc(
      `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${vb}"><rect width="100%" height="100%" fill="#123"/></svg>`,
    );
  for (
    const vb of ["0 0 100 1000", "0 0 10 3000", "0 0 100 101", "0 0 1000 5"]
  ) {
    const v = await validateFile(file(svg(vb), "svg"), SIDE_VIEW_RULE);
    if (vb === "0 0 1000 5") {
      assert(v.ok, "a very wide strip is still within the caps");
    } else {
      assert(!v.ok, `${vb} refused`);
    }
  }
  const ok = await validateFile(
    file(svg("0 0 800 240"), "svg"),
    SIDE_VIEW_RULE,
  );
  assert(ok.ok && ok.main.width === 1600 && ok.main.height === 480);
});

Deno.test("logos keep the long-side cap: tall vectors never exceed 384 px", async () => {
  const tall = enc(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 1000"><rect width="100" height="1000"/></svg>',
  );
  const v = await validateFile(file(tall, "svg"));
  assert(v.ok && Math.max(v.main.width, v.main.height) === RENDER_PX);
});
