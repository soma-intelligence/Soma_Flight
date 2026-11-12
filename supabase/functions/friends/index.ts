import { serviceClient } from "../_shared/auth.ts";
import { withCors } from "../_shared/cors.ts";
import { handler } from "./handler.ts";

const db = serviceClient();
const base = Deno.env.get("INVITE_BASE_URL");
Deno.serve(withCors((req) => handler(req, { db, base })));
