import { serviceClient } from "../_shared/auth.ts";
import { AirhexLogoProvider } from "../_shared/brand/airhex.ts";
import type { LogoProvider } from "../_shared/brand/logo_provider.ts";
import { handler } from "./handler.ts";

const db = serviceClient();

/** Airhex only when LOGO_PROVIDER=airhex and AIRHEX_KEY is set: production stays a no-op until then. */
function provider(): LogoProvider | null {
  const key = Deno.env.get("AIRHEX_KEY");
  if (Deno.env.get("LOGO_PROVIDER") === "airhex" && key) {
    return new AirhexLogoProvider(key);
  }
  return null;
}

Deno.serve((req) => handler(req, { db, provider }));
