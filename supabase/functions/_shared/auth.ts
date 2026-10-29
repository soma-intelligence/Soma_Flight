// Auth helpers: caller identity from the bearer token, and a service role client.
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import { ApiError } from "./errors.ts";

function env(name: string): string {
  const v = Deno.env.get(name);
  if (!v) throw new Error(`missing env ${name}`);
  return v;
}

/** Service role client. Bypasses RLS: use only for shared data and counters. */
export function serviceClient(): SupabaseClient {
  return createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

/** Validates the bearer token against Supabase Auth. Throws unauthorized. */
export async function requireUser(req: Request): Promise<{ userId: string }> {
  const header = req.headers.get("authorization") ?? "";
  const match = /^Bearer\s+(.+)$/i.exec(header);
  if (!match) throw new ApiError("unauthorized", 401, "Missing bearer token");
  const { data, error } = await serviceClient().auth.getUser(match[1]);
  if (error || !data.user) {
    throw new ApiError("unauthorized", 401, "Invalid token");
  }
  return { userId: data.user.id };
}
