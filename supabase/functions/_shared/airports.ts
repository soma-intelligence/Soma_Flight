import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { ApiError } from "./errors.ts";

/** IATA (3 letters) or ICAO (4) code to the ICAO code in `airports`. */
export async function resolveAirport(
  db: SupabaseClient,
  code: unknown,
): Promise<string> {
  const c = typeof code === "string" ? code.trim().toUpperCase() : "";
  if (!/^([A-Z0-9]{3}|[A-Z0-9]{4})$/.test(c)) {
    throw new ApiError("invalid_request", 400, "Invalid airport code");
  }
  const { data, error } = await db.from("airports").select("icao")
    .eq(c.length === 3 ? "iata" : "icao", c).maybeSingle();
  if (error) throw new Error(`airport lookup failed: ${error.message}`);
  if (!data) throw new ApiError("invalid_request", 400, `Unknown airport ${c}`);
  return data.icao as string;
}
