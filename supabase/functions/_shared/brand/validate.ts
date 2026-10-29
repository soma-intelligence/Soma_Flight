// Validation of every provider file before it reaches the bucket (all providers, one gate).
// A file passes only if: its mime (when the provider reported one) is on the allow-list and matches
// the format; its size is within the cap; its magic bytes match the format; rasters are at least
// 192 px on the long side (3x the 64 pt display size), read from the bytes and not from the provider's
// claim; SVGs are sanitised (script, foreignObject, event handlers, external references removed) and
// rejected when anything unsafe survives. The returned bytes are what gets stored.
import type { ProviderFile } from "./logo_provider.ts";

export const MIME_FOR = {
  svg: "image/svg+xml",
  png: "image/png",
  webp: "image/webp",
} as const;
export const MAX_SVG_BYTES = 512 * 1024;
export const MAX_RASTER_BYTES = 2 * 1024 * 1024;
export const MIN_RASTER_PX = 192;

export type Validated =
  | {
    ok: true;
    bytes: Uint8Array;
    format: "svg" | "png" | "webp";
    width: number | null;
    mime: string;
  }
  | { ok: false; reason: string };

const bad = (reason: string): Validated => ({ ok: false, reason });
const PNG_SIG = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

function startsWith(b: Uint8Array, sig: number[], at = 0): boolean {
  return b.length >= at + sig.length && sig.every((v, i) => b[at + i] === v);
}
const ascii = (b: Uint8Array, from: number, to: number) =>
  String.fromCharCode(...b.slice(from, to));

/** [width, height] from the IHDR chunk, or null when it is not a PNG. */
export function pngSize(b: Uint8Array): [number, number] | null {
  if (b.length < 24 || !startsWith(b, PNG_SIG) || ascii(b, 12, 16) !== "IHDR") {
    return null;
  }
  const v = new DataView(b.buffer, b.byteOffset, b.byteLength);
  return [v.getUint32(16), v.getUint32(20)];
}

/** [width, height] of a WebP (VP8, VP8L or VP8X), or null. */
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

const DATA_IMAGE =
  /^data:image\/(png|jpeg|gif|webp);base64,[A-Za-z0-9+/=\s]*$/i;
const REMOVE_ELEMENTS = [
  "script",
  "foreignObject",
  "iframe",
  "embed",
  "object",
  "audio",
  "video",
  "canvas",
  "animate",
  "animateTransform",
  "animateMotion",
  "set",
  "handler",
];

