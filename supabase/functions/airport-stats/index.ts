import { airportRows } from "../_shared/airport_codes.ts";
import { serviceClient } from "../_shared/auth.ts";
import type { BoardRow } from "../_shared/board_rows.ts";
import { checkRate } from "../_shared/limits.ts";
import { chosen, selectProviders } from "../_shared/providers/select.ts";
import { refreshBoard, serve } from "../airport-board/handler.ts";
import { handler, STATS_MAX_PER_HOUR } from "./handler.ts";

const db = serviceClient();
// BOARD_PROVIDER picks who answers; "none" answers available: false without any call.
const provider = chosen("board", (n) => Deno.env.get(n));
const { board } = selectProviders(db);
const boardDeps = { db, board };

Deno.serve((req) =>
  handler(req, {
    provider,
    airports: (codes) => airportRows(db, codes),
    rate: (userId) =>
      checkRate(userId, "airport-stats", STATS_MAX_PER_HOUR, 60, db),
    // The same snapshots, lease and TTL as airport-board: one provider call per airport and
    // direction every 5 minutes, whoever asks.
    board: async (icao, kind, now) => {
      const s = await serve(
        boardDeps,
        icao,
        kind,
        now,
        () => refreshBoard(boardDeps, icao, kind, now),
      );
      return {
        flights: (s.payload as { flights: BoardRow[] }).flights,
        fetchedAt: s.fetchedAt,
        stale: s.stale,
      };
    },
  })
);
