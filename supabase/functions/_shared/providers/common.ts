// Pieces every adapter needs to build a `flights` row the way toFlightRow does.
import type { FlightRow } from "./types.ts";

type Status = FlightRow["status"];

/** A row with every field null, to fill from a provider answer. */
export function blankRow(
  provider_id: string,
  ident: string,
  now: Date,
): FlightRow {
  return {
    provider_id,
    ident,
    operator: null,
    origin_icao: null,
    origin_iata: null,
    destination_icao: null,
    destination_iata: null,
    scheduled_out: null,
    scheduled_in: null,
    estimated_out: null,
    estimated_in: null,
    scheduled_off: null,
    scheduled_on: null,
    estimated_off: null,
    estimated_on: null,
    actual_out: null,
    actual_off: null,
    actual_on: null,
    actual_in: null,
    gate_origin: null,
    gate_destination: null,
    terminal_origin: null,
    terminal_destination: null,
    baggage_belt: null,
    aircraft_type: null,
    registration: null,
    status: "unknown",
    updated_at: now.toISOString(),
  };
}

/**
 * The app's status, with the precedence of statusOf (aeroapi.ts): canceled and diverted first, then
 * the latest actual time, then the provider's own word (already mapped to ours).
 */
export function deriveStatus(row: FlightRow, hint: Status | null): Status {
  if (hint === "canceled" || hint === "diverted") return hint;
  if (row.actual_in) return "arrived";
  if (row.actual_on) return "landed";
  if (row.actual_off) return "en_route";
  if (row.actual_out) return "departed";
  return hint ?? "unknown";
}

/**
 * Our provider_id for a flight from a provider without a stable flight id: provider, ICAO ident
 * (else IATA), origin ICAO (else IATA) and the origin-local departure date. Stable across lookups
 * and polls of the same provider. Two departures of one flight number from one airport on one day
 * would share it; that is rare enough to accept (docs/free-providers.md).
 */
export function syntheticId(
  provider: string,
  ident: string,
  origin: string,
  day: string,
): string {
  return `${provider}:${ident}:${origin}:${day}`;
}

/** Ident without spaces, upper case. */
export function cleanIdent(v: string): string {
  return v.replace(/\s+/g, "").toUpperCase();
}

/** True when the ident looks like an ICAO designator (three letters then figures). */
export function isIcaoIdent(ident: string): boolean {
  return /^[A-Z]{3}[0-9]{1,4}[A-Z]?$/.test(ident);
}

/** Picks the row nearest to `scheduledOut` (within 12 hours), else the first. Null for none. */
export function nearest<T extends { scheduled_out: string | null }>(
  rows: T[],
  scheduledOut: string | null,
): T | null {
  if (rows.length === 0) return null;
  if (!scheduledOut) return rows[0];
  const at = Date.parse(scheduledOut);
  let best: T | null = null;
  let gap = 12 * 3_600_000;
  for (const r of rows) {
    if (!r.scheduled_out) continue;
    const d = Math.abs(Date.parse(r.scheduled_out) - at);
    if (d <= gap) {
      gap = d;
      best = r;
    }
  }
  return best;
}

/**
 * Rows of this ident only, IATA (the row's ident) or ICAO (inside a synthetic id). Adapters do not
 * rely on the provider's own filter.
 */
export function ofIdent<T extends { ident: string; provider_id: string }>(
  rows: T[],
  ident: string,
): T[] {
  const id = cleanIdent(ident);
  return rows.filter((r) =>
    r.ident === id || r.provider_id.split(":")[1] === id
  );
}
