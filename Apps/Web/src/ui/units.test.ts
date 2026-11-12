// @vitest-environment jsdom
import { afterEach, describe, expect, it } from "vitest";
import { act, renderHook } from "@testing-library/react";
import { writeUnits } from "@/data/settings";
import { distanceText, useUnits, visibilityText } from "./units";

afterEach(() => localStorage.clear());

describe("distanceText", () => {
  it("reads whole km or miles, grouped", () => {
    expect(distanceText(8965)).toBe("8,965 km");
    expect(distanceText(8965, "mi")).toBe("5,571 mi");
    expect(distanceText(21720, "mi")).toBe("13,496 mi");
  });
});

describe("visibilityText", () => {
  it("follows WeatherBlock in km and caps miles at 10+", () => {
    expect(visibilityText(null)).toBe("--");
    expect(visibilityText(10)).toBe("16+ km");
    expect(visibilityText(3)).toBe("4.8 km");
    expect(visibilityText(6.5)).toBe("10 km");
    expect(visibilityText(10, "mi")).toBe("10+ mi");
    expect(visibilityText(2.5, "mi")).toBe("2.5 mi");
  });
});

describe("useUnits", () => {
  it("starts from the stored units and updates when Settings writes them", () => {
    const { result } = renderHook(() => useUnits());
    expect(result.current).toEqual({ distance: "km", clock: "h24" });
    const first = result.current;
    act(() => writeUnits({ distance: "mi", clock: "h12" }));
    expect(result.current).toEqual({ distance: "mi", clock: "h12" });
    expect(result.current).not.toBe(first);
  });

  it("follows a change made in another tab (storage event)", () => {
    const { result } = renderHook(() => useUnits());
    act(() => {
      localStorage.setItem("sf.units", JSON.stringify({ distance: "mi", clock: "h24" }));
      window.dispatchEvent(new StorageEvent("storage", { key: "sf.units" }));
    });
    expect(result.current.distance).toBe("mi");
  });
});
