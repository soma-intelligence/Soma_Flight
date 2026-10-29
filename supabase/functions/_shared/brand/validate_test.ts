import { assert, assertEquals } from "jsr:@std/assert@1";
import { CommonsLogoProvider, DEFAULT_COMMONS_BASE } from "./commons.ts";
import type { ProviderFile } from "./logo_provider.ts";
import { redact } from "./logo_provider.ts";
import {
  MAX_RASTER_BYTES,
  MAX_SVG_BYTES,
  pngSize,
  sanitizeSvg,
  validateFile,
  webpSize,
} from "./validate.ts";

const EVIL = new URL("../fixtures/svg-evil/", import.meta.url);
const read = (n: string) => Deno.readFile(new URL(n, EVIL));
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

function svgOut(v: ReturnType<typeof validateFile>): string {
  assert(v.ok, v.ok ? "" : v.reason);
  return new TextDecoder().decode(v.bytes);
}

Deno.test("validate: a clean svg passes unchanged in meaning", async () => {
  const out = svgOut(validateFile(file(await read("clean.svg"), "svg", {
    mime: "image/svg+xml; charset=utf-8",
  })));
  assert(out.includes("url(#g)") && out.includes('href="#g"'));
  assert(out.includes("data:image/png;base64,"));
});

Deno.test("validate: script, handlers and foreignObject are stripped", async () => {
  for (const name of ["script.svg", "onload.svg", "foreign.svg"]) {
    const out = svgOut(validateFile(file(await read(name), "svg")));
    assert(
      !/script|foreignobject|iframe|\son\w+=/i.test(out),
      `${name}: ${out}`,
    );
    assert(out.includes("<rect"), `${name} keeps its drawing`);
  }
});

Deno.test("validate: external hrefs, javascript urls and external css refs are stripped", async () => {
  const out = svgOut(validateFile(file(await read("external.svg"), "svg")));
  assert(!/evil\.test|javascript:/i.test(out), out);
  assert(out.includes("<rect"));
});

Deno.test("validate: an embedded svg data uri is stripped, entities are rejected", async () => {
  const out = svgOut(validateFile(file(await read("datasvg.svg"), "svg")));
  assert(!out.includes("data:image/svg"), out);
  const v = validateFile(file(await read("entity.svg"), "svg"));
  assert(!v.ok);
});

Deno.test("validate: sanitising is idempotent and nesting tricks do not survive", () => {
  const nested =
    '<svg xmlns="x"><scr<script></script>ipt>alert(1)</scr<script></script>ipt></svg>';
  const v = validateFile(file(enc(nested), "svg"));
  if (v.ok) assert(!/<script/i.test(new TextDecoder().decode(v.bytes)));
  const once = sanitizeSvg(nested);
  assert(!/<script[\s>]/i.test(sanitizeSvg(once)) || !v.ok);
});

Deno.test("validate: html or text dressed as svg is rejected", () => {
  assert(!validateFile(file(enc("<html><body>404</body></html>"), "svg")).ok);
  assert(!validateFile(file(enc("not an image"), "svg")).ok);
  assert(!validateFile(file(new Uint8Array([0xff, 0xfe, 0x00]), "svg")).ok);
  assert(!validateFile(file(enc('<svg xmlns="x"><rect'), "svg")).ok); // cut off
});

Deno.test("validate: mime must be on the allow-list and match the format", () => {
  const svg = enc("<svg xmlns='http://www.w3.org/2000/svg'/>");
  assert(validateFile(file(svg, "svg", { mime: "image/svg+xml" })).ok);
  assert(!validateFile(file(svg, "svg", { mime: "text/html" })).ok);
  assert(!validateFile(file(svg, "svg", { mime: "image/png" })).ok);
  assert(!validateFile(file(svg, "pdf")).ok);
});

Deno.test("validate: size caps", () => {
  const big = enc(`<svg xmlns="x">${" ".repeat(MAX_SVG_BYTES)}</svg>`);
  assert(!validateFile(file(big, "svg")).ok);
  const png = new Uint8Array(MAX_RASTER_BYTES + 1);
  assert(!validateFile(file(png, "png")).ok);
});

Deno.test("validate: png magic bytes and IHDR size decide, not the provider's claim", async () => {
  const wide = await Deno.readFile(
    new URL("../fixtures/svg-evil/wide256.png", import.meta.url),
  );
  assertEquals(pngSize(wide), [256, 100]);
  const ok = validateFile(
    file(wide, "png", { width: 9999, mime: "image/png" }),
  );
  assert(ok.ok && ok.width === 256);
  const small = await Deno.readFile(
    new URL("../fixtures/svg-evil/small64.png", import.meta.url),
  );
  assert(!validateFile(file(small, "png", { width: 512 })).ok);
  assert(!validateFile(file(wide.slice(0, 20), "png")).ok); // truncated header
  assert(!validateFile(file(enc("<html/>"), "png")).ok);
  const sig = wide.slice();
  sig[1] = 0x51;
  assert(!validateFile(file(sig, "png")).ok);
});

Deno.test("validate: webp header and size", () => {
  const vp8x = new Uint8Array(30);
  vp8x.set(enc("RIFF"), 0);
  vp8x.set(enc("WEBP"), 8);
  vp8x.set(enc("VP8X"), 12);
  // width 300 -> 299, height 200 -> 199 (24-bit little endian)
  vp8x[24] = 299 & 255;
  vp8x[25] = 299 >> 8;
  vp8x[27] = 199;
  assertEquals(webpSize(vp8x), [300, 200]);
  const ok = validateFile(file(vp8x, "webp", { mime: "image/webp" }));
  assert(ok.ok && ok.width === 300);
  vp8x[24] = 99; // 100 wide, 200 tall: long side 200 still passes
  vp8x[25] = 0;
  assert(validateFile(file(vp8x, "webp")).ok);
  vp8x[27] = 99; // 100 x 100
  assert(!validateFile(file(vp8x, "webp")).ok);
  assert(
    !validateFile(file(enc("RIFFxxxxWEBPjunkjunkjunkjunkjunk"), "webp")).ok,
  );
});

Deno.test("redact removes the credential digest", () => {
  assertEquals(
    redact("fetch failed https://x/y?md5apikey=0123abcd&variant=dark"),
    "fetch failed https://x/y?md5apikey=REDACTED&variant=dark",
  );
});

Deno.test("validate: every file of the Commons library passes (sanitised where needed)", async () => {
  const p = new CommonsLogoProvider(DEFAULT_COMMONS_BASE);
  const refused: string[] = [];
  let n = 0;
  for (const a of await p.list()) {
    const f = await p.logo(a.icao, "logo") as ProviderFile;
    n++;
    const v = validateFile(f);
    if (!v.ok) refused.push(`${a.icao}: ${v.reason}`);
  }
  console.log(
    `commons library: ${n} files, ${refused.length} refused`,
    refused.slice(0, 10),
  );
  assertEquals(refused.length, 0, refused.join("; "));
});
