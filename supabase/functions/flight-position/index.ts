import { serviceClient } from "../_shared/auth.ts";
import { selectProviders } from "../_shared/providers/select.ts";
import { withCors } from "../_shared/cors.ts";
import { handler } from "./handler.ts";

const db = serviceClient();
// POSITION_PROVIDER picks who answers (AeroAPI by default); built on the first call.
const { position } = selectProviders(db);
Deno.serve(withCors((req) => handler(req, { db, position })));
