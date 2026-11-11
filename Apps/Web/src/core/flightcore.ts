import init, * as pkg from "./pkg/flightcore_wasm.js";

export type LatLon = { lat: number; lon: number };

type Source = Parameters<typeof init>[0];

let loading: Promise<void> | null = null;

/**
 * Loads the wasm once; later calls share the first load. In the browser the
 * package fetches its own .wasm. Tests pass the bytes in because Node cannot
 * fetch a file URL.
 */
export function initCore(source?: BufferSource): Promise<void> {
  loading ??= init(source as Source).then(
    () => undefined,
    (e: unknown) => {
      loading = null; // allow a retry after a failed load
      throw e;
    },
  );
  return loading;
}

/** Throws a JS Error when the core rejects its input. */
function parsed<T>(json: string): T {
  const v = JSON.parse(json) as T | { error: string };
  if (v && typeof v === "object" && "error" in v && typeof v.error === "string") {
    throw new Error(v.error);
  }
  return v as T;
}

export function distanceKm(a: LatLon, b: LatLon): number {
  return pkg.distanceKm(JSON.stringify(a), JSON.stringify(b));
}

export function greatCircle(a: LatLon, b: LatLon, segments: number): LatLon[] {
  return parsed<LatLon[]>(pkg.greatCircle(JSON.stringify(a), JSON.stringify(b), segments));
}
