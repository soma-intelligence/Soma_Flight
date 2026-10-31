// The connections an event's flight is part of, for the "connection at risk" alert. Reads flights,
// user_flights and airports only: nothing calls the provider.
//
// The candidates are the flights around this one that could pair with it: leaving from where it lands
// within 24 hours of its landing, or landing where it leaves from within 24 hours before it. For each
// user who follows this flight, the pairing runs over this flight and the candidates they follow (the
// app's rule: shortest gaps win), so the alert goes to the users whose app shows that connection.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import {
  assess,
  type Assessment,
  type ConnFlight,
  PAIR_WINDOW_MS,
  pairs,
} from "../_shared/connections.ts";

/** Candidates read per direction, so a hub's busiest hour cannot run up the work. */
export const MAX_CANDIDATES = 40;
const PAGE = 1000;

export interface FoundConnection<F extends ConnFlight> {
  arriving: F;
  departing: F;
  assessment: Assessment;
  /** Users who follow both flights and pair them. */
  users: Set<string>;
}

const iso = (t: number) => new Date(t).toISOString();

async function candidates<F extends ConnFlight>(
  db: SupabaseClient,
  f: F,
): Promise<F[]> {
  const out: F[] = [];
  const landing = Date.parse(f.scheduled_in ?? f.estimated_in ?? "");
  if (f.destination_icao && Number.isFinite(landing)) {
    const { data, error } = await db.from("flights").select("*")
      .eq("origin_icao", f.destination_icao)
      .gt("scheduled_out", iso(landing))
      .lte("scheduled_out", iso(landing + PAIR_WINDOW_MS))
      .limit(MAX_CANDIDATES);
    if (error) throw new Error(`onward flights read failed: ${error.message}`);
    out.push(...(data as F[]));
  }
  const leaving = Date.parse(f.scheduled_out ?? f.estimated_out ?? "");
  if (f.origin_icao && Number.isFinite(leaving)) {
    const { data, error } = await db.from("flights").select("*")
      .eq("destination_icao", f.origin_icao)
      .gte("scheduled_in", iso(leaving - PAIR_WINDOW_MS))
      .lt("scheduled_in", iso(leaving))
      .limit(MAX_CANDIDATES);
    if (error) {
      throw new Error(`inbound flights read failed: ${error.message}`);
    }
    out.push(...(data as F[]));
  }
  return [...new Map(out.filter((c) => c.id !== f.id).map((c) => [c.id, c]))
    .values()];
}

/** Who follows which of `ids`, as user id to flight ids. */
async function follows(
  db: SupabaseClient,
  ids: string[],
): Promise<Map<string, Set<string>>> {
  const out = new Map<string, Set<string>>();
  for (let from = 0;; from += PAGE) {
    const { data, error } = await db.from("user_flights")
      .select("user_id, flight_id").in("flight_id", ids)
      .order("user_id").order("flight_id").range(from, from + PAGE - 1);
    if (error) throw new Error(`follows read failed: ${error.message}`);
    for (const r of data) {
      const set = out.get(r.user_id as string) ?? new Set<string>();
      set.add(r.flight_id as string);
      out.set(r.user_id as string, set);
    }
    if (data.length < PAGE) return out;
  }
}

/** ISO countries of airports by ICAO code; codes the table lacks are left out. */
async function countries(
  db: SupabaseClient,
  icaos: string[],
): Promise<Map<string, string>> {
  if (icaos.length === 0) return new Map();
  const { data, error } = await db.from("airports").select("icao, country")
    .in("icao", icaos);
  if (error) throw new Error(`airports read failed: ${error.message}`);
  return new Map(
    (data ?? []).filter((r) => r.country).map((r) =>
      [r.icao as string, r.country as string] as const
    ),
  );
}

/** Every connection `flight` is part of for at least one user who follows it, with its verdict. */
export async function connectionsOf<F extends ConnFlight>(
  db: SupabaseClient,
  flight: F,
): Promise<FoundConnection<F>[]> {
  const around = await candidates(db, flight);
  if (around.length === 0) return [];
  const byId = new Map([flight, ...around].map((f) => [f.id, f] as const));
  const followed = await follows(db, [...byId.keys()]);
  const found = new Map<string, { a: F; b: F; users: Set<string> }>();
  for (const [user, ids] of followed) {
    if (!ids.has(flight.id)) continue;
    const mine = [...ids].flatMap((id) => byId.get(id) ?? []);
    for (const [a, b] of pairs(mine)) {
      if (a.id !== flight.id && b.id !== flight.id) continue;
      const key = `${a.id}>${b.id}`;
      const c = found.get(key) ?? { a, b, users: new Set<string>() };
      c.users.add(user);
      found.set(key, c);
    }
  }
  if (found.size === 0) return [];
  const codes = new Set<string>();
  for (const { a, b } of found.values()) {
    for (const code of [a.origin_icao, b.origin_icao, b.destination_icao]) {
      if (code) codes.add(code);
    }
  }
  const country = await countries(db, [...codes]);
  return [...found.values()].map(({ a, b, users }) => ({
    arriving: a,
    departing: b,
    assessment: assess(a, b, (icao) => country.get(icao) ?? null),
    users,
  }));
}
