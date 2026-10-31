// The landing text's connection line for in-flight texts: for each user who follows this flight and an
// onward one from where it lands, the Connection Assistant's verdict, the onward gate and its time
// ("Next: AF 85 from gate K40 at 3:10 PM, 55m to connect, tight."). Read only when such a text goes out.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { bestDeparture, type ConnFlight } from "../_shared/connections.ts";
import { clock, displayIdent } from "../_shared/alert_copy.ts";
import { onwardLine } from "../_shared/sms_alerts.ts";
import { connectionsOf } from "./connections.ts";

export async function onwardNotes<F extends ConnFlight>(
  db: SupabaseClient,
  flight: F,
  originTz: (icao: string | null | undefined) => Promise<string | null>,
): Promise<Map<string, string>> {
  const out = new Map<string, string>();
  for (const c of await connectionsOf(db, flight)) {
    if (c.arriving.id !== flight.id) continue;
    const b = c.departing;
    const leaves = bestDeparture(b);
    const at = leaves === null
      ? null
      : clock(new Date(leaves).toISOString(), await originTz(b.origin_icao));
    const line = onwardLine(
      displayIdent(b.ident),
      c.assessment.verdict,
      c.assessment.layover,
      b.gate_origin,
      at,
    );
    // A user with two onward flights from one landing (rare) hears the first.
    for (const u of c.users) if (!out.has(u)) out.set(u, line);
  }
  return out;
}
