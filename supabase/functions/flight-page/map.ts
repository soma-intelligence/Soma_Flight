// The share page's static route map: the great circle between the two airports on a plain world outline,
// as inline SVG. No tiles, no third party: the land is Natural Earth 1:110m (public domain), the same
// outline the app's Passport map uses (world_land.json, made by Scripts/world/build_land.py).
//
// Projection: equirectangular, one unit per degree (x = lon + 180, y = 90 - lat). The viewBox crops the
// world to the route. A route across the antimeridian is drawn with continuous longitudes (beyond +-180)
// and the land is repeated one world to the left or right to stay under it.
import land from "./world_land.json" with { type: "json" };

export interface LatLon {
  lat: number;
  lon: number;
}

const rad = (d: number) => d * Math.PI / 180;
const deg = (r: number) => r * 180 / Math.PI;

/** `n` + 1 points along the great circle from `a` to `b`, with longitudes kept continuous (no jump at 180). */
export function greatCircle(a: LatLon, b: LatLon, n = 64): LatLon[] {
  const [p1, l1, p2, l2] = [rad(a.lat), rad(a.lon), rad(b.lat), rad(b.lon)];
  const d = 2 * Math.asin(Math.sqrt(
    Math.sin((p2 - p1) / 2) ** 2 +
      Math.cos(p1) * Math.cos(p2) * Math.sin((l2 - l1) / 2) ** 2,
  ));
  const out: LatLon[] = [];
  for (let i = 0; i <= n; i++) {
    const f = i / n;
    let lat: number, lon: number;
    if (d < 1e-9) {
      lat = a.lat;
      lon = a.lon;
    } else {
      const A = Math.sin((1 - f) * d) / Math.sin(d);
      const B = Math.sin(f * d) / Math.sin(d);
      const x = A * Math.cos(p1) * Math.cos(l1) +
        B * Math.cos(p2) * Math.cos(l2);
      const y = A * Math.cos(p1) * Math.sin(l1) +
        B * Math.cos(p2) * Math.sin(l2);
      const z = A * Math.sin(p1) + B * Math.sin(p2);
      lat = deg(Math.atan2(z, Math.sqrt(x * x + y * y)));
      lon = deg(Math.atan2(y, x));
    }
    out.push({ lat, lon });
  }
  for (let i = 1; i < out.length; i++) {
    while (out[i].lon - out[i - 1].lon > 180) out[i].lon -= 360;
    while (out[i].lon - out[i - 1].lon < -180) out[i].lon += 360;
  }
  return out;
}

/** The point a fraction `f` (0 to 1) of the way along `arc`. */
export function along(arc: LatLon[], f: number): LatLon {
  const t = Math.min(1, Math.max(0, f)) * (arc.length - 1);
  const i = Math.min(arc.length - 2, Math.floor(t));
  const k = t - i;
  return {
    lat: arc[i].lat + (arc[i + 1].lat - arc[i].lat) * k,
    lon: arc[i].lon + (arc[i + 1].lon - arc[i].lon) * k,
  };
}

const x = (p: LatLon) => p.lon + 180;
const y = (p: LatLon) => 90 - p.lat;
const r1 = (v: number) => Math.round(v * 10) / 10;
const r2 = (v: number) => Math.round(v * 100) / 100;

let landPath: string | undefined;

/** The whole world's land as one SVG path in map units, built once per isolate (even-odd fill). */
export function landD(): string {
  landPath ??= (land as { rings: number[][] }).rings.map((ring) => {
    let d = "";
    for (let i = 0; i + 1 < ring.length; i += 2) {
      d += `${i ? "L" : "M"}${r1(ring[i] + 180)} ${r1(90 - ring[i + 1])}`;
    }
    return d + "Z";
  }).join("");
  return landPath;
}

/** The map's colours; the page and the preview image use the app's dark palette. */
export interface MapStyle {
  sea: string;
  land: string;
  arc: string;
  done: string;
  dot: string;
  plane: string;
}

export const DARK_MAP: MapStyle = {
  sea: "#18181A",
  land: "#2C2C2F",
  arc: "#6C6C72",
  done: "#0A84FF",
  dot: "#FFFFFF",
  plane: "#0A84FF",
};

