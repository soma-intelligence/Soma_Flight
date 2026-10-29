// The one gate every provider file passes before it reaches the bucket.
//
// SVG is never stored or served. A vector is checked for size and shape, then rasterised here with
// resvg (WASM; it runs no scripts, loads no fonts and fetches nothing) into PNGs at 384 px and 192 px
// on the long side, on a transparent background. Only PNG (or a validated WebP) is stored.
//
// Fail closed, in this order: format on the allow-list and mime matching the format; size cap (SVG
// 512 KB, raster 2 MB); SVG must be UTF-8 with an <svg root, with no DOCTYPE carrying an internal
// subset or an external id (no entities, no DTD defaults); rasters need magic bytes, declared
// dimensions read from the header (1..4096 per side, long side at least 192) before any decode, and for
// PNG a walk of every chunk with CRC check ending in IEND. Anything else is a refusal with a reason.
import { initWasm, Resvg } from "npm:@resvg/resvg-wasm@2.6.2";
import type { ProviderFile } from "./logo_provider.ts";

export const RESVG_VERSION = "2.6.2";
export const MIME_FOR = {
  svg: "image/svg+xml",
  png: "image/png",
  webp: "image/webp",
} as const;
export const MAX_SVG_BYTES = 512 * 1024;
export const MAX_RASTER_BYTES = 2 * 1024 * 1024;
export const MIN_RASTER_PX = 192;
export const MAX_RASTER_PX = 4096;
/** Long sides of the PNGs rendered from a vector: the stored asset and the small one. */
export const RENDER_PX = 384;
export const SMALL_PX = 192;

export interface Png {
  bytes: Uint8Array;
  width: number;
  height: number;
}

export type Validated =
  | {
    ok: true;
    format: "png" | "webp";
    mime: "image/png" | "image/webp";
    /** The asset to store and sign. */
    main: Png;
    /** The 192 px long-side rendition, only for rendered vectors. */
    small: Png | null;
  }
  | { ok: false; reason: string };

const bad = (reason: string): Validated => ({ ok: false, reason });
const PNG_SIG = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

function startsWith(b: Uint8Array, sig: number[], at = 0): boolean {
  return b.length >= at + sig.length && sig.every((v, i) => b[at + i] === v);
}
const ascii = (b: Uint8Array, from: number, to: number) =>
  String.fromCharCode(...b.slice(from, to));

/** [width, height] from the IHDR chunk, or null when it is not a PNG. Header only, no decode. */
export function pngSize(b: Uint8Array): [number, number] | null {
  if (b.length < 24 || !startsWith(b, PNG_SIG) || ascii(b, 12, 16) !== "IHDR") {
    return null;
  }
  const v = new DataView(b.buffer, b.byteOffset, b.byteLength);
  return [v.getUint32(16), v.getUint32(20)];
}

/** [width, height] of a WebP (VP8, VP8L or VP8X) from its header, or null. */
export function webpSize(b: Uint8Array): [number, number] | null {
  if (
    b.length < 30 || ascii(b, 0, 4) !== "RIFF" || ascii(b, 8, 12) !== "WEBP"
  ) {
    return null;
  }
  const chunk = ascii(b, 12, 16);
  if (chunk === "VP8X") {
    const w = 1 + (b[24] | (b[25] << 8) | (b[26] << 16));
    const h = 1 + (b[27] | (b[28] << 8) | (b[29] << 16));
    return [w, h];
  }
  if (chunk === "VP8L" && b[20] === 0x2f) {
    const bits = b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24);
    return [1 + (bits & 0x3fff), 1 + ((bits >> 14) & 0x3fff)];
  }
  if (chunk === "VP8 " && b[23] === 0x9d && b[24] === 0x01 && b[25] === 0x2a) {
    return [(b[26] | (b[27] << 8)) & 0x3fff, (b[28] | (b[29] << 8)) & 0x3fff];
  }
  return null;
}

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

