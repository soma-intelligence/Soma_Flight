import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  AzureResponsesClient,
  chargeLlm,
  DEFAULT_CALL_COST_USD,
  llmCallCost,
  llmConfig,
  outputText,
} from "./llm.ts";
import { ApiError } from "./errors.ts";

const env = (m: Record<string, string>) => (n: string) => m[n];
const ON = {
  LLM_ENABLED: "true",
  AZURE_OPENAI_ENDPOINT: "https://x.openai.azure.com/",
  AZURE_OPENAI_API_KEY: "k",
};

Deno.test("llmConfig is null unless the switch is exactly true and the settings are present", () => {
  assertEquals(llmConfig(env({})), null);
  assertEquals(llmConfig(env({ ...ON, LLM_ENABLED: "TRUE" })), null);
  assertEquals(llmConfig(env({ ...ON, LLM_ENABLED: "1" })), null);
  assertEquals(llmConfig(env({ ...ON, AZURE_OPENAI_API_KEY: "" })), null);
  assertEquals(llmConfig(env({ ...ON, AZURE_OPENAI_ENDPOINT: "" })), null);
  assertEquals(
    llmConfig(env({ ...ON, AZURE_OPENAI_ENDPOINT: "http://x.example" })),
    null,
  );
});

Deno.test("llmConfig trims the endpoint and defaults the deployment", () => {
  assertEquals(llmConfig(env(ON)), {
    endpoint: "https://x.openai.azure.com",
    apiKey: "k",
    deployment: "gpt-6-luna",
  });
  assertEquals(
    llmConfig(env({ ...ON, AZURE_OPENAI_DEPLOYMENT: "mine" }))?.deployment,
    "mine",
  );
});

Deno.test("outputText reads output_text, or the message parts, and refuses an unfinished answer", () => {
  assertEquals(outputText({ output_text: "a" }), "a");
  assertEquals(
    outputText({
      output: [
        { type: "reasoning" },
        { type: "message", content: [{ type: "output_text", text: "b" }] },
      ],
    }),
    "b",
  );
  assertEquals(outputText({ status: "incomplete", output_text: "a" }), null);
  assertEquals(outputText({ output: [] }), null);
  assertEquals(outputText(null), null);
});

Deno.test("the client posts to the Responses API with the key header and strict JSON output", async () => {
  let seen: { url: string; init: RequestInit } | undefined;
  const fake = ((url: string, init: RequestInit) => {
    seen = { url, init };
    return Promise.resolve(
      new Response(JSON.stringify({ output_text: '{"text":"x"}' })),
    );
  }) as unknown as typeof fetch;
  const c = new AzureResponsesClient(llmConfig(env(ON))!, fake);
  const out = await c.complete({
    instructions: "i",
    input: "in",
    schemaName: "n",
    schema: { type: "object" },
    maxOutputTokens: 50,
  });
  assertEquals(out, '{"text":"x"}');
  assertEquals(seen!.url, "https://x.openai.azure.com/openai/v1/responses");
  const headers = seen!.init.headers as Record<string, string>;
  assertEquals(headers["api-key"], "k");
  const body = JSON.parse(seen!.init.body as string);
  assertEquals(body.model, "gpt-6-luna");
  assertEquals(body.store, false);
  assertEquals(body.text.format.strict, true);
  assertEquals(body.max_output_tokens, 50);
});

Deno.test("a provider failure becomes 503 llm_unavailable", async () => {
  const bad = (() =>
    Promise.resolve(
      new Response("no", { status: 500 }),
    )) as unknown as typeof fetch;
  const c = new AzureResponsesClient(llmConfig(env(ON))!, bad);
  const e = await assertRejects(() =>
    c.complete({
      instructions: "",
      input: "",
      schemaName: "n",
      schema: {},
      maxOutputTokens: 1,
    })
  );
  assertEquals((e as ApiError).code, "llm_unavailable");
  assertEquals((e as ApiError).status, 503);
});

Deno.test("llmCallCost falls back on the default", () => {
  assertEquals(llmCallCost(""), DEFAULT_CALL_COST_USD);
  assertEquals(llmCallCost("abc"), DEFAULT_CALL_COST_USD);
  assertEquals(llmCallCost("-1"), DEFAULT_CALL_COST_USD);
  assertEquals(llmCallCost("0.002"), 0.002);
});

Deno.test("chargeLlm counts under llm:<name> and refuses at the cap", async () => {
  const calls: Record<string, unknown>[] = [];
  const db = (ok: boolean) => ({
    rpc: (_fn: string, args: Record<string, unknown>) => {
      calls.push(args);
      return Promise.resolve({ data: ok, error: null });
    },
  });
  await chargeLlm(db(true) as never, "flight-brief", {
    now: new Date("2026-11-07T10:00:00Z"),
    cap: 5,
    cost: 0.01,
  });
  assertEquals(calls[0], {
    p_day: "2026-11-07",
    p_endpoint: "llm:flight-brief",
    p_cost: 0.01,
    p_cap: 5,
  });
  const e = await assertRejects(() =>
    chargeLlm(db(false) as never, "flight-brief", { cap: 5, cost: 0.01 })
  );
  assertEquals((e as ApiError).code, "llm_unavailable");
});
