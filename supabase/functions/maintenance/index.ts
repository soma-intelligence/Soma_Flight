import { pushViaFunction } from "../aeroapi-webhook/handler.ts";
import { serviceClient } from "../_shared/auth.ts";
import type { AlertApi } from "../_shared/follow.ts";
import { productionAeroApi } from "../_shared/limits.ts";
import { ladder, paceCounter } from "../_shared/providers/poll.ts";
import { FREE_TIER, pollShare, quotaRule } from "../_shared/providers/quota.ts";
import { selectProviders } from "../_shared/providers/select.ts";
import { handler } from "./handler.ts";

const db = serviceClient();
let aero: AlertApi | undefined;
const env = (n: string) => Deno.env.get(n);
Deno.serve((req) =>
  handler(req, {
    db,
    aero: () => (aero ??= productionAeroApi(db)),
    // Built per run (cheap): the poller follows STATUS_PROVIDER and its quota secrets.
    poller: () => {
      const p = selectProviders(db, { forPoll: true });
      const name = p.names.status;
      const pace = name in FREE_TIER
        ? paceCounter(
          db,
          name,
          quotaRule(name as keyof typeof FREE_TIER, env),
          pollShare(env),
        )
        : () => Promise.resolve();
      return { name, status: p.status, pace, points: ladder(env) };
    },
    push: pushViaFunction(db),
  })
);
