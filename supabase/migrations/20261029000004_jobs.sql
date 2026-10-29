-- Scheduled jobs: archiving landed flights, alert sweep and pruning (maintenance function), and the
-- daily AeroAPI spend alert (usage-alert function). Also closes Task 2 grant leftovers.
--
-- pg_net reads the function base URL and the service role key from Vault, by name:
--   functions_base_url  e.g. https://<ref>.supabase.co/functions/v1 (no trailing slash needed)
--   service_role_key    the project's service role key (or sb_secret_ key)
-- Both are created by hand per environment (docs/operations.md). Nothing secret is committed.

create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;

-- past_flights: what the app's PastFlight decodes. `date` becomes the departure instant (the app
-- decodes an ISO 8601 timestamp and buckets years in origin_tz), status and origin_tz are new, and
-- one archived row per user and flight makes archiving idempotent (manual rows have flight_id null).
create type past_flight_status as enum ('completed', 'canceled', 'diverted');
alter table past_flights alter column date type timestamptz using date::timestamptz;
alter table past_flights add column status past_flight_status not null default 'completed';
alter table past_flights add column origin_tz text;
alter table past_flights add constraint past_flights_user_flight_key unique (user_id, flight_id);

-- Great circle distance in km (haversine, mean Earth radius 6371 km).
create function public.haversine_km(lat1 float8, lon1 float8, lat2 float8, lon2 float8)
returns float8
language sql immutable set search_path = '' as $$
  select 2 * 6371 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2)
    + cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lon2 - lon1) / 2), 2)
  ));
$$;

-- Moves every follower of a finished flight into past_flights, 24 hours after it ended.
-- Finished: arrived, landed, canceled or diverted. Ended at: actual_in, else actual_on, else the
-- estimate, else the schedule (a canceled flight has no actuals). Destination is the flight's
-- destination_icao, which for a diverted flight is where it actually landed. block_minutes needs
-- both actual_out and actual_in (null for canceled); delay_minutes is actual_in against
-- scheduled_in, floor 0. Follows are deleted and archived in one statement, so a follow made
-- meanwhile is never dropped without its row, and the unique key makes a rerun insert nothing.
-- Live Activity tokens of the archived follows go too. Bounded to 500 flights per run.
-- Returns the number of past_flights rows inserted.
create function public.archive_landed_flights()
returns int
language plpgsql set search_path = '' as $$
declare n int;
begin
  with due as (
    select f.id from public.flights f
    where f.status in ('arrived', 'landed', 'canceled', 'diverted')
      and coalesce(f.actual_in, f.actual_on, f.estimated_in, f.scheduled_in) < now() - interval '24 hours'
      and exists (select 1 from public.user_flights uf where uf.flight_id = f.id)
    order by f.id
    limit 500
  ),
  gone as (
    delete from public.user_flights uf using due
    where uf.flight_id = due.id
    returning uf.user_id, uf.flight_id
  ),
  tokens as (
    delete from public.push_tokens t using gone
    where t.kind = 'live_activity' and t.user_id = gone.user_id and t.flight_id = gone.flight_id
  ),
  ins as (
    insert into public.past_flights (
      user_id, flight_id, date, ident, origin_icao, destination_icao, airline, aircraft_type,
      registration, distance_km, block_minutes, delay_minutes, status, origin_tz)
    select g.user_id, f.id,
      coalesce(f.actual_out, f.scheduled_out, f.estimated_out,
               f.actual_in, f.actual_on, f.estimated_in, f.scheduled_in),
      f.ident,
      coalesce(f.origin_icao, f.origin_iata, ''),
      coalesce(f.destination_icao, f.destination_iata, ''),
      f.operator, f.aircraft_type, f.registration,
      coalesce(round(public.haversine_km(o.lat, o.lon, d.lat, d.lon))::int, 0),
      case when f.status <> 'canceled' and f.actual_out is not null and f.actual_in is not null
        then round(extract(epoch from (f.actual_in - f.actual_out)) / 60)::int end,
      case when f.status = 'canceled' then 0
        else greatest(0, coalesce(round(extract(epoch from (f.actual_in - f.scheduled_in)) / 60)::int, 0)) end,
      case f.status when 'canceled' then 'canceled'::public.past_flight_status
                    when 'diverted' then 'diverted'::public.past_flight_status
                    else 'completed'::public.past_flight_status end,
      o.tz
    from gone g
    join public.flights f on f.id = g.flight_id
    left join public.airports o on o.icao = f.origin_icao
    left join public.airports d on d.icao = f.destination_icao
    on conflict (user_id, flight_id) do nothing
    returning 1
  )
  select count(*) into n from ins;
  return n;
end;
$$;

-- Flights still holding a provider alert while nobody follows them (archived, or an unfollow whose
-- provider delete failed). The maintenance function retries the delete through releaseAlert.
create function public.orphan_alert_flights(p_limit int)
returns setof uuid
language sql stable set search_path = '' as $$
  select f.id from public.flights f
  where f.alert_id is not null
    and not exists (select 1 from public.user_flights uf where uf.flight_id = f.id)
  order by f.updated_at
  limit p_limit;
