// Logo and brand colour sync. One call handles up to `limit` airlines that were never checked or
// were last checked over 7 days ago, oldest first, so hourly batches of 50 cover 2,050 airlines in
// about two days and every airline again each week.
//
// Rules, in the order they matter:
// - Every file passes validateFile before upload. SVG is never stored: it is rasterised to PNG
//   (384 px stored, 192 px small). An invalid file counts as a miss: nothing stored, the row stays.
// - Unchanged files are not downloaded: the stored etag or version goes to the provider, which
//   answers "unchanged"; only checked_at moves.
// - A provider outage (5xx, 429, network) is retried with backoff, then aborts the run without
//   stamping anyone; the next hourly tick retries. Bad data for one airline only fails that airline.
// - A run has a time budget and a request budget; what is left is reported as `deferred`.
// - A miss (the provider has no such file) is remembered for a day per airline and kind, and a row
//   the same provider no longer offers is dropped.
// - Precedence: a row from a higher-ranked provider is never replaced by a lower one (PROVIDER_RANKS).
// - A new version is a new object; the old one is removed after the row points at the new one.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import {
  type AssetKind,
  contentVersion,
  dbKind,
  type LogoProvider,
  PROVIDER_RANKS,
  providerRank,
  ProviderUnavailable,
  redact,
} from "./logo_provider.ts";
import type { SideViewProvider } from "./side_view_provider.ts";
import { mirrorPng, SIDE_VIEW_RULE, validateFile } from "./validate.ts";

export const BUCKET = "brand-assets";
export const RECHECK_DAYS = 7;
export const MISS_HOURS = 24;
export const DEFAULT_BUDGET_MS = 100_000;
export const DEFAULT_MAX_REQUESTS = 400;
/** Backoff before the 2nd and 3rd attempt of a call that hit an outage. */
export const BACKOFF_MS = [1000, 2000];
/** Colour for a provider airline we have nothing better for yet; replaced by the provider's own. */
const PLACEHOLDER_PRIMARY = "#6B7280";
const DAY_MS = 86_400_000;

export type StoppedBy = "done" | "deadline" | "budget" | "provider_unavailable";

export interface SyncReport {
  /** Airlines fully processed in this run (a failed one counts, an aborted one does not). */
  checked: number;
  /** Objects uploaded (new or changed). */
  changed: number;
  added: number;
  failed: number;
  /** Answered "unchanged" without a download. */
  unchanged: number;
  /** Provider had no file (or a rejected one) for a kind. */
  missed: number;
  /** Skipped because a miss was remembered, or a higher-ranked provider owns the row. */
  skipped: number;
  /** Files refused by validation. */
  rejected: number;
  /** Rows dropped because the provider stopped offering the kind. */
  dropped: number;
  /** Due airlines left for the next tick. */
  deferred: number;
  requests: number;
  ms: number;
  stoppedBy: StoppedBy;
}

export interface SyncOpts {
  limit: number;
  now: Date;
  /** Restrict the queue to these airlines (a manual resync of a few). Due-ness still applies. */
  icaos?: string[];
  budgetMs?: number;
  maxRequests?: number;
  /** Test hooks. */
  clock?: () => number;
  sleep?: (ms: number) => Promise<void>;
}

class Stop extends Error {
  constructor(readonly why: StoppedBy) {
    super(why);
  }
}

interface CallEnv {
  clock: () => number;
  sleep: (ms: number) => Promise<void>;
  startedAt: number;
  budgetMs: number;
  maxRequests: number;
}

/** One provider call: budgeted, retried with backoff on outages, aborting when they persist. */
function makeCall(report: SyncReport, env: CallEnv) {
  return async function call<T>(fn: () => Promise<T>): Promise<T> {
    for (let attempt = 0;; attempt++) {
      if (env.clock() - env.startedAt > env.budgetMs) {
        throw new Stop("deadline");
      }
      if (report.requests >= env.maxRequests) throw new Stop("budget");
      report.requests++;
      try {
        return await fn();
      } catch (e) {
        if (!(e instanceof ProviderUnavailable)) throw e;
        if (attempt >= BACKOFF_MS.length) {
          console.error(
            `brand sync: provider down, aborting: ${redact(e.message)}`,
          );
          throw new Stop("provider_unavailable");
        }
        await env.sleep(BACKOFF_MS[attempt]);
      }
    }
  };
}

