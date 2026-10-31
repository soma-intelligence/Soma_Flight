import { serviceClient } from "../_shared/auth.ts";
import { linqFromEnv } from "../_shared/linq.ts";
import { configFromEnv, handler } from "./handler.ts";

const db = serviceClient();
// Texts stay off until SMS_ALERTS_ENABLED is exactly "true"; without LINQ_API_KEY there is no sender.
Deno.serve((req) =>
  handler(req, {
    db,
    config: configFromEnv,
    sms: { db, sender: linqFromEnv() },
  })
);
