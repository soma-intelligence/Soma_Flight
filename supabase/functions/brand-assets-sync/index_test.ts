import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  loadIndexHandler,
  makeUser,
  test,
  testDb,
} from "../_shared/test_util.ts";
import { FakeLogoProvider } from "../_shared/brand/logo_provider.ts";
import { handler } from "./handler.ts";

const db = await testDb();
const BUCKET = "brand-assets";
const T = ["ZQA", "ZQB", "ZQC", "ZQD"]; // not in the seed
const b64 = (o: object) =>
  btoa(JSON.stringify(o)).replace(/=+$/, "").replace(/\+/g, "-").replace(
    /\//g,
    "_",
  );
const jwt = (role: string) => `${b64({ alg: "HS256" })}.${b64({ role })}.sig`;
const SERVICE_KEY = jwt("service_role");
const NOW1 = new Date("2026-11-01T10:00:00Z");
const NOW2 = new Date("2026-11-09T10:00:00Z"); // 8 days later: due again

const svg = (s: string) => new TextEncoder().encode(`<svg id="${s}"/>`);

function fake(...icaos: string[]): FakeLogoProvider {
  const p = new FakeLogoProvider("fake");
  p.airlines = icaos.map((icao, i) => ({
    icao,
    iata: `Q${"ABCD"[i]}`,
    name: `Test Air ${icao}`,
  }));
  return p;
}

function withFiles(
  p: FakeLogoProvider,
  icao: string,
  v: string,
  etag?: string,
) {
  for (const kind of ["logo", "logo_dark", "tail"]) {
    p.files.set(`${icao}/${kind}`, {
      bytes: svg(`${icao}${kind}${v}`),
      version: `${v}${kind}`.replace("_", ""),
      etag: etag ?? null,
    });
  }
  p.colorsBy.set(icao, { primary: "#AA0000", secondary: "#00BB00" });
}

async function run(
  provider: FakeLogoProvider | null,
  now: Date,
  query = "mode=logos&limit=50&icao=" + T.join(","),
  token = SERVICE_KEY,
) {
  const res = await handler(
    new Request(`http://localhost/brand-assets-sync?${query}`, {
      method: "POST",
      headers: { authorization: `Bearer ${token}` },
    }),
    {
      db,
      provider: () => provider,
      serviceKey: () => SERVICE_KEY,
      now: () => now,
    },
  );
  return { status: res.status, body: await res.json() };
}

/** Removes every row and object the sync made for the test airlines. */
async function wipe() {
  const paths: string[] = [];
  for (const icao of T) {
    const l = await db.storage.from(BUCKET).list(`logos/${icao}`);
    if (l.error) throw l.error;
    for (const o of l.data) paths.push(`logos/${icao}/${o.name}`);
  }
  if (paths.length) {
    const r = await db.storage.from(BUCKET).remove(paths);
    if (r.error) throw r.error;
  }
  const a = await db.from("airline_assets").delete().in("icao", T);
  if (a.error) throw a.error;
  const b = await db.from("airlines").delete().in("icao", T);
  if (b.error) throw b.error;
}

async function objects(icao: string): Promise<string[]> {
  const l = await db.storage.from(BUCKET).list(`logos/${icao}`);
  if (l.error) throw l.error;
  return l.data.map((o) => o.name).sort();
}

function guarded(name: string, fn: () => Promise<void>) {
  test(db, name, async () => {
    await wipe();
    try {
      await fn();
    } finally {
      await wipe();
    }
  });
}

