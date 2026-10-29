// Auth helpers: caller identity from the bearer token, and a service role client.
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import { ApiError } from "./errors.ts";
import { safeEqual } from "./apns.ts";

function env(name: string): string {
  const v = Deno.env.get(name);
  if (!v) throw new Error(`missing env ${name}`);
  return v;
}

let shared: SupabaseClient | undefined;

/** Service role client, created once per isolate. Bypasses RLS: shared data and counters only. */
export function serviceClient(): SupabaseClient {
  shared ??= createClient(
    env("SUPABASE_URL"),
    env("SUPABASE_SERVICE_ROLE_KEY"),
    {
      auth: { persistSession: false, autoRefreshToken: false },
    },
  );
  return shared;
}

/** The slice of the Supabase client that requireUser uses. */
export interface TokenVerifier {
  auth: {
    getUser(
      jwt: string,
    ): Promise<{ data: { user: { id: string } | null }; error: unknown }>;
  };
}

/** Validates the bearer token against Supabase Auth. Throws unauthorized. */
export async function requireUser(
  req: Request,
  client?: TokenVerifier,
): Promise<{ userId: string }> {
  const header = req.headers.get("authorization") ?? "";
  const match = /^Bearer\s+(.+)$/i.exec(header);
  if (!match) throw new ApiError("unauthorized", 401, "Missing bearer token");
  const { data, error } = await (client ?? serviceClient()).auth.getUser(
    match[1],
  );
  if (error || !data.user) {
    throw new ApiError("unauthorized", 401, "Invalid token");
  }
  return { userId: data.user.id };
}

/**
 * Service role check for internal functions (push-sender, maintenance, usage-alert). Two layers:
 * the bearer token must equal `key` (constant time), and when it is a JWT its `role` claim must
 * be service_role. The gateway's verify_jwt is a third.
 */
export async function isServiceCaller(
  req: Request,
  key: string | undefined,
): Promise<boolean> {
  const bearer = /^Bearer\s+(\S+)$/i.exec(
    req.headers.get("authorization") ?? "",
  )?.[1];
  if (!key || !bearer || !(await safeEqual(bearer, key))) return false;
  const parts = bearer.split(".");
  if (parts.length !== 3) return true; // opaque secret key (sb_secret_...), no claims to read
  try {
    const b64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const claims = JSON.parse(
      atob(b64.padEnd(Math.ceil(b64.length / 4) * 4, "=")),
    );
    return claims?.role === "service_role";
  } catch {
    return false;
  }
}
