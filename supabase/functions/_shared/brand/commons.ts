// Wikimedia Commons logo library (Task 8b). Reads assets/logos/commons/manifest.json and the files it
// names, built by Scripts/logos/fetch_commons.py. Free licences only (public domain, CC0, CC BY,
// CC BY-SA), attribution shown in the app's Acknowledgements. Used for local development and until
// the Airhex licence is signed: LOGO_PROVIDER=commons selects it, Airhex replaces it once licensed.
// The base is a URL: file:// for the repo copy (the default) or http(s):// when the edge runtime
// cannot see the repo (serve assets/logos/commons and set COMMONS_LOGO_BASE).
// Only the main logo exists here: no dark variant, no tail, no brand colours.
import {
  type BrandColors,
  contentVersion,
  type LogoKind,
  type LogoProvider,
  type ProviderAirline,
  type ProviderFile,
  ProviderUnavailable,
  sha256Hex,
} from "./logo_provider.ts";

/** The repo copy, resolved from this file: supabase/functions/_shared/brand -> assets/logos/commons. */
export const DEFAULT_COMMONS_BASE = new URL(
  "../../../../assets/logos/commons/",
  import.meta.url,
);

export interface CommonsEntry {
  name: string;
  iata: string | null;
  file: string;
  format: "svg" | "png";
  sha256: string;
  png_size: [number, number];
  license: string;
  source_page: string;
  attribution: string;
}

interface Manifest {
  logos: Record<string, CommonsEntry>;
}

export class CommonsLogoProvider implements LogoProvider {
  readonly name = "commons";
  private readonly base: URL;
  private manifest?: Promise<Manifest>;

  constructor(
    base: URL | string = DEFAULT_COMMONS_BASE,
    private readonly fetchFn: typeof fetch = fetch,
  ) {
    const s = String(base);
    this.base = new URL(s.endsWith("/") ? s : `${s}/`);
  }

  private async get(name: string): Promise<Response> {
    try {
      return await this.fetchFn(new URL(name, this.base));
    } catch (e) {
      throw new ProviderUnavailable(
        `commons library unreachable: ${(e as Error).message}`,
      );
    }
  }

  private load(): Promise<Manifest> {
    return this.manifest ??= (async () => {
      const res = await this.get("manifest.json");
      if (!res.ok) {
        await res.body?.cancel();
        throw new ProviderUnavailable(
          `commons manifest answered ${res.status}`,
        );
      }
      const body = await res.json();
      if (!body || typeof body.logos !== "object") {
        throw new ProviderUnavailable("commons manifest has no logos");
      }
      return body as Manifest;
    })().catch((e) => {
      this.manifest = undefined;
      throw e;
    });
  }

  async list(): Promise<ProviderAirline[]> {
    const { logos } = await this.load();
    return Object.entries(logos).filter(([icao]) => /^[A-Z]{3}$/.test(icao))
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([icao, e]) => ({ icao, iata: e.iata ?? null, name: e.name }));
  }

  async logo(icao: string, kind: LogoKind): Promise<ProviderFile | null> {
    if (kind !== "logo") return null;
    const { logos } = await this.load();
    const e = logos[icao];
    if (!e) return null;
    // The manifest only names files in its own folder.
    if (
      !/^[A-Z]{3}\.(svg|png)$/.test(e.file) || e.file !== `${icao}.${e.format}`
    ) {
      throw new Error(`commons manifest entry ${icao} names ${e.file}`);
    }
    const res = await this.get(e.file);
    if (!res.ok) {
      await res.body?.cancel();
      if (res.status >= 500) {
        throw new ProviderUnavailable(`commons file answered ${res.status}`);
      }
      return null;
    }
    const bytes = new Uint8Array(await res.arrayBuffer());
    if ((await sha256Hex(bytes)) !== e.sha256) {
      throw new Error(
        `commons file ${e.file} does not match its manifest sha256`,
      );
    }
    return {
      bytes,
      format: e.format,
      width: e.format === "png" ? e.png_size[0] : null,
      version: await contentVersion(bytes),
      etag: null,
    };
  }

  colors(_icao: string): Promise<BrandColors | null> {
    return Promise.resolve(null);
  }
}
