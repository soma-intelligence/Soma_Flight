# Backend operations

## Scheduled jobs (pg_cron, UTC)

Created by `supabase/migrations/20261029000004_jobs.sql` (and `usage-alert-cap` by `20261029000008_spend_cap.sql`). List them with `select jobname, schedule from cron.job;`
and see runs in `cron.job_run_details`.

| Job | Schedule | What it runs |
| --- | --- | --- |
| `archive-landed-flights` | `0 * * * *` | `archive_landed_flights()`: followers of flights that arrived, landed, were canceled or diverted more than an hour ago move to `past_flights` (24 hours before migration 20261103000001; the app hides them from My Flights and shows them in Passport at the same hour, `LandedFlights`). Stuck flights (scheduled, departed, en_route or unknown, arrival time 72 h past, no update for 48 h) are archived as completed when they left, otherwise their follows are dropped with no row |
| `maintenance-alerts` | `5 * * * *` | `maintenance?mode=alerts`: deletes provider alerts of flights nobody follows (just archived, or a failed unfollow), keeps `alert_id` when the provider delete fails |
| `maintenance-prune` | `30 3 * * *` | `maintenance?mode=prune`: rate events older than 2 h, route cache older than 1 h, snapshots not viewed for 7 days, processed webhook rows older than 30 days, events older than 90 days of unfollowed flights (batches of 5000 rows until one comes back short, at most 20 batches per table per run) |
| `usage-alert` | `0 8-11 * * *` | `usage-alert`: emails the owner once when yesterday's estimated AeroAPI spend is above the threshold; the later runs retry a failed send and do nothing once it went out |
| `usage-alert-cap` | `20 * * * *` | `usage-alert?mode=cap`: emails the owner once a day when today's running spend reaches 80% of the daily cap |
| `brand-logos-sync` | `17 * * * *` | `brand-assets-sync?mode=logos&limit=50`: logos, dark logos, tails and brand colours for the 50 airlines never checked or checked over 7 days ago, oldest first. 2,050 airlines are all checked within two days, then each again once 7 days old, which is the weekly refresh. A no-op until the logo provider is configured (below) |
| `brand-side-views-sync` | `41 * * * *` | `brand-assets-sync?mode=side_views&limit=100`: side views (airline livery on one aircraft type) from the side view provider, up to 100 files a run; pairs whose version is unchanged cost no fetch. A no-op until `SIDE_VIEW_PROVIDER` is configured (below) |
| `cron-history-prune` | `45 3 * * *` | deletes `cron.job_run_details` rows older than 7 days |
| `insights-cache-prune` | `50 3 * * *` | deletes `forecast_cache` and `inbound_cache` rows fetched more than 2 days ago (`20261030000011_insights_cache.sql`) |
| `llm-brief-cache-prune` | `55 3 * * *` | deletes `llm_brief_cache` rows older than a day (`20261107000040_llm_brief_cache.sql`) |
| `faa-status-sweep` | `*/5 * * * *` | `faa-status?mode=sweep`: reads the FAA's NAS status (free, no key) and sends the `airport_program` alert for each new ground stop, ground delay program or closure that holds a followed flight (`20261030000019_faa.sql`) |
| `faa-notam-cache-prune` | `57 3 * * *` | deletes `faa_notam_cache` rows fetched more than a day ago |
| `provider-poll` | `*/5 * * * *` | `maintenance?mode=poll`: the polling refresh of followed flights for a status provider without a webhook (`20261031000027_free_providers.sql`, docs/free-providers.md). Answers `{ skipped }` and calls nothing while `STATUS_PROVIDER` is `aeroapi` or `none` |
| `provider-quota-prune` | `10 4 * * *` | deletes `provider_quota` periods older than three months and `provider_polls` rows of flights nobody follows |

Boards are not refreshed by a job: `airport-board` refreshes lazily on read.

pg_net does not act on the answer of a function. To see what the last calls returned (pg_net keeps
responses for about 6 hours):

```sql
select id, status_code, content::text, error_msg, created
from net._http_response order by created desc limit 20;
select jobname, status, return_message, start_time
from cron.job_run_details join cron.job using (jobid) order by start_time desc limit 20;
```

## Function grants

No function in `public` is a client API. Every one is closed to PUBLIC, anon and authenticated, and
`supabase/tests/archive_test.sql` fails if one becomes executable by anon or authenticated (its
allow-list is empty). Postgres gives PUBLIC execute on every new function by default, so a new
function in `public` needs its own `revoke execute ... from public, anon, authenticated`.

## Vault secrets (read by pg_net jobs)

`invoke_edge_function(name, query)` reads two secrets from `vault.decrypted_secrets` by name. Without
them the function logs a warning and the job posts nothing.

