// faa-notams on the local stack: not configured without the FAA key, decoded and cached with it, stale
// when the API fails. The API is never called: the answer is _shared/fixtures/notam_api_ksfo.json.
import { assertEquals } from "jsr:@std/assert@1";
import {
  fakeVerifier,
  loadIndexHandler,
  makeUser,
  test as baseTest,
  testDb,
} from "../_shared/test_util.ts";
import { NOTAM_URL } from "../_shared/notam.ts";
import { type Answer, CACHE_TTL_MS, handler } from "./handler.ts";

const API = Deno.readTextFileSync(
  new URL("../_shared/fixtures/notam_api_ksfo.json", import.meta.url),
);
const NOW = new Date("2026-10-31T08:00:00Z");
const at = (ms: number) => () => new Date(NOW.getTime() + ms);
const CREDS = () => ({
  clientId: "id",
  clientSecret: "secret",
  url: NOTAM_URL,
});

const db = await testDb();

async function clear() {
  const r = await db.from("faa_notam_cache").delete().in("airport_icao", [
    "KSFO",
    "LFPG",
  ]);
  if (r.error) throw r.error;
}

function test(name: string, fn: () => Promise<void>) {
  baseTest(db, name, async () => {
    await clear();
    try {
      await fn();
    } finally {
      await clear();
    }
  });
}

function api(body: string | null) {
  const f = {
    calls: 0,
    body,
    fn: (() => {
      f.calls++;
      return Promise.resolve(
        f.body === null
          ? new Response("down", { status: 500 })
          : new Response(f.body),
      );
    }) as typeof fetch,
  };
  return f;
}

function get(token: string | null, query: string): Request {
  return new Request(`http://localhost/faa-notams?${query}`, {
    headers: token ? { authorization: `Bearer ${token}` } : {},
  });
}

async function ask(
  query: string,
  deps: Partial<Parameters<typeof handler>[1]> = {},
): Promise<{ status: number; body: Answer & { error?: { code: string } } }> {
  const user = await makeUser(db);
  const res = await handler(get(user, query), {
    db,
    verifier: fakeVerifier,
    now: at(0),
    credentials: CREDS,
    ...deps,
  });
  return { status: res.status, body: await res.json() };
}

test("without the FAA key: not configured, nothing called, nothing stored", async () => {
  const faa = api(API);
  const { status, body } = await ask("airport=SFO", {
    fetchFn: faa.fn,
    credentials: () => undefined,
  });
  assertEquals(status, 200);
  assertEquals([body.configured, body.notams], [false, []]);
  assertEquals(faa.calls, 0);
  const row = await db.from("faa_notam_cache").select("airport_icao").eq(
    "airport_icao",
    "KSFO",
  );
  assertEquals(row.data, []);
});

test("with the key: decoded, ranked and cached for 15 minutes", async () => {
  const faa = api(API);
  const { body } = await ask("airport=SFO", { fetchFn: faa.fn });
  assertEquals(body.configured, true);
  assertEquals(body.airport, "KSFO");
  assertEquals(body.iata, "SFO");
  assertEquals(body.notams[0].title, "Runway 10L/28R closed");
  assertEquals(
    body.notams[0].raw,
    "!SFO 10/101 SFO RWY 10L/28R CLSD 2610310500-2610311300",
  );
  assertEquals(body.notams.length, 7);
  await ask("airport=KSFO", { fetchFn: faa.fn, now: at(CACHE_TTL_MS - 1000) });
  assertEquals(faa.calls, 1);
});

test("an airport outside the US is asked by its ICAO code, decoded and cached like any other", async () => {
  const urls: string[] = [];
  const fn = ((input: string | URL | Request) => {
    urls.push(String(input));
    return Promise.resolve(new Response(API));
  }) as typeof fetch;
  const { status, body } = await ask("airport=CDG", { fetchFn: fn });
  assertEquals(status, 200);
  assertEquals([body.airport, body.iata, body.configured], [
    "LFPG",
    "CDG",
    true,
  ]);
  assertEquals(new URL(urls[0]).searchParams.get("icaoLocation"), "LFPG");
  // Without the key it is not configured, with no call, outside the US as inside.
  await clear();
  const off = await ask("airport=LFPG", {
    fetchFn: fn,
    credentials: () => undefined,
  });
  assertEquals([off.body.configured, off.body.notams, urls.length], [
    false,
    [],
    1,
  ]);
});

test("a failing API: the last answer, stale; none at all is 503", async () => {
  const faa = api(API);
  await ask("airport=SFO", { fetchFn: faa.fn });
  faa.body = null;
  const stale = await ask("airport=SFO", {
    fetchFn: faa.fn,
    now: at(CACHE_TTL_MS + 1000),
  });
  assertEquals([stale.status, stale.body.stale, stale.body.notams.length], [
    200,
    true,
    7,
  ]);
  await clear();
  const none = await ask("airport=SFO", { fetchFn: faa.fn });
  assertEquals([none.status, none.body.error?.code], [
    503,
    "provider_unavailable",
  ]);
});

test("bad requests", async () => {
  assertEquals((await ask("airport=ZZZZ")).status, 400);
  const res = await handler(get("bad", "airport=SFO"), {
    db,
    verifier: fakeVerifier,
  });
  assertEquals(res.status, 401);
});

test("the deployed entry point starts and answers", async () => {
  const serve = await loadIndexHandler(
    new URL("./index.ts", import.meta.url).href,
  );
  assertEquals((await serve(get(null, "airport=SFO"))).status, 401);
});

// MARK: Contract files: what SupabaseFAAService decodes in Swift

const CONTRACT_DIR = new URL("./contract/", import.meta.url);

async function checkContract(name: string, actual: unknown) {
  const url = new URL(`${name}.json`, CONTRACT_DIR);
  const text = JSON.stringify(actual, null, 2) + "\n";
  if (Deno.env.get("UPDATE_CONTRACT") === "1") {
    await Deno.mkdir(CONTRACT_DIR, { recursive: true });
    await Deno.writeTextFile(url, text);
    return;
  }
  assertEquals(
    JSON.parse(await Deno.readTextFile(url)),
    JSON.parse(text),
    `contract/${name}.json is out of date: run with UPDATE_CONTRACT=1`,
  );
}

test("contract examples match the handler's answers", async () => {
  await checkContract(
    "notams",
    (await ask("airport=SFO", { fetchFn: api(API).fn })).body,
  );
  await checkContract(
    "not_configured",
    (await ask("airport=SFO", { credentials: () => undefined })).body,
  );
});
