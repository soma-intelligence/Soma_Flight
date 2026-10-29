# Provider check: FlightAware AeroAPI pricing and terms

Checked 2026-10-28. Source for every figure below: https://www.flightaware.com/commercial/aeroapi/ (official FlightAware page, read through a page-to-text fetch, so figures are as rendered there). The page says "Prices may change." Recheck at the moment of purchase.

The FlightAware docs portal (https://www.flightaware.com/aeroapi/portal/documentation) sits behind a login and was not readable. The full terms of service were not read; only the tier feature table on the pricing page was. See "Open unknowns".

## 1. Tiers (official)

| | Personal | Standard | Premium |
|---|---|---|---|
| Monthly minimum | none | $100 | $1,000 |
| Free usage | up to $5/month ($10 for ADS-B feeders) | none stated | none stated |
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
| Airport board (arrivals, departures, scheduled) | `/airports/{id}/flights` | $0.020 |
| Airport arrivals or departures only | `/airports/{id}/flights/arrivals`, `/departures` | not listed separately; assume $0.020 |
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
| Result sets per board refresh (busy airport) | 3 | 3 |
| Airport-hours viewed per month, for the spec's cron refresh | 3,000 | 20,000 |
| Cron refreshes per airport-hour (every 5 min) | 12 | 12 |
| Volume discount | none | none |

These are guesses, not measurements. Unique airports per 5 minute window is implicit in the cache-miss rate: popular airports collapse many opens into one refresh at 10,000 users.

### Result

| Line | 1,000 users | 10,000 users |
|---|---|---|
| Ident lookups at $0.005 | $50 | $500 |
| Route searches at $0.05 | $150 | $1,500 |
| Alert deliveries ($0.02 x 8 per unique flight) | $512 | $3,200 |
| Boards, lazy refresh only (on open when stale) | $252 | $1,800 |
| **Total, lazy boards** | **$964** | **$7,000** |
| Boards, spec cron as written (refresh 1 h after last view) | $2,160 | $14,400 |
| **Total, spec cron** | **$2,872** | **$19,600** |

Per active user per month: about $0.96 and $0.70 with lazy boards.

Findings:
- The $100 minimum does not matter. Usage dominates from the first hundred users.
- The spec's 5 minute cron on boards viewed in the last hour is the largest line and roughly doubles to triples the bill. Refresh only when a user opens a stale board, or keep the cron to a 10 to 15 minute window after the last view and cap it to the top airports.
- Route search at $0.05 is the priciest per call. Cache search results by (route, date) for a few minutes.
- Alerts scale with unique flights, so sharing matters. The share factor is the most uncertain input.
- A Pro price must clear about $1 per user per month in data cost on top of Apple's cut. The free tier (3 flights) costs roughly $0.30 to $0.50.
- Volume discounts exist on Standard and Premium but are not published. Ask sales once usage is real.

## 5. Open unknowns

- Full AeroAPI terms (attribution, caching and retention limits, redistribution of raw records).
- Whether `/airports/{id}/flights/arrivals` and `/departures` carry the same $0.020; only `/airports/{id}/flights` is listed in the text read.
- Volume discount rates.
- Whether an alert delivery bills once per webhook call or per event inside it.
- Cirium: no pricing or terms were checked. It is quote-based and was out of scope for this task.

## Decision needed

Recommendation: AeroAPI, Standard tier ($100/month minimum), not Cirium.

Why:
- FlightAware's own tier table states Standard allows storage and distribution of derivative works for B2C, which is our case. Personal does not, so the personal key stays for internal testing only.
- Prices are public, per call, and small to start: about $1,000 per month at 1,000 active users and about $7,000 at 10,000 with the cost rules tightened. Cirium has no public prices.
- Alerts are webhooks at $0.02 per delivery, with free subscription management, which matches the shared-row design.

Conditions for the owner:
1. Someone reads the full terms of service before the commercial key is bought (attribution and caching limits). If they bar consumer redistribution or require a Premium contract, switch to Cirium.
2. Accept changing two spec rules: lazy board refresh instead of the 5 minute cron on everything viewed in the last hour, and a short cache on route searches.
3. Task 3 (provider calls) may start once the owner confirms AeroAPI. Tasks that do not hit the provider continue meanwhile.
