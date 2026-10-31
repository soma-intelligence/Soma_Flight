import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { hashToken, newToken } from "../_shared/share.ts";
import {
  loadIndexHandler,
  makeUser,
  test,
  testDb,
  trackFlightId,
} from "../_shared/test_util.ts";
import { handler, parsePath } from "./handler.ts";

const db = await testDb();
const NOW = new Date("2026-11-03T15:30:00Z");
const BASE = "http://localhost/functions/v1/flight-page/";

/** AF 84 in the air, followed by `user` with a seat, booking code and notes that must never show. */
async function sharedFlight(
  opts: { arrival?: string; revoked?: boolean } = {},
): Promise<{ token: string; flightId: string; user: string }> {
  const user = await makeUser(db);
  const f = await db.from("flights").insert({
    provider_id: `page-${crypto.randomUUID()}`,
    ident: "AF84",
    operator: "AF",
    origin_icao: "LFPG",
    origin_iata: "CDG",
    destination_icao: "KSFO",
    destination_iata: "SFO",
    scheduled_out: "2026-11-03T09:35:00Z",
    actual_out: "2026-11-03T09:52:00Z",
    actual_off: "2026-11-03T10:10:00Z",
    scheduled_in: opts.arrival ?? "2026-11-03T20:55:00Z",
    estimated_in: opts.arrival ?? "2026-11-03T21:12:00Z",
    gate_origin: "K47",
    terminal_origin: "2E",
    gate_destination: "A3",
    baggage_belt: "6",
    status: "en_route",
  }).select("id").single();
  if (f.error) throw f.error;
  trackFlightId(f.data.id);
  const uf = await db.from("user_flights").insert({
    user_id: user,
    flight_id: f.data.id,
    seat: "23K",
    booking_code: "QXZ7PL",
    notes: "Meet Sam at the north exit",
  });
  if (uf.error) throw uf.error;
  const token = newToken();
  const s = await db.from("flight_shares").insert({
    token_hash: await hashToken(token),
    flight_id: f.data.id,
    user_id: user,
    created_at: "2026-11-03T08:00:00Z",
    revoked_at: opts.revoked ? "2026-11-03T09:00:00Z" : null,
  });
  if (s.error) throw s.error;
  return { token, flightId: f.data.id, user };
}

function get(path: string, now = NOW, headers: HeadersInit = {}) {
  return handler(new Request(BASE + path, { headers }), {
    db,
    now: () => now,
    publicUrl: "https://project.supabase.co",
    image: () => Promise.resolve(new Uint8Array([0x89, 0x50, 0x4e, 0x47])),
  });
}

Deno.test("paths: a token, or a token and og.png; anything else is nothing", () => {
  const t = "a".repeat(43);
  assertEquals(parsePath(`/flight-page/${t}`), { token: t, image: false });
  assertEquals(parsePath(`/functions/v1/flight-page/${t}/og.png`), {
    token: t,
    image: true,
  });
  assertEquals(parsePath(`/${t}`), { token: t, image: false });
  assertEquals(parsePath(`/flight-page/${t}/other`), null);
  assertEquals(parsePath(`/flight-page/short`), null);
  assertEquals(parsePath(`/flight-page/`), null);
});

test(
  db,
  "an open link shows the flight, live, with its gate, belt and status",
  async () => {
    const { token } = await sharedFlight();
    const res = await get(token, NOW, { "accept-language": "en-GB" });
    assertEquals(res.status, 200);
    assertEquals(res.headers.get("content-type"), "text/html; charset=utf-8");
    assertEquals(
      res.headers.get("cache-control"),
      "public, max-age=30, s-maxage=30",
    );
    assertEquals(res.headers.get("referrer-policy"), "no-referrer");
    assertStringIncludes(
      res.headers.get("content-security-policy")!,
      "default-src 'none'",
    );
    const html = await res.text();
    assertStringIncludes(html, "AF 84");
    assertStringIncludes(html, "Paris to San Francisco");
    assertStringIncludes(html, "In the air");
    assertStringIncludes(html, ">K47<");
    assertStringIncludes(html, ">6<");
    assertStringIncludes(html, `role="progressbar"`);
    assertStringIncludes(html, `<meta http-equiv="refresh" content="60">`);
    assertStringIncludes(
      html,
      `content="https://somalabs.me/f/${token}/og.png"`,
    );
  },
);

