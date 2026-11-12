import { flightCategory, initCore } from "@/core/flightcore";
import type { AirportConditions } from "@/data/airports";

/** The category the core reads from ceiling and visibility; the feed's own word when it cannot. */
export async function categoryOf(w: Pick<AirportConditions, "ceilingFt" | "visibilitySm" | "category">): Promise<string | null> {
  if (w.visibilitySm == null) return w.category;
  try {
    await initCore();
    return flightCategory(w.ceilingFt ?? null, w.visibilitySm);
  } catch {
    return w.category;
  }
}