guarded("firstRunUploadsAll", async () => {
  const p = fake("ZQA");
  withFiles(p, "ZQA", "v1");
  const { status, body } = await run(p, NOW1);
  assertEquals(status, 200);
  assertEquals(
    {
      checked: body.checked,
      changed: body.changed,
      added: body.added,
      failed: body.failed,
    },
    { checked: 1, changed: 3, added: 1, failed: 0 },
  );
  const rows = await db.from("airline_assets").select("*").eq("icao", "ZQA");
  assertEquals(rows.data!.length, 3);
  assertEquals((await objects("ZQA")).length, 3);
  for (const r of rows.data!) {
    assertEquals(r.provider, "fake");
    assert(r.path.startsWith(`logos/ZQA/${r.kind}-`));
    const dl = await db.storage.from(BUCKET).download(r.path);
    assert(dl.data && (await dl.data.text()).startsWith("<svg"));
  }
  const al = await db.from("airlines").select("*").eq("icao", "ZQA").single();
  assertEquals(al.data!.color_primary, "#AA0000");
  assertEquals(al.data!.color_secondary, "#00BB00");
  assertEquals(al.data!.colors_source, "fake");
  assertEquals(new Date(al.data!.logo_checked_at).getTime(), NOW1.getTime());
});

guarded("unchangedVersionNotDownloadedAgain", async () => {
  const p = fake("ZQA");
  withFiles(p, "ZQA", "v1");
  await run(p, NOW1);
  const before = await objects("ZQA");
  // Not due yet: nothing is even asked of the provider.
  const calls = p.calls.logo;
  const early = await run(p, new Date(NOW1.getTime() + 3_600_000));
  assertEquals(early.body.checked, 0);
  assertEquals(p.calls.logo, calls);
  // Due again, same versions: no upload, checked_at moves.
  const again = await run(p, NOW2);
  assertEquals(again.body.checked, 1);
  assertEquals(again.body.changed, 0);
  assertEquals(await objects("ZQA"), before);
  const rows = await db.from("airline_assets").select("checked_at,fetched_at")
    .eq("icao", "ZQA");
  for (const r of rows.data!) {
    assertEquals(new Date(r.checked_at).getTime(), NOW2.getTime());
    assertEquals(new Date(r.fetched_at).getTime(), NOW1.getTime());
  }
});

guarded("changedEtagUploadsNewVersion", async () => {
  const p = fake("ZQA");
  withFiles(p, "ZQA", "v1", '"e1"');
  await run(p, NOW1);
  const first = await db.from("airline_assets").select("path").eq("icao", "ZQA")
    .eq("kind", "logo").single();
  withFiles(p, "ZQA", "v2", '"e2"');
  const { body } = await run(p, NOW2);
  assertEquals(body.changed, 3);
  const now = await db.from("airline_assets").select("path,version,etag").eq(
    "icao",
    "ZQA",
  ).eq("kind", "logo").single();
  assert(now.data!.path !== first.data!.path);
  assertEquals(now.data!.etag, '"e2"');
  const names = await objects("ZQA");
  assertEquals(names.length, 3, "old objects removed after the rows moved");
  assert(!names.includes(first.data!.path.split("/").pop()!));
  assert(names.includes(now.data!.path.split("/").pop()!));
});

guarded("newProviderAirlineInserted", async () => {
  const p = fake("ZQB");
  withFiles(p, "ZQB", "v1");
  p.colorsBy.delete("ZQB");
  const { body } = await run(p, NOW1);
  assertEquals(body.added, 1);
  const al = await db.from("airlines").select("*").eq("icao", "ZQB").single();
  assertEquals(al.data!.name, "Test Air ZQB");
  assertEquals(al.data!.iata, "QA");
  assertEquals(al.data!.colors_source, "seed"); // no provider colours: placeholder stays marked seed
  // A second run adds nothing.
  const again = await run(p, NOW2);
  assertEquals(again.body.added, 0);
});

