-- Cache for nearby-flights, the radar of flights in the air around a place (AeroAPI /flights/search with a
-- latlong box, a paid call). One row per rounded bounding box: the function snaps the box the user asked
-- about to a 0.25 degree grid, so everyone looking at the same area shares one paid call, and serves the
-- answer for 60 seconds. A stale row is still served when the provider refuses (the daily spend cap, an
-- outage). Every paid call goes through the usage counter (charge_usage, usage_counters) as any other.
--
-- key: south, west, north and east edges of the snapped box, e.g. 37.25_-122.5_38_-121.5.
create table radar_cache (
  key        text primary key check (key ~ '^-?[0-9]+(\.[0-9]+)?_-?[0-9]+(\.[0-9]+)?_-?[0-9]+(\.[0-9]+)?_-?[0-9]+(\.[0-9]+)?$'),
  payload    jsonb not null,
  fetched_at timestamptz not null default now()
);
alter table radar_cache enable row level security;
-- No policy and no client grants: service role only. Reassert in case default privileges change.
revoke all on radar_cache from anon, authenticated;

-- A position is worth nothing a day later. cron.schedule upserts by name.
select cron.schedule('radar-cache-prune', '50 3 * * *', $$
  delete from public.radar_cache where fetched_at < now() - interval '1 day';
$$);
