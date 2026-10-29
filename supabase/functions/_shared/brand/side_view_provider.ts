// Side view provider port. Side views (an airline's livery on one aircraft type, seen from the side)
// come from a different supplier than logos, so they get their own small interface: a list of
// airline and type pairs with a version, and one file per pair. The concrete adapter (Logostream API
// or Airliners Illustrated delivery) is written once the owner picks one and signs; both fit.
// Until then SIDE_VIEW_PROVIDER stays unset and the sync is a no-op.
import {
  MAX_BODY_BYTES,
  type ProviderFile,
  ProviderUnavailable,
  readCapped,
} from "./logo_provider.ts";

export interface SideViewPair {
  /** Airline ICAO. */
  icao: string;
  /** Aircraft ICAO type, for example B738. */
  aircraftType: string;
  /** Content version the provider reports for this pair. A new value means a new file. */
  version: string;
  /** Which way the drawing points. Absent means left, which is what the app wants. */
  nose?: "left" | "right";
}

export interface SideViewProvider {
  readonly name: string;
  /** Every pair on offer. Throws ProviderUnavailable on outages. */
  list(): Promise<SideViewPair[]>;
  /** The file for one pair, null when the provider has none. */
  file(icao: string, aircraftType: string): Promise<ProviderFile | null>;
}

const key = (icao: string, type: string) => `${icao}/${type}`;

export interface FakeSideViewFile {
  bytes: Uint8Array;
  format: "png" | "svg" | "webp";
  version: string;
  nose?: "left" | "right";
}

/** Test double: configurable pairs and files; counts every call. */
export class FakeSideViewProvider implements SideViewProvider {
  readonly name: string;
  pairs = new Map<string, FakeSideViewFile>();
  /** list() and file() throw ProviderUnavailable. */
  outage = false;
  calls = { list: 0, file: 0 };

  constructor(name = "fake") {
    this.name = name;
  }

  set(icao: string, type: string, f: FakeSideViewFile): void {
    this.pairs.set(key(icao, type), f);
  }

  list(): Promise<SideViewPair[]> {
    this.calls.list++;
    if (this.outage) {
      return Promise.reject(new ProviderUnavailable("fake outage"));
    }
    return Promise.resolve(
      [...this.pairs].map(([k, f]) => {
        const [icao, aircraftType] = k.split("/");
        return { icao, aircraftType, version: f.version, nose: f.nose };
      }),
    );
  }

  file(icao: string, aircraftType: string): Promise<ProviderFile | null> {
    this.calls.file++;
    if (this.outage) {
      return Promise.reject(new ProviderUnavailable("fake outage"));
    }
    const f = this.pairs.get(key(icao, aircraftType));
    if (!f) return Promise.resolve(null);
    return Promise.resolve({
      bytes: f.bytes,
      format: f.format,
      width: null,
      version: f.version,
      etag: null,
    });
  }
}

interface RecordedManifest {
  provider?: string;
  pairs: {
    icao: string;
    aircraftType: string;
    file: string;
    format: "png" | "svg" | "webp";
    version: string;
    nose?: "left" | "right";
  }[];
}

/**
 * Replays a fixture folder: manifest.json (pairs with file, format, version, nose) plus the files it
 * names. `dir` is a file:// or http(s):// URL or a path. The fixtures hold images made for the tests,
 * not any provider's artwork.
 */
export class RecordedSideViewProvider implements SideViewProvider {
  readonly name: string;
  private manifest?: Promise<RecordedManifest>;
  private readonly base: URL;
  readonly calls = { list: 0, file: 0 };

  constructor(dir: URL | string, name = "recorded") {
    this.name = name;
    let s = String(dir);
    if (!/^[a-z]+:\/\//i.test(s)) s = new URL(s, `file://${Deno.cwd()}/`).href;
    this.base = new URL(s.endsWith("/") ? s : `${s}/`);
  }

  private async read(name: string): Promise<Uint8Array> {
    const url = new URL(name, this.base);
    if (url.protocol === "file:") {
      const b = await Deno.readFile(url);
      if (b.length > MAX_BODY_BYTES) {
        throw new Error(`recorded ${name}: too large`);
      }
      return b;
    }
    const res = await fetch(url);
    if (!res.ok) {
      await res.body?.cancel();
      throw new ProviderUnavailable(`recorded ${name}: ${res.status}`);
    }
    const body = await readCapped(res);
    if (!body) throw new Error(`recorded ${name}: too large`);
    return body;
  }

  private load(): Promise<RecordedManifest> {
    return this.manifest ??= this.read("manifest.json").then((b) =>
      JSON.parse(new TextDecoder().decode(b)) as RecordedManifest
    );
  }

  async list(): Promise<SideViewPair[]> {
    this.calls.list++;
    return (await this.load()).pairs.map((p) => ({
      icao: p.icao,
      aircraftType: p.aircraftType,
      version: p.version,
      nose: p.nose,
    }));
  }

  async file(icao: string, aircraftType: string): Promise<ProviderFile | null> {
    this.calls.file++;
    const p = (await this.load()).pairs.find((x) =>
      x.icao === icao && x.aircraftType === aircraftType
    );
    if (!p) return null;
    const bytes = await this.read(p.file);
    return {
      bytes,
      format: p.format,
      width: null,
      version: p.version,
      etag: null,
    };
  }
}
