// Side view sync against the local stack. Fixtures are test images made for this repo
// (_shared/fixtures/side_views), never provider artwork. Every row, airline and object is removed.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { test, testDb } from "../test_util.ts";
import {
  FakeSideViewProvider,
  RecordedSideViewProvider,
} from "./side_view_provider.ts";
import { syncSideViews } from "./sync.ts";
import { handler } from "../../brand-assets-sync/handler.ts";

const db = await testDb();
const BUCKET = "brand-assets";
const T = ["ZQA", "ZQB", "ZQC"]; // not in the seed
const FIX = new URL("../fixtures/side_views/", import.meta.url);
const NOW1 = new Date("2026-11-01T10:00:00Z");
const NOW2 = new Date("2026-11-02T10:00:00Z");

const b64 = (o: object) =>
  btoa(JSON.stringify(o)).replace(/=+$/, "").replace(/\+/g, "-").replace(
    /\//g,
    "_",
  );
const SERVICE_KEY = `${b64({ alg: "HS256" })}.${
  b64({ role: "service_role" })
}.sig`;

const opts = (now = NOW1, limit = 100) => ({
  limit,
  now,
  icaos: T,
  sleep: () => Promise.resolve(),
});

async function addAirlines(...icaos: string[]) {
  const r = await db.from("airlines").upsert(
    icaos.map((icao) => ({
      icao,
      name: `Test Air ${icao}`,
      color_primary: "#6B7280",
      colors_source: "seed",
    })),
    { onConflict: "icao" },
  );
  if (r.error) throw r.error;
}

async function wipe() {
  const paths: string[] = [];
  for (const icao of T) {
    const l = await db.storage.from(BUCKET).list(`side-views/${icao}`);
    if (l.error) throw l.error;
    for (const o of l.data) paths.push(`side-views/${icao}/${o.name}`);
  }
  if (paths.length) {
    const r = await db.storage.from(BUCKET).remove(paths);
    if (r.error) throw r.error;
  }
  for (const t of ["airline_assets", "airline_asset_misses", "airlines"]) {
    const r = await db.from(t).delete().in("icao", T);
    if (r.error) throw r.error;
  }
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

async function rows(icao?: string) {
  const q = db.from("airline_assets").select("*").eq("kind", "side_view").in(
    "icao",
    icao ? [icao] : T,
  ).order("icao").order("aircraft_type");
  const r = await q;
  if (r.error) throw r.error;
  return r.data!;
}

async function objects(): Promise<string[]> {
  const out: string[] = [];
  for (const icao of T) {
    const l = await db.storage.from(BUCKET).list(`side-views/${icao}`);
    if (l.error) throw l.error;
    out.push(...l.data.map((o) => `${icao}/${o.name}`));
  }
  return out.sort();
}

// ---- a small PNG decoder (8-bit RGBA, any filter) to look at the stored pixels ----
async function decode(bytes: Uint8Array) {
  const v = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let pos = 8;
  let w = 0, h = 0, type = 0;
  const idat: Uint8Array[] = [];
  while (pos < bytes.length) {
    const len = v.getUint32(pos);
    const name = String.fromCharCode(...bytes.slice(pos + 4, pos + 8));
    const body = bytes.slice(pos + 8, pos + 8 + len);
    if (name === "IHDR") {
      w = new DataView(body.buffer).getUint32(0);
      h = new DataView(body.buffer).getUint32(4);
      type = body[9];
      assertEquals(body[8], 8);
    }
    if (name === "IDAT") idat.push(body);
    pos += 12 + len;
  }
  assertEquals(type, 6, "RGBA expected");
  const all = new Uint8Array(idat.reduce((n, c) => n + c.length, 0));
  let at = 0;
  for (const c of idat) {
    all.set(c, at);
    at += c.length;
  }
  const raw = new Uint8Array(
    await new Response(
      new Blob([all]).stream().pipeThrough(new DecompressionStream("deflate")),
    ).arrayBuffer(),
  );
  const bpp = 4, stride = w * bpp;
  const px = new Uint8Array(h * stride);
  for (let y = 0; y < h; y++) {
    const f = raw[y * (stride + 1)];
    for (let x = 0; x < stride; x++) {
      const cur = raw[y * (stride + 1) + 1 + x];
      const a = x >= bpp ? px[y * stride + x - bpp] : 0;
      const b = y > 0 ? px[(y - 1) * stride + x] : 0;
      const c = x >= bpp && y > 0 ? px[(y - 1) * stride + x - bpp] : 0;
      let p = 0;
      if (f === 1) p = a;
      else if (f === 2) p = b;
      else if (f === 3) p = (a + b) >> 1;
      else if (f === 4) {
        const q = a + b - c;
        const pa = Math.abs(q - a), pb = Math.abs(q - b), pc = Math.abs(q - c);
        p = pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
      }
      px[y * stride + x] = (cur + p) & 255;
    }
  }
  return { w, h, px };
}

/** Mean x of the red nose cone, as a fraction of the width: under 0.5 means the nose points left. */
async function noseAt(path: string): Promise<number> {
  const d = await db.storage.from(BUCKET).download(path);
  if (d.error) throw d.error;
  const { w, h, px } = await decode(new Uint8Array(await d.data.arrayBuffer()));
  let sum = 0, n = 0;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const i = (y * w + x) * 4;
      if (px[i + 3] > 200 && px[i] > 150 && px[i + 1] < 90) {
        sum += x;
        n++;
      }
    }
  }
  assert(n > 100, "nose cone not found");
  return sum / n / w;
}

