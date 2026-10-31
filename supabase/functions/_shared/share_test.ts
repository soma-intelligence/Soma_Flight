import { assert, assertEquals, assertNotEquals } from "jsr:@std/assert@1";
import {
  arrivalOf,
  DEFAULT_SHARE_BASE,
  hashToken,
  newToken,
  shareExpiresAt,
  shareIsOpen,
  shareUrl,
  TOKEN_RE,
} from "./share.ts";

const H = 3600_000;

Deno.test("tokens are 43 base64url characters and never repeat", () => {
  const seen = new Set<string>();
  for (let i = 0; i < 500; i++) {
    const t = newToken();
    assert(TOKEN_RE.test(t), t);
    seen.add(t);
  }
  assertEquals(seen.size, 500);
});

Deno.test("a token is stored as its SHA-256 hex, never as itself", async () => {
  const t = "A".repeat(43);
  const h = await hashToken(t);
  assert(/^[0-9a-f]{64}$/.test(h));
  assertEquals(h, await hashToken(t));
  assertNotEquals(h, await hashToken("B".repeat(43)));
  assert(!h.includes(t));
});

Deno.test("share URLs use the configured https base, else somalabs.me/f/", () => {
  const t = "x".repeat(43);
  assertEquals(shareUrl(t), `${DEFAULT_SHARE_BASE}${t}`);
  assertEquals(
    shareUrl(t, "https://staging.somalabs.me/f"),
    `https://staging.somalabs.me/f/${t}`,
  );
  assertEquals(shareUrl(t, "http://evil.test/f/"), `${DEFAULT_SHARE_BASE}${t}`);
  assertEquals(shareUrl(t, ""), `${DEFAULT_SHARE_BASE}${t}`);
});

Deno.test("arrival is the gate time, else the runway, else the estimate, else the schedule", () => {
  const base = {
    scheduled_in: "2026-11-03T20:00:00Z",
    estimated_in: "2026-11-03T20:30:00Z",
    actual_on: "2026-11-03T20:20:00Z",
    actual_in: "2026-11-03T20:28:00Z",
  };
  assertEquals(arrivalOf(base), Date.parse("2026-11-03T20:28:00Z"));
  assertEquals(
    arrivalOf({ ...base, actual_in: null }),
    Date.parse("2026-11-03T20:20:00Z"),
  );
  assertEquals(
    arrivalOf({ ...base, actual_in: null, actual_on: null }),
    Date.parse("2026-11-03T20:30:00Z"),
  );
  assertEquals(
    arrivalOf({ scheduled_in: "2026-11-03T20:00:00Z" }),
    Date.parse("2026-11-03T20:00:00Z"),
  );
  // No arrival time at all: a day after departure. No time at all: nothing.
  assertEquals(
    arrivalOf({ scheduled_out: "2026-11-03T08:00:00Z" }),
    Date.parse("2026-11-04T08:00:00Z"),
  );
  assertEquals(arrivalOf({}), null);
});

Deno.test("a share expires 24 hours after arrival, and a delay moves it", () => {
  const created = new Date("2026-11-03T06:00:00Z");
  const onTime = { scheduled_in: "2026-11-03T20:00:00Z" };
  assertEquals(
    shareExpiresAt(onTime, created).toISOString(),
    "2026-11-04T20:00:00.000Z",
  );
  const late = { ...onTime, estimated_in: "2026-11-03T23:10:00Z" };
  assertEquals(
    shareExpiresAt(late, created).toISOString(),
    "2026-11-04T23:10:00.000Z",
  );
  // A flight with no time at all: 48 hours after the share was made.
  assertEquals(
    shareExpiresAt({}, created).toISOString(),
    "2026-11-05T06:00:00.000Z",
  );
});

Deno.test("a share opens until expiry, and never once revoked", () => {
  const f = { scheduled_in: "2026-11-03T20:00:00Z" };
  const share = { created_at: "2026-11-03T06:00:00Z", revoked_at: null };
  const arrival = Date.parse(f.scheduled_in);
  assert(shareIsOpen(share, f, new Date(arrival)));
  assert(shareIsOpen(share, f, new Date(arrival + 24 * H - 1)));
  assert(!shareIsOpen(share, f, new Date(arrival + 24 * H)));
  assert(
    !shareIsOpen(
      { ...share, revoked_at: "2026-11-03T07:00:00Z" },
      f,
      new Date(arrival),
    ),
  );
});

Deno.test("a canceled flight's link closes a day after its planned arrival", () => {
  const canceled = {
    scheduled_out: "2026-11-03T08:00:00Z",
    scheduled_in: "2026-11-03T10:00:00Z",
  };
  const share = { created_at: "2026-11-02T08:00:00Z", revoked_at: null };
  assert(shareIsOpen(share, canceled, new Date("2026-11-04T09:59:00Z")));
  assert(!shareIsOpen(share, canceled, new Date("2026-11-04T10:00:00Z")));
});
