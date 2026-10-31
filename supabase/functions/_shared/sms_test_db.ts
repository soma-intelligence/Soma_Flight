// Test helper: an in-memory stand-in for the slice of the Supabase client the text message code uses
// (from, select, insert, upsert, update, delete, eq, in, is, or, maybeSingle, rpc), so the SMS rules are
// tested without the local stack. Not a PostgREST emulator: just enough for those calls.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";

type Row = Record<string, unknown>;
type Filter = (r: Row) => boolean;
export type RpcHandler = (args: Record<string, unknown>) => unknown;

export interface FakeDb {
  client: SupabaseClient;
  tables: Map<string, Row[]>;
  /** Every table read or written, in order. */
  touched: string[];
  rpcs: { name: string; args: Record<string, unknown> }[];
}

/** One `or(...)` expression: "a.eq.true,b.eq.true". */
function orFilter(expr: string): Filter {
  const parts = expr.split(",").map((p) => p.split("."));
  return (r) =>
    parts.some(([col, op, val]) => op === "eq" && String(r[col]) === val);
}

export function fakeDb(
  seed: Record<string, Row[]> = {},
  rpc: Record<string, RpcHandler> = {},
): FakeDb {
  const tables = new Map<string, Row[]>(
    Object.entries(seed).map(([k, v]) => [k, v.map((r) => ({ ...r }))]),
  );
  const touched: string[] = [];
  const rpcs: { name: string; args: Record<string, unknown> }[] = [];
  const table = (name: string) => {
    if (!tables.has(name)) tables.set(name, []);
    return tables.get(name)!;
  };

  function builder(name: string) {
    touched.push(name);
    const filters: Filter[] = [];
    let op: "select" | "update" | "delete" | "insert" | "upsert" = "select";
    let payload: Row | Row[] | undefined;
    let conflict: string[] = [];
    let ignoreDuplicates = false;
    const run = (): { data: unknown; error: null | { message: string } } => {
      const rows = table(name);
      const match = (r: Row) => filters.every((f) => f(r));
      switch (op) {
        case "select":
          return {
            data: rows.filter(match).map((r) => ({ ...r })),
            error: null,
          };
        case "update": {
          const hit = rows.filter(match);
          for (const r of hit) Object.assign(r, payload as Row);
          return { data: hit.map((r) => ({ ...r })), error: null };
        }
        case "delete": {
          const keep = rows.filter((r) => !match(r));
          const gone = rows.filter(match);
          tables.set(name, keep);
          return { data: gone, error: null };
        }
        case "insert":
        case "upsert": {
          const list = Array.isArray(payload) ? payload : [payload as Row];
          const out: Row[] = [];
          for (const p of list) {
            const same = conflict.length > 0
              ? rows.find((r) => conflict.every((c) => r[c] === p[c]))
              : undefined;
            if (same) {
              if (op === "insert") {
                return { data: null, error: { message: "duplicate key" } };
              }
              if (!ignoreDuplicates) Object.assign(same, p);
              continue;
            }
            const r = { ...p };
            rows.push(r);
            out.push(r);
          }
          return { data: out, error: null };
        }
      }
    };
    const q = {
      select(_cols?: string) {
        return q;
      },
      insert(rows: Row | Row[]) {
        op = "insert";
        payload = rows;
        return q;
      },
      upsert(
        rows: Row | Row[],
        opts: { onConflict?: string; ignoreDuplicates?: boolean } = {},
      ) {
        op = "upsert";
        payload = rows;
        conflict = (opts.onConflict ?? "").split(",").filter(Boolean);
        ignoreDuplicates = opts.ignoreDuplicates ?? false;
        return q;
      },
      update(patch: Row) {
        op = "update";
        payload = patch;
        return q;
      },
      delete() {
        op = "delete";
        return q;
      },
      eq(col: string, v: unknown) {
        filters.push((r) => r[col] === v);
        return q;
      },
      is(col: string, v: unknown) {
        filters.push((r) => (r[col] ?? null) === v);
        return q;
      },
      not(col: string, op: string, v: unknown) {
        if (op !== "is") throw new Error(`fake not.${op} unsupported`);
        filters.push((r) => (r[col] ?? null) !== v);
        return q;
      },
      in(col: string, vs: unknown[]) {
        filters.push((r) => vs.includes(r[col]));
        return q;
      },
      or(expr: string) {
        filters.push(orFilter(expr));
        return q;
      },
      maybeSingle() {
        const r = run();
        const list = (r.data ?? []) as Row[];
        return Promise.resolve({ data: list[0] ?? null, error: r.error });
      },
      single() {
        return q.maybeSingle();
      },
      then<T>(
        ok: (v: { data: unknown; error: null | { message: string } }) => T,
        bad?: (e: unknown) => T,
      ) {
        return Promise.resolve(run()).then(ok, bad);
      },
    };
    return q;
  }

  const client = {
    from: (name: string) => builder(name),
    rpc: (name: string, args: Record<string, unknown>) => {
      rpcs.push({ name, args });
      const h = rpc[name];
      if (!h) {
        return Promise.resolve({
          data: null,
          error: { message: `no rpc ${name}` },
        });
      }
      return Promise.resolve({ data: h(args), error: null });
    },
  } as unknown as SupabaseClient;
  return { client, tables, touched, rpcs };
}

/** claim_sms over an in-memory log: true once per user, flight and key. */
export function claimOnce(): RpcHandler {
  const seen = new Set<string>();
  return (a) => {
    const k = `${a.p_user}|${a.p_flight}|${a.p_key}`;
    if (seen.has(k)) return false;
    seen.add(k);
    return true;
  };
}
