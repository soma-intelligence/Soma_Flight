// Test helpers: a service client on the local Supabase stack and throwaway users.
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

let cached: { url: string; key: string } | undefined;

async function localEnv(): Promise<{ url: string; key: string }> {
  if (cached) return cached;
  let url = Deno.env.get("SUPABASE_URL");
  let key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) {
    const out = await new Command("npx", {
      args: ["supabase", "status", "-o", "env"],
      stdout: "piped",
      stderr: "null",
    }).output();
    const text = new TextDecoder().decode(out.stdout);
    const get = (n: string) =>
      new RegExp(`^${n}="?([^"\\n]+)"?$`, "m").exec(text)?.[1];
    url ??= get("API_URL");
    key ??= get("SERVICE_ROLE_KEY");
  }
  if (!url || !key) throw new Error("local Supabase stack is not running");
  return cached = { url, key };
}

const Command = Deno.Command;

export async function testDb(): Promise<SupabaseClient> {
  const { url, key } = await localEnv();
  return createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

export async function makeUser(
  db: SupabaseClient,
  plan: "free" | "pro" = "free",
): Promise<string> {
  const { data, error } = await db.auth.admin.createUser({
    email: `t-${crypto.randomUUID()}@test.local`,
    email_confirm: true,
  });
  if (error) throw error;
  const id = data.user.id;
  if (plan === "pro") {
    const r = await db.from("profiles").update({ plan }).eq("user_id", id);
    if (r.error) throw r.error;
  }
  return id;
}

/** Token verifier for tests: the bearer token is the user id. */
export const fakeVerifier = {
  auth: {
    getUser(jwt: string) {
      return Promise.resolve(
        jwt === "bad"
          ? { data: { user: null }, error: { message: "bad" } }
          : { data: { user: { id: jwt } }, error: null },
      );
    },
  },
};
