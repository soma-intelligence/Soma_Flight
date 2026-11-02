-- Cache for flight-schedules, the "add a flight" search of days and weeks ahead (AeroAPI schedules, a
-- paid call). One row per search and day: the function stores the provider's answer whole (an empty one
-- included) and serves it for 6 hours, so the same search shares one paid call. A stale row is still
-- served when the provider refuses (the daily spend cap, an outage).
--
-- key: "<origin|*>-<destination|*>-<airline|*>-<ident|*>-<date>", e.g. KSFO-KORD-*-*-2026-11-20.
create table schedules_cache (
  key        text primary key,
  flights    jsonb not null,
  fetched_at timestamptz not null
);
alter table schedules_cache enable row level security;
-- No policy and no client grants: service role only. Reassert in case default privileges change.
revoke all on schedules_cache from anon, authenticated;

-- A day's schedule is worth nothing a day after its answer was stale. cron.schedule upserts by name.
select cron.schedule('schedules-cache-prune', '50 3 * * *', $$
  delete from public.schedules_cache where fetched_at < now() - interval '1 day';
$$);
