import { serviceClient } from "../_shared/auth.ts";
import { selectProviders } from "../_shared/providers/select.ts";
import { handler } from "./handler.ts";

const db = serviceClient();
// STATUS_PROVIDER picks who answers (AeroAPI by default); built on the first call.
const { status } = selectProviders(db);
Deno.serve((req) => handler(req, { db, status }));
