// Logo provider port. The sync talks to this interface only, so a second provider (or the fake in
// tests) plugs in without touching it. A provider holds the licence key; nothing here reaches a device.

export type LogoKind = "logo" | "logo_dark" | "tail";

export interface ProviderAirline {
  icao: string;
  iata: string | null;
  name: string;
}

export interface ProviderFile {
  bytes: Uint8Array;
  format: "svg" | "pdf" | "png";
  /** Pixel width for rasters, null for vectors. */
  width: number | null;
  /** Content version: a prefix of the sha256 of the bytes. Names the stored object. */
  version: string;
  /** The provider's validator when it sends one. Compared first when both sides have it. */
  etag: string | null;
}

export interface BrandColors {
  primary: string; // #RRGGBB
  secondary: string | null;
}

export interface LogoProvider {
  readonly name: string;
  list(): Promise<ProviderAirline[]>;
  /** null when the provider has no such file; throws ProviderUnavailable on outages. */
  logo(icao: string, kind: LogoKind): Promise<ProviderFile | null>;
  colors(icao: string): Promise<BrandColors | null>;
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
  format?: "svg" | "pdf" | "png";
  width?: number | null;
  version: string;
  etag?: string | null;
}

/** Test double: configurable list, files, colours and failures; counts every call. */
export class FakeLogoProvider implements LogoProvider {
  readonly name: string;
  airlines: ProviderAirline[] = [];
  files = new Map<string, FakeFile>(); // key `${icao}/${kind}`
  colorsBy = new Map<string, BrandColors>();
  failIcao = new Set<string>();
  calls = { list: 0, logo: 0, colors: 0 };

  constructor(name = "fake") {
    this.name = name;
  }

  list(): Promise<ProviderAirline[]> {
    this.calls.list++;
    return Promise.resolve(this.airlines);
  }

  logo(icao: string, kind: LogoKind): Promise<ProviderFile | null> {
    this.calls.logo++;
    if (this.failIcao.has(icao)) {
      return Promise.reject(new ProviderUnavailable(`fake outage ${icao}`));
    }
    const f = this.files.get(`${icao}/${kind}`);
    if (!f) return Promise.resolve(null);
    return Promise.resolve({
      bytes: f.bytes,
      format: f.format ?? "svg",
      width: f.width ?? null,
      version: f.version,
      etag: f.etag ?? null,
    });
  }

  colors(icao: string): Promise<BrandColors | null> {
    this.calls.colors++;
    return Promise.resolve(this.colorsBy.get(icao) ?? null);
  }
}
