import { serviceClient } from "../_shared/auth.ts";
import { handler } from "./handler.ts";

const db = serviceClient();
const base = Deno.env.get("SHARE_BASE_URL");
const appUrl = Deno.env.get("GET_APP_URL");
const publicUrl = Deno.env.get("PUBLIC_SUPABASE_URL") ??
  Deno.env.get("SUPABASE_URL");
Deno.serve((req) => handler(req, { db, base, appUrl, publicUrl }));
