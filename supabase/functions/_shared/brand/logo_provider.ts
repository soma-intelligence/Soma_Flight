// Logo provider port. The sync talks to this interface only, so a second provider (or the fake in
// tests) plugs in without touching it. A provider holds the licence key; nothing here reaches a device.

/**
 * What a provider can serve. `tail_logo` is stored as the `tail` kind of airline_assets;
 * `side_view` is keyed by airline and aircraft type.
 */
export type AssetKind =
  | "logo"
  | "logo_dark"
  | "tail_logo"
  | "side_view"
  | "wordmark";
/** Old name of AssetKind, kept for the adapters. */
export type LogoKind = AssetKind;

/** airline_assets.kind for a port kind. */
export function dbKind(
  kind: AssetKind,
): "logo" | "logo_dark" | "tail" | "side_view" | "wordmark" {
  return kind === "tail_logo" ? "tail" : kind;
}

/**
 * Precedence between providers: a licensed provider beats Commons, Commons beats nothing.
 * A row written by a higher-ranked provider is never replaced by a lower one; a lower-ranked row is
 * replaced as soon as a higher-ranked provider has the file. Equal ranks never replace each other.
 * Unknown provider names rank as Commons (1).
 */
export const PROVIDER_RANKS: Record<string, number> = { airhex: 2, commons: 1 };
export function providerRank(name: string): number {
  return PROVIDER_RANKS[name] ?? 1;
}

export interface ProviderAirline {
  icao: string;
  iata: string | null;
  name: string;
}

export interface ProviderFile {
  bytes: Uint8Array;
  format: "svg" | "pdf" | "png" | "webp";
  /** Pixel width for rasters, null for vectors. The sync re-reads it from the bytes. */
  width: number | null;
  /** Content version: a prefix of the sha256 of the bytes. Names the stored object. */
  version: string;
  /** The provider's validator when it sends one. Compared first when both sides have it. */
  etag: string | null;
  /** Content type the provider reported, when it reported one. Checked against the allow-list. */
  mime?: string | null;
}

/** What the sync already holds for an asset, so a provider can answer "unchanged" without a body. */
export interface KnownAsset {
  etag: string | null;
  version: string;
  format: string;
}

export interface FetchOpts {
  /** Aircraft ICAO type, side views only. */
  aircraftType?: string;
  known?: KnownAsset;
}

export interface BrandColors {
  primary: string; // #RRGGBB
  secondary: string | null;
}

export interface LogoProvider {
  readonly name: string;
  /** Precedence (see PROVIDER_RANKS). */
  readonly rank: number;
  /** The kinds this provider can serve; the sync never asks for others and never drops their rows. */
  readonly kinds: readonly AssetKind[];
  /** False when the provider has no brand colours; the sync then never touches colours. */
  readonly hasColors: boolean;
  list(): Promise<ProviderAirline[]>;
  /**
   * null when the provider has no such file; "unchanged" when `opts.known` is still current (no
   * body downloaded); throws ProviderUnavailable on outages (5xx, 429, network).
   */
  logo(
    icao: string,
    kind: AssetKind,
    opts?: FetchOpts,
  ): Promise<ProviderFile | "unchanged" | null>;
  /** Aircraft types with a side view for this airline; only providers with side_view in kinds. */
  sideViewTypes?(icao: string): Promise<string[]>;
  colors(icao: string): Promise<BrandColors | null>;
}

/** Largest body any provider file may have (the raster cap); the SVG cap is checked after. */
export const MAX_BODY_BYTES = 2 * 1024 * 1024;

/**
 * Reads a response body with a running byte cap: content-length is checked first, then the stream is
 * cancelled as soon as it passes the cap. Returns null when the body is too large.
 */
export async function readCapped(
  res: Response,
  max = MAX_BODY_BYTES,
): Promise<Uint8Array | null> {
  const declared = Number(res.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > max) {
    await res.body?.cancel();
    return null;
  }
  if (!res.body) return new Uint8Array(0);
  const reader = res.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.length;
    if (total > max) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  const out = new Uint8Array(total);
  let at = 0;
  for (const c of chunks) {
    out.set(c, at);
    at += c.length;
  }
  return out;
}

/** Removes the provider credential digest from text that may reach logs or errors. */
export function redact(text: string): string {
  return text.replace(/md5apikey=[^&\s"')]*/gi, "md5apikey=REDACTED");
}

export class ProviderUnavailable extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ProviderUnavailable";
  }
}

export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", bytes as BufferSource);
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/** Short content version used in object names. */
export async function contentVersion(bytes: Uint8Array): Promise<string> {
  return (await sha256Hex(bytes)).slice(0, 16);
}

export interface FakeFile {
  bytes: Uint8Array;
  format?: "svg" | "pdf" | "png" | "webp";
  width?: number | null;
  version: string;
  etag?: string | null;
  mime?: string | null;
}

/** Test double: configurable list, files, colours and failures; counts every call. */
export class FakeLogoProvider implements LogoProvider {
  readonly name: string;
  rank: number;
  kinds: readonly AssetKind[] = ["logo", "logo_dark", "tail_logo"];
  hasColors = true;
  airlines: ProviderAirline[] = [];
  files = new Map<string, FakeFile>(); // key `${icao}/${kind}` or `${icao}/side_view/${type}`
  colorsBy = new Map<string, BrandColors>();
  failIcao = new Set<string>();
  /** Every call throws ProviderUnavailable (an outage). */
  outage = false;
  calls = { list: 0, logo: 0, colors: 0 };
  /** logo calls that returned a body vs. calls answered "unchanged" or null. */
  downloads = 0;
  checks = 0;

  constructor(name = "fake") {
    this.name = name;
    this.rank = providerRank(name);
  }

  list(): Promise<ProviderAirline[]> {
    this.calls.list++;
    return Promise.resolve(this.airlines);
  }

  sideViewTypes(icao: string): Promise<string[]> {
    const p = `${icao}/side_view/`;
    return Promise.resolve(
      [...this.files.keys()].filter((k) => k.startsWith(p)).map((k) =>
        k.slice(p.length)
      ),
    );
  }

  logo(
    icao: string,
    kind: AssetKind,
    opts: FetchOpts = {},
  ): Promise<ProviderFile | "unchanged" | null> {
    this.calls.logo++;
    this.checks++;
    if (this.outage) {
      return Promise.reject(new ProviderUnavailable("fake outage"));
    }
    if (this.failIcao.has(icao)) {
      return Promise.reject(new Error(`fake bad data ${icao}`));
    }
    const key = kind === "side_view"
      ? `${icao}/side_view/${opts.aircraftType}`
      : `${icao}/${kind}`;
    const f = this.files.get(key);
    if (!f) return Promise.resolve(null);
    const known = opts.known;
    if (
      known &&
      (f.etag != null && known.etag != null
        ? f.etag === known.etag
        : f.version === known.version)
    ) {
      return Promise.resolve("unchanged");
    }
    this.downloads++;
    return Promise.resolve({
      bytes: f.bytes,
      format: f.format ?? "svg",
      width: f.width ?? null,
      version: f.version,
      etag: f.etag ?? null,
      mime: f.mime,
    });
  }

  colors(icao: string): Promise<BrandColors | null> {
    this.calls.colors++;
    return Promise.resolve(this.colorsBy.get(icao) ?? null);
  }
}