| Name | Value |
| --- | --- |
| `functions_base_url` | `https://<project-ref>.supabase.co/functions/v1` |
| `service_role_key` | the project's service role key (a JWT whose role is service_role, since the functions run with `verify_jwt = true`) |

Create them once per environment in the SQL editor, never in a migration or a committed file:

```sql
select vault.create_secret('https://<project-ref>.supabase.co/functions/v1', 'functions_base_url');
select vault.create_secret('<service role key>', 'service_role_key');
-- to rotate: select vault.update_secret(id, '<new value>') from vault.secrets where name = 'service_role_key';
```

## Function secrets

| Function | Secret | Notes |
| --- | --- | --- |
| `maintenance` | `AEROAPI_KEY` | alerts mode only |
| every AeroAPI caller | `AEROAPI_DAILY_CAP_USD` | global daily spend cap in USD, default 50 (below) |
| `usage-alert` | `AEROAPI_DAILY_CAP_USD` | the cap mode alerts at 80% of it; set it on `usage-alert` too |
| `brand-assets-sync` | `LOGO_PROVIDER`, `AIRHEX_KEY` | set after the licence is signed: `LOGO_PROVIDER=airhex` and the licensed key. Until both are set the function answers `{ skipped: "provider not configured" }` and does nothing, which is the production state |
| `brand-assets-sync` | `SIDE_VIEW_PROVIDER`, `SIDE_VIEW_BASE` | unset in production until the owner picks and signs a side view provider (Logostream API or Airliners Illustrated delivery); the licensed adapter is added to `brand-assets-sync/index.ts` then. `SIDE_VIEW_PROVIDER=recorded` with `SIDE_VIEW_BASE` (an http(s) URL of a fixture folder) replays recorded files for local rehearsals. Unset, `mode=side_views` answers `{ skipped: "provider not configured" }` |
| `usage-alert` | `RESEND_API_KEY`, `OWNER_EMAIL` | required to send; missing gives 503 |
| `usage-alert` | `USAGE_ALERT_USD` | threshold in USD, default 25 |
| `usage-alert` | `USAGE_ALERT_FROM` | sender, default `Soma Flight <alerts@somalabs.me>` (domain must be verified in Resend) |
| `faa-notams` | `FAA_NOTAM_CLIENT_ID`, `FAA_NOTAM_CLIENT_SECRET` | the owner's FAA developer account (api.faa.gov, the NOTAM API app's client id and secret; free). Until both are set the function answers `configured: false` and the app shows no NOTAMs, which is the production state. `supabase secrets set FAA_NOTAM_CLIENT_ID=... FAA_NOTAM_CLIENT_SECRET=...` turns it on at once (unconfigured answers are never cached) |
| `faa-notams` | `FAA_NOTAM_URL` | optional: the endpoint, default `https://external-api.faa.gov/notamapi/v1/notams`, should the FAA move it |
| `flight-lookup`, `follow-flight`, `maintenance` | `STATUS_PROVIDER` | `aeroapi` (default when unset), `aviationstack`, `flightlabs` or `none`. Anything other than `aeroapi` makes no AeroAPI alerts and turns on the polling refresh (docs/free-providers.md) |
| `airport-board` | `BOARD_PROVIDER` | `aeroapi` (default), `aviationstack`, `flightlabs` or `none` |
| `flight-position` | `POSITION_PROVIDER` | `aeroapi` (default), `aviationstack`, `flightlabs`, `opensky` or `none` |
| provider callers | `AVIATIONSTACK_KEY`, `FLIGHTLABS_KEY`, `OPENSKY_CLIENT_ID`, `OPENSKY_CLIENT_SECRET` | the provider keys; OpenSky also works without its pair (anonymous) |
| provider callers | `AVIATIONSTACK_MONTHLY_QUOTA`, `FLIGHTLABS_MONTHLY_QUOTA`, `OPENSKY_DAILY_CREDITS` | the plan's allowance, default the free tier (100, 50, 400; 4,000 for OpenSky with an account). Set it to the paid plan's number after an upgrade |
| `maintenance` | `POLL_QUOTA_SHARE`, `POLL_POINTS` | share of each allowance the poller may use (default 0.7) and `extended` for eight polls a flight instead of four |
| provider callers | `AVIATIONSTACK_BASE_URL`, `AVIATIONSTACK_ALLOW_HTTP`, `AVIATIONSTACK_TIMES`, `FLIGHTLABS_BASE_URL` | optional. An `http://` Aviationstack base is refused on the hosted project whatever `AVIATIONSTACK_ALLOW_HTTP` says (the key travels in the query string). `AVIATIONSTACK_TIMES=utc` if a real answer shows its times are UTC (default `local`) |

The spend alert claims the day in `usage_alerts` before sending and sets `sent_at` after, so it sends at
most one email per UTC day. A failed send releases the claim and the next hourly run retries; a claim
left by a crash (no `sent_at`) is taken over after 15 minutes. Trigger it by hand with
`select public.invoke_edge_function('usage-alert');`.

