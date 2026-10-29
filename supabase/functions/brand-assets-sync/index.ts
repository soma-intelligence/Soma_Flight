import { serviceClient } from "../_shared/auth.ts";
import { AirhexLogoProvider } from "../_shared/brand/airhex.ts";
import {
  CommonsLogoProvider,
  DEFAULT_COMMONS_BASE,
} from "../_shared/brand/commons.ts";
import type { LogoProvider } from "../_shared/brand/logo_provider.ts";
import { handler } from "./handler.ts";

const db = serviceClient();

/**
 * Airhex only when LOGO_PROVIDER=airhex and AIRHEX_KEY is set: production stays a no-op until then.
 * LOGO_PROVIDER=commons loads the Wikimedia Commons library (local development), from
 * COMMONS_LOGO_BASE when set, else the repo copy.
 */
function provider(): LogoProvider | null {
  const choice = Deno.env.get("LOGO_PROVIDER");
  const key = Deno.env.get("AIRHEX_KEY");
  if (choice === "airhex" && key) {
    return new AirhexLogoProvider(key);
  }
  if (choice === "commons") {
    return new CommonsLogoProvider(
      Deno.env.get("COMMONS_LOGO_BASE") || DEFAULT_COMMONS_BASE,
    );
  }
  return null;
}

Deno.serve((req) => handler(req, { db, provider }));
