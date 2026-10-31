-- Cache for alternate-flights, the "Other flights" card of a canceled flight or a connection at risk
-- (AeroAPI schedules, a paid call). One row per route and hour: the function asks the provider for the
-- 24 hours from the start of the hour it was asked about, stores the answer whole (an empty one
-- included) and serves it for 30 minutes, so everyone looking at the same route that hour shares one
-- paid call. A stale row is still served when the provider refuses (the daily spend cap, an outage).
--
-- key: origin ICAO, destination ICAO and the UTC hour, e.g. KSFO-KORD-2026-11-03T15.
create table alternates_cache (
  key        text primary key check (key ~ '^[A-Z0-9]{3,4}-[A-Z0-9]{3,4}-[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}$'),
  payload    jsonb not null,
  fetched_at timestamptz not null default now()
);
alter table alternates_cache enable row level security;
-- No policy and no client grants: service role only. Reassert in case default privileges change.
revoke all on alternates_cache from anon, authenticated;

-- An hour's schedule is worth nothing a day later. cron.schedule upserts by name.
select cron.schedule('alternates-cache-prune', '55 3 * * *', $$
  delete from public.alternates_cache where fetched_at < now() - interval '1 day';
$$);
