# Soma Flight: global goal

Set 2026-10-31. Every plan, spec and session on this repo serves this goal. When a task does not move it forward, say so before doing it.

## The goal

**Ship Soma Flight to the public App Store (iPhone and Mac) as the most trustworthy flight tracker a traveller can carry: it tells you what is happening to your flight before the airline does, it keeps a beautiful record of every flight you take, and it never sells, reads or tracks anything about you.**

## What "done" means

The goal is reached when all of these are true at the same time:

1. **Live on the App Store.** Soma Flight for iOS and macOS passed App Review and is downloadable, built from `main`, signed with the Soma Labs team.
2. **Real data in production.** The Supabase project `soma-flight` runs the backend on FlightAware AeroAPI (Standard tier, B2C terms read and met); no screen in a Release build runs on fakes or fixtures.
3. **Proactive, not just reactive.** Gate, delay, cancel, boarding and inbound-plane alerts reach the phone as a push and a Live Activity update within about a minute of the provider alert, with no per-user polling.
4. **History people keep.** Landed flights move to Passport on their own; past flights can be added, edited, imported (CSV) and exported (JSON, CSV).
5. **Bounded cost.** AeroAPI spend stays under the daily cap with shared caching and per-user limits, and the owner gets an email before the cap is hit.
6. **Clean legally.** Privacy policy and support pages answer at `somalabs.me/privacy` and `somalabs.me/support`; account deletion revokes the Apple token; every logo, livery and side view shown is licensed, public domain or ours, and trademark use is cleared.

## Principles (hold on every task)

- **Privacy first.** No ads, no analytics SDK, no tracking, no mailbox access (email import reads only an email the user shares or forwards, on the phone), no contacts, no precise location unless a feature needs it and the user turns it on. Data collected = what the App Store privacy manifest already declares.
- **Our own product.** Inspired by the reference screenshots, never their name, copy, marks or artwork. We never draw an airline trademark ourselves.
- **Ask before money or deploys.** No paid key, licence, purchase, Supabase cloud change or deploy without the owner's explicit yes.
- **Fail closed.** Release builds refuse to run without real config; a missing licence shows a monogram, not a borrowed mark.
- **One codebase.** Rust `flightcore` for logic, `FlightKit` for the shared Swift layer; iOS, macOS, Watch and widgets are shells over it. The web version runs the same `flightcore` through `flightcore-wasm`.

## Priority order

Work in this order. A lower line waits until the line above is done or blocked on the owner.

