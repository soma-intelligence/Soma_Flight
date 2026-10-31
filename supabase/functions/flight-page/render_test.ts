// The share page without a database: what it says about a flight at each stage, the map, and the HTML
// itself against a stored snapshot (`UPDATE_SNAPSHOTS=1 deno test -A flight-page/render_test.ts` rewrites
// it after a deliberate change; read the diff before committing).
import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { along, greatCircle, routeMapSvg } from "./map.ts";
import { esc, pickLocale, renderGone, renderPage } from "./render.ts";
import {
  type AirlineRow,
  type AirportRow,
  buildView,
  type FlightRow,
  formatIdent,
  toneFor,
} from "./view.ts";

const CDG: AirportRow = {
  icao: "LFPG",
  iata: "CDG",
  name: "Paris Charles de Gaulle Airport",
  city: "Paris",
  lat: 49.0097,
  lon: 2.5479,
  tz: "Europe/Paris",
};
const SFO: AirportRow = {
  icao: "KSFO",
  iata: "SFO",
  name: "San Francisco International Airport",
  city: "San Francisco",
  lat: 37.6188,
  lon: -122.375,
  tz: "America/Los_Angeles",
};
const AF: AirlineRow = {
  icao: "AFR",
  iata: "AF",
  name: "Air France",
  color_primary: "#002157",
};

/** AF 84, CDG 10:35 to SFO 12:55 local on Tuesday 3 November 2026, gate and belt known. */
function af84(over: Partial<FlightRow> = {}): FlightRow {
  return {
    id: "00000000-0000-0000-0000-000000000084",
    ident: "AF84",
    operator: "AF",
    origin_icao: "LFPG",
    origin_iata: "CDG",
    destination_icao: "KSFO",
    destination_iata: "SFO",
    scheduled_out: "2026-11-03T09:35:00Z",
    estimated_out: null,
    actual_out: null,
    scheduled_in: "2026-11-03T20:55:00Z",
    estimated_in: null,
    actual_in: null,
    actual_off: null,
    scheduled_on: null,
    estimated_on: null,
    actual_on: null,
    gate_origin: "K47",
    gate_destination: "A3",
    terminal_origin: "2E",
    terminal_destination: "I",
    baggage_belt: "6",
    aircraft_type: "B77W",
    status: "scheduled",
    position_lat: null,
    position_lon: null,
    position_at: null,
    updated_at: "2026-11-03T07:58:00Z",
    ...over,
  };
}

const NOW = new Date("2026-11-03T08:00:00Z");
const URL_ = "https://somalabs.me/f/" + "T".repeat(43);

function page(f: FlightRow, now = NOW, logoUrl: string | null = null): string {
  return renderPage({
    view: buildView(f, CDG, SFO, AF, now),
    origin: CDG,
    destination: SFO,
    logoUrl,
    pageUrl: URL_,
    imageUrl: `${URL_}/og.png`,
    appUrl: "https://somalabs.me/flight",
    locale: "en-GB",
    now,
  });
}

Deno.test("idents read like the app's", () => {
  assertEquals(formatIdent("AF84"), "AF 84");
  assertEquals(formatIdent("EZY12"), "EZY 12");
  assertEquals(formatIdent("U21234"), "U2 1234");
  assertEquals(formatIdent("AF"), "AF");
});

Deno.test("delay tones follow the app: 15 and 45 minutes, canceled and diverted first", () => {
  const m = 60_000;
  assertEquals(toneFor(null, "scheduled"), "onTime");
  assertEquals(toneFor(14 * m + 59_000, "scheduled"), "onTime");
  assertEquals(toneFor(15 * m, "scheduled"), "late");
  assertEquals(toneFor(45 * m, "en_route"), "veryLate");
  assertEquals(toneFor(90 * m, "canceled"), "canceled");
  assertEquals(toneFor(0, "diverted"), "diverted");
});

Deno.test("before departure: on time or delayed, with a countdown and no progress", () => {
  const v = buildView(af84(), CDG, SFO, AF, NOW);
  assertEquals(v.status, { text: "On time", tone: "onTime" });
  assertEquals(v.countdown, "Departs in 1h 35m");
  assertEquals(v.progress, null);
  assertEquals(v.flown, null);
  const late = buildView(
    af84({ estimated_out: "2026-11-03T10:25:00Z" }),
    CDG,
    SFO,
    AF,
    NOW,
  );
  assertEquals(late.status, { text: "Delayed", tone: "veryLate" });
  assertEquals(late.origin.label, "Estimated");
});

Deno.test("in the air: progress by the clock, and a fresh reported position", () => {
  const f = af84({
    status: "en_route",
    actual_out: "2026-11-03T09:40:00Z",
    actual_off: "2026-11-03T10:00:00Z",
    estimated_in: "2026-11-03T21:05:00Z",
    estimated_on: "2026-11-03T21:00:00Z",
    position_lat: 60.1,
    position_lon: -40.2,
    position_at: "2026-11-03T15:20:00Z",
  });
  const now = new Date("2026-11-03T15:30:00Z");
  const v = buildView(f, CDG, SFO, AF, now);
  assertEquals(v.status.text, "In the air");
  assertEquals(v.countdown, "Lands in 5h 35m");
  assertEquals(Math.round(v.progress! * 100), 50);
  assertEquals(v.flown, v.progress);
  assertEquals(v.position, { lat: 60.1, lon: -40.2 });
  // A position older than half an hour is not drawn.
  const stale = buildView(f, CDG, SFO, AF, new Date("2026-11-03T16:00:00Z"));
  assertEquals(stale.position, null);
});