$$;

-- Daily housekeeping, each delete bounded by p_batch rows. Returns the count per table.
create function public.prune_maintenance(p_batch int default 5000)
returns jsonb
language plpgsql set search_path = '' as $$
declare
  n_rate int; n_route int; n_snap int; n_lease int; n_inbox int; n_events int;
begin
  -- Rate limits look back at most an hour.
  delete from public.rate_events where id in (
    select id from public.rate_events where at < now() - interval '2 hours' limit p_batch);
  get diagnostics n_rate = row_count;
  -- Route searches are reused for 10 minutes (flight-lookup ROUTE_CACHE_MINUTES); an hour is past it.
  delete from public.route_cache where (origin_icao, destination_icao, date) in (
    select origin_icao, destination_icao, date from public.route_cache
    where fetched_at < now() - interval '1 hour' limit p_batch);
  get diagnostics n_route = row_count;
  -- Snapshots of airports nobody opened for a week.
  delete from public.airport_snapshots where (icao, kind) in (
    select icao, kind from public.airport_snapshots
    where coalesce(last_viewed_at, fetched_at) < now() - interval '7 days' limit p_batch);
  get diagnostics n_snap = row_count;
  delete from public.airport_refresh_leases where (icao, kind) in (
    select icao, kind from public.airport_refresh_leases
    where until < now() - interval '1 hour' limit p_batch);
  get diagnostics n_lease = row_count;
  -- Processed deliveries after 30 days. Failed rows awaiting replay (processed_at null) stay.
  delete from public.webhook_inbox where id in (
    select id from public.webhook_inbox
    where processed_at is not null and received_at < now() - interval '30 days' limit p_batch);
  get diagnostics n_inbox = row_count;
  -- Events older than 90 days of flights nobody follows.
  delete from public.flight_events where id in (
    select e.id from public.flight_events e
    where e.received_at < now() - interval '90 days'
      and not exists (select 1 from public.user_flights uf where uf.flight_id = e.flight_id)
    limit p_batch);
  get diagnostics n_events = row_count;
  return jsonb_build_object(
    'rate_events', n_rate, 'route_cache', n_route, 'airport_snapshots', n_snap,
    'airport_refresh_leases', n_lease, 'webhook_inbox', n_inbox, 'flight_events', n_events);
end;
$$;

-- One spend alert per UTC day: usage-alert claims the day here before sending.
create table usage_alerts (
  day      date primary key,
  total    numeric(10,4) not null,
  sent_at  timestamptz not null default now()
);
alter table usage_alerts enable row level security;
revoke all on usage_alerts from anon, authenticated;

-- POST to an edge function with the service role key, both read from Vault. Returns the pg_net
-- request id, or null (with a warning) when a secret is missing. p_query is appended after '?'.
-- Security definer so only this function, not its callers, needs to read Vault.
create function public.invoke_edge_function(p_name text, p_query text default null)
returns bigint
language plpgsql security definer set search_path = '' as $$
declare v_url text; v_key text;
begin
  if p_name !~ '^[a-z0-9-]+$' then
    raise exception 'invalid function name %', p_name;
  end if;
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'functions_base_url';
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'service_role_key';
  if v_url is null or v_key is null then
    raise warning 'invoke_edge_function(%): vault secrets functions_base_url or service_role_key missing', p_name;
    return null;
  end if;
  return net.http_post(
    url := rtrim(v_url, '/') || '/' || p_name || coalesce('?' || p_query, ''),
    body := '{}'::jsonb,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_key),
    timeout_milliseconds := 120000);
end;
$$;

revoke execute on function
  public.haversine_km(float8, float8, float8, float8),
  public.archive_landed_flights(),
  public.orphan_alert_flights(int),
  public.prune_maintenance(int),
  public.invoke_edge_function(text, text)
from public, anon, authenticated;
grant execute on function
  public.haversine_km(float8, float8, float8, float8),
  public.archive_landed_flights(),
  public.orphan_alert_flights(int),
  public.prune_maintenance(int),
  public.invoke_edge_function(text, text)
to service_role;

-- Task 2 leftovers: the signup trigger function is not an API, and new public functions start
-- closed. Per-schema defaults cannot remove the global PUBLIC execute grant, hence both lines.
revoke execute on function public.handle_new_user() from public, anon, authenticated;
alter default privileges for role postgres in schema public
  revoke execute on functions from anon, authenticated;
alter default privileges for role postgres revoke execute on functions from public;

-- Schedules (UTC). cron.schedule upserts by name, so a rerun does not duplicate.
select cron.schedule('archive-landed-flights', '0 * * * *',
  $$select public.archive_landed_flights()$$);
select cron.schedule('maintenance-alerts', '5 * * * *',
  $$select public.invoke_edge_function('maintenance', 'mode=alerts')$$);
select cron.schedule('maintenance-prune', '30 3 * * *',
  $$select public.invoke_edge_function('maintenance', 'mode=prune')$$);
select cron.schedule('usage-alert', '0 8 * * *',
  $$select public.invoke_edge_function('usage-alert')$$);
