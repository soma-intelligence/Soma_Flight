# Add a flight: one search bar that understands what you type

Date: 2026-11-01. Owner approved the design in chat the same day.

## Why

The owner adds flights they are going to take. Today's search only reads a flight number, a route as
two airport codes, or one airport, with the date set apart, and a route only searches today's departure
board. A flight three weeks out cannot be found by route at all. Adding a flight must feel like typing a
sentence: "Paris New York Dec 12" and the right flight is one tap away.

Done in 109e858 already (not part of this spec): Add replaces Follow in the copy, and My Flights rows
slide left to delete.

## What the traveller sees

1. **One field, free order.** Any mix of: a flight number ("AF 84", "af84"), an airline by name or code
   ("Air France", "AF", "AFR"), one or two places (city, airport name or code, with typos as the
   suggester already allows), a date, a time of day. Separators are spaces, commas, "to", "vers", "-".
2. **Chips under the field.** Each understood piece shows as a chip as soon as it is recognised:
   "Air France", "Paris (CDG, ORY)", "Fri Nov 7", "Evening". Tapping a chip's x removes that piece from
   the text. Words nobody understood are left in the field and ignored by the search, so a stray word
   never empties the results.
3. **Ready-made rows on an empty field** (above today's recents): the traveller's upcoming flights not
   yet added, the frequent routes ("CDG to SFO, as usual"), and "Today" and "Tomorrow" shortcuts that
   put a date chip in.
4. **Missing pieces filled in.** The search runs as soon as there is a place, an airline or a number,
   plus a date (today when none is typed):
   - number + date: that flight on that day (today's lookup).
   - two places + date: every flight between them that day, airline and time filters applied.
   - one place + date: every departure that day from that place, grouped by destination, the
     traveller's frequent destinations first.
   - airline + place(s) + date: the same, that airline only.
   - a time of day sorts the rows by distance to it ("morning" 08:00, "midday" 12:00, "afternoon"
     15:00, "evening" 19:00, "night" 22:00, "18h" or "6pm" exactly).
5. **Rows** keep today's look: logo, number, times local to each airport, route, and an Add button that
   turns into Added.
6. **Far flights.** A flight more than two days out is added to the follow-later queue
   (`FollowLaterQueue`, already used by imports) and shows in My Flights at once as a "Planned" row with
   its scheduled times, followed for real two days before it leaves. Deleting that row (swipe or menu)
   drops it from the queue.

## Dates and words understood

English and French, case and accents folded: today/aujourd'hui, tomorrow/demain, day after
tomorrow/après-demain, weekday names (next occurrence, "next Friday"/"vendredi prochain" one week
later), "12 Dec", "Dec 12", "12 décembre", "12/12" (day first when the device region is not US, month
first in the US), "2026-12-12". A date before today means next year for day-month forms. A date more
than 330 days out is refused with a short note under the field (airline schedules do not reach further).

## Architecture

- **`SearchIntent` (new, FlightKit/Search).** Pure parser: text plus `now`, region, the airline and
  airport directories in, a value out with `ident`, `airline`, `origins: [ICAO]`, `destinations: [ICAO]`,
  `day: LocalDay?`, `timeOfDay: Int? (minutes)`, `chips`, `leftover`. A city yields all its airports
  (Paris gives CDG, ORY, BVA only when BVA has scheduled airline service in the bundled data; otherwise
  CDG and ORY). `FlightQuery.parse` stays for the existing callers and is fed from the intent.
- **`FlightService.search(_ intent:)` (new).** Returns rows for the cases above. Within two days it uses
  today's paths (lookup by ident, board for one place, `flight-lookup` route for two). Beyond two days,
  or with an airline and no number, it calls a new backend function.
- **`flight-schedules` (new Edge Function).** `POST { origin?, destination?, airline?, ident?, date }`,
  at least one of origin, destination, ident. Calls AeroAPI `GET /schedules/{start}/{end}` (client
  already in `_shared/aeroapi.ts`, used by alternate-flights) over the origin-local day, codeshares
  off. Cached per query and day in a new `schedules_cache` table for 6 hours, empty answers included,
  shared by all users, served stale when the provider refuses (same pattern as `alternates_cache`).
  Goes through the spend cap and `checkRate` (30 an hour per user, like lookups). Answers plans
  (number, airline, airports, scheduled times, aircraft type), not tracked flights.
- **Adding a planned row** puts an `UpcomingFlight` in the follow-later queue; the queue's existing
  promotion (`HomeModel+Imports`) follows it when it is two days out. My Flights reads the queue to show
  Planned rows.
- **Fakes.** `FakeFlightService` answers `search` from the seed so previews, snapshots and tests run
  offline, and Debug builds work with `BOARD_PROVIDER=none`.

## Cost and release

AeroAPI `/schedules` is billed per page; the client's table guesses $0.02 and marks it UNVERIFIED.
Six-hour shared caching plus the per-user rate keep it near one call per distinct route and day. The
function is written and tested locally; it is deployed only on the owner's yes (production switch-on is
still backend plan Task 10). Until then far-date searches show "Future dates need the live service" in
Release and fake rows in Debug.

## Out of scope

Multi-leg itineraries, prices, seat maps, calendar sync (separate P1 item), Mac-specific layout changes
beyond what the shared view gives.

## Tests

- `SearchIntentTests`: every phrase in this spec in both languages, any order, typos on cities,
  US and non-US day/month order, past day-month rolls to next year, the 330-day limit, leftovers kept.
- `SearchRoutingTests`: each intent picks the right service path (near vs far, with and without airline).
- `flight-schedules` Deno tests: validation, cache hit, stale on refusal, rate limit, spend cap.
- My Flights shows a Planned row from the queue, and deleting it empties the queue entry.
- Device check on the owner's iPhone: add a flight three weeks out by "city city date".
