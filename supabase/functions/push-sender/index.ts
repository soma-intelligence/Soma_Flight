import { serviceClient } from "../_shared/auth.ts";
import { configFromEnv, handler } from "./handler.ts";

const db = serviceClient();
Deno.serve((req) => handler(req, { db, config: configFromEnv }));
