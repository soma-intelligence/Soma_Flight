// liveConditions without a database or the network: the table and fetch are fakes. A non-US airport
// (LFPG) is read from METAR, TAF and NOTAM answers; each failing source is left out, not faked.
import { assert, assertEquals } from "jsr:@std/assert@1";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { liveConditions, NOTAM_TTL_MS } from "./conditions.ts";
import { NOTAM_URL } from "../_shared/notam.ts";

const NOW = new Date("2026-10-31T08:00:00Z");
const CREDS = () => ({
  clientId: "id",
  clientSecret: "secret",
  url: NOTAM_URL,
});
const fixture = (name: string) =>
  Deno.readTextFileSync(
    new URL(`../_shared/fixtures/${name}`, import.meta.url),
  );

/** A table fake that keeps one row per table and key, enough for the cache reads and writes. */
function fakeDb(
  rows: Record<string, { payload: unknown; fetched_at: string }> = {},
) {
  const writes: unknown[] = [];
  const db = {
    writes,
    from(table: string) {
      return {
        select: () => ({
          eq: (_c: string, v: string) => ({
            maybeSingle: () =>
              Promise.resolve({
                data: table === "airports" ? { iata: "CDG" } : rows[v] ?? null,
                error: null,
              }),
          }),
        }),
        upsert: (row: { airport_icao: string }) => {
          writes.push(row);
          return Promise.resolve({ error: null });
        },
      };
    },
  };
  return db as unknown as SupabaseClient & { writes: unknown[] };
}

function noaaAndFaa(
  opts: { metar?: string | null; taf?: string | null; notam?: string | null } =
    {},
) {
  const seen: string[] = [];
  const fn = ((input: string | URL | Request) => {
    const url = String(input);
    seen.push(url);
    const pick = url.includes("/metar?")
      ? opts.metar
      : url.includes("/taf?")
      ? opts.taf
      : opts.notam;
    return Promise.resolve(
      pick === null || pick === undefined
        ? new Response("down", { status: 503 })
        : new Response(pick),
    );
  }) as typeof fetch;
  return { fn, seen };
}

const METAR = fixture("metar_kaus.json");
const TAF = fixture("taf_kaus.json");
const NOTAMS = fixture("notam_api_ksfo.json");

Deno.test("a non-US airport: weather and notices read, the summary says what it was made from", async () => {
  const net = noaaAndFaa({ metar: METAR, taf: TAF, notam: NOTAMS });
  const db = fakeDb();
  const c = await liveConditions(db, { fetchFn: net.fn, credentials: CREDS })(
    "LFPG",
    NOW,
  );
  assert(c);
  assertEquals(c.sources, { metar: true, taf: true, notam: true });
  assert(net.seen.some((u) => u.includes("icaoLocation=LFPG")));
  assert(net.seen.some((u) => u.includes("ids=LFPG")));
  // The notices were stored for faa-notams to reuse.
  assertEquals(db.writes.length, 1);
});

Deno.test("without the NOTAM key only the weather is read, and the API is never called", async () => {
  const net = noaaAndFaa({ metar: METAR, taf: TAF });
  const c = await liveConditions(fakeDb(), {
    fetchFn: net.fn,
    credentials: () => undefined,
  })("LFPG", NOW);
  assert(c);
  assertEquals(c.sources, { metar: true, taf: true, notam: false });
  assertEquals(net.seen.some((u) => u.includes("notamapi")), false);
});

Deno.test("a fresh cached notice list is used without a call", async () => {
  const cached = {
    LFPG: {
      fetched_at: new Date(NOW.getTime() - 60_000).toISOString(),
      payload: {
        notams: [{
          number: "A1/26",
          kind: "airport_closed",
          title: "Airport closed",
          detail: null,
          relevance: 100,
          raw: "x",
          starts_at: new Date(NOW.getTime() - 3600_000).toISOString(),
          ends_at: new Date(NOW.getTime() + 3600_000).toISOString(),
          ends_estimated: false,
        }],
      },
    },
  };
  const net = noaaAndFaa({ metar: METAR, taf: TAF });
  const c = await liveConditions(fakeDb(cached), {
    fetchFn: net.fn,
    credentials: CREDS,
  })("LFPG", NOW);
  assert(c);
  assertEquals(c.level, "major");
  assertEquals(c.reasons[0].text, "Airport closed by notice");
  assertEquals(net.seen.some((u) => u.includes("notamapi")), false);
});

Deno.test("a failing notice API falls back to a stale list, else the source is left out", async () => {
  const old = {
    LFPG: {
      fetched_at: new Date(NOW.getTime() - NOTAM_TTL_MS - 1000).toISOString(),
      payload: { notams: [] },
    },
  };
  const net = noaaAndFaa({ metar: METAR, taf: TAF, notam: null });
  const stale = await liveConditions(fakeDb(old), {
    fetchFn: net.fn,
    credentials: CREDS,
  })("LFPG", NOW);
  assertEquals(stale?.sources.notam, true);
  const none = await liveConditions(fakeDb(), {
    fetchFn: net.fn,
    credentials: CREDS,
  })("LFPG", NOW);
  assertEquals(none?.sources.notam, false);
});

Deno.test("nothing readable at all is no summary, not an all clear", async () => {
  const net = noaaAndFaa({ metar: null, taf: null, notam: null });
  const c = await liveConditions(fakeDb(), {
    fetchFn: net.fn,
    credentials: () => undefined,
  })("LFPG", NOW);
  assertEquals(c, null);
});

Deno.test("the weather is kept 10 minutes in the isolate", async () => {
  const net = noaaAndFaa({ metar: METAR, taf: TAF });
  const f = liveConditions(fakeDb(), {
    fetchFn: net.fn,
    credentials: () => undefined,
  });
  await f("LFPG", NOW);
  const calls = net.seen.length;
  await f("LFPG", new Date(NOW.getTime() + 5 * 60_000));
  assertEquals(net.seen.length, calls);
  await f("LFPG", new Date(NOW.getTime() + 11 * 60_000));
  assert(net.seen.length > calls);
});
