import { useSyncExternalStore } from "react";
import { readUnits, UNITS_EVENT, UNITS_KEY, type Units } from "@/data/settings";

const KM_PER_MILE = 1.609_344;

let cached: Units = { distance: "km", clock: "h24" };

/** The stored units, the same object while they are unchanged (useSyncExternalStore needs that). */
function snapshot(): Units {
  const now = readUnits();
  if (now.distance !== cached.distance || now.clock !== cached.clock) cached = now;
  return cached;
}

function subscribe(onChange: () => void): () => void {
  const onStorage = (e: StorageEvent) => {
    if (e.key === null || e.key === UNITS_KEY) onChange();
  };
  window.addEventListener(UNITS_EVENT, onChange);
  window.addEventListener("storage", onStorage);
  return () => {
    window.removeEventListener(UNITS_EVENT, onChange);
    window.removeEventListener("storage", onStorage);
  };
}

/** The units chosen in Settings (`sf.units`); every reader updates at once when they change. */
export function useUnits(): Units {
  return useSyncExternalStore(subscribe, snapshot, snapshot);
}

/** "8,965 km" or "5,571 mi" (TravelFacts.distance), whole units grouped the en-US way. */
export function distanceText(km: number, unit: Units["distance"] = "km"): string {
  const value = unit === "km" ? Math.round(km) : Math.round(km / KM_PER_MILE);
  return `${value.toLocaleString("en-US")} ${unit}`;
}

/**
 * A METAR visibility (statute miles) in the chosen unit, as WeatherBlock.visibilityText: "16+ km" from
 * 10 miles up, one decimal under 10 km; in miles "10+ mi" from 10 up.
 */
export function visibilityText(sm: number | null, unit: Units["distance"] = "km"): string {
  if (sm === null) return "--";
  if (unit === "mi") return sm >= 10 ? "10+ mi" : `${Number(sm.toFixed(1))} mi`;
  if (sm >= 10) return "16+ km";
  const km = sm * 1.609;
  return km < 10 ? `${km.toFixed(1)} km` : `${Math.round(km)} km`;
}