export interface RouteMap {
  origin: LatLon;
  destination: LatLon;
  /** A reported position of the plane; without one, a trip under way puts it at `progress` along the arc. */
  plane?: LatLon | null;
  /** How much of the trip is flown, 0 to 1, for the bright part of the arc; null draws none. */
  progress?: number | null;
}

/**
 * The route map as a standalone `<svg>` of `width` by `height` pixels: the world cropped around the arc
 * with a margin, kept to the given aspect, never past the poles.
 */
export function routeMapSvg(
  m: RouteMap,
  width: number,
  height: number,
  style: MapStyle = DARK_MAP,
): string {
  const arc = greatCircle(m.origin, m.destination);
  const xs = arc.map(x), ys = arc.map(y);
  let minX = Math.min(...xs), maxX = Math.max(...xs);
  let minY = Math.min(...ys), maxY = Math.max(...ys);
  // A margin of a fifth of the route each side, and at least 24 degrees across.
  const padX = Math.max((maxX - minX) * 0.2, 6),
    padY = Math.max((maxY - minY) * 0.2, 6);
  minX -= padX;
  maxX += padX;
  minY -= padY;
  maxY += padY;
  const aspect = width / height;
  let w = Math.max(maxX - minX, 24), h = Math.max(maxY - minY, 24 / aspect);
  if (w / h > aspect) h = w / aspect;
  else w = h * aspect;
  if (h > 180) {
    h = 180;
    w = h * aspect;
  }
  const cx = (minX + maxX) / 2, cy = (minY + maxY) / 2;
  const vx = cx - w / 2;
  const vy = Math.min(Math.max(cy - h / 2, 0), 180 - h);
  // The land again one world over when the view reaches past either edge.
  const copies = [0];
  if (vx < 0) copies.push(-360);
  if (vx + w > 360) copies.push(360);

  // Strokes and dots scale with the crop, so a short hop and an ocean crossing look alike.
  const unit = w / width;
  const stroke = Math.max(0.05, r2(2.5 * unit));
  const dot = Math.max(0.1, r2(5 * unit));
  const pts = arc.map((p) => `${r1(x(p))},${r1(y(p))}`).join(" ");
  const progress = m.progress ?? null;
  let done = "";
  if (progress !== null && progress > 0) {
    const n = Math.max(1, Math.round(progress * (arc.length - 1)));
    const head = along(arc, progress);
    done = `<polyline points="${
      arc.slice(0, n).map((p) => `${r1(x(p))},${r1(y(p))}`).join(" ")
    } ${r1(x(head))},${
      r1(y(head))
    }" fill="none" stroke="${style.done}" stroke-width="${stroke}" stroke-linecap="round"/>`;
  }
  // With no reported position, the plane sits where the clock puts it along the arc.
  const at = m.plane ??
    (progress !== null && progress > 0 && progress < 1
      ? along(arc, progress)
      : null);
  let plane = "";
  if (at) {
    // A reported position is wrapped to the arc's side of the antimeridian.
    const p = { ...at };
    while (x(p) - cx > 180) p.lon -= 360;
    while (x(p) - cx < -180) p.lon += 360;
    plane = `<circle cx="${r1(x(p))}" cy="${r1(y(p))}" r="${
      r2(dot * 1.6)
    }" fill="${style.plane}" stroke="${style.dot}" stroke-width="${stroke}"/>`;
  }
  const ends = [arc[0], arc[arc.length - 1]].map((p) =>
    `<circle cx="${r1(x(p))}" cy="${r1(y(p))}" r="${dot}" fill="${style.dot}"/>`
  ).join("");
  const lands = copies.map((dx) =>
    `<path transform="translate(${dx} 0)" d="${landD()}" fill="${style.land}" fill-rule="evenodd"/>`
  ).join("");
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${r1(vx)} ${
    r1(vy)
  } ${r1(w)} ${
    r1(h)
  }" width="${width}" height="${height}" preserveAspectRatio="xMidYMid slice" role="img" aria-label="Route map"><rect x="${
    r1(vx - 1)
  }" y="${r1(vy - 1)}" width="${r1(w + 2)}" height="${
    r1(h + 2)
  }" fill="${style.sea}"/>${lands}<polyline points="${pts}" fill="none" stroke="${style.arc}" stroke-width="${stroke}" stroke-dasharray="${
    r2(stroke * 2)
  } ${r2(stroke * 2)}" stroke-linecap="round"/>${done}${ends}${plane}</svg>`;
}