guarded("lockedColorsKept", async () => {
  const ins = await db.from("airlines").insert({
    icao: "ZQC",
    iata: "QC",
    name: "Locked Air",
    color_primary: "#112233",
    color_secondary: "#445566",
    colors_source: "locked",
  });
  if (ins.error) throw ins.error;
  const p = fake("ZQC");
  withFiles(p, "ZQC", "v1");
  const { body } = await run(p, NOW1);
  assertEquals(body.changed, 3); // logos still sync
  const al = await db.from("airlines").select("*").eq("icao", "ZQC").single();
  assertEquals(al.data!.color_primary, "#112233");
  assertEquals(al.data!.color_secondary, "#445566");
  assertEquals(al.data!.colors_source, "locked");
});

guarded("oneFailureDoesNotStopBatch", async () => {
  const p = fake("ZQA", "ZQB", "ZQC");
  for (const c of ["ZQA", "ZQB", "ZQC"]) withFiles(p, c, "v1");
  p.failIcao.add("ZQB");
  const { status, body } = await run(p, NOW1);
  assertEquals(status, 200);
  assertEquals(body.checked, 3);
  assertEquals(body.failed, 1);
  assertEquals(body.changed, 6);
  assertEquals((await objects("ZQA")).length, 3);
  assertEquals((await objects("ZQB")).length, 0);
  assertEquals((await objects("ZQC")).length, 3);
  // The failed airline is retried in about a day, not stuck at the head of the queue.
  const al = await db.from("airlines").select("logo_checked_at").eq(
    "icao",
    "ZQB",
  )
    .single();
  const t = new Date(al.data!.logo_checked_at).getTime();
  assertEquals(t, NOW1.getTime() - 6 * 86_400_000);
  p.failIcao.clear();
  const next = await run(p, new Date(NOW1.getTime() + 25 * 3_600_000));
  assertEquals(next.body.checked, 1);
  assertEquals((await objects("ZQB")).length, 3);
});

Deno.test({
  name: "notConfiguredIsNoOp",
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const saved = [Deno.env.get("LOGO_PROVIDER"), Deno.env.get("AIRHEX_KEY")];
    try {
      const before = await db.from("airlines").select("*", {
        count: "exact",
        head: true,
      });
      for (
        const env of [
          { provider: undefined, key: undefined },
          { provider: "airhex", key: undefined }, // provider chosen, licence not signed yet
          { provider: undefined, key: "k" }, // key without a provider choice
        ]
      ) {
        if (env.provider) Deno.env.set("LOGO_PROVIDER", env.provider);
        else Deno.env.delete("LOGO_PROVIDER");
        if (env.key) Deno.env.set("AIRHEX_KEY", env.key);
        else Deno.env.delete("AIRHEX_KEY");
        const h = await loadIndexHandler(
          new URL("./index.ts", import.meta.url).href +
            `?c=${crypto.randomUUID()}`,
        );
        const res = await h(
          new Request(
            "http://localhost/brand-assets-sync?mode=logos&limit=50",
            {
              method: "POST",
              headers: {
                authorization: `Bearer ${
                  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
                }`,
              },
            },
          ),
        );
        assertEquals(res.status, 200);
        assertEquals(await res.json(), {
          ok: true,
          mode: "logos",
          skipped: "provider not configured",
        });
      }
      const after = await db.from("airlines").select("*", {
        count: "exact",
        head: true,
      });
      assertEquals(after.count, before.count);
    } finally {
      for (const [i, n] of ["LOGO_PROVIDER", "AIRHEX_KEY"].entries()) {
        if (saved[i] === undefined) Deno.env.delete(n);
        else Deno.env.set(n, saved[i]!);
      }
    }
  },
});

test(db, "userJwtRefused", async () => {
  const user = await makeUser(db);
  const p = fake("ZQA");
  const r = await run(p, NOW1, "mode=logos&limit=1", user);
  assertEquals(r.status, 401);
  assertEquals(p.calls.list, 0);
  const anon = await run(p, NOW1, "mode=logos&limit=1", jwt("anon"));
  assertEquals(anon.status, 401);
  const bad = await run(p, NOW1, "mode=nope", SERVICE_KEY);
  assertEquals(bad.status, 400);
});
