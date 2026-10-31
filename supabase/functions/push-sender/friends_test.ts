// Friend alerts: which alerts a friend hears, their words, and who gets them, on a stand-in database and a
// stand-in APNs (no local stack needed). The watcher query itself is tested in supabase/tests/friends_test.sql.
import { assertEquals } from "jsr:@std/assert@1";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { Alert, AlertFlight } from "../_shared/alerts.ts";
import {
  forFriends,
  FRIEND_DELAY_MIN,
  friendAlertText,
  friendLabel,
} from "../_shared/friend_alerts.ts";
import { deliverToFriends } from "./handler.ts";

const FLIGHT = {
  id: "f2000000-0000-4000-8000-000000000001",
  provider_id: "AFR84-1",
  ident: "AFR84",
  status: "en_route",
  origin_icao: "LFPG",
  origin_iata: "CDG",
  destination_icao: "KSFO",
  destination_iata: "SFO",
  scheduled_out: null,
  scheduled_in: null,
  estimated_out: null,
  estimated_in: null,
  actual_out: null,
  actual_in: null,
} as AlertFlight & { id: string; provider_id: string; [k: string]: unknown };

const alert = (kind: Alert["kind"], minutes?: number): Alert => ({
  kind,
  category: kind.includes("delay") ? "delays" : "takeoff_landing",
  key: kind,
  minutes,
});

Deno.test("friends hear take-off, landing and big delays only", () => {
  const all = [
    alert("takeoff"),
    alert("departed"),
    alert("landing"),
    alert("gate_change"),
    alert("baggage_belt"),
    alert("departure_delay", FRIEND_DELAY_MIN - 1),
    alert("arrival_delay", FRIEND_DELAY_MIN),
    alert("cancel"),
  ];
  assertEquals(forFriends(all).map((a) => a.kind), [
    "takeoff",
    "landing",
    "arrival_delay",
  ]);
  // Gate out and in stand in only when there is no runway time.
  assertEquals(
    forFriends([alert("departed"), alert("arrived")]).map((a) => a.kind),
    ["departed", "arrived"],
  );
});

Deno.test("the words name the friend, never a seat or booking", () => {
  assertEquals(friendAlertText(alert("takeoff"), FLIGHT, "Ada", "🌿"), {
    title: "🌿 Ada is on the way",
    body: "AFR 84 CDG to SFO took off.",
  });
  assertEquals(
    friendAlertText(alert("landing"), FLIGHT, "Ada").title,
    "Ada has landed",
  );
  assertEquals(friendAlertText(alert("arrival_delay", 95), FLIGHT, null), {
    title: "A friend's flight is late",
    body: "AFR 84 CDG to SFO is arriving 1 h 35 min late.",
  });
  assertEquals(friendLabel("  "), "A friend");
});

/** A database answering the watcher RPC, push_tokens and notification_preferences. */
function fakeDb(
  watchers: unknown[],
  tokens: { user_id: string; token: string }[],
  prefs: Record<string, unknown>[] = [],
) {
  const table = (rows: Record<string, unknown>[]) => {
    let out = rows;
    const q = {
      select: () => q,
      eq: (k: string, v: unknown) => {
        out = out.filter((r) => !(k in r) || r[k] === v);
        return q;
      },
      in: (k: string, vs: unknown[]) => {
        out = out.filter((r) => vs.includes(r[k]));
        return q;
      },
      update: () => q,
      delete: () => q,
      then: (ok: (v: unknown) => unknown) =>
        Promise.resolve({ data: out, error: null }).then(ok),
    };
    return q;
  };
  const tokenRows = tokens.map((t) => ({
    ...t,
    kind: "alert",
    updated_at: "2026-11-01T00:00:00Z",
    bad_count: 0,
  }));
  return {
    rpc: (fn: string) =>
      Promise.resolve(
        fn === "friend_alert_watchers"
          ? { data: watchers, error: null }
          : { data: null, error: { message: fn } },
      ),
    from: (name: string) => table(name === "push_tokens" ? tokenRows : prefs),
  } as unknown as SupabaseClient;
}

function ctx(
  db: SupabaseClient,
  sent: { token: string; body: Record<string, unknown> }[],
) {
  const fetchFn = ((url: string, init: RequestInit) => {
    sent.push({
      token: url.split("/").pop()!,
      body: JSON.parse(init.body as string),
    });
    return Promise.resolve(new Response(null, { status: 200 }));
  }) as unknown as typeof fetch;
  return {
    db,
    cfg: {
      teamId: "T",
      keyId: "K",
      p8: "",
      bundleId: "me.somalabs.flight",
      sandbox: true,
    },
    jwt: "jwt",
    fetchFn,
    evict: () => {},
    expiration: 0,
    eventId: "e0000000-0000-4000-8000-000000000001",
  } as unknown as Parameters<typeof deliverToFriends>[0];
}

const W = (watcher: string, owner = "owner-1", name = "Ada") => ({
  watcher_id: watcher,
  owner_id: owner,
  owner_name: name,
  owner_emoji: null,
});

Deno.test("each watcher gets the friend alert on their own devices", async () => {
  const sent: { token: string; body: Record<string, unknown> }[] = [];
  const db = fakeDb([W("b"), W("c")], [{ user_id: "b", token: "tok-b" }, {
    user_id: "c",
    token: "tok-c",
  }]);
  const t = await deliverToFriends(ctx(db, sent), FLIGHT, [
    alert("takeoff"),
    alert("gate_change"),
  ]);
  assertEquals(t.sent, 2);
  assertEquals(sent.map((s) => s.token).sort(), ["tok-b", "tok-c"]);
  assertEquals(
    (sent[0].body.aps as { alert: { title: string } }).alert.title,
    "Ada is on the way",
  );
  assertEquals(sent[0].body.friendId, "owner-1");
  assertEquals(t.kinds, ["friend:takeoff", "friend:takeoff"]);
});

Deno.test("a watcher's own category switch still applies", async () => {
  const sent: { token: string; body: Record<string, unknown> }[] = [];
  const db = fakeDb([W("b")], [{ user_id: "b", token: "tok-b" }], [{
    user_id: "b",
    delays: false,
  }]);
  const t = await deliverToFriends(ctx(db, sent), FLIGHT, [
    alert("departure_delay", 45),
    alert("takeoff"),
  ]);
  assertEquals(t.kinds, ["friend:takeoff"]);
  assertEquals(sent.length, 1);
});

Deno.test("nothing friend-worthy or nobody watching sends nothing", async () => {
  const sent: { token: string; body: Record<string, unknown> }[] = [];
  const db = fakeDb([W("b")], [{ user_id: "b", token: "tok-b" }]);
  assertEquals(
    (await deliverToFriends(ctx(db, sent), FLIGHT, [alert("gate_change")]))
      .sent,
    0,
  );
  const none = fakeDb([], [{ user_id: "b", token: "tok-b" }]);
  assertEquals(
    (await deliverToFriends(ctx(none, sent), FLIGHT, [alert("takeoff")])).sent,
    0,
  );
  assertEquals(sent.length, 0);
});
