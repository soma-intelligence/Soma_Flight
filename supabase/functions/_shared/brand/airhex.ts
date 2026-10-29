// Airhex adapter (airhex.com, airline logo and brand data API).
// The licence key is sent the documented way: as an MD5 digest in `md5apikey`, never in clear.
// URL shapes follow the provider's public API documentation as recorded in fixtures/airhex/;
// they must be re-checked against the live account once the licence is signed (Task 8 report).
//   list    GET {API}/airlines.json?md5apikey=...            sizes offered + airlines (+ dark flag)
//   logo    GET {CONTENT}/airlines_{IATA}_{size}_{size}_{r|t}.{svg|png}?md5apikey=...[&variant=dark]
//   colours GET {API}/airlines/{IATA}/colors.json?md5apikey=...
// Vector first, else PNG at the largest size offered and never under 192 px (3x the 64 pt display).
import { crypto as stdCrypto } from "jsr:@std/crypto@1";
import { encodeHex } from "jsr:@std/encoding@1/hex";
import {
  type AssetKind,
  type BrandColors,
  contentVersion,
  type FetchOpts,
  type KnownAsset,
  type LogoProvider,
  type ProviderAirline,
  type ProviderFile,
  ProviderUnavailable,
  readCapped,
  redact,
} from "./logo_provider.ts";
import { pngSize } from "./validate.ts";

export const AIRHEX_API = "https://content.airhex.com/api";
export const AIRHEX_CONTENT = "https://content.airhex.com/content/logos";
export const MIN_RASTER_PX = 192;
const HEX = /^#[0-9A-Fa-f]{6}$/;

interface ListEntry {
  icao: string;
  iata: string | null;
  name: string;
  dark: boolean;
}

export async function md5Hex(s: string): Promise<string> {
  // WebCrypto has no MD5; the std crypto wrapper does.
  const d = await stdCrypto.subtle.digest("MD5", new TextEncoder().encode(s));
  return encodeHex(new Uint8Array(d));
}

export class AirhexLogoProvider implements LogoProvider {
  readonly name = "airhex";
  readonly rank = 2;
  readonly kinds = ["logo", "logo_dark", "tail_logo"] as const;
  readonly hasColors = true;
  private signed?: Promise<string>;
  private catalog?: Promise<
    { sizes: number[]; byIcao: Map<string, ListEntry> }
  >;

  constructor(
    private readonly key: string,
    private readonly fetchFn: typeof fetch = fetch,
  ) {}

  private sig(): Promise<string> {
    return this.signed ??= md5Hex(this.key);
  }

  private async get(url: string, etag?: string | null): Promise<Response> {
    let res: Response;
    try {
      res = await this.fetchFn(
        url,
        etag ? { headers: { "if-none-match": etag } } : undefined,
      );
    } catch (e) {
      throw new ProviderUnavailable(
        redact(`airhex unreachable: ${(e as Error).message}`),
      );
    }
    if (res.status >= 500 || res.status === 429) {
      await res.body?.cancel();
      throw new ProviderUnavailable(`airhex answered ${res.status}`);
    }
    return res;
  }

  private loadCatalog() {
    return this.catalog ??= (async () => {
      const res = await this.get(
        `${AIRHEX_API}/airlines.json?md5apikey=${await this.sig()}`,
      );
      if (!res.ok) {
        await res.body?.cancel();
        throw new ProviderUnavailable(`airhex list answered ${res.status}`);
      }
      const body = await res.json();
      const byIcao = new Map<string, ListEntry>();
      for (const a of body.airlines ?? []) {
        if (typeof a.icao !== "string" || !/^[A-Z]{3}$/.test(a.icao)) continue;
        byIcao.set(a.icao, {
          icao: a.icao,
          iata: typeof a.iata === "string" && a.iata ? a.iata : null,
          name: String(a.name ?? a.icao),
          dark: a.dark === true,
        });
      }
      const sizes = ((body.sizes ?? []) as number[]).filter((n) =>
        Number.isInteger(n)
      ).sort((a, b) => a - b);
      return { sizes, byIcao };
    })().catch((e) => {
      this.catalog = undefined; // a failed list is retried by the next call
      throw e;
    });
  }

  async list(): Promise<ProviderAirline[]> {
    const { byIcao } = await this.loadCatalog();
    return [...byIcao.values()].map((a) => ({
      icao: a.icao,
      iata: a.iata,
      name: a.name,
    }));
  }

  async logo(
    icao: string,
    kind: AssetKind,
    opts: FetchOpts = {},
  ): Promise<ProviderFile | "unchanged" | null> {
    if (kind === "side_view") return null;
    const { sizes, byIcao } = await this.loadCatalog();
    const a = byIcao.get(icao);
    if (!a || !a.iata) return null;
    if (kind === "logo_dark" && !a.dark) return null;
    const style = kind === "tail_logo" ? "t" : "r";
    const variant = kind === "logo_dark" ? "&variant=dark" : "";
    const sig = await this.sig();
    const largest = sizes.at(-1);
    const url = (size: number, ext: string) =>
      `${AIRHEX_CONTENT}/airlines_${a.iata}_${size}_${size}_${style}.${ext}` +
      `?md5apikey=${sig}${variant}`;
    const known: KnownAsset | undefined = opts.known;

    // Vector first. The size in a vector URL is only a hint. A stored validator goes out as
    // If-None-Match, so an unchanged file costs a 304 and no body.
    {
      const vec = await this.get(url(largest ?? 512, "svg"), known?.etag);
      if (vec.status === 304) return "unchanged";
      if (vec.ok && (vec.headers.get("content-type") ?? "").includes("svg")) {
        return await this.file(vec, "svg");
      }
      await vec.body?.cancel();
    }
    // Stored assets are always PNG (vectors are rasterised), so the source kind is unknown: try both.
    if (largest === undefined || largest < MIN_RASTER_PX) return null;
    const png = await this.get(url(largest, "png"), known?.etag);
    if (png.status === 304) return "unchanged";
    if (!png.ok) {
      await png.body?.cancel();
      return null;
    }
    return await this.file(png, "png");
  }

  private async file(
    res: Response,
    format: "svg" | "png",
  ): Promise<ProviderFile> {
    const bytes = await readCapped(res);
    if (!bytes) throw new Error("airhex body over the size cap");
    return {
      bytes,
      format,
      width: format === "png" ? (pngSize(bytes)?.[0] ?? null) : null,
      mime: res.headers.get("content-type"),
      version: await contentVersion(bytes),
      etag: res.headers.get("etag"),
    };
  }

  async colors(icao: string): Promise<BrandColors | null> {
    const { byIcao } = await this.loadCatalog();
    const a = byIcao.get(icao);
    if (!a || !a.iata) return null;
    const res = await this.get(
      `${AIRHEX_API}/airlines/${a.iata}/colors.json?md5apikey=${await this
        .sig()}`,
    );
    if (!res.ok) {
      await res.body?.cancel();
      return null;
    }
    const body = await res.json();
    if (typeof body.primary !== "string" || !HEX.test(body.primary)) {
      return null;
    }
    const sec = typeof body.secondary === "string" && HEX.test(body.secondary)
      ? body.secondary.toUpperCase()
      : null;
    return { primary: body.primary.toUpperCase(), secondary: sec };
  }
}
