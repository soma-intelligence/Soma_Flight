# Soma Flight v1.1: flight detail, Passport stats, aircraft and brand assets

Date: 2026-10-29
Status: draft for owner review
Builds on: `2026-10-28-soma-flight-v1-design.md`

## 1. Goal

Match the second set of reference screenshots (25 images, numbered 29 to 53 in the design reference) screen by screen, with real airline logos, round country flags and side-view aircraft in airline liveries. Same naming rule as v1: Soma Flight only, never the reference app's name, logo, illustrations or copy. No paywall, no "Pro" upsell and no Friends tab (out of v1 scope).

## 2. Owner decisions (2026-10-29)

| Topic | Decision |
|---|---|
| Airline logos | Licensed logo service (Airhex type), commercial licence, cached in the app and the backend |
| Country flags | Open source round flags (circle-flags, MIT), bundled |
| Aircraft side views | Full liveries per airline |
| Data not bought yet | Build every section now on fake data; wire the paid AeroAPI calls after the owner approves the cost |

## 3. Screens

### 3.1 Flight detail (refs 29 to 35)

Sheet header: airline logo, "UA 990 · FRI, 30 OCT", route title, close button. Floating bottom bar: share, notify bell (per-flight switch from Task 12), more menu. No "Get Pro" button.

Sections in order:
1. Countdown card ("Departs in 1 day", or live status).
2. Departure block: IATA, airport name link, big time, status word, gate badge (yellow when assigned), terminal. Duration, distance and "Overnight" line. Arrival block with +1 day marker, terminal.
3. Booking code and seat tiles (tap to edit; stored per follow).
4. Good to Know: per airport, disruption row (from airport severity, links to the airport sheet), departure weather, arrival weather, time zone change ("+8 hours, 10:15 arrival is 02:15 San Francisco time").
5. Arrival forecast: late %, average late, observed flights, bars Early / On time / 15m / 30m / 45m+ / Canceled / Diverted, over the last 60 days for this flight number (paid data, fake until approved).
6. Where's my plane: livery side view, aircraft type, inbound flight chain (paid data, fake until approved).
7. Detailed timetable: gate departure, taxi, take off, land, taxi, gate arrival, air time, total time; scheduled vs estimated vs actual.
8. Airline card: logo, name, alliance, phone, website, X, Facebook buttons, ATC callsign, ICAO, IATA (static airline reference data).
9. My history on this route: flights, distance, flight time, most recent flights with logo, duration, registration and aircraft.
10. Updates: event timeline from `flight_events` (shown in full, never blurred).
11. Notes (tap to edit, stored per follow).
12. Report data issue link (opens mail to support).

### 3.2 My Flights row (ref 36)

Countdown column ("1 DAY"), airline logo, ident, date, route title, departure and arrival codes with times and +1 marker. "Added to My Flights" toast after a follow.

### 3.3 Add Flight (ref 38)

Frequently used: airlines and airports with logo or flag, "Find by Route" row. Search placeholder uses Soma copy.

### 3.4 Passport tab and full Passport (refs 37, 39 to 43, 44, 52, 53)

Passport tab: passport card, delay card, "Most flown aircraft" card with livery side view and "All Aircraft Stats" link.

Full Passport page (purple theme, year chips):
- Header map: flat world map with route arcs, airport dots, ticker of flown airports, row of round flags of visited countries.
- Passport card with machine readable zone strip in Soma Flight wording.
- Flights: total, domestic, international, long haul; per Year / Month / Weekday bar chart.
- Flight distance: km and mi, average, around Earth / to the Moon / around the Sun bars, shortest and longest flight.
- Flight time: hours, days, weeks, months, years, average, in air, taxiing, shortest and longest.
- Top visited airports (connections under 8 hours count once), top airlines with logos (flights or distance), top routes (flights or distance), countries and territories with flags, continents grid.

### 3.5 Aircraft stats (refs 45 to 51)

Light blue theme with blueprint panels:
- Totals: total aircraft, newest, oldest, % by manufacturer.
- Most flown aircraft with livery side view, flights and hours.
- Frequented tail: blueprint tail drawing, registration, name, type, age, flag, airline logo.
- Cabin: class bar and seat type icons, favourite seat.
- Aircraft types bars (flights, time, distance).
- Class and seat donuts (class, seat position, reason).
- Most frequent tails list, aircraft age chart by decade, newest and oldest cards with side views.

New user-entered fields: seat class, seat, reason (personal or business), booking code, notes. Aircraft facts (age, delivery date, tail name) come from a reference dataset, fake until a source is chosen.

## 4. Brand assets

### 4.1 Airline logos

- One `AirlineLogo` view keyed by ICAO code, with a monogram fallback (IATA code on the airline colour) when no logo is cached.
- The backend fetches logos from the licensed service, stores them in a Supabase Storage bucket and serves them to the app; the app caches them on disk. The licence key stays server side.
- Until the licence is signed, development uses the monogram fallback and the service's free demo set only in Debug.

### 4.2 Country flags

circle-flags SVGs bundled as an asset catalog (converted to PDF vectors), keyed by ISO 3166-1 alpha-2, with the licence file in the app's acknowledgements. Airports map to countries through `airports.country`.

### 4.3 Aircraft side views and liveries

- Vector side-view base per aircraft family (A220, A319/A320/A321, A330, A350, A380, 737, 737 MAX, 747, 757, 767, 777, 787, E-Jets, CRJ, ATR), drawn in our own style from public dimensions, with layers: fuselage, windows, doors, wing, engines, tail, gear.
- A livery is data, not a separate drawing: colour regions (fuselage top, belly, cheatline, tail, engines, winglets), title text, and the licensed tail logo placed on the fin. Renderer composes base plus livery in SwiftUI (Canvas or layered shapes) so every airline works on every family.
- First batch: the airlines in the owner's own history (United, Lufthansa, Air France, Air Canada, Transavia, Brussels Airlines, Flair, Ryanair) on the families they fly.
- Blueprint style (line art) of the same bases for the aircraft stats panels.

Legal note: the logo licence covers the provider's artwork. Airline names, logos and liveries are the airlines' trademarks. Before App Store submission the owner confirms with the provider or counsel that showing them in a commercial app is covered (nominative use is the usual basis, but it is not settled here).

## 5. Data model additions

- `user_flights` and `past_flights`: `seat_class`, `seat`, `reason`, `booking_code`, `notes`.
- `airlines` reference table: ICAO, IATA, name, callsign, alliance, country, brand colours, links, `logo_path`.
- `aircraft_types` reference table: ICAO type, family, manufacturer, name.
- `aircraft` (optional, paid or licensed source later): registration, type, delivery date, name.
- Passport stats extended in the Rust core: domestic/international split, per weekday/month/year, distance comparisons, airport visits with the 8 hour connection rule, countries and continents, aircraft and seat stats. Shared fixtures as before.

## 6. Out of scope

Paywall, Friends, live airport disruption advisories text from air traffic control, booking import, aircraft data purchase (separate cost approval).

## 7. Testing

Core fixtures for every new stat; snapshot compares against refs 29 to 53 (iOS) and the Mac equivalents; livery renderer snapshot per airline and family; fallback tests (no logo, unknown country, unknown aircraft family).
