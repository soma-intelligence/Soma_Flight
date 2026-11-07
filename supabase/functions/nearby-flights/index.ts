import { serviceClient } from "../_shared/auth.ts";
import { lazyAeroApi } from "../_shared/limits.ts";
import { dbCache, handler } from "./handler.ts";

const db = serviceClient();
const aero = lazyAeroApi(db); // built on the first AeroAPI call
const cache = dbCache(db);
Deno.serve((req) =>
  handler(req, {
    db,
    aero,
    cache,
    enabled: () => Deno.env.get("RADAR_ENABLED") === "true",
    hasKey: () => !!Deno.env.get("AEROAPI_KEY"),
  })
);