## Turning on the language-model texts

Off by default on both sides. To switch on, after the owner says yes on cost:

1. Apply `20261107000040_llm_brief_cache.sql` and deploy `flight-brief`.
2. `supabase secrets set LLM_ENABLED=true AZURE_OPENAI_ENDPOINT=https://<resource>.openai.azure.com AZURE_OPENAI_API_KEY=<key>` (and `AZURE_OPENAI_DEPLOYMENT` if the deployment is not `gpt-6-luna`). Optionally set `LLM_CALL_COST_USD` to the measured cost of one call.
3. Set `LLM_ENABLED = YES` in the xcconfigs of the build that should show the sections.

Spend: a model call is counted as endpoint `llm:flight-brief` in `usage_counters` and counts against the same daily cap as AeroAPI, so a busy day of texts can use the budget AeroAPI needs: watch `select endpoint, calls, estimated_cost from usage_counters where day = current_date;`. Switch off at once with `supabase secrets set LLM_ENABLED=false`.

## Daily AeroAPI spend cap

Every AeroAPI request goes through the usage counter (`usageCounter` in `_shared/limits.ts`), which calls
`charge_usage(day, endpoint, cost, cap)` before the request is sent. When today's (UTC) estimated
spend in `usage_counters` plus the request's cost would pass `AEROAPI_DAILY_CAP_USD` (default 50), the
request is not sent and not counted, and the caller gets `provider_unavailable` (503):

- `airport-board` serves the stale snapshot when it has one;
- `flight-lookup` route searches still serve the 10 minute route cache; ident searches and new routes fail;
- `flight-position` answers the stored row (no new position);
- `follow-flight` only creates and deletes alerts, which cost 0 and always pass, so follows of stored
  flights, unfollows and the alert sweep keep working (following an airport board row the app has not
  stored yet needs an ident lookup first, which fails).

Alert deliveries are billed by the provider whatever we do; `process_alert` counts them and they use
the day's budget. The cap resets at 00:00 UTC. To lift it for the rest of the day, set a higher
`AEROAPI_DAILY_CAP_USD` (`supabase secrets set AEROAPI_DAILY_CAP_USD=80`); the functions read it on
their next cold start.

The intraday alert (`usage-alert-cap`, hourly at :20) emails the owner the first time in a UTC day
that the running spend reaches 80% of the cap. It is claimed as kind `cap` in `usage_alerts`, apart
from the morning email about yesterday (kind `daily`), so each sends at most once a day. Trigger it by
hand with `select public.invoke_edge_function('usage-alert', 'mode=cap');`.

Today's spend so far:

```sql
select endpoint, calls, estimated_cost from usage_counters where day = (now() at time zone 'utc')::date
order by estimated_cost desc;
```

## Logo and brand colour sync

