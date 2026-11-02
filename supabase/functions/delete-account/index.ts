import { appleConfigFromEnv, appleRevoker } from "../_shared/apple.ts";
import { serviceClient } from "../_shared/auth.ts";
import { lazyAeroApi } from "../_shared/limits.ts";
import { handler } from "./handler.ts";

const db = serviceClient();
const aero = lazyAeroApi(db); // built on the first AeroAPI call
const appleConfig = appleConfigFromEnv();
const apple = appleConfig ? appleRevoker(appleConfig) : null;
Deno.serve((req) => handler(req, { db, aero, apple }));
