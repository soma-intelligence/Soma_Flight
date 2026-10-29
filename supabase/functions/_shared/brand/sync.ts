// Logo and brand colour sync. One call handles up to `limit` airlines that were never checked or
// were last checked over 7 days ago, oldest first, so hourly batches of 50 cover 2,050 airlines in
// two days and every airline again each week. Nothing is downloaded twice: an unchanged validator
// (etag, else content version) only bumps checked_at. A new version is a new object; the old one is
// removed after the row points at the new one, so a signed URL never lands on a missing object.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { LogoKind, LogoProvider } from "./logo_provider.ts";

export const BUCKET = "brand-assets";
export const RECHECK_DAYS = 7;
const KINDS: LogoKind[] = ["logo", "logo_dark", "tail"];
const MIME = {
  svg: "image/svg+xml",
  pdf: "application/pdf",
  png: "image/png",
} as const;
/** Colour for a provider airline we have nothing better for yet; replaced by the provider's own. */
const PLACEHOLDER_PRIMARY = "#6B7280";
const DAY_MS = 86_400_000;

export interface SyncReport {
  checked: number;
  changed: number;
  added: number;
  failed: number;
}

export interface SyncOpts {
  limit: number;
  now: Date;
  /** Restrict the queue to these airlines (a manual resync of a few). Due-ness still applies. */
  icaos?: string[];
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

async function syncKind(
  db: SupabaseClient,
  storage: SupabaseClient["storage"],
  provider: LogoProvider,
  icao: string,
  kind: LogoKind,
  now: Date,
): Promise<boolean> {
  const file = await provider.logo(icao, kind);
  const stamp = now.toISOString();
  const cur = must(
    await db.from("airline_assets").select("path, version, etag").eq(
      "icao",
      icao,
    ).eq("kind", kind).eq("aircraft_type", "").maybeSingle(),
    "asset read failed",
  ).data;
  if (!file) return false; // the provider has none; an existing row stays as it is
  const same = cur !== null &&
    (file.etag !== null && cur.etag !== null
      ? file.etag === cur.etag
      : file.version === cur.version);
  if (same) {
    must(
      await db.from("airline_assets").update({ checked_at: stamp }).eq(
        "icao",
        icao,
      ).eq("kind", kind).eq("aircraft_type", ""),
      "asset bump failed",
    );
    return false;
  }
  const path = `logos/${icao}/${kind}-${file.version}.${file.format}`;
  must(
    await storage.from(BUCKET).upload(path, file.bytes, {
      contentType: MIME[file.format],
      upsert: true,
    }),
    "upload failed",
  );
  must(
    await db.from("airline_assets").upsert({
      icao,
      kind,
      aircraft_type: "",
      path,
      format: file.format,
      width: file.width,
      version: file.version,
      etag: file.etag,
      provider: provider.name,
      fetched_at: stamp,
      checked_at: stamp,
    }, { onConflict: "icao,kind,aircraft_type" }),
    "asset upsert failed",
  );
  if (cur && cur.path !== path) {
    const rm = await storage.from(BUCKET).remove([cur.path]);
    if (rm.error) console.error(`brand sync: old object kept ${cur.path}`);
  }
  return true;
}

async function syncColors(
  db: SupabaseClient,
  provider: LogoProvider,
  icao: string,
  now: Date,
): Promise<void> {
  const c = await provider.colors(icao);
  if (!c) return;
  // The filter keeps livery seeds ('locked') out even if the row was locked since we read it.
  must(
    await db.from("airlines").update({
      color_primary: c.primary,
      color_secondary: c.secondary,
      colors_source: provider.name,
      colors_updated_at: now.toISOString(),
    }).eq("icao", icao).neq("colors_source", "locked"),
    "colour update failed",
  );
}

export async function syncLogos(
  db: SupabaseClient,
  storage: SupabaseClient["storage"],
  provider: LogoProvider,
  opts: SyncOpts,
): Promise<SyncReport> {
  const report: SyncReport = { checked: 0, changed: 0, added: 0, failed: 0 };
  report.added = await addMissingAirlines(db, provider);

  const cutoff = new Date(opts.now.getTime() - RECHECK_DAYS * DAY_MS)
    .toISOString();
  let queue = db.from("airlines").select("icao")
    .or(`logo_checked_at.is.null,logo_checked_at.lt.${cutoff}`);
  if (opts.icaos) queue = queue.in("icao", opts.icaos);
  const due = must(
    await queue
      .order("logo_checked_at", { ascending: true, nullsFirst: true })
      .order("icao").limit(opts.limit),
    "queue read failed",
  ).data ?? [];

  for (const { icao } of due as { icao: string }[]) {
    report.checked++;
    try {
      for (const kind of KINDS) {
        if (await syncKind(db, storage, provider, icao, kind, opts.now)) {
          report.changed++;
        }
      }
      await syncColors(db, provider, icao, opts.now);
      must(
        await db.from("airlines").update({
          logo_checked_at: opts.now.toISOString(),
        }).eq("icao", icao),
        "mark failed",
      );
    } catch (e) {
      report.failed++;
      console.error(`brand sync: ${icao} failed`, (e as Error).message);
      // Retry in about a day instead of at the head of every hour's queue.
      await db.from("airlines").update({
        logo_checked_at: new Date(
          opts.now.getTime() - (RECHECK_DAYS - 1) * DAY_MS,
        ).toISOString(),
      }).eq("icao", icao);
    }
  }
  return report;
}