- `brand-assets-sync` pulls logos and colours from a provider through the `LogoProvider` port (`_shared/brand/`). A provider declares its `kinds` (`logo`, `logo_dark`, `wordmark`, `tail_logo`, `side_view`; Commons serves `logo` and `wordmark`), whether it has colours, and a rank. `LOGO_PROVIDER=airhex` (with `AIRHEX_KEY`) or `LOGO_PROVIDER=commons` selects one; anything else is a no-op.
- Precedence: licensed provider (Airhex, rank 2) over Commons (rank 1) over nothing. A stored asset from a higher-ranked provider is never replaced by a lower one (the lower one is not even asked); a lower-ranked row is replaced as soon as the higher provider has the file. Equal ranks never replace each other. The same rank order guards colours: `colors_source = 'locked'` is never overwritten, and a lower-ranked provider never overwrites a higher one's colours. Provider colours do replace curated `seed` colours (intended: the seed is a placeholder until a provider answers; lock a livery colour to keep it).
- Validation, for every provider, before upload (`_shared/brand/validate.ts`). **SVG is never stored or served**: a vector is rasterised at sync with resvg (WASM, npm `@resvg/resvg-wasm` 2.6.2, vendored in `_shared/brand/resvg/` and shipped as a static file; it runs no scripts, loads no fonts and fetches nothing) to PNGs on a transparent background, 384 px on the long side (the stored asset, `path`) and 192 px (`path_small`). Before rendering an SVG must be at most 512 KB, UTF-8, an `<svg` document, with no DOCTYPE carrying an internal subset, a SYSTEM id or a non-W3C PUBLIC id, and no ENTITY/ATTLIST/ELEMENT declaration; otherwise it is refused. Rasters (PNG, WebP; mime on the allow-list `image/png`, `image/webp`, matching the format) are at most 2 MB, the declared size is read from the header before any decode and must be 1 to 4096 px per side with the long side at least 192, and a PNG must pass a full chunk walk (CRCs right, IDAT present, IEND last and final). Provider bodies are read with a running byte cap, so an oversize body is cut off while streaming. A refused file counts as a miss, is logged with the reason and never replaces an existing row. One Commons file (FJI) is refused for its DTD.
- Conditional fetch: the stored etag (Airhex: `If-None-Match`, 304) or version (Commons: manifest sha256) goes to the provider, which answers "unchanged"; only `checked_at` moves and no body is downloaded.
- Outage: 5xx, 429 and network errors are retried (three attempts, with a 1 s then a 2 s pause), then the run stops with 502 `{ ok: false, stoppedBy: "provider_unavailable" }` without stamping any airline; the next hourly tick retries. Bad data for one airline only fails that airline (stamped back about a day).
- Budget per run: 100 s and 400 provider requests. What is left is reported as `deferred` and picked up next tick. Every answer carries a summary (`checked, changed, added, failed, unchanged, missed, skipped, rejected, dropped, deferred, requests, ms, stoppedBy`).
- Misses: when a provider has no file for an airline and kind (or sent one validation refused), `airline_asset_misses` remembers it for a day per provider, so a retry inside the day does not ask again. A row the same provider stops offering is deleted with its object. Airlines are otherwise rechecked weekly (`airlines.logo_checked_at`).
- A new provider version is a new object (`logos/<ICAO>/<kind>-<version>.png` and `...-<version>-small.png`, `side-views/<ICAO>/<TYPE>-<version>.png`); the old object is removed after the row points at the new one.
- Manual resync of a few airlines: `POST /brand-assets-sync?mode=logos&icao=UAL,AFR` with the service role key.
- The key is sent only as an MD5 digest (`md5apikey`) and redacted from any error text.
- Licence checklist (TODO when the Airhex licence is signed): re-record `_shared/fixtures/airhex/` against the live account, re-check the URL shapes in `_shared/brand/airhex.ts` (they were written from the public documentation with no key, so `sendsKeyAsDocumented` and the other Airhex tests are a contract to re-verify, not a recording), then set `LOGO_PROVIDER=airhex` and `AIRHEX_KEY` as function secrets.
- Local demo key: none exists. If one is obtained, it goes only in `supabase/functions/.env.local` (git-ignored). It is never set as a project secret.

## Side view sync

- `brand-assets-sync?mode=side_views` pulls side views through the `SideViewProvider` port (`_shared/brand/side_view_provider.ts`): `list()` returns airline and aircraft type pairs with a version (and optionally which way the nose points), `file(icao, type)` returns one file. `FakeSideViewProvider` and `RecordedSideViewProvider` (replays `_shared/fixtures/side_views/`, test images made for this repo) are the only implementations until a provider is licensed.
- A pair is fetched when it has no row, its version or nose changed, or a lower-ranked provider owns the row; unchanged pairs only get `checked_at` moved, with no fetch. `limit` (default 100) caps files fetched per run. Pairs for airlines missing from `airlines` are skipped and counted as `unknownAirlines`; the sync never adds an airline for a side view. Rows the provider no longer lists are dropped with their object.
- Image rule (same validation gate as logos, with a side view rule): PNG only (WebP refused), at least 1200 px wide and at most 4096, transparent background, nose to the left. A vector is rendered 1600 px wide (no small rendition). A pair listed with `nose: "right"` is mirrored with resvg before upload; the row has `note = 'mirrored'` and the answer counts `mirrored`.
- Same run rules as the logo sync: outage retry then 502, 100 s and 400 request budgets, remembered misses, rank precedence. Objects: `side-views/<ICAO>/<TYPE>-<content hash>[m].png`.
- Local edge check (2026-10-29): `npx supabase functions serve brand-assets-sync --env-file <file>` with `LOGO_PROVIDER=commons`, `COMMONS_LOGO_BASE` and `SIDE_VIEW_PROVIDER=recorded`, `SIDE_VIEW_BASE` pointing at `python3 -m http.server` URLs on `host.docker.internal`: the vendored resvg WASM loads from the static file and rasterises in the edge runtime (3 Commons logos at 384 and 192 px, 3 side views including a mirrored one and a vector at 1600 px).
- Brand chain check (2026-10-29, after the signed path fix): same serve with `LOGO_PROVIDER=commons`, `POST /brand-assets-sync?mode=logos&icao=UAL,DLH,AFR`, then `INTEGRATION=1 INTEGRATION_BRAND=1 INTEGRATION_SERVICE_KEY=<local service key> swift test --filter brandChainServesLogos` in `Packages/FlightKit`: a signed-in test user gets the three logos as PNG bytes through `SupabaseBrandAssetService` (`brand-asset` answers project-relative paths, the app joins them to 127.0.0.1:58321 while the function signs on kong:8000). Clean up after: the six rows, their objects, `airlines.logo_checked_at`.
