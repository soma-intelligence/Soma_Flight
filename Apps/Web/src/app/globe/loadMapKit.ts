/** The pinned MapKit JS 5 script, the only third-party script the app loads. */
export const MAPKIT_SRC = "https://cdn.apple-mapkit.com/mk/5.x.x/mapkit.js";

/** The slice of MapKit JS the globe uses. MapKit ships no types we may install, so this is ours. */
/* eslint-disable @typescript-eslint/no-explicit-any */
export type MapKit = {
  init(options: { authorizationCallback: (done: (token: string) => void) => void; language?: string }): void;
  Map: any;
  Coordinate: any;
  Padding: any;
  PolylineOverlay: any;
  Style: any;
  Annotation: any;
  [key: string]: any;
};

declare global {
  interface Window {
    mapkit?: MapKit;
  }
}

let loading: Promise<MapKit> | null = null;

function insertScript(): Promise<void> {
  return new Promise((resolve, reject) => {
    if (window.mapkit) return resolve();
    const s = document.createElement("script");
    s.src = MAPKIT_SRC;
    s.crossOrigin = "anonymous";
    s.async = true;
    s.onload = () => resolve();
    s.onerror = () => {
      s.remove();
      reject(new Error("MapKit JS failed to load"));
    };
    document.head.appendChild(s);
  });
}

/**
 * Loads MapKit JS once and initialises it. The first token is fetched before the script is inserted, so a
 * failing `mapkit-token` never pulls the script; MapKit asks the callback for a new token itself when the
 * current one nears its `exp`, and each ask calls `fetchToken` again. A failure clears the shared promise,
 * so the next call retries from the start.
 */
export function loadMapKit(fetchToken: () => Promise<string>): Promise<MapKit> {
  loading ??= (async () => {
    const first = await fetchToken();
    await insertScript();
    const mapkit = window.mapkit;
    if (!mapkit) throw new Error("MapKit JS is missing");
    let pending: string | null = first;
    mapkit.init({
      authorizationCallback: (done) => {
        if (pending) {
          const t = pending;
          pending = null;
          done(t);
          return;
        }
        fetchToken().then(done, () => {
          /* no token: MapKit keeps its last map and asks again later */
        });
      },
    });
    return mapkit;
  })().catch((e: unknown) => {
    loading = null;
    throw e;
  });
  return loading;
}
