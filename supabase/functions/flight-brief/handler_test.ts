import { assert, assertEquals } from "jsr:@std/assert@1";
const test = Deno.test;
import type { LlmClient, LlmConfig } from "../_shared/llm.ts";
import { ApiError } from "../_shared/errors.ts";
import {
  BRIEF_TTL_MS,
  type BriefCache,
  type CachedBrief,
  type Deps,
  handler,
} from "./handler.ts";
import type { Kind } from "./facts.ts";

const FLIGHT = "6f1c2b1e-0a47-4b6e-9d2c-3b1d0a7c5e11";
const NOW = new Date("2026-11-07T12:00:00Z");
const CONFIG: LlmConfig = {
  endpoint: "https://x",
  apiKey: "k",
  deployment: "d",
};
const FACTS = [
  { id: "ident", value: "AF84" },
  { id: "gate", value: "K45" },
  { id: "walk_minutes", value: 12 },
];
const GOOD = JSON.stringify({
  text: "Gate K45 is about a 12 minute walk from security.",
  facts_used: ["gate", "walk_minutes"],
});

function setup(over: Partial<Deps> & { raw?: string } = {}) {
  const log = {
    model: 0,
    charged: 0,
    rated: 0,
    puts: 0,
    inputs: [] as string[],
  };
  const store = new Map<string, CachedBrief>();
  const cache: BriefCache = {
    get: (s, k, h) => Promise.resolve(store.get(`${s}|${k}|${h}`) ?? null),
    put: (s, k, h, row, now) => {
      log.puts++;
      store.set(`${s}|${k}|${h}`, { ...row, created_at: now.toISOString() });
      return Promise.resolve();
    },
  };
  const llm: LlmClient = {
    complete: (req) => {
      log.model++;
      log.inputs.push(req.input);
      return Promise.resolve(over.raw ?? GOOD);
    },
  };
  const deps: Deps = {
    config: () => CONFIG,
    llm: () => llm,
    rate: () => {
      log.rated++;
      return Promise.resolve();
    },
    charge: () => {
      log.charged++;
      return Promise.resolve();
    },
    cache,
    verifier: {
      auth: {
        getUser: (jwt: string) =>
          Promise.resolve(
            jwt === "good"
              ? { data: { user: { id: "u1" } }, error: null }
              : { data: { user: null }, error: new Error("bad") },
          ),
      },
    },
    now: () => NOW,
    ...over,
  };
  return { deps, log, store };
}