Deno.test("down: landed or arrived, the whole route flown, no progress bar", () => {
  const f = af84({
    status: "arrived",
    actual_out: "2026-11-03T09:40:00Z",
    actual_on: "2026-11-03T20:40:00Z",
    actual_in: "2026-11-03T20:50:00Z",
  });
  const v = buildView(f, CDG, SFO, AF, new Date("2026-11-03T21:15:00Z"));
  assertEquals(v.status, { text: "Arrived", tone: "onTime" });
  assertEquals(v.countdown, "Landed 25m ago");
  assertEquals(v.progress, null);
  assertEquals(v.flown, 1);
  assertEquals(v.destination.label, "Arrived");
});

Deno.test("canceled and diverted say so in their colours", () => {
  assertEquals(
    buildView(af84({ status: "canceled" }), CDG, SFO, AF, NOW).status,
    {
      text: "Canceled",
      tone: "canceled",
    },
  );
  assertEquals(
    buildView(af84({ status: "diverted" }), CDG, SFO, AF, NOW).status,
    {
      text: "Diverted",
      tone: "diverted",
    },
  );
});

Deno.test("the great circle bends north and stays continuous across the antimeridian", () => {
  const arc = greatCircle(CDG, SFO);
  assertEquals(arc.length, 65);
  assert(
    Math.max(...arc.map((p) => p.lat)) > 58,
    "CDG to SFO bends far north of both ends",
  );
  const tokyo = { lat: 35.55, lon: 139.78 };
  const pacific = greatCircle(SFO, tokyo);
  for (let i = 1; i < pacific.length; i++) {
    assert(
      Math.abs(pacific[i].lon - pacific[i - 1].lon) < 20,
      "no jump at 180",
    );
  }
  assert(
    pacific[pacific.length - 1].lon < -180,
    "Tokyo is reached westward, past -180",
  );
  const mid = along(arc, 0.5);
  assert(mid.lat > 55);
});

Deno.test("the map is plain SVG: the land repeats across the antimeridian, no outside links", () => {
  const svg = routeMapSvg(
    { origin: SFO, destination: { lat: 35.55, lon: 139.78 } },
    560,
    280,
  );
  assert(svg.startsWith("<svg"));
  assertEquals((svg.match(/<path /g) ?? []).length, 2);
  assert(!/https?:\/\/(?!www\.w3\.org)/.test(svg));
  const local = routeMapSvg(
    {
      origin: CDG,
      destination: SFO,
      progress: 0.5,
      plane: { lat: 60, lon: -40 },
    },
    560,
    280,
  );
  assertEquals((local.match(/<path /g) ?? []).length, 1);
  assertEquals((local.match(/<polyline /g) ?? []).length, 2);
});

Deno.test("the page escapes data and shows no account data", () => {
  const html = page(af84({ gate_origin: `<script>alert(1)</script>` }));
  assert(!html.includes("<script>"));
  assertStringIncludes(html, "&lt;script&gt;");
  assertEquals(esc(`"'<>&`), "&quot;&#39;&lt;&gt;&amp;");
  // The page's inputs carry no seat, booking code or notes: the words never appear.
  for (const word of ["Seat", "Booking", "Notes", "Confirmation"]) {
    assert(!html.includes(word), word);
  }
});

Deno.test("the page refreshes every minute and carries Open Graph tags", () => {
  const html = page(af84());
  assertStringIncludes(html, `<meta http-equiv="refresh" content="60">`);
  assertStringIncludes(
    html,
    `<meta property="og:title" content="AF 84 · Paris to San Francisco">`,
  );
  assertStringIncludes(
    html,
    `<meta property="og:image" content="${URL_}/og.png">`,
  );
  assertStringIncludes(html, `<meta property="og:url" content="${URL_}">`);
  assertStringIncludes(
    html,
    `href="https://somalabs.me/flight">Get Soma Flight</a>`,
  );
  assert(!html.includes("<script"));
});

Deno.test("a logo shows as an image, else the airline's monogram", () => {
  assertStringIncludes(
    page(af84()),
    `<div class="mark mono" style="background:#002157" aria-hidden="true">AF</div>`,
  );
  assertStringIncludes(
    page(
      af84(),
      NOW,
      "https://x.supabase.co/storage/v1/object/sign/a.png?token=t",
    ),
    `<img class="mark" src="https://x.supabase.co/storage/v1/object/sign/a.png?token=t"`,
  );
});

Deno.test("locales come from Accept-Language, en-US when none fits", () => {
  assertEquals(pickLocale("fr-FR,fr;q=0.9,en;q=0.8"), "fr-FR");
  assertEquals(pickLocale(null), "en-US");
  assertEquals(pickLocale("*"), "en-US");
  assertEquals(pickLocale("not a locale!!"), "en-US");
});

Deno.test("the closed link page names nothing", () => {
  const html = renderGone("https://somalabs.me/flight");
  assertStringIncludes(html, "This flight is no longer shared");
  assert(!html.includes("og:"));
});

const SNAPSHOT = new URL(
  "./__snapshots__/page_af84_en_route.html",
  import.meta.url,
);

Deno.test("the page in the air matches its snapshot", async () => {
  const html = page(
    af84({
      status: "en_route",
      actual_out: "2026-11-03T09:52:00Z",
      actual_off: "2026-11-03T10:10:00Z",
      estimated_in: "2026-11-03T21:12:00Z",
      estimated_on: "2026-11-03T21:05:00Z",
      updated_at: "2026-11-03T15:27:00Z",
    }),
    new Date("2026-11-03T15:30:00Z"),
  );
  if (Deno.env.get("UPDATE_SNAPSHOTS") === "1") {
    await Deno.mkdir(new URL("./__snapshots__/", import.meta.url), {
      recursive: true,
    });
    await Deno.writeTextFile(SNAPSHOT, html);
  }
  assertEquals(html, await Deno.readTextFile(SNAPSHOT));
});
