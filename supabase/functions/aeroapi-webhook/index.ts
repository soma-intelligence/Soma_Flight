import { serviceClient } from "../_shared/auth.ts";
import { handler, pushViaFunction } from "./handler.ts";

const db = serviceClient();
Deno.serve((req) =>
  handler(req, {
    db,
    secret: () => Deno.env.get("WEBHOOK_SECRET"),
    previousSecret: () => Deno.env.get("WEBHOOK_SECRET_PREVIOUS"),
    push: pushViaFunction(db),
  })
);
