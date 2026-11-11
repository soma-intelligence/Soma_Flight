import { serviceClient } from "../_shared/auth.ts";
import { withCors } from "../_shared/cors.ts";
import { checkRate } from "../_shared/limits.ts";
import { handler } from "./handler.ts";

const keyId = Deno.env.get("MAPKIT_KEY_ID");
const teamId = Deno.env.get("MAPKIT_TEAM_ID");
// Secrets store the PEM with literal \n sequences on one line.
const privateKey = Deno.env.get("MAPKIT_PRIVATE_KEY")?.replace(/\\n/g, "\n");
// Without all three the function answers 503 provider_unavailable.
const secrets = keyId && teamId && privateKey
  ? { keyId, teamId, privateKey }
  : null;

const db = serviceClient();
Deno.serve(withCors((req) =>
  handler(req, {
    verify: db,
    rate: checkRate,
    now: () => new Date(),
    secrets,
  })
));
