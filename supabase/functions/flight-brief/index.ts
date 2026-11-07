import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { serviceClient } from "../_shared/auth.ts";
import { checkRate } from "../_shared/limits.ts";
import { AzureResponsesClient, chargeLlm, llmConfig } from "../_shared/llm.ts";
import { BRIEF_MAX_PER_HOUR, type BriefCache, handler } from "./handler.ts";

function dbCache(db: SupabaseClient): BriefCache {
  return {
    async get(subject, kind, hash) {
      const { data, error } = await db.from("llm_brief_cache").select(
        "text, facts_used, created_at",
      ).eq("subject", subject).eq("kind", kind).eq("facts_hash", hash)
        .maybeSingle();
      if (error) {
        throw new Error(`llm_brief_cache read failed: ${error.message}`);
      }
      return data
        ? {
          text: data.text as string,
          facts_used: data.facts_used as string[],
          created_at: data.created_at as string,
        }
        : null;
    },
    async put(subject, kind, hash, row, now) {
      const { error } = await db.from("llm_brief_cache").upsert({
        subject,
        kind,
        facts_hash: hash,
        text: row.text,
        facts_used: row.facts_used,
        created_at: now.toISOString(),
      });
      if (error) throw new Error(error.message);
    },
  };
}

// The service client is built on the first call, so the function boots and answers 503 llm_unavailable
// with no secrets at all while the feature is off.
let db: SupabaseClient | undefined;
const get = () => (db ??= serviceClient());

Deno.serve((req) =>
  handler(req, {
    config: () => llmConfig(),
    llm: (config) => new AzureResponsesClient(config),
    rate: (userId) =>
      checkRate(userId, "flight-brief", BRIEF_MAX_PER_HOUR, 60, get()),
    charge: (now) => chargeLlm(get(), "flight-brief", { now }),
    cache: {
      get: (s, k, h) => dbCache(get()).get(s, k, h),
      put: (s, k, h, r, n) => dbCache(get()).put(s, k, h, r, n),
    },
  })
);