function emptyReport(): SyncReport {
  return {
    checked: 0,
    changed: 0,
    added: 0,
    failed: 0,
    unchanged: 0,
    missed: 0,
    skipped: 0,
    rejected: 0,
    dropped: 0,
    deferred: 0,
    requests: 0,
    ms: 0,
    stoppedBy: "done",
  };
}

function must<T extends { error: { message: string } | null }>(
  r: T,
  what: string,
): T {
  if (r.error) throw new Error(`${what}: ${r.error.message}`);
  return r;
}

async function addMissingAirlines(
  db: SupabaseClient,
  provider: LogoProvider,
): Promise<number> {
  const listed = (await provider.list()).filter((a) =>
    /^[A-Z]{3}$/.test(a.icao) && a.name
  );
  if (listed.length === 0) return 0;
  const known = new Set<string>();
  for (let from = 0;; from += 1000) {
    const r = must(
      await db.from("airlines").select("icao").order("icao").range(
        from,
        from + 999,
      ),
      "airline read failed",
    );
    for (const row of r.data ?? []) known.add(row.icao);
    if ((r.data?.length ?? 0) < 1000) break;
  }
  const fresh = listed.filter((a) => !known.has(a.icao)).map((a) => ({
    icao: a.icao,
    iata: a.iata && /^[A-Z0-9]{2}$/.test(a.iata) ? a.iata : null,
    name: a.name,
    color_primary: PLACEHOLDER_PRIMARY,
    colors_source: "seed",
  }));
  if (fresh.length === 0) return 0;
  must(
    await db.from("airlines").upsert(fresh, {
      onConflict: "icao",
      ignoreDuplicates: true,
    }),
    "airline insert failed",
  );
  return fresh.length;
}

interface AssetRow {
  kind: string;
  aircraft_type: string;
  path: string;
  path_small: string | null;
  format: string;
  version: string;
  etag: string | null;
  provider: string;
}

interface Item {
  kind: AssetKind;
  type: string; // aircraft type for side views, else ""
}

export function assetPath(
  icao: string,
  item: Item,
  version: string,
  ext: string,
  small = false,
): string {
  const tail = `${version}${small ? "-small" : ""}.${ext}`;
  return item.kind === "side_view"
    ? `side-views/${icao}/${item.type}-${tail}`
    : `logos/${icao}/${dbKind(item.kind)}-${tail}`;
}

const paths = (r: { path: string; path_small: string | null }) =>
  r.path_small ? [r.path, r.path_small] : [r.path];

