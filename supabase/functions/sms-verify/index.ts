import { serviceClient } from "../_shared/auth.ts";
import { linqFromEnv } from "../_shared/linq.ts";
import { handler } from "./handler.ts";

const db = serviceClient();
// No LINQ_API_KEY: no sender, so start answers 503 and nothing is sent.
Deno.serve((req) => handler(req, { db, sender: linqFromEnv() }));