const recorded = () => new RecordedSideViewProvider(FIX);
const fixtureBytes = (n: string) => Deno.readFile(new URL(n, FIX));

guarded("uploadsPairsOnce", async () => {
  await addAirlines("ZQA", "ZQB");
  const p = recorded();
  const r = await syncSideViews(db, db.storage, p, opts());
  assertEquals(
    [r.changed, r.failed, r.rejected, r.unknownAirlines, r.stoppedBy],
    [3, 0, 0, 0, "done"],
  );
  const got = await rows();
  assertEquals(
    got.map((x) => [x.icao, x.aircraft_type, x.format, x.width, x.provider]),
    [
      ["ZQA", "A320", "png", 1300, "recorded"],
      ["ZQA", "B738", "png", 1600, "recorded"],
      ["ZQB", "B738", "png", 1600, "recorded"], // the SVG, rendered 1600 px wide
    ],
  );
  assert(got.every((x) => x.path_small === null));
  const objs = await objects();
  assertEquals(objs.length, 3);
  assert(objs.every((o) => o.endsWith(".png")));
  // A second run uploads nothing.
  const again = await syncSideViews(db, db.storage, p, opts(NOW2));
  assertEquals([again.changed, again.unchanged], [0, 3]);
  assertEquals(await objects(), objs);
});

guarded("unchangedPairSkipped", async () => {
  await addAirlines("ZQA", "ZQB");
  const p = recorded();
  await syncSideViews(db, db.storage, p, opts());
  const filesBefore = p.calls.file;
  const second = await syncSideViews(db, db.storage, p, opts(NOW2));
  assertEquals(
    p.calls.file,
    filesBefore,
    "no file fetched for unchanged pairs",
  );
  assertEquals([second.unchanged, second.changed, second.requests], [3, 0, 1]);
  const got = await rows();
  assert(
    got.every((x) => new Date(x.checked_at).getTime() === NOW2.getTime()),
  );
  assert(got.every((x) => x.fetched_at.startsWith("2026-11-01")));
});

guarded("changedPairNewVersion", async () => {
  await addAirlines("ZQA");
  const p = new FakeSideViewProvider("fake");
  const png = await fixtureBytes("ZQA-B738.png");
  p.set("ZQA", "B738", { bytes: png, format: "png", version: "v1" });
  await syncSideViews(db, db.storage, p, opts());
  const first = (await rows("ZQA"))[0];
  assertEquals(first.version, "v1");
  const old = await objects();
  assertEquals(old.length, 1);

  // Same pair, new drawing and version: a new object, the old one removed.
  p.set("ZQA", "B738", {
    bytes: await fixtureBytes("ZQA-A320.png"),
    format: "png",
    version: "v2",
    nose: "right",
  });
  const r = await syncSideViews(db, db.storage, p, opts(NOW2));
  assertEquals([r.changed, r.unchanged], [1, 0]);
  const now = (await rows("ZQA"))[0];
  assertEquals([now.version, now.note, now.width], ["v2", "mirrored", 1300]);
  assert(now.path !== first.path);
  const objs = await objects();
  assertEquals(objs.length, 1);
  assert(!objs.includes(`ZQA/${first.path.split("/").pop()}`));
});

guarded("unknownAirlineSkipped", async () => {
  await addAirlines("ZQA"); // ZQB is not an airline
  const r = await syncSideViews(db, db.storage, recorded(), opts());
  assertEquals([r.changed, r.unknownAirlines], [2, 1]);
  assertEquals((await rows()).map((x) => x.icao), ["ZQA", "ZQA"]);
  const b = await db.from("airlines").select("icao").eq("icao", "ZQB");
  assertEquals(
    b.data!.length,
    0,
    "the sync never adds an airline for a side view",
  );
});

guarded("noseRightMirrored", async () => {
  await addAirlines("ZQA");
  const r = await syncSideViews(db, db.storage, recorded(), {
    ...opts(),
    icaos: ["ZQA"],
  });
  assertEquals([r.changed, r.mirrored], [2, 1]);
  const [a320, b738] = await rows("ZQA");
  assertEquals([a320.aircraft_type, a320.note], ["A320", "mirrored"]);
  assertEquals([b738.aircraft_type, b738.note], ["B738", null]);
  // The A320 fixture is drawn nose right; the stored image points left like the B738.
  assert((await noseAt(a320.path)) < 0.3, "mirrored nose is on the left");
  assert((await noseAt(b738.path)) < 0.3, "left nose untouched");
  assertEquals(a320.width, 1300);
});

