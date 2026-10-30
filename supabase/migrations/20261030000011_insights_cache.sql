-- Cache for flight-insights, the flight sheet's two paid sections (AeroAPI history and the inbound
-- chain). Each answer is stored whole, null and empty answers included, so repeated opens of the same
-- flight cost nothing: the function reads the row and only pays the provider when it is older than its
-- TTL (12 hours for a forecast, 10 minutes for an inbound chain). A stale row is still served when the
-- provider refuses (the daily spend cap, an outage).
--
-- forecast_cache: one row per flight number (upper case IATA designator, e.g. AF84).
-- inbound_cache: one row per flights row; it goes with the flight.
create table forecast_cache (
  ident      text primary key check (ident ~ '^([A-Z]{3}|[A-Z0-9]{2})[0-9]{1,4}[A-Z]?$'),
  payload    jsonb not null,
  fetched_at timestamptz not null default now()
);
alter table forecast_cache enable row level security;
-- No policy and no client grants: service role only. Reassert in case default privileges change.
revoke all on forecast_cache from anon, authenticated;

create table inbound_cache (
  flight_id  uuid primary key references flights(id) on delete cascade,
  payload    jsonb not null,
  fetched_at timestamptz not null default now()
);
alter table inbound_cache enable row level security;
revoke all on inbound_cache from anon, authenticated;

-- Rows nobody opened for two days are worth nothing: a forecast is rebuilt after 12 hours and a chain
-- after 10 minutes anyway. cron.schedule upserts by name.
select cron.schedule('insights-cache-prune', '50 3 * * *', $$
  delete from public.forecast_cache where fetched_at < now() - interval '2 days';
  delete from public.inbound_cache where fetched_at < now() - interval '2 days';
$$);
