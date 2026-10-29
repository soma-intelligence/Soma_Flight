// Board rows in the app's `Flight` wire shape (FlightKit Models/Flight.swift): an id, no null airport
// codes, ISO 8601 dates with milliseconds. The id is a UUID v5 of the provider id, so it is stable
// across refreshes. It is a board id, not flights.id (boards are not written to `flights`).
import { type AeroFlight, type FlightRow, toFlightRow } from "./aeroapi.ts";

/** Fixed namespace for board row ids. Never change it: it would renumber every row. */
export const BOARD_ID_NAMESPACE = "7b3e1c4a-5d2f-4e8b-9a61-0c3f5d7e9b21";

export type BoardRow =
  & Omit<FlightRow, "origin_icao" | "destination_icao">
  & {
    id: string;
    origin_icao: string;
    destination_icao: string;
  };

export async function uuidV5(name: string, namespace: string): Promise<string> {
  const ns = namespace.replaceAll("-", "").match(/../g)!.map((h) =>
    parseInt(h, 16)
  );
  const bytes = new TextEncoder().encode(name);
  const data = new Uint8Array(16 + bytes.length);
  data.set(ns);
  data.set(bytes, 16);
  const h = new Uint8Array(await crypto.subtle.digest("SHA-1", data)).slice(
    0,
    16,
  );
  h[6] = (h[6] & 0x0f) | 0x50;
  h[8] = (h[8] & 0x3f) | 0x80;
  const hex = [...h].map((b) => b.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${
    hex.slice(16, 20)
  }-${hex.slice(20)}`;
}

const DATE_KEYS = [
  "scheduled_out",
  "scheduled_in",
  "estimated_out",
  "estimated_in",
  "scheduled_off",
  "scheduled_on",
  "estimated_off",
  "estimated_on",
  "actual_out",
  "actual_off",
  "actual_on",
  "actual_in",
] as const;

function isoMillis(v: string | null): string | null {
  if (!v) return null;
  const ms = Date.parse(v);
  return Number.isFinite(ms) ? new Date(ms).toISOString() : null;
}

/**
 * Rows for a board of `kind` at `icao`. A missing airport on the viewed side is the viewed airport.
 * A missing airport on the other side drops the row (logged): the app cannot show it.
 * One row per fa_flight_id (a diverted flight comes back twice).
 */
export async function toBoardRows(
  flights: AeroFlight[],
  icao: string,
  kind: "departures" | "arrivals",
  now: Date,
): Promise<BoardRow[]> {
  const seen = new Set<string>();
  const out: BoardRow[] = [];
  for (const f of flights) {
    const row = toFlightRow(f, now);
    if (seen.has(row.provider_id)) continue;
    const origin = row.origin_icao ?? (kind === "departures" ? icao : null);
    const destination = row.destination_icao ??
      (kind === "arrivals" ? icao : null);
    if (!origin || !destination) {
      console.error(
        `board ${icao} ${kind}: dropped ${row.provider_id} without ${
          origin ? "destination" : "origin"
        } airport`,
      );
      continue;
    }
    seen.add(row.provider_id);
    const normalized = { ...row } as Record<string, unknown>;
    for (const k of DATE_KEYS) normalized[k] = isoMillis(row[k]);
    normalized.updated_at = isoMillis(row.updated_at) ?? now.toISOString();
    out.push({
      ...(normalized as unknown as FlightRow),
      id: await uuidV5(row.provider_id, BOARD_ID_NAMESPACE),
      origin_icao: origin,
      destination_icao: destination,
    });
  }
  return out;
}
