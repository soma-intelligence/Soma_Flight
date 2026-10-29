import { assert, assertEquals, assertMatch } from "jsr:@std/assert@1";
import {
  fakeVerifier,
  loadIndexHandler,
  makeUser,
  test,
  testDb,
} from "../_shared/test_util.ts";
import { handler } from "./handler.ts";

const db = await testDb();
const BUCKET = "brand-assets";
const TAG = crypto.randomUUID().slice(0, 8);

function get(token: string | null, query: string): Request {
  return new Request(`http://localhost/brand-asset?${query}`, {
    method: "GET",
    headers: token ? { authorization: `Bearer ${token}` } : {},
  });
}

/** Uploads an object and its airline_assets row; the returned cleanup removes both. */
async function seed(
  kind: string,
  aircraftType: string,
  path: string,
  body: string,
  icao = "UAL",
) {
  const up = await db.storage.from(BUCKET).upload(path, body, {
    contentType: "image/svg+xml",
    upsert: true,
  });
  if (up.error) throw up.error;
  const row = await db.from("airline_assets").insert({
    icao,
    kind,
    aircraft_type: aircraftType,
    path,
    format: "svg",
    width: 640,
    version: `t${TAG}`,
    provider: "test",
    fetched_at: new Date().toISOString(),
    checked_at: new Date().toISOString(),
  });
  if (row.error) throw row.error;
  return async () => {
    const d = await db.from("airline_assets").delete().eq("icao", icao)
      .eq("kind", kind).eq("aircraft_type", aircraftType);
    if (d.error) throw d.error;
    const r = await db.storage.from(BUCKET).remove([path]);
    if (r.error) throw r.error;
  };
}

test(db, "servesSignedUrlWithVersion", async () => {
  const user = await makeUser(db);
  const path = `logos/UAL/logo-t${TAG}.svg`;
  const undo = await seed(
    "logo",
    "",
    path,
    "<svg xmlns='http://www.w3.org/2000/svg'/>",
  );
  const sideUndo = await seed(
    "side_view",
    "B38M",
    `side-views/UAL/B38M-t${TAG}.svg`,
    "<svg xmlns='http://www.w3.org/2000/svg'/>",
  );
  try {
    const fixed = new Date("2026-11-01T12:00:00Z");
    const res = await handler(get(user, "airline=UAL&kind=logo"), {
      db,
      verifier: fakeVerifier,
      now: () => fixed,
    });
    assertEquals(res.status, 200);
    const body = await res.json();
    assertEquals(body.version, `t${TAG}`);
    assertEquals(body.format, "svg");
    assertEquals(body.width, 640);
    assertEquals(body.expiresAt, "2026-11-01T13:00:00.000Z");
    assertMatch(body.url, /^https?:\/\//);
    assert(body.url.includes(`logo-t${TAG}.svg`));
    const file = await fetch(body.url);
    assertEquals(file.status, 200);
    assertMatch(await file.text(), /<svg/);

    const side = await handler(
      get(user, "airline=ual&kind=side_view&type=b38m"),
      {
        db,
        verifier: fakeVerifier,
      },
    );
    assertEquals(side.status, 200);
    assert((await side.json()).url.includes(`B38M-t${TAG}.svg`));
  } finally {
    await undo();
    await sideUndo();
  }
});

test(db, "missingAssetIs404", async () => {
  const user = await makeUser(db);
  const d = { db, verifier: fakeVerifier };
  const none = await handler(get(user, "airline=UAL&kind=tail"), d);
  assertEquals(none.status, 404);
  assertEquals((await none.json()).error.code, "not_found");
  const unknown = await handler(get(user, "airline=ZZZ&kind=logo"), d);
  assertEquals(unknown.status, 404);
  assertEquals((await unknown.json()).error.code, "not_found");
  const noSide = await handler(
    get(user, "airline=UAL&kind=side_view&type=A388"),
    d,
  );
  assertEquals(noSide.status, 404);
});

test(db, "sideViewNeedsType", async () => {
  const user = await makeUser(db);
  const res = await handler(get(user, "airline=UAL&kind=side_view"), {
    db,
    verifier: fakeVerifier,
  });
  assertEquals(res.status, 400);
  assertEquals((await res.json()).error.code, "invalid_request");
});

test(db, "typeRefusedForLogo", async () => {
  const user = await makeUser(db);
  const d = { db, verifier: fakeVerifier };
  const res = await handler(get(user, "airline=UAL&kind=logo&type=B38M"), d);
  assertEquals(res.status, 400);
  assertEquals((await res.json()).error.code, "invalid_request");
  const bad = await handler(get(user, "airline=UAL&kind=nope"), d);
  assertEquals(bad.status, 400);
});

test(db, "noJwt401", async () => {
  const d = { db, verifier: fakeVerifier };
  const none = await handler(get(null, "airline=UAL&kind=logo"), d);
  assertEquals(none.status, 401);
  const bad = await handler(get("bad", "airline=UAL&kind=logo"), d);
  assertEquals(bad.status, 401);
});

test(db, "rateLimit429", async () => {
  const user = await makeUser(db);
  const now = new Date().toISOString();
  const rows = Array.from({ length: 600 }, () => ({
    user_id: user,
    endpoint: "brand-asset",
    at: now,
  }));
  const ins = await db.from("rate_events").insert(rows);
  if (ins.error) throw ins.error;
  const res = await handler(get(user, "airline=UAL&kind=logo"), {
    db,
    verifier: fakeVerifier,
  });
  assertEquals(res.status, 429);
  assertEquals((await res.json()).error.code, "rate_limited");
});

test(db, "startsWithNoProviderKey", async () => {
  const h = await loadIndexHandler(new URL("./index.ts", import.meta.url).href);
  const res = await h(get(null, "airline=UAL&kind=logo"));
  assertEquals(res.status, 401);
});