/** Strips what can run code or fetch something. Pure string work; the caller re-checks the result. */
export function sanitizeSvg(text: string): string {
  let t = text;
  for (const el of REMOVE_ELEMENTS) {
    t = t.replace(
      new RegExp(
        `<${el}\\b[^>]*?/>|<${el}\\b[^>]*>[\\s\\S]*?</${el}\\s*>`,
        "gi",
      ),
      "",
    );
    t = t.replace(new RegExp(`</?${el}\\b[^>]*>`, "gi"), ""); // stray open or close tags
  }
  // Event handler attributes, quoted or bare.
  t = t.replace(/\s+on[a-z]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/gi, "");
  // href and xlink:href: a fragment or an embedded raster image only.
  t = t.replace(
    /\s+((?:xlink:)?href)\s*=\s*("([^"]*)"|'([^']*)')/gi,
    (m, _n, _q, dq, sq) => {
      const v = String(dq ?? sq ?? "").trim();
      return v.startsWith("#") || DATA_IMAGE.test(v) ? m : "";
    },
  );
  t = t.replace(/\s+(?:xlink:)?href\s*=\s*[^\s>"'][^\s>]*/gi, ""); // unquoted
  // CSS: no @import, and url() only to a fragment or an embedded raster image.
  t = t.replace(/@import[^;]*;?/gi, "");
  t = t.replace(
    /url\(\s*(['"]?)(.*?)\1\s*\)/gi,
    (m, _q, v) => {
      const s = String(v).trim();
      return s.startsWith("#") || DATA_IMAGE.test(s) ? m : "none";
    },
  );
  // javascript: anywhere in an attribute value.
  t = t.replace(
    /\s+[\w:-]+\s*=\s*("[^"]*javascript:[^"]*"|'[^']*javascript:[^']*')/gi,
    "",
  );
  return t;
}

const SAFE_REF = /^(#|data:image\/(png|jpeg|gif|webp);base64,)/i;

/**
 * Entity declarations are allowed only as plain internal text values (Inkscape declares namespaces
 * that way): no SYSTEM or PUBLIC, and no reference to another entity, so nothing can expand or fetch.
 */
function entitiesSafe(t: string): boolean {
  const decls = t.match(/<!ENTITY[^>]*>/gi) ?? [];
  return decls.every((d) =>
    /^<!ENTITY\s+[\w.-]+\s+(?:"[^"&]*"|'[^'&]*')\s*>$/i.test(d)
  );
}

/** Anything unsafe that survives sanitising rejects the file. */
function unsafeLeft(t: string): string | null {
  if (/<\s*(script|foreignObject|iframe|embed|object)\b/i.test(t)) {
    return "script-like element";
  }
  if (/\son[a-z]+\s*=/i.test(t)) return "event handler";
  if (/javascript:/i.test(t)) return "javascript url";
  if (!entitiesSafe(t)) return "entity declaration";
  for (
    const m of t.matchAll(/\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/gi)
  ) {
    if (!SAFE_REF.test((m[1] ?? m[2] ?? m[3] ?? "").trim())) {
      return "external reference";
    }
  }
  for (const m of t.matchAll(/url\(\s*(['"]?)(.*?)\1\s*\)/gi)) {
    if (!SAFE_REF.test(m[2].trim())) return "external css reference";
  }
  return null;
}

export function validateFile(file: ProviderFile): Validated {
  const fmt = file.format;
  if (fmt !== "svg" && fmt !== "png" && fmt !== "webp") {
    return bad(`format ${fmt} is not allowed`);
  }
  const expected = MIME_FOR[fmt];
  if (file.mime != null) {
    const m = file.mime.split(";")[0].trim().toLowerCase();
    if (m !== expected) return bad(`mime ${m} does not match ${fmt}`);
  }
  const b = file.bytes;
  if (b.length === 0) return bad("empty file");
  if (fmt === "svg") {
    if (b.length > MAX_SVG_BYTES) return bad("svg over 512 KB");
    let text: string;
    try {
      text = new TextDecoder("utf-8", { fatal: true }).decode(b);
    } catch {
      return bad("svg is not utf-8");
    }
    const head = text.replace(/^﻿/, "").replace(
      /^(\s|<\?xml[\s\S]*?\?>|<!--[\s\S]*?-->|<!DOCTYPE[^>\[]*(\[[\s\S]*?\])?\s*>)*/i,
      "",
    );
    if (!/^<svg[\s>]/i.test(head)) return bad("not an svg document");
    if (!entitiesSafe(text)) return bad("entity declaration");
    let clean = text;
    for (let i = 0; i < 3; i++) {
      const next = sanitizeSvg(clean);
      if (next === clean) break;
      clean = next;
    }
    const left = unsafeLeft(clean);
    if (left) return bad(`unsafe svg: ${left}`);
    if (!/<\/svg\s*>|<svg\b[^>]*\/>/i.test(clean)) return bad("svg is cut off");
    return {
      ok: true,
      bytes: new TextEncoder().encode(clean),
      format: "svg",
      width: null,
      mime: expected,
    };
  }
  if (b.length > MAX_RASTER_BYTES) return bad("raster over 2 MB");
  const size = fmt === "png" ? pngSize(b) : webpSize(b);
  if (!size) return bad(`bytes are not a ${fmt}`);
  const [w, h] = size;
  if (Math.max(w, h) < MIN_RASTER_PX) {
    return bad(`raster ${w}x${h} under ${MIN_RASTER_PX} px`);
  }
  return { ok: true, bytes: b, format: fmt, width: w, mime: expected };
}
