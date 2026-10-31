// The link preview image (og:image): the route map at 1200 by 630, as a PNG. Messages, Slack and the rest
// fetch it once when the link is pasted. Drawn by resvg (the WASM the brand sync already vendors), from
// our own SVG only: no text, so no fonts are needed.
import { initWasm, Resvg } from "npm:@resvg/resvg-wasm@2.6.2";
import { type RouteMap, routeMapSvg } from "./map.ts";

export const OG_WIDTH = 1200;
export const OG_HEIGHT = 630;

let ready: Promise<void> | undefined;

/** Loads the vendored resvg WASM once per isolate (config.toml ships it as a static file). */
function resvgReady(): Promise<void> {
  ready ??= (async () => {
    const bytes = await Deno.readFile(
      new URL("../_shared/brand/resvg/resvg_bg.wasm", import.meta.url),
    );
    await initWasm(await WebAssembly.compile(bytes));
  })().catch((e) => {
    ready = undefined;
    throw e;
  });
  return ready;
}

/** The preview PNG for a route. */
export async function ogImage(m: RouteMap): Promise<Uint8Array> {
  await resvgReady();
  const svg = routeMapSvg(m, OG_WIDTH, OG_HEIGHT);
  const r = new Resvg(svg, {
    fitTo: { mode: "width", value: OG_WIDTH },
    font: { loadSystemFonts: false, fontFiles: [] },
  });
  try {
    const img = r.render();
    const png = img.asPng();
    img.free();
    return png;
  } finally {
    r.free();
  }
}
