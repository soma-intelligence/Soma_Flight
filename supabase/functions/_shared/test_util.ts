// Test helpers: a service client on the local Supabase stack and throwaway users.
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

let cached: { url: string; key: string; anon: string } | undefined;

async function localEnv(): Promise<{ url: string; key: string; anon: string }> {
  if (cached) return cached;
  let url = Deno.env.get("SUPABASE_URL");
  let key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  let anon = Deno.env.get("SUPABASE_ANON_KEY");
  if (!url || !key || !anon) {
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
    anon ??= get("ANON_KEY");
  }
  if (!url || !key || !anon) {
    throw new Error("local Supabase stack is not running");
  }
  return cached = { url, key, anon };
}

const Command = Deno.Command;

export async function testDb(): Promise<SupabaseClient> {
  const { url, key } = await localEnv();
  return createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

/** A client signed in as `userId` through the public API: what the app can do, RLS and grants included. */
export async function userClient(
  db: SupabaseClient,
  userId: string,
): Promise<SupabaseClient> {
  const { url, anon } = await localEnv();
  const got = await db.auth.admin.getUserById(userId);
  if (got.error) throw got.error;
  const password = crypto.randomUUID();
  const upd = await db.auth.admin.updateUserById(userId, { password });
  if (upd.error) throw upd.error;
  const client = createClient(url, anon, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const signIn = await client.auth.signInWithPassword({
    email: got.data.user!.email!,
    password,
  });
  if (signIn.error) throw signIn.error;
  return client;
}

/** Everything a test creates, removed by `cleanup` so the database ends as it began. */
const made = {
  users: [] as string[],
  flightIds: [] as string[],
  providerIds: new Set<string>(),
  airports: [] as string[],
  routes: [] as { origin: string; destination: string; date: string }[],
};

export function trackFlightId(id: string): void {
  made.flightIds.push(id);
}
export function trackProviderIds(ids: string[]): void {
  for (const id of ids) made.providerIds.add(id);
}
export function trackAirport(icao: string): void {
  made.airports.push(icao);
}
export function trackRoute(origin: string, destination: string, date: string) {
  made.routes.push({ origin, destination, date });
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
  made.users.push(id);
  if (plan === "pro") {
    const r = await db.from("profiles").update({ plan }).eq("user_id", id);
    if (r.error) throw r.error;
  }
  return id;
}

/** Deletes tracked rows: flights (cascades user_flights), route cache, rate events, profiles, users. */
export async function cleanup(db: SupabaseClient): Promise<void> {
  const users = made.users.splice(0);
  const flightIds = made.flightIds.splice(0);
  const providerIds = [...made.providerIds];
  made.providerIds.clear();
  const routes = made.routes.splice(0);
  const check = (r: { error: { message: string } | null }) => {
    if (r.error) throw new Error(`cleanup failed: ${r.error.message}`);
  };
  for (const r of routes) {
    check(
      await db.from("route_cache").delete().eq("origin_icao", r.origin)
        .eq("destination_icao", r.destination).eq("date", r.date),
    );
  }
  const airports = made.airports.splice(0);
  if (airports.length) {
    check(await db.from("airports").delete().in("icao", airports));
  }
  if (flightIds.length) {
    check(await db.from("flights").delete().in("id", flightIds));
  }
  if (providerIds.length) {
    check(await db.from("flights").delete().in("provider_id", providerIds));
  }
  if (users.length) {
    check(await db.from("rate_events").delete().in("user_id", users));
    check(await db.from("profiles").delete().in("user_id", users));
    for (const id of users) {
      const r = await db.auth.admin.deleteUser(id);
      // A test that deleted the account itself leaves nothing to remove.
      if (r.error && r.error.status !== 404) {
        throw new Error(`cleanup failed: ${r.error.message}`);
      }
    }
  }
}

/** Deno.test wrapper that always cleans up, pass or fail. */
export function test(
  db: SupabaseClient,
  name: string,
  fn: () => Promise<void>,
): void {
  Deno.test({
    name,
    sanitizeOps: false,
    sanitizeResources: false,
    fn: async () => {
      try {
        await fn();
      } finally {
        await cleanup(db);
      }
    },
  });
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

/**
 * Loads a function's index.ts the way the edge runtime does, with no AEROAPI_KEY and Deno.serve
 * captured, and returns the request handler it registered. Proves the function starts without the key.
 */
export async function loadIndexHandler(
  indexUrl: string,
): Promise<(req: Request) => Response | Promise<Response>> {
  const { url, key } = await localEnv();
  Deno.env.set("SUPABASE_URL", url);
  Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", key);
  Deno.env.delete("AEROAPI_KEY");
  const realServe = Deno.serve;
  let captured: ((req: Request) => Response | Promise<Response>) | undefined;
  // deno-lint-ignore no-explicit-any
  (Deno as any).serve = (h: (req: Request) => Response | Promise<Response>) => {
    captured = h;
    return { finished: Promise.resolve(), shutdown: () => Promise.resolve() };
  };
  try {
    await import(indexUrl);
  } finally {
    // deno-lint-ignore no-explicit-any
    (Deno as any).serve = realServe;
  }
  if (!captured) throw new Error(`${indexUrl} did not call Deno.serve`);
  return captured;
}