test(
  db,
  "the page never shows the sharer's seat, booking code or notes",
  async () => {
    const { token, user } = await sharedFlight();
    const html = await (await get(token)).text();
    for (const secret of ["23K", "QXZ7PL", "Meet Sam", user]) {
      assert(!html.includes(secret), `leaked ${secret}`);
    }
  },
);

test(db, "a revoked link is closed, like an unknown one", async () => {
  const { token } = await sharedFlight({ revoked: true });
  const res = await get(token);
  assertEquals(res.status, 404);
  const html = await res.text();
  assertStringIncludes(html, "This flight is no longer shared");
  assert(!html.includes("AF 84"));
  const unknown = await get(newToken());
  assertEquals(unknown.status, 404);
  assertEquals(await unknown.text(), html);
});

test(db, "a link closes 24 hours after arrival", async () => {
  const { token } = await sharedFlight({ arrival: "2026-11-03T20:55:00Z" });
  const before = await get(token, new Date("2026-11-04T20:54:00Z"));
  assertEquals(before.status, 200);
  await before.body?.cancel();
  const after = await get(token, new Date("2026-11-04T20:55:00Z"));
  assertEquals(after.status, 404);
  await after.body?.cancel();
});

test(
  db,
  "revoking through the table closes the page on the next load",
  async () => {
    const { token, flightId } = await sharedFlight();
    const open = await get(token);
    assertEquals(open.status, 200);
    await open.body?.cancel();
    const r = await db.from("flight_shares").update({
      revoked_at: NOW.toISOString(),
    }).eq("flight_id", flightId);
    if (r.error) throw r.error;
    const closed = await get(token);
    assertEquals(closed.status, 404);
    await closed.body?.cancel();
  },
);

test(db, "the preview image is a PNG for open links only", async () => {
  const { token } = await sharedFlight();
  const res = await get(`${token}/og.png`);
  assertEquals(res.status, 200);
  assertEquals(res.headers.get("content-type"), "image/png");
  assertEquals((await res.arrayBuffer()).byteLength, 4);
  const closed = await get(`${newToken()}/og.png`);
  assertEquals(closed.status, 404);
  await closed.body?.cancel();
});

test(db, "a malformed path and a POST answer nothing useful", async () => {
  const bad = await get("not-a-token");
  assertEquals(bad.status, 404);
  await bad.body?.cancel();
  const post = await handler(new Request(BASE + "x", { method: "POST" }), {
    db,
  });
  assertEquals(post.status, 405);
});

test(db, "index.ts starts and answers without a JWT", async () => {
  const serve = await loadIndexHandler(
    new URL("./index.ts", import.meta.url).href,
  );
  const res = await serve(new Request(BASE + newToken()));
  assertEquals(res.status, 404);
  await res.body?.cancel();
});

Deno.test("the preview image renders a real PNG of the route", async () => {
  const { ogImage, OG_WIDTH, OG_HEIGHT } = await import("./og.ts");
  const png = await ogImage({
    origin: { lat: 49.0097, lon: 2.5479 },
    destination: { lat: 37.6188, lon: -122.375 },
    progress: 0.5,
  });
  assertEquals([...png.slice(0, 4)], [0x89, 0x50, 0x4e, 0x47]);
  const view = new DataView(png.buffer, png.byteOffset);
  assertEquals([view.getUint32(16), view.getUint32(20)], [OG_WIDTH, OG_HEIGHT]);
});
