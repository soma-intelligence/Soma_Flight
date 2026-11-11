import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { readConfig, type Config } from "@/app/config";

/**
 * The URL the client talks to. In development, VITE_SUPABASE_PROXY=1 sends it
 * through the same-origin `/sb` Vite proxy; production always uses the config.
 */
export function clientUrl(
  cfg: Config,
  env: Record<string, string | undefined>,
  origin: string,
  dev: boolean,
): string {
  return dev && env.VITE_SUPABASE_PROXY === "1" ? `${origin}/sb` : cfg.url;
}

let client: SupabaseClient | null = null;

/** The one Supabase client, created on first use. Throws when no server is configured. */
export function getSupabase(): SupabaseClient {
  if (client) return client;
  const env = import.meta.env as Record<string, string | undefined>;
  const cfg = readConfig(env, import.meta.env.PROD);
  if (!cfg) throw new Error("No server configured");
  client = createClient(clientUrl(cfg, env, window.location.origin, import.meta.env.DEV), cfg.key, {
    auth: { flowType: "pkce", persistSession: true, storage: localStorage },
  });
  return client;
}
