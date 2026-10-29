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
