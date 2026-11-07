// Shared client for the language-model texts (flight-brief). Azure OpenAI, Responses API.
//
// The feature is switched off until the owner says yes on cost: LLM_ENABLED must be exactly "true" and
// AZURE_OPENAI_ENDPOINT and AZURE_OPENAI_API_KEY must be set, else `llmConfig` is null and the caller
// answers 503 llm_unavailable. AZURE_OPENAI_DEPLOYMENT names the deployment (default gpt-6-luna).
// Nothing here ever logs a key, a prompt or an answer.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { ApiError } from "./errors.ts";
import { dailyCap } from "./limits.ts";

export const DEFAULT_DEPLOYMENT = "gpt-6-luna";
/** Cautious cost counted per model call in USD, until the owner measures the real figure. */
export const DEFAULT_CALL_COST_USD = 0.01;

export interface LlmConfig {
  endpoint: string;
  apiKey: string;
  deployment: string;
}

type Env = (name: string) => string | undefined;

/** The configuration, or null when the switch is off or a setting is missing. */
export function llmConfig(
  env: Env = (n) => Deno.env.get(n),
): LlmConfig | null {
  if (env("LLM_ENABLED") !== "true") return null;
  const endpoint = env("AZURE_OPENAI_ENDPOINT")?.trim().replace(/\/+$/, "");
  const apiKey = env("AZURE_OPENAI_API_KEY")?.trim();
  if (!endpoint || !apiKey) return null;
  if (!/^https:\/\//.test(endpoint)) return null;
  const deployment = env("AZURE_OPENAI_DEPLOYMENT")?.trim() ||
    DEFAULT_DEPLOYMENT;
  return { endpoint, apiKey, deployment };
}

/** The error every off, unconfigured, capped or failed model call ends in: 503 llm_unavailable. */
export function llmUnavailable(message = "Language model is unavailable") {
  return new ApiError("llm_unavailable", 503, message);
}

export interface LlmRequest {
  instructions: string;
  input: string;
  /** JSON schema the answer must follow (strict structured output). */
  schemaName: string;
  schema: Record<string, unknown>;
  maxOutputTokens: number;
}

/** What the handler needs from a model: the answer's JSON text. */
export interface LlmClient {
  complete(req: LlmRequest): Promise<string>;
}

type Fetch = typeof fetch;

/** Azure OpenAI through the Responses API (`POST {endpoint}/openai/v1/responses`). */
export class AzureResponsesClient implements LlmClient {
  constructor(
    private readonly config: LlmConfig,
    private readonly fetchFn: Fetch = fetch,
    private readonly timeoutMs = 20_000,
  ) {}

  async complete(req: LlmRequest): Promise<string> {
    let res: Response;
    try {
      res = await this.fetchFn(`${this.config.endpoint}/openai/v1/responses`, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "api-key": this.config.apiKey,
        },
        body: JSON.stringify({
          model: this.config.deployment,
          instructions: req.instructions,
          input: req.input,
          max_output_tokens: req.maxOutputTokens,
          store: false,
          text: {
            format: {
              type: "json_schema",
              name: req.schemaName,
              schema: req.schema,
              strict: true,
            },
          },
        }),
        signal: AbortSignal.timeout(this.timeoutMs),
      });
    } catch (e) {
      console.error("llm request failed", (e as Error).name);
      throw llmUnavailable();
    }
    if (!res.ok) {
      console.error("llm provider status", res.status);
      await res.body?.cancel();
      throw llmUnavailable();
    }
    let body: unknown;
    try {
      body = await res.json();
    } catch {
      throw llmUnavailable();
    }
    const text = outputText(body);
    if (text === null) throw llmUnavailable("Language model gave no answer");
    return text;
  }
}

/** The text of a Responses API answer: `output_text` when present, else the output_text parts. */
export function outputText(body: unknown): string | null {
  const b = body as {
    status?: string;
    output_text?: unknown;
    output?: { type?: string; content?: { type?: string; text?: unknown }[] }[];
  } | null;
  if (!b || typeof b !== "object") return null;
  if (b.status && b.status !== "completed") return null;
  if (typeof b.output_text === "string" && b.output_text) return b.output_text;
  const parts: string[] = [];
  for (const item of b.output ?? []) {
    if (item.type !== "message") continue;
    for (const c of item.content ?? []) {
      if (c.type === "output_text" && typeof c.text === "string") {
        parts.push(c.text);
      }
    }
  }
  return parts.length ? parts.join("") : null;
}

/** LLM_CALL_COST_USD (cost counted per call), or the cautious default for a missing or invalid value. */
export function llmCallCost(
  raw: string | undefined = Deno.env.get("LLM_CALL_COST_USD"),
): number {
  const n = Number(raw);
  return raw && Number.isFinite(n) && n > 0 ? n : DEFAULT_CALL_COST_USD;
}

/**
 * Counts one model call in today's usage_counters (UTC day, endpoint `llm:<name>`) through charge_usage,
 * the same spend cap as the AeroAPI calls (AEROAPI_DAILY_CAP_USD: one budget for every paid call).
 * Throws llm_unavailable when the call would pass the cap, before any request goes out.
 */
export async function chargeLlm(
  db: Pick<SupabaseClient, "rpc">,
  name: string,
  opts: { now?: Date; cap?: number; cost?: number } = {},
): Promise<void> {
  const { data, error } = await db.rpc("charge_usage", {
    p_day: (opts.now ?? new Date()).toISOString().slice(0, 10),
    p_endpoint: `llm:${name}`,
    p_cost: opts.cost ?? llmCallCost(),
    p_cap: opts.cap ?? dailyCap(),
  });
  if (error) throw new Error(`charge_usage failed: ${error.message}`);
  if (data !== true) {
    console.error(`daily spend cap reached, llm:${name} refused`);
    throw llmUnavailable("Daily budget reached");
  }
}