function crc32(b: Uint8Array, from: number, to: number): number {
  let c = 0xffffffff;
  for (let i = from; i < to; i++) c = CRC_TABLE[(c ^ b[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

/** Walks every chunk: lengths in range, CRCs right, IHDR first, an IDAT, IEND last and final. */
export function pngComplete(b: Uint8Array): boolean {
  if (!startsWith(b, PNG_SIG)) return false;
  const v = new DataView(b.buffer, b.byteOffset, b.byteLength);
  let pos = 8;
  let first = true;
  let idat = false;
  while (pos + 12 <= b.length) {
    const len = v.getUint32(pos);
    const end = pos + 12 + len;
    if (end > b.length) return false;
    const type = ascii(b, pos + 4, pos + 8);
    if (first && type !== "IHDR") return false;
    first = false;
    if (crc32(b, pos + 4, pos + 8 + len) !== v.getUint32(pos + 8 + len)) {
      return false;
    }
    if (type === "IDAT") idat = true;
    if (type === "IEND") return len === 0 && idat && end === b.length;
    pos = end;
  }
  return false;
}

// ---- rasterising vectors ----

let ready: Promise<void> | undefined;
/** Loads the vendored resvg WASM once. */
function resvgReady(): Promise<void> {
  return ready ??= (async () => {
    const bytes = await Deno.readFile(
      new URL("./resvg/resvg_bg.wasm", import.meta.url),
    );
    await initWasm(await WebAssembly.compile(bytes));
  })().catch((e) => {
    ready = undefined;
    throw e;
  });
}

/** Resvg options: no system fonts, no font files; the WASM build has no file or network access anyway. */
const OPTS = { font: { loadSystemFonts: false, fontFiles: [] } };

function renderPng(svg: string, size: number, byWidth = false): Png {
  const probe = new Resvg(svg, OPTS);
  const wide = probe.width >= probe.height;
  if (!(probe.width > 0 && probe.height > 0)) throw new Error("empty svg");
  probe.free();
  const r = new Resvg(svg, {
    ...OPTS,
    fitTo: byWidth || wide
      ? { mode: "width", value: size }
      : { mode: "height", value: size },
  });
  const img = r.render();
  const bytes = img.asPng();
  const out = { bytes, width: img.width, height: img.height };
  img.free();
  r.free();
  return out;
}

/** DOCTYPE with an internal subset or an external id is refused outright. */
function doctypeRefusal(text: string): string | null {
  const m = /<!DOCTYPE\b[^>]*?(\[|>)/i.exec(text);
  if (/<!ENTITY|<!ATTLIST|<!ELEMENT/i.test(text)) return "dtd declaration";
  if (!m) return null;
  if (m[1] === "[") return "doctype with an internal subset";
  const decl = /<!DOCTYPE\b[^>]*>/i.exec(text)![0];
  if (/\bSYSTEM\b/i.test(decl)) return "doctype with an external id";
  // The W3C SVG public id is what older editors write; resvg never fetches the DTD it names.
  if (
    /\bPUBLIC\b/i.test(decl) && !/PUBLIC\s+["']-\/\/W3C\/\/DTD SVG/i.test(decl)
  ) {
    return "doctype with an external id";
  }
  return null;
}

/**
 * Extra rules for one kind of asset. Side views are PNG only (no WebP), at least 1200 px wide, and a
 * vector is rendered 1600 px wide with no small rendition.
 */
export interface ValidateRule {
  pngOnly?: boolean;
  minWidth?: number;
  /** Render a vector this many px wide (instead of 384 px on the long side) and skip the small one. */
  svgWidth?: number;
}
export const SIDE_VIEW_RULE: ValidateRule = {
  pngOnly: true,
  minWidth: 1200,
  svgWidth: 1600,
};

/**
 * Flips a PNG left to right (same size, transparency kept) by rendering it through resvg as an
 * embedded image. Used when a provider draws the nose to the right.
 */
export async function mirrorPng(png: Png): Promise<Png> {
  await resvgReady();
  let bin = "";
  for (let i = 0; i < png.bytes.length; i += 0x8000) {
    bin += String.fromCharCode(...png.bytes.subarray(i, i + 0x8000));
  }
  const { width: w, height: h } = png;
  const svg =
    `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}"><image width="${w}" height="${h}" transform="translate(${w} 0) scale(-1 1)" href="data:image/png;base64,${
      btoa(bin)
    }"/></svg>`;
  const out = renderPng(svg, w, true);
  if (out.width !== w || out.height !== h || !pngComplete(out.bytes)) {
    throw new Error("mirror produced a different image");
  }
  return out;
}

async function rasteriseSvg(
  file: ProviderFile,
  rule?: ValidateRule,
): Promise<Validated> {
  const b = file.bytes;
  if (b.length > MAX_SVG_BYTES) return bad("svg over 512 KB");
  let text: string;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(b);
  } catch {
    return bad("svg is not utf-8");
  }
  const refusal = doctypeRefusal(text);
  if (refusal) return bad(refusal);
  const head = text.replace(/^﻿/, "").replace(
    /^(\s|<\?xml[\s\S]*?\?>|<!--[\s\S]*?-->|<!DOCTYPE[^>\[]*>)*/i,
    "",
  );
  if (!/^<svg[\s>]/i.test(head)) return bad("not an svg document");
  try {
    await resvgReady();
    const main = rule?.svgWidth
      ? renderPng(text, rule.svgWidth, true)
      : renderPng(text, RENDER_PX);
    const small = rule?.svgWidth ? null : renderPng(text, SMALL_PX);
    for (const p of small ? [main, small] : [main]) {
      if (!pngComplete(p.bytes)) return bad("render produced a broken png");
    }
    return {
      ok: true,
      format: "png",
      mime: "image/png",
      main,
      small,
    };
  } catch (e) {
    return bad(`svg does not render: ${(e as Error).message}`);
  }
}

export async function validateFile(
  file: ProviderFile,
  rule?: ValidateRule,
): Promise<Validated> {
  const fmt = file.format;
  if (fmt !== "svg" && fmt !== "png" && fmt !== "webp") {
    return bad(`format ${fmt} is not allowed`);
  }
  if (rule?.pngOnly && fmt === "webp") return bad("webp is not allowed here");
  if (file.mime != null) {
    const m = file.mime.split(";")[0].trim().toLowerCase();
    if (m !== MIME_FOR[fmt]) return bad(`mime ${m} does not match ${fmt}`);
  }
  const b = file.bytes;
  if (b.length === 0) return bad("empty file");
  if (fmt === "svg") return await rasteriseSvg(file, rule);

  if (b.length > MAX_RASTER_BYTES) return bad("raster over 2 MB");
  // Declared size from the header first; nothing is decoded before this passes.
  const size = fmt === "png" ? pngSize(b) : webpSize(b);
  if (!size) return bad(`bytes are not a ${fmt}`);
  const [w, h] = size;
  if (w < 1 || h < 1 || w > MAX_RASTER_PX || h > MAX_RASTER_PX) {
    return bad(`raster ${w}x${h} outside 1 to ${MAX_RASTER_PX} px`);
  }
  if (Math.max(w, h) < MIN_RASTER_PX) {
    return bad(`raster ${w}x${h} under ${MIN_RASTER_PX} px`);
  }
  if (rule?.minWidth && w < rule.minWidth) {
    return bad(`raster ${w}x${h} under ${rule.minWidth} px wide`);
  }
  if (fmt === "png" && !pngComplete(b)) {
    return bad("png is truncated or corrupt");
  }
  return {
    ok: true,
    format: fmt,
    mime: MIME_FOR[fmt],
    main: { bytes: b, width: w, height: h },
    small: null,
  };
}
