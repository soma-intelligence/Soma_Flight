// The deployed entry point must start and serve its no-AeroAPI paths without AEROAPI_KEY.
import { assertEquals } from "jsr:@std/assert@1";
import {
  loadIndexHandler,
  makeUser,
  test,
  testDb,
  userClient,
} from "../_shared/test_util.ts";

const db = await testDb();
const serve = await loadIndexHandler(
  new URL("./index.ts", import.meta.url).href,
);

const fixture = (name: string) =>
  Deno.readTextFileSync(
    new URL(`../_shared/fixtures/${name}`, import.meta.url),
  );

async function token(userId: string): Promise<string> {
  const c = await userClient(db, userId);
  return (await c.auth.getSession()).data.session!.access_token;
}

async function clearKaus() {
  for (const t of ["airport_snapshots", "airport_refresh_leases"]) {
    const r = await db.from(t).delete().eq("icao", "KAUS");
    if (r.error) throw r.error;
  }
}

test(
  db,
  "airport-board starts without AEROAPI_KEY and serves weather",
  async () => {
    await clearKaus();
    const realFetch = globalThis.fetch;
    globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) => {
      const url = String(input);
      if (!url.startsWith("https://aviationweather.gov/")) {
        return realFetch(input, init);
      }
      return Promise.resolve(
        new Response(
          fixture(
            url.includes("/metar?") ? "metar_kaus.json" : "taf_kaus.json",
          ),
        ),
      );
    }) as typeof fetch;
    try {
      const t = await token(await makeUser(db));
      const res = await serve(
        new Request("http://local/airport-board?airport=AUS&kind=weather", {
          headers: { authorization: `Bearer ${t}` },
        }),
      );
      assertEquals(res.status, 200);
      assertEquals((await res.json()).weather.category, "IFR");

      // A board needs AeroAPI: 503 only when asked for.
      const board = await serve(
        new Request("http://local/airport-board?airport=AUS&kind=departures", {
          headers: { authorization: `Bearer ${t}` },
        }),
      );
      assertEquals(board.status, 503);
      assertEquals((await board.json()).error.code, "provider_unavailable");
    } finally {
      globalThis.fetch = realFetch;
      await clearKaus();
    }
  },
);
