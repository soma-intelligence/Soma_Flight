# Backend operations

## Scheduled jobs (pg_cron, UTC)

Created by `supabase/migrations/20261029000004_jobs.sql`. List them with `select jobname, schedule from cron.job;`
and see runs in `cron.job_run_details`.

| Job | Schedule | What it runs |
| --- | --- | --- |
| `archive-landed-flights` | `0 * * * *` | `archive_landed_flights()`: followers of flights that arrived, landed, were canceled or diverted more than 24 hours ago move to `past_flights`. Stuck flights (scheduled, departed, en_route or unknown, arrival time 72 h past, no update for 48 h) are archived as completed when they left, otherwise their follows are dropped with no row |
| `maintenance-alerts` | `5 * * * *` | `maintenance?mode=alerts`: deletes provider alerts of flights nobody follows (just archived, or a failed unfollow), keeps `alert_id` when the provider delete fails |
| `maintenance-prune` | `30 3 * * *` | `maintenance?mode=prune`: rate events older than 2 h, route cache older than 1 h, snapshots not viewed for 7 days, processed webhook rows older than 30 days, events older than 90 days of unfollowed flights (batches of 5000 rows until one comes back short, at most 20 batches per table per run) |
| `usage-alert` | `0 8-11 * * *` | `usage-alert`: emails the owner once when yesterday's estimated AeroAPI spend is above the threshold; the later runs retry a failed send and do nothing once it went out |
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
| `usage-alert` | `RESEND_API_KEY`, `OWNER_EMAIL` | required to send; missing gives 503 |
| `usage-alert` | `USAGE_ALERT_USD` | threshold in USD, default 25 |
| `usage-alert` | `USAGE_ALERT_FROM` | sender, default `Soma Flight <alerts@somalabs.me>` (domain must be verified in Resend) |

The spend alert claims the day in `usage_alerts` before sending and sets `sent_at` after, so it sends at
most one email per UTC day. A failed send releases the claim and the next hourly run retries; a claim
left by a crash (no `sent_at`) is taken over after 15 minutes. Trigger it by hand with
`select public.invoke_edge_function('usage-alert');`.
