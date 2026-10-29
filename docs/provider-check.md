# Provider check: FlightAware AeroAPI pricing and terms

Checked 2026-10-28. Source for every figure below: https://www.flightaware.com/commercial/aeroapi/ (official FlightAware page, read through a page-to-text fetch, so figures are as rendered there). The page says "Prices may change." Recheck at the moment of purchase.

The FlightAware docs portal (https://www.flightaware.com/aeroapi/portal/documentation) sits behind a login and was not readable. The full terms of service were not read; only the tier feature table on the pricing page was. See "Open unknowns".

## 1. Tiers (official)

| | Personal | Standard | Premium |
|---|---|---|---|
| Monthly minimum | none | $100 | $1,000 |
| Free usage | up to $5/month ($10 for ADS-B feeders), Personal only | none stated on the page | none stated on the page |
| Rate limit | 10 result sets/minute | 5 result sets/second | 100 result sets/second |
| Alerts | not included | included | included |
| History | not included | 500,000 result sets/month | 500,000 result sets/month |
| Volume discounts | no | yes (terms not published) | yes (terms not published) |

A result set is 15 records. Per-endpoint prices are the same across tiers, charged per result set; a query that returns more than 15 records costs one set per page.

## 2. Per-endpoint prices (official, per result set)

| Need | AeroAPI endpoint | Price |
|---|---|---|
| Flight by ident | `/flights/{ident}` (listed as "flight info") | $0.005 |
| Flight search (route, filters) | `/flights/search` | $0.050 |
| Advanced search | `/flights/search/advanced` | $0.050 |
| Airport board, combined | `/airports/{id}/flights` | $0.020 |
| Airport arrivals, departures, scheduled arrivals, scheduled departures | `/airports/{id}/flights/arrivals`, `/departures`, `/scheduled_arrivals`, `/scheduled_departures` | $0.005 each (re-read on the official page, 2026-10-28) |
| Airport delays | `/airports/delays` (all) / `/airports/{id}/delays` | $0.050 / $0.010 |
| Alert delivery (callback to our webhook) | push alert | $0.020 per delivery |
| Create, read, modify, delete alerts and callback URL | `/alerts` | $0.000 |
| Position / track | `/flights/{id}/position`, `/track` | $0.010 / $0.012 |
| Airport weather | `/airports/{id}/weather/*` | $0.002 (not needed, we use aviationweather.gov) |

## 3. Terms: can a paid consumer app show the data?

Official tier feature table, Standard column: "Storage and distribution of derivative works for business or business-to-consumer purposes." So Standard ($100 minimum) covers B2C, which is a public App Store app. Personal is limited to personal or academic use and must not ship in the app. Premium adds B2B.

Caveats: this is the marketing feature table, not the signed agreement. Attribution rules, cache or retention limits, and any ban on resale of raw data are in the full terms and need a read before purchase.

## 4. Monthly cost estimate

Rules from the spec: followed flights are shared rows (one alert per real flight), board snapshots live 5 minutes, alerts are pushed by webhook and never polled.

### Assumptions (per active user per month unless noted)

| Assumption | 1,000 users | 10,000 users |
|---|---|---|
| Ident lookups (`/flights/{ident}`, 1 set) | 10 | 10 |
| Route or filter searches (`/flights/search`, 1 set) | 3 | 3 |
| Flights followed | 4 | 4 |
| Share factor (unique real flights / follows) | 0.8 | 0.5 |
| Alert deliveries per unique flight | 8 | 8 |
| Airport sheet opens | 6 | 6 |
| Opens that miss the 5 min cache (lazy refresh) | 70% | 50% |
| Result sets per board refresh (4 endpoints: departures, scheduled_departures, arrivals, scheduled_arrivals, 2 sets each at a busy airport, $0.005 per set) | 8 = $0.04 | 8 = $0.04 |
| Airports viewed per day | 25 | 80 |
| Hours per day each has a viewer in the last hour | 4 | 8 |
| Airport-hours per month (airports x hours x 30), for the spec's cron | 3,000 | 19,200 |
| Cron refreshes per airport-hour (every 5 min) | 12 = $0.48 | 12 = $0.48 |
| Volume discount | none | none |

Airports per day and hours per day are guesses, not measurements, as are all other inputs. Unique airports per 5 minute window is implicit in the cache-miss rate: popular airports collapse many opens into one refresh at 10,000 users.

### Result

| Line | 1,000 users | 10,000 users |
|---|---|---|
| Ident lookups at $0.005 | $50 | $500 |
| Route searches at $0.05 | $150 | $1,500 |
| Alert deliveries ($0.02 x 8 per unique flight) | $512 | $3,200 |
| Boards, lazy refresh only (4,200 / 30,000 refreshes x $0.04) | $168 | $1,200 |
| **Total, lazy boards** | **$880** | **$6,400** |
| Boards, spec cron as written (3,000 / 19,200 airport-hours x $0.48) | $1,440 | $9,216 |
| **Total, spec cron** | **$2,152** | **$14,416** |

Per active user per month: about $0.88 and $0.64 with lazy boards.

These totals are a floor. They exclude the $100 monthly minimum (it only bites below about $100 of usage) and extra calls such as position and track ($0.010 and $0.012 per set), which a map or live view would add. Weather is free from aviationweather.gov.

Findings:
- The $100 minimum does not matter. Usage dominates from the first hundred users.
- With the real arrivals/departures prices, boards are cheap when refreshed lazily (about 19% of the bill at 1,000 users and 19% at 10,000). The spec's 5 minute cron on boards viewed in the last hour makes the board line 8.6 times larger at 1,000 users and 7.7 times larger at 10,000, and the total 2.4 times and 2.3 times the lazy total ($2,152 vs $880, $14,416 vs $6,400). Lazy refresh on view is the right call; alerts are then the largest line.
- Route search at $0.05 is the priciest per call. Cache search results by (route, date) for a few minutes.
- Alerts scale with unique flights, so sharing matters. The share factor is the most uncertain input.
- A Pro price must clear about $1 per user per month in data cost on top of Apple's cut. The free tier (3 flights) costs roughly $0.30 to $0.50.
- Volume discounts exist on Standard and Premium but are not published. Ask sales once usage is real.

Controller ruling: boards refresh lazily on view (no 5 min cron); route searches cached 10 min.

## 5. Open unknowns

- Full AeroAPI terms (attribution, caching and retention limits, redistribution of raw records).
- How many result sets a real busy-airport board spans (assumed 2 per endpoint).
- Volume discount rates.
- Whether an alert delivery bills once per webhook call or per event inside it.
- Cirium: no pricing or terms were checked. It is quote-based and was out of scope for this task.

## Decision needed

Recommendation: AeroAPI, Standard tier ($100/month minimum), not Cirium.

Why:
- FlightAware's own tier table states Standard allows storage and distribution of derivative works for B2C, which is our case. Personal does not, so the personal key stays for internal testing only.
- Prices are public, per call, and small to start: about $900 per month at 1,000 active users and about $6,400 at 10,000 with lazy boards. Cirium has no public prices.
- Alerts are webhooks at $0.02 per delivery, with free subscription management, which matches the shared-row design.

Conditions for the owner:
1. Someone reads the full terms of service before the commercial key is bought (attribution and caching limits). If they bar consumer redistribution or require a Premium contract, switch to Cirium.
2. Accept changing two spec rules: lazy board refresh instead of the 5 minute cron, and a short cache on route searches (see the controller ruling).
3. Task 3 (provider calls) may start once the owner confirms AeroAPI. Tasks that do not hit the provider continue meanwhile.

## 6. Endpoint cost notes added with the AeroAPI client (2026-10-29)

The AeroAPI OpenAPI file (4.17.1) publishes no prices, so these come from the pricing page figures in section 2 or are marked unverified.

| Endpoint used by the client | Price per result set | Status |
|---|---|---|
| `/flights/{ident}` | $0.005 | official pricing page |
| `/flights/{id}/position` | $0.010 | official pricing page (section 2) |
| `/airports/{id}/flights/departures`, `/arrivals`, `/scheduled_departures`, `/scheduled_arrivals` | $0.005 each | official pricing page |
| `/airports/{id}/flights/to/{dest_id}` (route search) | $0.020 assumed | UNVERIFIED: not listed on the pricing page; the combined board price is used as a stand-in. Confirm before purchase. |
| `/alerts`, `/alerts/{id}` | $0.000 | official pricing page |

`/flights/search` is no longer used (it returns only airborne flights).
