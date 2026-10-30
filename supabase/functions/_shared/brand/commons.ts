// Wikimedia Commons logo library (Task 8b). Reads assets/logos/commons/manifest.json and the files it
// names, built by Scripts/logos/fetch_commons.py. Free licences only (public domain, CC0, CC BY,
// CC BY-SA), attribution shown in the app's Acknowledgements. Used for local development and until
// the Airhex licence is signed: LOGO_PROVIDER=commons selects it, Airhex replaces it once licensed.
// The base is a URL: file:// for the repo copy (the default) or http(s):// when the edge runtime
// cannot see the repo (serve assets/logos/commons and set COMMONS_LOGO_BASE).
// Two marks per airline (Task 8c): the wordmark (manifest "logos", kind "wordmark") and, when Commons
// has one, the compact symbol (manifest "symbols", kind "symbol", files under symbol/). Kind 'logo' is
// the symbol when present, else the wordmark: wordmarks are unreadable at 24 to 34 pt. Kind 'wordmark'
// asks for the wordmark explicitly, for wide slots. No dark variant, no tail, no brand colours.
import {
  type AssetKind,
  type BrandColors,
  contentVersion,
  type FetchOpts,
  type LogoProvider,
  type ProviderAirline,
  type ProviderFile,
  ProviderUnavailable,
  readCapped,
  sha256Hex,
} from "./logo_provider.ts";

/** The repo copy, resolved from this file: supabase/functions/_shared/brand -> assets/logos/commons. */
export const DEFAULT_COMMONS_BASE = new URL(
  "../../../../assets/logos/commons/",
  import.meta.url,
);

/** What this provider can answer: the port's kinds plus the explicit wordmark. */
export type CommonsKind = AssetKind | "wordmark";

export interface CommonsEntry {
  kind?: "wordmark" | "symbol";
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
  symbols?: Record<string, CommonsEntry>;
}

export class CommonsLogoProvider implements LogoProvider {
  readonly name = "commons";
  readonly rank = 1;
  readonly kinds = ["logo"] as const;
  readonly hasColors = false;
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
      if (body.symbols != null && typeof body.symbols !== "object") {
        throw new ProviderUnavailable("commons manifest symbols is not a map");
      }
      return body as Manifest;
    })().catch((e) => {
      this.manifest = undefined;
      throw e;
    });
  }

  async list(): Promise<ProviderAirline[]> {
    const { logos, symbols = {} } = await this.load();
    const all = new Map<string, CommonsEntry>();
    for (
      const [icao, e] of [...Object.entries(symbols), ...Object.entries(logos)]
    ) {
      all.set(icao, e);
    }
    return [...all].filter(([icao]) => /^[A-Z]{3}$/.test(icao))
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([icao, e]) => ({ icao, iata: e.iata ?? null, name: e.name }));
  }

  /**
   * 'logo' serves the symbol when the airline has one, else the wordmark; 'wordmark' serves the
   * wordmark only. Other kinds are not in this library.
   */
  async logo(
    icao: string,
    kind: CommonsKind,
    opts: FetchOpts = {},
  ): Promise<ProviderFile | "unchanged" | null> {
    if (kind !== "logo" && kind !== "wordmark") return null;
    const { logos, symbols = {} } = await this.load();
    const symbol = kind === "logo" ? symbols[icao] : undefined;
    const e = symbol ?? logos[icao];
    if (!e) return null;
    // The manifest only names files in its own folder: <ICAO>.<ext> or symbol/<ICAO>.<ext>.
    const dir = symbol ? "symbol/" : "";
    if (
      !/^(symbol\/)?[A-Z]{3}\.(svg|png)$/.test(e.file) ||
      e.file !== `${dir}${icao}.${e.format}`
    ) {
      throw new Error(`commons manifest entry ${icao} names ${e.file}`);
    }
    // The manifest carries the sha256, so an unchanged file is known without reading it.
    if (opts.known && opts.known.version === e.sha256.slice(0, 16)) {
      return "unchanged";
    }
    const res = await this.get(e.file);
    if (!res.ok) {
      await res.body?.cancel();
      if (res.status >= 500) {
        throw new ProviderUnavailable(`commons file answered ${res.status}`);
      }
      return null;
    }
    const bytes = await readCapped(res);
    if (!bytes) throw new Error(`commons file ${e.file} is over the size cap`);
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
