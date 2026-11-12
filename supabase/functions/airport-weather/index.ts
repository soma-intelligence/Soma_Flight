import { serviceClient } from "../_shared/auth.ts";
import { withCors } from "../_shared/cors.ts";
import { feed } from "../faa-status/handler.ts";
import { handler, liveDeps } from "./handler.ts";

const db = serviceClient();
// The FAA programs come from faa-status's shared 5 minute cache of the NAS feed.
const deps = liveDeps(db, (now) => feed({ db }, now));
Deno.serve(withCors((req) => handler(req, deps)));
