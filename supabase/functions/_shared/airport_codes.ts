// Several airports in one request (the Airports list): the codes as the app sends them, and their
// rows from `airports`, so a function answers by ICAO whichever code was asked.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { ApiError } from "./errors.ts";

export interface AirportRow {
  icao: string;
  iata: string | null;
  country: string | null;
}

/**
 * The comma separated codes of `raw` (IATA or ICAO), upper case, each once, in order. Throws
 * invalid_request when there is none, more than `max`, or one that is not a code.
 */
export function parseCodes(raw: string | null, max: number): string[] {
  const codes = [
    ...new Set(
      (raw ?? "").split(",").map((c) => c.trim().toUpperCase()).filter((c) =>
        c !== ""
      ),
    ),
  ];
  if (codes.length === 0) {
    throw new ApiError("invalid_request", 400, "No airport code");
  }
  if (codes.length > max) {
    throw new ApiError(
      "invalid_request",
      400,
      `At most ${max} airports per request`,
    );
  }
  for (const c of codes) {
    if (!/^([A-Z0-9]{3}|[A-Z0-9]{4})$/.test(c)) {
      throw new ApiError("invalid_request", 400, "Invalid airport code");
    }
  }
  return codes;
}

/** Rows for the codes that exist; unknown codes are left out. */
export async function airportRows(
  db: SupabaseClient,
  codes: string[],
): Promise<AirportRow[]> {
  if (codes.length === 0) return [];
  const iata = codes.filter((c) => c.length === 3);
  const icao = codes.filter((c) => c.length === 4);
  const parts: string[] = [];
  if (iata.length) parts.push(`iata.in.(${iata.join(",")})`);
  if (icao.length) parts.push(`icao.in.(${icao.join(",")})`);
  const { data, error } = await db.from("airports")
    .select("icao, iata, country").or(parts.join(","));
  if (error) throw new Error(`airports read failed: ${error.message}`);
  return (data ?? []) as AirportRow[];
}

/** The rows in the order the codes were asked, each once. */
export function inAskedOrder(
  codes: string[],
  rows: AirportRow[],
): AirportRow[] {
  const out: AirportRow[] = [];
  const seen = new Set<string>();
  for (const c of codes) {
    const r = rows.find((x) => x.icao === c || x.iata === c);
    if (r && !seen.has(r.icao)) {
      seen.add(r.icao);
      out.push(r);
    }
  }
  return out;
}
