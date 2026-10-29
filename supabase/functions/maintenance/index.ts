import { serviceClient } from "../_shared/auth.ts";
import type { AlertApi } from "../_shared/follow.ts";
import { productionAeroApi } from "../_shared/limits.ts";
import { handler } from "./handler.ts";

const db = serviceClient();
let aero: AlertApi | undefined;
Deno.serve((req) =>
  handler(req, { db, aero: () => (aero ??= productionAeroApi(db)) })
);
