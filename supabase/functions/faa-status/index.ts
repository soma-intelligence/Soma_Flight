import { serviceClient } from "../_shared/auth.ts";
import { withCors } from "../_shared/cors.ts";
import { liveConditions } from "./conditions.ts";
import { handler } from "./handler.ts";

const db = serviceClient();
const conditions = liveConditions(db);
Deno.serve(withCors((req) => handler(req, { db, conditions })));