export async function syncLogos(
  db: SupabaseClient,
  storage: SupabaseClient["storage"],
  provider: LogoProvider,
  opts: SyncOpts,
): Promise<SyncReport> {
  const clock = opts.clock ?? Date.now;
  const sleep = opts.sleep ??
    ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)));
  const startedAt = clock();
  const budgetMs = opts.budgetMs ?? DEFAULT_BUDGET_MS;
  const maxRequests = opts.maxRequests ?? DEFAULT_MAX_REQUESTS;
  const stamp = opts.now.toISOString();
  const report: SyncReport = emptyReport();

  const call = makeCall(report, {
    clock,
    sleep,
    startedAt,
    budgetMs,
    maxRequests,
  });

  async function dropRow(icao: string, row: AssetRow): Promise<void> {
    must(
      await db.from("airline_assets").delete().eq("icao", icao).eq(
        "kind",
        row.kind,
      ).eq("aircraft_type", row.aircraft_type),
      "asset delete failed",
    );
    const rm = await storage.from(BUCKET).remove(paths(row));
    if (rm.error) console.error(`brand sync: object kept ${row.path}`);
  }

  async function remember(icao: string, item: Item): Promise<void> {
    must(
      await db.from("airline_asset_misses").upsert({
        icao,
        kind: dbKind(item.kind),
        aircraft_type: item.type,
        provider: provider.name,
        miss_until: new Date(opts.now.getTime() + MISS_HOURS * 3_600_000)
          .toISOString(),
      }, { onConflict: "icao,kind,aircraft_type,provider" }),
      "miss write failed",
    );
  }

  async function doItem(
    icao: string,
    item: Item,
    rows: AssetRow[],
    misses: Set<string>,
  ): Promise<void> {
    const k = dbKind(item.kind);
    const row = rows.find((r) => r.kind === k && r.aircraft_type === item.type);
    const mine = row?.provider === provider.name;
    if (row && !mine && providerRank(row.provider) >= provider.rank) {
      report.skipped++; // a provider of equal or higher rank owns it
      return;
    }
    if (misses.has(`${k}/${item.type}/${provider.name}`)) {
      report.skipped++; // remembered miss, still fresh
      return;
    }
    const got = await call(() =>
      provider.logo(icao, item.kind, {
        aircraftType: item.type || undefined,
        known: mine
          ? { etag: row!.etag, version: row!.version, format: row!.format }
          : undefined,
      })
    );
    if (got === "unchanged") {
      report.unchanged++;
      must(
        await db.from("airline_assets").update({ checked_at: stamp }).eq(
          "icao",
          icao,
        ).eq("kind", k).eq("aircraft_type", item.type),
        "asset bump failed",
      );
      return;
    }
    if (got === null) {
      report.missed++;
      await remember(icao, item);
      if (mine) {
        await dropRow(icao, row!);
        report.dropped++;
      }
      return;
    }
    const v = await validateFile(got);
    if (!v.ok) {
      console.error(`brand sync: ${icao} ${item.kind} rejected: ${v.reason}`);
      report.rejected++;
      report.missed++;
      await remember(icao, item);
      return; // an existing row stays
    }
    const same = mine &&
      (got.etag !== null && row!.etag !== null
        ? got.etag === row!.etag
        : got.version === row!.version);
    if (same) {
      report.unchanged++;
      must(
        await db.from("airline_assets").update({ checked_at: stamp }).eq(
          "icao",
          icao,
        ).eq("kind", k).eq("aircraft_type", item.type),
        "asset bump failed",
      );
      return;
    }
    const path = assetPath(icao, item, got.version, v.format);
    const pathSmall = v.small
      ? assetPath(icao, item, got.version, v.format, true)
      : null;
    must(
      await storage.from(BUCKET).upload(path, v.main.bytes, {
        contentType: v.mime,
        upsert: true,
      }),
      "upload failed",
    );
    if (pathSmall && v.small) {
      must(
        await storage.from(BUCKET).upload(pathSmall, v.small.bytes, {
          contentType: v.mime,
          upsert: true,
        }),
        "small upload failed",
      );
    }
    must(
      await db.from("airline_assets").upsert({
        icao,
        kind: k,
        aircraft_type: item.type,
        path,
        path_small: pathSmall,
        format: v.format,
        width: v.main.width,
        version: got.version,
        etag: got.etag,
        provider: provider.name,
        fetched_at: stamp,
        checked_at: stamp,
      }, { onConflict: "icao,kind,aircraft_type" }),
      "asset upsert failed",
    );
    report.changed++;
    if (row) {
      const keep = new Set([path, ...(pathSmall ? [pathSmall] : [])]);
      const old = paths(row).filter((p) => !keep.has(p));
      if (old.length) {
        const rm = await storage.from(BUCKET).remove(old);
        if (rm.error) console.error(`brand sync: old object kept ${row.path}`);
      }
    }
    if (misses.has(`${k}/${item.type}/${provider.name}`)) {
      await db.from("airline_asset_misses").delete().eq("icao", icao).eq(
        "kind",
        k,
      ).eq("aircraft_type", item.type).eq("provider", provider.name);
    }
  }

  async function doAirline(icao: string): Promise<void> {
    const rows = (must(
      await db.from("airline_assets").select(
        "kind, aircraft_type, path, path_small, format, version, etag, provider",
      ).eq("icao", icao),
      "asset read failed",
    ).data ?? []) as AssetRow[];
    const missRows = must(
      await db.from("airline_asset_misses").select(
        "kind, aircraft_type, provider",
      ).eq("icao", icao).gt("miss_until", stamp),
      "miss read failed",
    ).data ?? [];
    const misses = new Set<string>(
      missRows.map((
        m: { kind: string; aircraft_type: string; provider: string },
      ) => `${m.kind}/${m.aircraft_type}/${m.provider}`),
    );
    const items: Item[] = [];
    for (const kind of provider.kinds) {
      if (kind === "side_view") continue;
      items.push({ kind, type: "" });
    }
    if (provider.kinds.includes("side_view") && provider.sideViewTypes) {
      const types = await call(() => provider.sideViewTypes!(icao));
      for (const type of types) items.push({ kind: "side_view", type });
      // A side view this provider wrote and no longer lists is stale.
      for (
        const r of rows.filter((r) =>
          r.kind === "side_view" && r.provider === provider.name &&
          !types.includes(r.aircraft_type)
        )
      ) {
        await dropRow(icao, r);
        report.dropped++;
      }
    }
    for (const item of items) await doItem(icao, item, rows, misses);
    if (provider.hasColors) {
      const c = await call(() => provider.colors(icao));
      if (c) {
        // Never over a livery seed ('locked'), never over a higher-ranked provider's colours.
        const higher = Object.entries(PROVIDER_RANKS).filter(([, r]) =>
          r > provider.rank
        ).map(([n]) => n);
        let q = db.from("airlines").update({
          color_primary: c.primary,
          color_secondary: c.secondary,
          colors_source: provider.name,
          colors_updated_at: stamp,
        }).eq("icao", icao).neq("colors_source", "locked");
        if (higher.length) {
          q = q.not("colors_source", "in", `(${higher.join(",")})`);
        }
        must(await q, "colour update failed");
      }
    }
    must(
      await db.from("airlines").update({ logo_checked_at: stamp }).eq(
        "icao",
        icao,
      ),
      "mark failed",
    );
  }

  try {
    report.added = await call(() => addMissingAirlines(db, provider));
    const cutoff = new Date(opts.now.getTime() - RECHECK_DAYS * DAY_MS)
      .toISOString();
    let queue = db.from("airlines").select("icao")
      .or(`logo_checked_at.is.null,logo_checked_at.lt.${cutoff}`);
    if (opts.icaos) queue = queue.in("icao", opts.icaos);
    const due = (must(
      await queue
        .order("logo_checked_at", { ascending: true, nullsFirst: true })
        .order("icao").limit(opts.limit),
      "queue read failed",
    ).data ?? []) as { icao: string }[];

    let i = 0;
    try {
      for (; i < due.length; i++) {
        const { icao } = due[i];
        try {
          await doAirline(icao);
          report.checked++;
        } catch (e) {
          if (e instanceof Stop) throw e;
          report.checked++;
          report.failed++;
          console.error(
            `brand sync: ${icao} failed`,
            redact((e as Error).message),
          );
          // Retry in about a day instead of at the head of every hour's queue.
          try {
            must(
              await db.from("airlines").update({
                logo_checked_at: new Date(
                  opts.now.getTime() - (RECHECK_DAYS - 1) * DAY_MS,
                ).toISOString(),
              }).eq("icao", icao),
              "stamp-back failed",
            );
          } catch (e2) {
            console.error(
              `brand sync: ${icao} not deferred`,
              (e2 as Error).message,
            );
          }
        }
      }
    } catch (e) {
      if (!(e instanceof Stop)) throw e;
      report.stoppedBy = e.why;
      report.deferred = due.length - i;
    }
  } catch (e) {
    if (!(e instanceof Stop)) throw e;
    report.stoppedBy = e.why;
  }
  report.ms = clock() - startedAt;
  return report;
}