1. **Release blockers** in [docs/app-store-checklist.md](docs/app-store-checklist.md): Apple agreement and profiles, privacy and support pages, Apple token revocation, AeroAPI terms, review demo account, real-device checks.
2. **Production switch-on**: backend plan Task 10 (Supabase project, secrets, `db push`, `functions deploy`, AeroAPI webhook) and `INSIGHTS_ENABLED` in Release, on the owner's yes.
3. **Proactive layer** (audit P1): more push types, calendar sync, computed "leave now" time.
4. **Store presence**: real screenshots at the required sizes, metadata, age rating, review notes.
5. **Owner additions (2026-10-31)**: a Friends tab between My Flights and Passport; import from Flighty (its CSV export), from the calendar and from shared confirmation emails; ideas from the Soar comparison.
6. **Owner additions (2026-11-08)**: the 40 features listed in [Feature ideas (2026-11-08)](#feature-ideas-2026-11-08) below.
7. **Web version (owner addition, 2026-11-08)**: a public web app that matches the iPad and Mac layout (globe across the window, the tab's screen in a panel on the left, a flight opening in that panel), on the same Supabase backend and accounts. Built with Vite, React and shadcn/ui. Same principles as the apps: no analytics, no tracking, no fakes in production, and no deploy without the owner's yes.
8. **After launch**: P2 and P3 items from [docs/audits/2026-10-30-flighty-pro-audit.md](docs/audits/2026-10-30-flighty-pro-audit.md) and [docs/audits/2026-10-30-soar-diff.md](docs/audits/2026-10-30-soar-diff.md).

## Feature ideas (2026-11-08)

The owner added all of these to the goal. Each one follows the principles above: no tracking, health and photo data stay on the device, every social or location feature is off until the user turns it on, and nothing makes a paid call without the owner's yes.

**Proactive**

1. **Connection at risk.** Cross the inbound delay, the minimum connection time and the gate-to-gate distance; warn before landing ("22 min of margin, gate 15 min away") and offer rebooking options from `alternate-flights`.
2. **Leave-now time.** Drive time (MapKit ETA) plus security wait (`security-wait`) plus bag drop, recomputed when the flight moves.
3. **Pickup mode.** A shared link tells the person collecting the traveller when to leave so they reach the curb on time, not just when the plane lands.

**Health, the Soma side**

4. **Jet lag plan.** Sleep, light and caffeine timing for the 3 days before and after, from the itinerary's time zones, tuned by real sleep from Apple Health, computed on the phone. Built on Prism's engine, shared through WellnessKit's `Circadian` target, and handed to Prism: see [Prism integration](docs/superpowers/specs/2026-11-08-prism-integration-design.md).
5. **Fear of flying mode.** Live explanation of sounds and bumps, the turbulence forecast on the route (free data from aviationweather.gov), guided breathing when the Watch sees the heart rate climb.
6. **Recovery after the flight.** Passport shows what each trip did to the body: sleep, HRV, resting heart rate. On the phone only. See [Prism integration](docs/superpowers/specs/2026-11-08-prism-integration-design.md).
7. **Long-haul care.** Watch reminders to drink and to walk (blood clot risk). Listed as later work in [Prism integration](docs/superpowers/specs/2026-11-08-prism-integration-design.md).

**When things go wrong**

8. **Passenger rights.** After a 3 h delay or a cancellation, say whether EU261 or the US DOT rules apply and what to claim (250 to 600 EUR), and draft the claim letter on the phone. Information, not legal advice; counsel reviews the copy before release.
9. **Cancellation kit.** The airline's phone number, what to ask the agent, a reminder about hotel and meal vouchers for an overnight stay.
10. **Reliability before booking.** "This flight lands late 4 times in 10 in December", from `airport-stats` and stored history.

**At the airport and in the air**

11. **Boarding group timing.** Estimate when the traveller's group boards from the boarding start ("group 5, about 12 min").
12. **Walking connection.** Gate-to-gate walk time, from free OpenStreetMap indoor maps where they exist.
13. **Arrival.** Baggage belt, local time, weather and the way out of the airport.
14. **Offline flight.** Before boarding, download the map, route and flight facts; with no wifi, estimate the position in flight from the schedule and the route ("over Greenland"). No server cost.

**On the device**

15. **Siri and Shortcuts (App Intents).** "Is my flight on time?", plus automations such as a playlist at takeoff.
16. **CarPlay.** Flight status on the drive to the airport, and the arrival time of the person being collected.
17. **Boarding pass on the Watch.** It comes up on its own at the gate.

**Passport and friends**

18. **Year in review.** Shareable cards made on the phone: distance, countries, longest flight, total delay, hours in the air.
19. **Travel journal.** Photos from the day of a flight attached to it, through the limited photo picker (no full library access).
20. **CO2 per flight.** A public, sourced method; no offsets sold.
21. **Aircraft flown.** Tail number of each plane ("you have flown this aircraft 3 times").
22. **Crossing paths.** Two friends in the same airport at the same time both get told; off by default, each one opts in.
23. **Route poster**, ready to print.

**Trust and practical**

24. **Encrypted CloudKit sync with no Soma account.**
25. **Personal MCP server** to reach the user's flight data from Claude and other tools. Open question for the owner: for the owner only, or for every user.
26. **Travel documents.** Passport expiry reminders and visa or ESTA/ETIAS needs by destination (builds on `TravelDocuments`).
27. **Expense export.** One PDF per trip for business travel.

**Predictions (must have, the owner's words: "il le faut")**

They train on the free historical data kept outside the app (US BTS on-time records, airport weather, ATC programs, CBP wait times). Each one shows its confidence and says "probable" until the airline or the agency confirms.

28. **Predicted delay.** Inbound aircraft, weather, ATC programs and NOTAMs give "probable delay 40 min, medium confidence" before the airline announces it.
29. **Predicted gate.** The gate this flight number usually gets, marked probable until the airline confirms it.
30. **Immigration wait.** CBP wait times on arrival in the US, from the public data.

**On device and in the air (added 2026-11-08)**

31. **Flight summaries by Apple Foundation Models.** The flight brief is written on the phone by Apple's on-device model: no cost, nothing leaves the phone, the Azure switch can stay off.
32. **Cabin noise.** The sound level the Watch measures in the cabin, with a reminder to protect the ears.
33. **Cabin pressure.** Why people feel tired in flight (cabin at about 2,400 m), with the Watch SpO2 when the user turns it on.
34. **Window side.** Which side to sit on to see the sunset, the Alps or the city, from the route and the sun's position; works offline.
35. **Sun in flight.** Sunrise and sunset times as seen from the plane.
36. **Landmarks overflown.** An offline notice when the plane passes over a known place ("over Mont Blanc").
37. **Destination card.** Plug type, currency, tipping customs, eSIM reminder and the US State Department advisory level.
38. **Status tracker.** Segments and distance flown this year against the thresholds of the programme the user enters; no airline login.
39. **Schengen 90/180 counter.** Days spent in the Schengen area over any 180-day window, from the flight history, on the phone.
40. **Home-made Wallet pass.** A Wallet card for flights that have none. Needs a Pass Type ID certificate (owner's yes).

## Out of scope until launch

Global radar, track replay, iPad and Vision Pro shells, TripIt import, paid tiers. They come back after the goal is reached.

## Owner actions

These sit with the owner and cannot be done by an agent:

- Apple Program License Agreement accepted by the account holder.
- AeroAPI Standard key and cost approval.
- Logo and side view licences (Airhex or another `LogoProvider`, a `SideViewProvider`), and counsel on airline trademarks.
- Publishing the privacy and support pages on the landing site.
- Every deploy and every purchase.
