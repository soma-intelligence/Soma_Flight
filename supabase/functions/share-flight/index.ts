import { serviceClient } from "../_shared/auth.ts";
import { handler } from "./handler.ts";

const db = serviceClient();
const base = Deno.env.get("SHARE_BASE_URL");
Deno.serve((req) => handler(req, { db, base }));