export interface SideViewReport extends SyncReport {
  /** Pairs skipped because the airline is not in `airlines`. */
  unknownAirlines: number;
  /** Pairs uploaded after flipping a nose-right drawing. */
  mirrored: number;
}

interface SideRow {
  aircraft_type: string;
  icao: string;
  path: string;
  version: string;
  provider: string;
  note: string | null;
}

const chunks = <T>(a: T[], n: number): T[][] =>
  Array.from(
    { length: Math.ceil(a.length / n) },
    (_, i) => a.slice(i * n, i * n + n),
  );

/**
 * Side view sync. The provider lists airline and aircraft type pairs with a version; a pair is
 * fetched when it has no row, its version or nose changed, or a lower-ranked provider owns the row.
 * Same rules as syncLogos: the validation gate (PNG only, at least 1200 px wide; vectors are
 * rendered 1600 px wide), outage abort, time and request budgets, remembered misses, rank precedence,
 * new version = new object. `limit` caps the files fetched in one run (unchanged pairs cost nothing).
 * Pairs for airlines missing from `airlines` are skipped and counted, never inserted. A nose-right
 * drawing is mirrored before upload and the row notes `mirrored`.
 */
export async function syncSideViews(
  db: SupabaseClient,
  storage: SupabaseClient["storage"],
  provider: SideViewProvider,
  opts: SyncOpts,
): Promise<SideViewReport> {
  const clock = opts.clock ?? Date.now;
  const sleep = opts.sleep ??
    ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)));
  const startedAt = clock();
  const stamp = opts.now.toISOString();
  const rank = providerRank(provider.name);
  const report: SideViewReport = {
    ...emptyReport(),
    unknownAirlines: 0,
    mirrored: 0,
  };
  const call = makeCall(report, {
    clock,
    sleep,
    startedAt,
    budgetMs: opts.budgetMs ?? DEFAULT_BUDGET_MS,
    maxRequests: opts.maxRequests ?? DEFAULT_MAX_REQUESTS,
  });
  const done = <T>(r: T): T => {
    report.ms = clock() - startedAt;
    return r;
  };

  async function syncPair(
    pair: {
      icao: string;
      aircraftType: string;
      version: string;
      nose?: string;
    },
    row: SideRow | undefined,
  ): Promise<void> {
    const remember = async () =>
      must(
        await db.from("airline_asset_misses").upsert({
          icao: pair.icao,
          kind: "side_view",
          aircraft_type: pair.aircraftType,
          provider: provider.name,
          miss_until: new Date(
            opts.now.getTime() + MISS_HOURS * 3_600_000,
          ).toISOString(),
        }, { onConflict: "icao,kind,aircraft_type,provider" }),
        "miss write failed",
      );
    const got = await call(() => provider.file(pair.icao, pair.aircraftType));
    if (got === null) {
      report.missed++;
      await remember();
      return; // an existing row stays
    }
    const v = await validateFile(got, SIDE_VIEW_RULE);
    if (!v.ok) {
      console.error(
        `brand sync: ${pair.icao} side_view ${pair.aircraftType} rejected: ${v.reason}`,
      );
      report.rejected++;
      report.missed++;
      await remember();
      return;
    }
    let image = v.main;
    const mirrored = pair.nose === "right";
    if (mirrored) {
      try {
        image = await mirrorPng(image);
      } catch (e) {
        console.error(
          `brand sync: ${pair.icao} side_view ${pair.aircraftType} not mirrored: ${
            (e as Error).message
          }`,
        );
        report.rejected++;
        report.missed++;
        await remember();
        return;
      }
    }
    const path = assetPath(
      pair.icao,
      { kind: "side_view", type: pair.aircraftType },
      `${await contentVersion(got.bytes)}${mirrored ? "m" : ""}`,
      v.format,
    );
    must(
      await storage.from(BUCKET).upload(path, image.bytes, {
        contentType: v.mime,
        upsert: true,
      }),
      "upload failed",
    );
    must(
      await db.from("airline_assets").upsert({
        icao: pair.icao,
        kind: "side_view",
        aircraft_type: pair.aircraftType,
        path,
        path_small: null,
        format: v.format,
        width: image.width,
        version: pair.version,
        etag: null,
        provider: provider.name,
        note: mirrored ? "mirrored" : null,
        fetched_at: stamp,
        checked_at: stamp,
      }, { onConflict: "icao,kind,aircraft_type" }),
      "asset upsert failed",
    );
    report.changed++;
    if (mirrored) report.mirrored++;
    if (row && row.path !== path) {
      const rm = await storage.from(BUCKET).remove([row.path]);
      if (rm.error) console.error(`brand sync: old object kept ${row.path}`);
    }
    await db.from("airline_asset_misses").delete().eq("icao", pair.icao).eq(
      "kind",
      "side_view",
    ).eq("aircraft_type", pair.aircraftType).eq("provider", provider.name);
  }

  try {
    let pairs = await call(() => provider.list());
    const total = pairs.length;
    pairs = pairs.filter((p) => {
      const ok = /^[A-Z]{3}$/.test(p.icao) &&
        /^[A-Z0-9]{2,4}$/.test(p.aircraftType) && !!p.version;
      if (!ok) report.rejected++;
      return ok;
    });
    if (opts.icaos) pairs = pairs.filter((p) => opts.icaos!.includes(p.icao));

    const icaos = [...new Set(pairs.map((p) => p.icao))];
    const known = new Set<string>();
    const rows = new Map<string, SideRow>(); // `${icao}/${type}`
    const misses = new Set<string>();
    for (const part of chunks(icaos, 200)) {
      for (
        const a of must(
          await db.from("airlines").select("icao").in("icao", part),
          "airline read failed",
        ).data ?? []
      ) known.add(a.icao);
      for (
        const r of (must(
          await db.from("airline_assets").select(
            "icao, aircraft_type, path, version, provider, note",
          ).eq("kind", "side_view").in("icao", part),
          "asset read failed",
        ).data ?? []) as SideRow[]
      ) rows.set(`${r.icao}/${r.aircraft_type}`, r);
      for (
        const m of must(
          await db.from("airline_asset_misses").select(
            "icao, aircraft_type",
          ).eq("kind", "side_view").eq("provider", provider.name).gt(
            "miss_until",
            stamp,
          ).in("icao", part),
          "miss read failed",
        ).data ?? []
      ) misses.add(`${m.icao}/${m.aircraft_type}`);
    }

    // Rows this provider wrote and no longer lists are stale, whole airlines included (not when the
    // list came back empty).
    if (total > 0) {
      const listed = new Set(pairs.map((p) => `${p.icao}/${p.aircraftType}`));
      const mineRows: SideRow[] = [];
      for (let from = 0;; from += 1000) {
        let q = db.from("airline_assets").select(
          "icao, aircraft_type, path, version, provider, note",
        ).eq("kind", "side_view").eq("provider", provider.name).order("icao")
          .order("aircraft_type").range(from, from + 999);
        if (opts.icaos) q = q.in("icao", opts.icaos);
        const page =
          (must(await q, "asset read failed").data ?? []) as SideRow[];
        mineRows.push(...page);
        if (page.length < 1000) break;
      }
      for (const r of mineRows) {
        const k = `${r.icao}/${r.aircraft_type}`;
        if (listed.has(k)) continue;
        must(
          await db.from("airline_assets").delete().eq("icao", r.icao).eq(
            "kind",
            "side_view",
          ).eq("aircraft_type", r.aircraft_type),
          "asset delete failed",
        );
        const rm = await storage.from(BUCKET).remove([r.path]);
        if (rm.error) console.error(`brand sync: object kept ${r.path}`);
        rows.delete(k);
        report.dropped++;
      }
    }

    // Pairs with no row first, then the rest in list order.
    const queue = pairs.filter((p) => known.has(p.icao)).sort((a, b) =>
      Number(rows.has(`${a.icao}/${a.aircraftType}`)) -
      Number(rows.has(`${b.icao}/${b.aircraftType}`))
    );
    report.unknownAirlines = pairs.length - queue.length;
    const bump = new Map<string, string[]>(); // icao -> types still current
    let fetched = 0;

    for (let i = 0; i < queue.length; i++) {
      const pair = queue[i];
      const k = `${pair.icao}/${pair.aircraftType}`;
      const row = rows.get(k);
      const mine = row?.provider === provider.name;
      if (row && !mine && providerRank(row.provider) >= rank) {
        report.checked++;
        report.skipped++; // a provider of equal or higher rank owns it
        continue;
      }
      const wantNote = pair.nose === "right" ? "mirrored" : null;
      if (
        mine && row!.version === pair.version && row!.note === wantNote
      ) {
        report.checked++;
        report.unchanged++;
        const t = bump.get(pair.icao) ?? [];
        t.push(pair.aircraftType);
        bump.set(pair.icao, t);
        continue;
      }
      if (misses.has(k)) {
        report.checked++;
        report.skipped++;
        continue;
      }
      if (fetched >= opts.limit) {
        report.deferred = queue.slice(i).filter((p) => {
          const r = rows.get(`${p.icao}/${p.aircraftType}`);
          return !(r?.provider === provider.name && r.version === p.version) &&
            !misses.has(`${p.icao}/${p.aircraftType}`);
        }).length;
        break;
      }
      fetched++;
      report.checked++;
      try {
        await syncPair(pair, row);
      } catch (e) {
        if (e instanceof Stop) {
          report.checked--;
          report.deferred = queue.length - i;
          throw e;
        }
        report.failed++;
        console.error(
          `brand sync: ${k} side view failed`,
          redact((e as Error).message),
        );
      }
    }

    for (const [icao, types] of bump) {
      must(
        await db.from("airline_assets").update({ checked_at: stamp }).eq(
          "icao",
          icao,
        ).eq("kind", "side_view").in("aircraft_type", types),
        "asset bump failed",
      );
    }
  } catch (e) {
    if (!(e instanceof Stop)) throw e;
    report.stoppedBy = e.why;
  }
  return done(report);
}