guarded("notConfiguredIsNoOp", async () => {
  await addAirlines("ZQA");
  for (const deps of [{}, { sideViewProvider: () => null }]) {
    const res = await handler(
      new Request("http://localhost/brand-assets-sync?mode=side_views", {
        method: "POST",
        headers: { authorization: `Bearer ${SERVICE_KEY}` },
      }),
      { db, provider: () => null, serviceKey: () => SERVICE_KEY, ...deps },
    );
    assertEquals(res.status, 200);
    assertEquals(await res.json(), {
      ok: true,
      mode: "side_views",
      skipped: "provider not configured",
    });
  }
  assertEquals((await rows()).length, 0);
  assertEquals((await objects()).length, 0);
});

guarded("handlerRunsSideViews", async () => {
  await addAirlines("ZQA", "ZQB");
  const res = await handler(
    new Request(
      `http://localhost/brand-assets-sync?mode=side_views&icao=${T.join(",")}`,
      { method: "POST", headers: { authorization: `Bearer ${SERVICE_KEY}` } },
    ),
    {
      db,
      provider: () => null,
      sideViewProvider: () => recorded(),
      serviceKey: () => SERVICE_KEY,
      now: () => NOW1,
    },
  );
  const body = await res.json();
  assertEquals([res.status, body.ok, body.mode, body.changed], [
    200,
    true,
    "side_views",
    3,
  ]);
  assertEquals((await rows()).length, 3);
});

guarded("narrowAndWebpRefused", async () => {
  await addAirlines("ZQA");
  const p = new FakeSideViewProvider("fake");
  p.set("ZQA", "B738", {
    bytes: await fixtureBytes("narrow-1000.png"),
    format: "png",
    version: "n1",
  });
  p.set("ZQA", "A320", {
    bytes: await fixtureBytes("ZQA-B738.png"),
    format: "webp", // wrong on purpose: PNG only
    version: "w1",
  });
  const r = await syncSideViews(db, db.storage, p, opts());
  assertEquals([r.changed, r.rejected, r.missed], [0, 2, 2]);
  assertEquals((await rows()).length, 0);
  // The refusal is remembered for a day: the next tick does not fetch again.
  const fetched = p.calls.file;
  const next = await syncSideViews(db, db.storage, p, opts(NOW1));
  assertEquals([p.calls.file, next.skipped], [fetched, 2]);
});

guarded("outageAbortsAndHigherRankWins", async () => {
  await addAirlines("ZQA");
  const down = new FakeSideViewProvider("fake");
  down.outage = true;
  const r = await syncSideViews(db, db.storage, down, opts());
  assertEquals([r.stoppedBy, r.changed], ["provider_unavailable", 0]);
  assertEquals(down.calls.list, 3, "three attempts");

  // A row an equal or higher ranked provider wrote is left alone.
  const png = await fixtureBytes("ZQA-B738.png");
  const high = new FakeSideViewProvider("airhex");
  high.set("ZQA", "B738", { bytes: png, format: "png", version: "h1" });
  await syncSideViews(db, db.storage, high, opts());
  const low = new FakeSideViewProvider("commons");
  low.set("ZQA", "B738", {
    bytes: await fixtureBytes("ZQA-A320.png"),
    format: "png",
    version: "c1",
  });
  const s = await syncSideViews(db, db.storage, low, opts(NOW2));
  assertEquals([s.changed, s.skipped, low.calls.file], [0, 1, 0]);
  assertEquals((await rows("ZQA"))[0].provider, "airhex");
});

guarded("limitDefersAndStaleRowDropped", async () => {
  await addAirlines("ZQA", "ZQB");
  const p = recorded();
  const first = await syncSideViews(db, db.storage, p, opts(NOW1, 2));
  assertEquals([first.changed, first.deferred], [2, 1]);
  const second = await syncSideViews(db, db.storage, p, opts(NOW2, 2));
  assertEquals([second.changed, second.unchanged, second.deferred], [1, 2, 0]);
  assertEquals((await rows()).length, 3);

  // The provider stops listing ZQB/B738: its row and object go.
  const fake = new FakeSideViewProvider("recorded");
  fake.set("ZQA", "B738", {
    bytes: await fixtureBytes("ZQA-B738.png"),
    format: "png",
    version: (await p.list()).find((x) =>
      x.icao === "ZQA" && x.aircraftType === "B738"
    )!.version,
  });
  const third = await syncSideViews(db, db.storage, fake, opts(NOW2));
  assertEquals(third.dropped, 2);
  assertEquals((await rows()).map((x) => x.icao + x.aircraft_type), [
    "ZQAB738",
  ]);
  assertEquals((await objects()).length, 1);
});
