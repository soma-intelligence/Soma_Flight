// POST /flight-brief { kind, subject, facts } -> { kind, subject, text, facts_used, generated_at, cached }
// Short language-model texts from facts the app already shows. SWITCHED OFF until the owner says yes on
// cost: without LLM_ENABLED=true and the Azure OpenAI settings every call answers 503 llm_unavailable.
//
//   kind door_to_door    subject = flight id (uuid): a guide from the leave-by inputs, terminal, gate,
//                        walk, security wait and check-in
//   kind delay_cause     subject = flight id (uuid): why the flight is late, from the inbound plane,
//                        METAR, FAA program and gate changes
//   kind airport_summary subject = airport code (IATA or ICAO): current conditions from weather,
//                        delays, FAA program and the security wait
//
// Guardrails (facts.ts): the request carries structured facts only, each with an id from a fixed list
// and a value of a strict type, so no name or document number can reach a prompt. The model answers
// JSON { text, facts_used }; the answer is dropped (503) when it cites an unknown fact, cites nothing,
// or writes a number that is not in a cited fact. Answers are cached per subject, kind and facts hash
// (llm_brief_cache), so the same facts never pay twice. Each model call is counted in usage_counters
// (endpoint llm:flight-brief) under the same daily cap as AeroAPI, and a user gets
// BRIEF_MAX_PER_HOUR calls an hour (cache hits count too: they cost a read, not a model call).
import { requireUser, type TokenVerifier } from "../_shared/auth.ts";
import { ApiError, errorResponse, json } from "../_shared/errors.ts";
import {
  type LlmClient,
  type LlmConfig,
  llmUnavailable,
} from "../_shared/llm.ts";
import {
  ANSWER_SCHEMA,
  checkAnswer,
  factsHash,
  instructionsFor,
  type Kind,
  KINDS,
  parseFacts,
  renderFacts,
} from "./facts.ts";

export const BRIEF_MAX_PER_HOUR = 30;
/** A cached answer is served for this long; the key already holds the facts, so it only bounds age. */
export const BRIEF_TTL_MS = 6 * 3_600_000;
export const MAX_OUTPUT_TOKENS = 400;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const AIRPORT = /^[A-Za-z]{3,4}$/;

export interface CachedBrief {
  text: string;
  facts_used: string[];
  created_at: string;
}

export interface BriefCache {
  get(
    subject: string,
    kind: Kind,
    hash: string,
  ): Promise<CachedBrief | null>;
  put(
    subject: string,
    kind: Kind,
    hash: string,
    row: { text: string; facts_used: string[] },
    now: Date,
  ): Promise<void>;
}

export interface Deps {
  /** The model settings, or null when the feature is off or not configured. */
  config: () => LlmConfig | null;
  llm: (config: LlmConfig) => LlmClient;
  /** Throws rate_limited (429) over the per-user limit. */
  rate: (userId: string) => Promise<void>;
  /** Counts one model call in the spend cap; throws llm_unavailable at the cap. */
  charge: (now: Date) => Promise<void>;
  cache: BriefCache;
  verifier?: TokenVerifier;
  now?: () => Date;
}

export async function handler(req: Request, deps: Deps): Promise<Response> {
  try {
    if (req.method !== "POST") {
      throw new ApiError("invalid_request", 405, "POST only");
    }
    const { userId } = await requireUser(req, deps.verifier);
    const config = deps.config();
    if (!config) throw llmUnavailable();
    await deps.rate(userId);

    let body: Record<string, unknown>;
    try {
      body = await req.json();
    } catch {
      throw new ApiError("invalid_request", 400, "Body must be JSON");
    }
    if (!body || typeof body !== "object" || Array.isArray(body)) {
      throw new ApiError("invalid_request", 400, "Body must be an object");
    }
    const kind = body.kind as Kind;
    if (!KINDS.includes(kind)) {
      throw new ApiError("invalid_request", 400, "Unknown kind");
    }
    const subject = typeof body.subject === "string"
      ? (kind === "airport_summary"
        ? body.subject.toUpperCase()
        : body.subject.toLowerCase())
      : "";
    const subjectOk = kind === "airport_summary"
      ? AIRPORT.test(subject)
      : UUID.test(subject);
    if (!subjectOk) {
      throw new ApiError(
        "invalid_request",
        400,
        kind === "airport_summary"
          ? "subject must be an airport code"
          : "subject must be a flight id",
      );
    }
    const parsed = parseFacts(kind, body.facts);
    if ("error" in parsed) {
      throw new ApiError("invalid_request", 400, parsed.error);
    }
    const { facts } = parsed;
    const now = (deps.now ?? (() => new Date()))();
    const hash = await factsHash(kind, facts);

    const hit = await deps.cache.get(subject, kind, hash);
    if (hit && now.getTime() - Date.parse(hit.created_at) < BRIEF_TTL_MS) {
      return json({
        kind,
        subject,
        text: hit.text,
        facts_used: hit.facts_used,
        generated_at: new Date(hit.created_at).toISOString(),
        cached: true,
      });
    }

    await deps.charge(now);
    const raw = await deps.llm(config).complete({
      instructions: instructionsFor(kind),
      input: renderFacts(facts),
      schemaName: "flight_brief",
      schema: ANSWER_SCHEMA,
      maxOutputTokens: MAX_OUTPUT_TOKENS,
    });
    const checked = checkAnswer(raw, facts);
    if (!checked.ok) {
      console.error(`flight-brief answer dropped: ${checked.reason}`);
      throw llmUnavailable("No safe answer");
    }
    try {
      await deps.cache.put(subject, kind, hash, {
        text: checked.text,
        facts_used: checked.factsUsed,
      }, now);
    } catch (e) {
      // A failed write is logged, never a failed answer: the model call is already paid for.
      console.error("llm_brief_cache write failed", (e as Error).message);
    }
    return json({
      kind,
      subject,
      text: checked.text,
      facts_used: checked.factsUsed,
      generated_at: now.toISOString(),
      cached: false,
    });
  } catch (e) {
    return errorResponse(e);
  }
}
