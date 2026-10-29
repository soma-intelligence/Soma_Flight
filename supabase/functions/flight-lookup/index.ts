import { serviceClient } from "../_shared/auth.ts";
import { productionAeroApi } from "../_shared/limits.ts";
import { handler } from "./handler.ts";

const db = serviceClient();
const aero = productionAeroApi(db);
Deno.serve((req) => handler(req, { db, aero }));