const post = (body: unknown, token = "good") =>
  new Request("http://x/flight-brief", {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
const ask = (extra: Record<string, unknown> = {}) =>
  post({ kind: "door_to_door", subject: FLIGHT, facts: FACTS, ...extra });
const code = async (r: Response) => (await r.json()).error?.code;

test("off or missing config answers 503 llm_unavailable and spends nothing", async () => {
  const { deps, log } = setup({ config: () => null });
  const r = await handler(ask(), deps);
  assertEquals(r.status, 503);
  assertEquals(await code(r), "llm_unavailable");
  assertEquals([log.model, log.charged], [0, 0]);
});

test("a signed-in user is required, before anything else", async () => {
  const { deps, log } = setup();
  const noHeader = await handler(
    new Request("http://x/flight-brief", { method: "POST", body: "{}" }),
    deps,
  );
  assertEquals(noHeader.status, 401);
  const bad = await handler(ask(), { ...deps, verifier: deps.verifier });
  assertEquals(bad.status, 200);
  const badToken = await handler(post({}, "nope"), deps);
  assertEquals(badToken.status, 401);
  assertEquals(log.model, 1);
});

test("only POST", async () => {
  const { deps } = setup();
  const r = await handler(new Request("http://x/flight-brief"), deps);
  assertEquals(r.status, 405);
});

test("a good request is rate counted, charged, answered and cached", async () => {
  const { deps, log, store } = setup();
  const r = await handler(ask(), deps);
  assertEquals(r.status, 200);
  const b = await r.json();
  assertEquals(b.kind, "door_to_door");
  assertEquals(b.subject, FLIGHT);
  assertEquals(b.cached, false);
  assertEquals(b.facts_used, ["gate", "walk_minutes"]);
  assertEquals(b.generated_at, NOW.toISOString());
  assertEquals([log.model, log.charged, log.rated, log.puts], [1, 1, 1, 1]);
  assertEquals(store.size, 1);
  // The prompt holds the facts and nothing else of the request.
  assertEquals(log.inputs[0], "gate: K45\nident: AF84\nwalk_minutes: 12");
});

test("the same facts are served from the cache: no model call, no charge", async () => {
  const { deps, log } = setup();
  await handler(ask(), deps);
  const r = await handler(ask(), deps);
  const b = await r.json();
  assertEquals(b.cached, true);
  assertEquals(b.text, "Gate K45 is about a 12 minute walk from security.");
  assertEquals([log.model, log.charged, log.rated], [1, 1, 2]);
});

test("changed facts, another kind or another flight miss the cache", async () => {
  const { deps, log } = setup();
  await handler(ask(), deps);
  await handler(
    ask({ facts: [...FACTS.slice(0, 2), { id: "walk_minutes", value: 13 }] }),
    deps,
  );
  assertEquals(log.model, 2);
});

test("an expired cache row is written again", async () => {
  const { deps, log, store } = setup();
  await handler(ask(), deps);
  for (const [k, v] of store) {
    store.set(k, {
      ...v,
      created_at: new Date(NOW.getTime() - BRIEF_TTL_MS - 1).toISOString(),
    });
  }
  await handler(ask(), deps);
  assertEquals(log.model, 2);
});

test("a guardrail failure is 503, not cached, and the call is still counted", async () => {
  const bad = JSON.stringify({
    text: "The gate is K45 and the walk is 40 minutes.",
    facts_used: ["gate", "walk_minutes"],
  });
  const { deps, log, store } = setup({ raw: bad });
  const r = await handler(ask(), deps);
  assertEquals(r.status, 503);
  assertEquals(await code(r), "llm_unavailable");
  assertEquals(store.size, 0);
  assertEquals(log.charged, 1);
});

test("the spend cap and the rate limit stop the call before the model", async () => {
  const capped = setup({
    charge: () => Promise.reject(new ApiError("llm_unavailable", 503, "cap")),
  });
  const r1 = await handler(ask(), capped.deps);
  assertEquals(r1.status, 503);
  assertEquals(capped.log.model, 0);

  const limited = setup({
    rate: () => Promise.reject(new ApiError("rate_limited", 429, "many")),
  });
  const r2 = await handler(ask(), limited.deps);
  assertEquals(r2.status, 429);
  assertEquals(limited.log.model, 0);
});

test("bad bodies are 400 invalid_request", async () => {
  const { deps } = setup();
  const cases = [
    { kind: "poem", subject: FLIGHT, facts: FACTS },
    { kind: "door_to_door", subject: "not-a-uuid", facts: FACTS },
    {
      kind: "door_to_door",
      subject: FLIGHT,
      facts: [...FACTS, { id: "passenger", value: "Ada" }],
    },
    { kind: "door_to_door", subject: FLIGHT },
    {
      kind: "airport_summary",
      subject: FLIGHT,
      facts: [{ id: "iata", value: "SFO" }, { id: "wind_knots", value: 5 }],
    },
  ];
  for (const c of cases) {
    const r = await handler(post(c), deps);
    assertEquals(r.status, 400, JSON.stringify(c));
    assertEquals(await code(r), "invalid_request");
  }
  const notJson = await handler(
    new Request("http://x", {
      method: "POST",
      headers: { authorization: "Bearer good" },
      body: "{",
    }),
    deps,
  );
  assertEquals(notJson.status, 400);
});

test("airport_summary takes an airport code and upper cases it", async () => {
  const raw = JSON.stringify({
    text: "Winds are 12 knots at SFO and the weather is VFR right now.",
    facts_used: ["wind_knots", "weather_category", "iata"],
  });
  const { deps, store } = setup({ raw });
  const r = await handler(
    post({
      kind: "airport_summary" satisfies Kind,
      subject: "ksfo",
      facts: [
        { id: "iata", value: "SFO" },
        { id: "wind_knots", value: 12 },
        { id: "weather_category", value: "VFR" },
      ],
    }),
    deps,
  );
  assertEquals(r.status, 200);
  assertEquals((await r.json()).subject, "KSFO");
  assert([...store.keys()][0].startsWith("KSFO|airport_summary|"));
});

// MARK: Contract file: what SupabaseFlightBriefService decodes in Swift

const CONTRACT_DIR = new URL("./contract/", import.meta.url);

test("contract example matches the handler's answer", async () => {
  const { deps } = setup();
  const answer = await (await handler(ask(), deps)).json();
  const text = JSON.stringify(answer, null, 2) + "\n";
  const url = new URL("door_to_door.json", CONTRACT_DIR);
  if (Deno.env.get("UPDATE_CONTRACT") === "1") {
    await Deno.mkdir(CONTRACT_DIR, { recursive: true });
    await Deno.writeTextFile(url, text);
    return;
  }
  assertEquals(
    JSON.parse(await Deno.readTextFile(url)),
    JSON.parse(text),
    "contract/door_to_door.json is out of date: run with UPDATE_CONTRACT=1",
  );
});
