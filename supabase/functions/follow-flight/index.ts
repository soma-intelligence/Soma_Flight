import { serviceClient } from "../_shared/auth.ts";
import { lazyAeroApi } from "../_shared/limits.ts";
import { selectProviders } from "../_shared/providers/select.ts";
import { handler } from "./handler.ts";

const db = serviceClient();
// AeroAPI alerts only when AeroAPI is the status provider; the others are polled (maintenance).
const aero = selectProviders(db).names.status === "aeroapi"
  ? lazyAeroApi(db) // built on the first AeroAPI call
  : null;
Deno.serve((req) => handler(req, { db, aero }));
