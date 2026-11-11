import { getSupabase } from "./client";
import { decodeFlight } from "./decode";
import type { RealtimeChannel } from "@supabase/supabase-js";
import type { Flight } from "./types";

/** Realtime accepts at most 100 values in an `in` filter. */
const MAX_IDS = 100;

/** `UPDATE`s on `flights` filtered by `id=in.(...)`, one channel per 100 ids. Returns the unsubscribe. */
export function subscribeFlights(ids: string[], onRow: (f: Flight) => void): () => void {
  const unique = Array.from(new Set(ids)).sort();
  const sb = getSupabase();
  const channels: RealtimeChannel[] = [];
  for (let i = 0; i < unique.length; i += MAX_IDS) {
    const group = unique.slice(i, i + MAX_IDS);
    const ch = sb
      .channel(`flights-${i / MAX_IDS}-${Math.random().toString(36).slice(2, 8)}`)
      .on(
        "postgres_changes",
        { event: "UPDATE", schema: "public", table: "flights", filter: `id=in.(${group.join(",")})` },
        (payload: { new: unknown }) => {
          try {
            onRow(decodeFlight(payload.new));
          } catch {
            // an unreadable row is skipped
          }
        },
      )
      .subscribe();
    channels.push(ch);
  }
  return () => {
    for (const ch of channels) void sb.removeChannel(ch);
  };
}
