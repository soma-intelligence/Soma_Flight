import { describe, expect, it } from "vitest";
import {
  COLLAPSED_FRACTION,
  MEDIUM_FRACTION,
  MINIMUM_COLLAPSED_CONTENT,
  MINIMUM_STEP,
  PEEK_ROW_HEIGHT,
  HEADER_HEIGHT,
  TAB_BAR_HEIGHT,
  STANDARD,
  contentRoom,
  lowered,
  nearest,
  raised,
  sheetHeight,
  sheetTop,
  snap,
  type Detent,
  type SheetGeometry,
} from "./sheetGeometry";

// Cases copied from Packages/FlightKit/Tests/FlightKitTests/SheetDetentTests.swift.
const pro: SheetGeometry = STANDARD;
const proMax: SheetGeometry = { screenHeight: 956, safeTop: 62, safeBottom: 34 };
const se: SheetGeometry = { screenHeight: 667, safeTop: 20, safeBottom: 0 };
const short: SheetGeometry = { screenHeight: 600, safeTop: 50, safeBottom: 34 };
const all: Detent[] = ["collapsed", "medium", "expanded"];

describe("sheet constants", () => {
  it("match SheetGeometry in Swift", () => {
    expect(MEDIUM_FRACTION).toBe(0.4);
    expect(COLLAPSED_FRACTION).toBe(0.67);
    expect(HEADER_HEIGHT).toBe(74);
    expect(PEEK_ROW_HEIGHT).toBe(64);
    expect(TAB_BAR_HEIGHT).toBe(53);
    expect(MINIMUM_COLLAPSED_CONTENT).toBe(191);
    expect(MINIMUM_STEP).toBe(80);
    expect(STANDARD).toEqual({ screenHeight: 874, safeTop: 62, safeBottom: 34 });
  });
});

describe("sheetTop", () => {
  it("matches Swift for each detent on each screen", () => {
    expect(sheetTop("expanded", pro)).toBe(62);
    expect(sheetTop("medium", pro)).toBe(373);
    expect(sheetTop("collapsed", pro)).toBe(583);
    expect(sheetHeight("medium", pro)).toBe(501);
    expect(sheetHeight("collapsed", pro)).toBe(291);

    expect(sheetTop("expanded", proMax)).toBe(62);
    expect(sheetTop("medium", proMax)).toBe(406);
    expect(sheetTop("collapsed", proMax)).toBe(638);

    expect(sheetTop("expanded", se)).toBe(20);
    expect(sheetTop("medium", se)).toBe(279);
    expect(sheetTop("collapsed", se)).toBe(453);

    expect(sheetTop("collapsed", short)).toBe(600 - 34 - MINIMUM_COLLAPSED_CONTENT);
  });

  it("keeps the header and one peek row above the tab bar when collapsed", () => {
    for (const g of [pro, proMax, se, short]) {
      const room = contentRoom("collapsed", g);
      expect(room).toBeGreaterThanOrEqual(PEEK_ROW_HEIGHT);
      const headerBottom = sheetTop("collapsed", g) + HEADER_HEIGHT;
      expect(headerBottom + room + TAB_BAR_HEIGHT + g.safeBottom).toBe(g.screenHeight);
      expect(contentRoom("medium", g)).toBeGreaterThan(room);
      expect(contentRoom("expanded", g)).toBeGreaterThan(contentRoom("medium", g));
    }
  });

  it("puts medium at about 43% and collapsed at about 67% on tall phones", () => {
    for (const g of [pro, proMax]) {
      expect(Math.abs(sheetTop("medium", g) / g.screenHeight - 0.43)).toBeLessThan(0.01);
      expect(Math.abs(sheetTop("collapsed", g) / g.screenHeight - 0.67)).toBeLessThan(0.01);
    }
  });

  it("keeps the detents ordered and apart on every screen", () => {
    for (let height = 560; height <= 1000; height += 20) {
      const g = { screenHeight: height, safeTop: 59, safeBottom: 34 };
      expect(sheetTop("expanded", g)).toBeLessThan(sheetTop("medium", g));
      expect(sheetTop("collapsed", g) - sheetTop("medium", g)).toBeGreaterThanOrEqual(MINIMUM_STEP);
      expect(sheetHeight("collapsed", g) - g.safeBottom).toBeGreaterThanOrEqual(MINIMUM_COLLAPSED_CONTENT);
    }
  });
});

describe("snap", () => {
  it("snaps a slow release to the nearest detent", () => {
    expect(snap(300, 0, pro)).toBe("medium");
    expect(snap(150, 0, pro)).toBe("expanded");
    expect(snap(470, 0, pro)).toBe("medium");
    expect(snap(480, 0, pro)).toBe("collapsed");
    expect(snap(900, 0, pro)).toBe("collapsed");
    expect(nearest(-40, pro)).toBe("expanded");
  });

  it("carries a fling in its direction", () => {
    expect(snap(300, -2000, pro)).toBe("expanded");
    expect(snap(400, 1500, pro)).toBe("collapsed");
    expect(snap(450, 200, pro)).toBe("collapsed");
    expect(snap(450, -200, pro)).toBe("medium");
    expect(snap(62, 1200, pro)).toBe("medium");
  });
});

describe("steps", () => {
  it("steps up and down", () => {
    expect(raised("collapsed")).toBe("medium");
    expect(raised("medium")).toBe("expanded");
    expect(raised("expanded")).toBeNull();
    expect(lowered("expanded")).toBe("medium");
    expect(lowered("collapsed")).toBeNull();
    expect(all.map(raised)).toEqual(["medium", "expanded", null]);
  });
});
