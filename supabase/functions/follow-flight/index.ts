import { serviceClient } from "../_shared/auth.ts";
import { lazyAeroApi } from "../_shared/limits.ts";
import { handler } from "./handler.ts";

const db = serviceClient();
const aero = lazyAeroApi(db); // built on the first AeroAPI call
Deno.serve((req) => handler(req, { db, aero }));
