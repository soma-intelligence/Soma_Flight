# Backend operations

## Scheduled jobs (pg_cron, UTC)

Created by `supabase/migrations/20261029000004_jobs.sql` (and `usage-alert-cap` by `20261029000008_spend_cap.sql`). List them with `select jobname, schedule from cron.job;`
and see runs in `cron.job_run_details`.

| Job | Schedule | What it runs |
| --- | --- | --- |
| `archive-landed-flights` | `0 * * * *` | `archive_landed_flights()`: followers of flights that arrived, landed, were canceled or diverted more than 24 hours ago move to `past_flights`. Stuck flights (scheduled, departed, en_route or unknown, arrival time 72 h past, no update for 48 h) are archived as completed when they left, otherwise their follows are dropped with no row |
| `maintenance-alerts` | `5 * * * *` | `maintenance?mode=alerts`: deletes provider alerts of flights nobody follows (just archived, or a failed unfollow), keeps `alert_id` when the provider delete fails |
| `maintenance-prune` | `30 3 * * *` | `maintenance?mode=prune`: rate events older than 2 h, route cache older than 1 h, snapshots not viewed for 7 days, processed webhook rows older than 30 days, events older than 90 days of unfollowed flights (batches of 5000 rows until one comes back short, at most 20 batches per table per run) |
| `usage-alert` | `0 8-11 * * *` | `usage-alert`: emails the owner once when yesterday's estimated AeroAPI spend is above the threshold; the later runs retry a failed send and do nothing once it went out |
| `usage-alert-cap` | `20 * * * *` | `usage-alert?mode=cap`: emails the owner once a day when today's running spend reaches 80% of the daily cap |
| `brand-logos-sync` | `17 * * * *` | `brand-assets-sync?mode=logos&limit=50`: logos, dark logos, tails and brand colours for the 50 airlines never checked or checked over 7 days ago, oldest first. 2,050 airlines are all checked within two days, then each again once 7 days old, which is the weekly refresh. A no-op until the logo provider is configured (below) |
| `cron-history-prune` | `45 3 * * *` | deletes `cron.job_run_details` rows older than 7 days |

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
| `usage-alert` | `RESEND_API_KEY`, `OWNER_EMAIL` | required to send; missing gives 503 |
| `usage-alert` | `USAGE_ALERT_USD` | threshold in USD, default 25 |
| `usage-alert` | `USAGE_ALERT_FROM` | sender, default `Soma Flight <alerts@somalabs.me>` (domain must be verified in Resend) |

The spend alert claims the day in `usage_alerts` before sending and sets `sent_at` after, so it sends at
most one email per UTC day. A failed send releases the claim and the next hourly run retries; a claim
left by a crash (no `sent_at`) is taken over after 15 minutes. Trigger it by hand with
`select public.invoke_edge_function('usage-alert');`.

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

- `brand-assets-sync` pulls logos and colours from a provider through the `LogoProvider` port (`_shared/brand/`). A provider declares its `kinds` (`logo`, `logo_dark`, `tail_logo`, `side_view`), whether it has colours, and a rank. `LOGO_PROVIDER=airhex` (with `AIRHEX_KEY`) or `LOGO_PROVIDER=commons` selects one; anything else is a no-op.
- Precedence: licensed provider (Airhex, rank 2) over Commons (rank 1) over nothing. A stored asset from a higher-ranked provider is never replaced by a lower one (the lower one is not even asked); a lower-ranked row is replaced as soon as the higher provider has the file. Equal ranks never replace each other. The same rank order guards colours: `colors_source = 'locked'` is never overwritten, and a lower-ranked provider never overwrites a higher one's colours. Provider colours do replace curated `seed` colours (intended: the seed is a placeholder until a provider answers; lock a livery colour to keep it).
- Validation, for every provider, before upload: mime on the allow-list (`image/svg+xml`, `image/png`, `image/webp`) and matching the format; size cap (SVG 512 KB, raster 2 MB); magic bytes; raster dimensions read from the bytes (PNG IHDR, WebP header), at least 192 px on the long side; SVG sanitised (script, foreignObject, iframe/embed/object, animation elements, event handlers, external `href`, `javascript:`, `data:` URIs other than raster images, external CSS `url()` and `@import` removed; entity declarations only as plain text; anything unsafe left rejects the file). A refused file counts as a miss, is logged with the reason and never replaces an existing row.
- Conditional fetch: the stored etag (Airhex: `If-None-Match`, 304) or version (Commons: manifest sha256) goes to the provider, which answers "unchanged"; only `checked_at` moves and no body is downloaded.
- Outage: 5xx, 429 and network errors are retried (2 s and 4 s backoff, three attempts), then the run stops with 502 `{ ok: false, stoppedBy: "provider_unavailable" }` without stamping any airline; the next hourly tick retries. Bad data for one airline only fails that airline (stamped back about a day).
- Budget per run: 100 s and 400 provider requests. What is left is reported as `deferred` and picked up next tick. Every answer carries a summary (`checked, changed, added, failed, unchanged, missed, skipped, rejected, dropped, deferred, requests, ms, stoppedBy`).
- Misses: when a provider has no file for an airline and kind (or sent one validation refused), `airline_asset_misses` remembers it for a day, so a retry inside the day does not ask again. A row the same provider stops offering is deleted with its object. Airlines are otherwise rechecked weekly (`airlines.logo_checked_at`).
- A new provider version is a new object (`logos/<ICAO>/<kind>-<version>.<ext>`, `side-views/<ICAO>/<TYPE>-<version>.<ext>`); the old object is removed after the row points at the new one.
- Manual resync of a few airlines: `POST /brand-assets-sync?mode=logos&icao=UAL,AFR` with the service role key.
- The key is sent only as an MD5 digest (`md5apikey`) and redacted from any error text.
- Licence checklist (TODO when the Airhex licence is signed): re-record `_shared/fixtures/airhex/` against the live account, re-check the URL shapes in `_shared/brand/airhex.ts` (they were written from the public documentation with no key, so `sendsKeyAsDocumented` and the other Airhex tests are a contract to re-verify, not a recording), then set `LOGO_PROVIDER=airhex` and `AIRHEX_KEY` as function secrets.
- Local demo key: none exists. If one is obtained, it goes only in `supabase/functions/.env.local` (git-ignored). It is never set as a project secret.
