import { serviceClient } from "../_shared/auth.ts";
import { liveConditions } from "./conditions.ts";
import { handler } from "./handler.ts";

const db = serviceClient();
const conditions = liveConditions(db);
Deno.serve((req) => handler(req, { db, conditions }));
