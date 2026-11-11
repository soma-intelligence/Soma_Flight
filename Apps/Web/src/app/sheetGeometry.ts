/**
 * The narrow window's bottom sheet: its three resting heights and where a drag lands. Ported one to one
 * from Packages/FlightKit/Sources/FlightKit/App/SheetDetents.swift (SheetDetent, SheetGeometry).
 *
 * Positions are y values from the top of the window. Medium and collapsed are fractions of the height
 * between the two safe areas, counted from the top one; expanded sits on the top safe area.
 */
export type Detent = "collapsed" | "medium" | "expanded";

/** Lowest first, as SheetDetent's raw values. */
export const DETENTS: readonly Detent[] = ["collapsed", "medium", "expanded"];

export type SheetGeometry = {
  /** The full window height. */
  screenHeight: number;
  /** Room kept above the expanded sheet. */
  safeTop: number;
  /** Room under the content, where the tab pill sits. */
  safeBottom: number;
};

/** Medium's top as a fraction of the height between the safe areas. */
export const MEDIUM_FRACTION = 0.4;
/** Collapsed's top as a fraction of the height between the safe areas. */
export const COLLAPSED_FRACTION = 0.67;
/** The pinned header at the sheet's top: 22 px top padding, the large title, 12 px under it. */
export const HEADER_HEIGHT = 74;
/** One peek row under the header, the most a collapsed sheet promises to show. */
export const PEEK_ROW_HEIGHT = 64;
/** The tab pill and search button above the bottom safe area. */
export const TAB_BAR_HEIGHT = 53;
/** The least a collapsed sheet keeps above the bottom safe area: header, one peek row, the pill. */
export const MINIMUM_COLLAPSED_CONTENT = HEADER_HEIGHT + PEEK_ROW_HEIGHT + TAB_BAR_HEIGHT;
/** The least room medium leaves above a collapsed sheet. */
export const MINIMUM_STEP = 80;
/** How far a release's speed carries the sheet before it is matched to a detent, in seconds. */
export const PROJECTION = 0.2;

/** A 6.3 inch iPhone (iPhone 17 Pro), the Swift tests' reference screen. */
export const STANDARD: SheetGeometry = { screenHeight: 874, safeTop: 62, safeBottom: 34 };

/**
 * The browser window's geometry. A browser has no status bar or home indicator: the expanded sheet keeps
 * 8 px of globe above it (the panel's top margin), and 34 px at the bottom keeps the pill 20 px above the
 * window's edge as on the iPhone (53 + 34 = 8 + 59 + 20).
 */
export function webGeometry(screenHeight: number): SheetGeometry {
  return { screenHeight, safeTop: 8, safeBottom: 34 };
}

function usable(g: SheetGeometry): number {
  return Math.max(0, g.screenHeight - g.safeTop - g.safeBottom);
}

/** Swift's `.rounded()`: to nearest, halves away from zero. */
function round(x: number): number {
  return Math.sign(x) * Math.round(Math.abs(x));
}

/** The y of the sheet's top edge resting in `detent`. */
export function sheetTop(detent: Detent, g: SheetGeometry): number {
  switch (detent) {
    case "expanded":
      return g.safeTop;
    case "medium": {
      const top = round(g.safeTop + usable(g) * MEDIUM_FRACTION);
      return Math.min(top, sheetTop("collapsed", g) - MINIMUM_STEP);
    }
    case "collapsed": {
      const top = round(g.safeTop + usable(g) * COLLAPSED_FRACTION);
      return Math.min(top, g.screenHeight - g.safeBottom - MINIMUM_COLLAPSED_CONTENT);
    }
  }
}

/** How much of the window the sheet covers in `detent`. */
export function sheetHeight(detent: Detent, g: SheetGeometry): number {
  return g.screenHeight - sheetTop(detent, g);
}

/** The room for content between the pinned header and the tab pill in `detent`. */
export function contentRoom(detent: Detent, g: SheetGeometry): number {
  return sheetHeight(detent, g) - g.safeBottom - TAB_BAR_HEIGHT - HEADER_HEIGHT;
}

/** The detent whose top is closest to `top` (the lower one on a tie, as Swift's `min`). */
export function nearest(top: number, g: SheetGeometry): Detent {
  let best: Detent = DETENTS[0];
  for (const d of DETENTS) {
    if (Math.abs(sheetTop(d, g) - top) < Math.abs(sheetTop(best, g) - top)) best = d;
  }
  return best;
}

/** Where a drag released at `top` moving at `velocity` (px per second, positive downward) comes to rest. */
export function snap(top: number, velocity: number, g: SheetGeometry): Detent {
  return nearest(top + velocity * PROJECTION, g);
}

/** One step up, null at the top. */
export function raised(d: Detent): Detent | null {
  return DETENTS[DETENTS.indexOf(d) + 1] ?? null;
}

/** One step down, null at the bottom. */
export function lowered(d: Detent): Detent | null {
  return DETENTS[DETENTS.indexOf(d) - 1] ?? null;
}
