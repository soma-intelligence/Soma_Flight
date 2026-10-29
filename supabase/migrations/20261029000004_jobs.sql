-- Scheduled jobs: archiving finished (and stuck) flights, alert sweep and pruning (maintenance
-- function), the daily AeroAPI spend alert (usage-alert function). Also closes Task 2 grant leftovers.
--
-- pg_net reads the function base URL and the service role key from Vault, by name:
--   functions_base_url  e.g. https://<ref>.supabase.co/functions/v1 (no trailing slash needed)
--   service_role_key    the project's service role key as a JWT (role service_role): the functions
--                       run with verify_jwt = true, so the gateway rejects an opaque sb_secret_ key
-- Both are created by hand per environment (docs/operations.md). Nothing secret is committed.

create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;

-- past_flights: what the app's PastFlight decodes. `date` becomes the departure instant (the app
-- decodes an ISO 8601 timestamp and buckets years in origin_tz), status and origin_tz are new, the
-- fields the app decodes as non-optional are not null, and one archived row per user and flight
-- makes archiving idempotent (manual rows have flight_id null).
create type past_flight_status as enum ('completed', 'canceled', 'diverted');
alter table past_flights alter column date type timestamptz using (date::timestamp at time zone 'UTC');
alter table past_flights add column status past_flight_status not null default 'completed';
alter table past_flights add column origin_tz text;
update past_flights set ident = coalesce(ident, ''), origin_icao = coalesce(origin_icao, ''),
  destination_icao = coalesce(destination_icao, ''), distance_km = coalesce(distance_km, 0),
  delay_minutes = coalesce(delay_minutes, 0)
where ident is null or origin_icao is null or destination_icao is null
  or distance_km is null or delay_minutes is null;
alter table past_flights
  alter column ident set default '', alter column ident set not null,
  alter column origin_icao set default '', alter column origin_icao set not null,
  alter column destination_icao set default '', alter column destination_icao set not null,
  alter column distance_km set default 0, alter column distance_km set not null,
  alter column delay_minutes set default 0, alter column delay_minutes set not null;
alter table past_flights add constraint past_flights_user_flight_key unique (user_id, flight_id);
create index past_flights_flight_id_idx on past_flights (flight_id);

-- Sweep indexes: prune ranges and the orphan alert lookup.
create index rate_events_at_idx on rate_events (at);
create index webhook_inbox_processed_received_idx on webhook_inbox (received_at)
  where processed_at is not null;
create index flight_events_received_at_idx on flight_events (received_at);
create index flights_alert_idx on flights (id) where alert_id is not null;

-- Great circle distance in km (haversine, mean Earth radius 6371 km). least() keeps asin in its
-- domain when rounding pushes the term above 1 (near-antipodal pairs). Strict: a null coordinate
-- gives null (least() alone would turn it into the antipodal distance).
create function public.haversine_km(lat1 float8, lon1 float8, lat2 float8, lon2 float8)
returns float8
language sql immutable strict set search_path = '' as $$
  select 2 * 6371 * asin(least(1::float8, sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2)
    + cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lon2 - lon1) / 2), 2)
  )));
$$;

-- Moves the followers of finished flights into past_flights and drops follows of stuck flights.
--
-- Finished: arrived, landed, canceled or diverted, ended 24 hours ago. Ended at: actual_in, else
-- actual_on, else the estimate, else the schedule (a canceled flight has no actuals).
-- Stuck: scheduled, departed, en_route or unknown, coalesce(estimated_in, scheduled_in) 72 hours
-- ago and no update for 48 hours (no webhook movement). With actual_out it flew and the arrival was
-- missed: archived as completed, block null, delay 0. Without actual_out it was never seen leaving:
-- follows go, no past row (no phantom miles; the user can add it by hand).
--
-- Row fields: destination is destination_icao, which for a diverted flight is where it landed.
-- Airports are matched on ICAO, else IATA, for distance and origin_tz (distance 0 and tz null when
-- unknown). block_minutes = actual_in - actual_out when both exist and in > out, else null.
-- delay_minutes = coalesce(actual_in, actual_on) - scheduled_in, floor 0; 0 for canceled, diverted
-- (the original schedule does not apply) and stuck flights.
--
-- Follows are deleted and archived in one statement, so a follow made meanwhile is never dropped
-- without its row, and the unique key makes a rerun insert nothing. Live Activity tokens of removed
-- follows go too. Users whose profile is deleted get no row. A second concurrent run returns 0 at
-- once (advisory lock). Bounded to 500 flights per run. Returns the number of rows inserted.
create function public.archive_landed_flights()
returns int
language plpgsql set search_path = '' as $$
declare n int; n_dropped int;
begin
  if not pg_try_advisory_xact_lock(hashtextextended('archive_landed_flights', 0)) then
    return 0;
  end if;
  with due as (
    select f.id,
      case when f.status in ('arrived', 'landed', 'canceled', 'diverted') then 'finished'
           when f.actual_out is not null then 'stuck_flown'
           else 'stuck_unflown' end as kind
    from public.flights f
    where exists (select 1 from public.user_flights uf where uf.flight_id = f.id)
      and (
        (f.status in ('arrived', 'landed', 'canceled', 'diverted')
          and coalesce(f.actual_in, f.actual_on, f.estimated_in, f.scheduled_in) < now() - interval '24 hours')
        or (f.status in ('scheduled', 'departed', 'en_route', 'unknown')
          and coalesce(f.estimated_in, f.scheduled_in) < now() - interval '72 hours'
          and f.updated_at < now() - interval '48 hours'))
    order by f.id
    limit 500
  ),
  gone as (
    delete from public.user_flights uf using due
    where uf.flight_id = due.id
    returning uf.user_id, uf.flight_id, due.kind
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
      coalesce(f.origin_icao, o.icao, f.origin_iata, ''),
      coalesce(f.destination_icao, d.icao, f.destination_iata, ''),
      f.operator, f.aircraft_type, f.registration,
      coalesce(round(public.haversine_km(o.lat, o.lon, d.lat, d.lon))::int, 0),
      case when g.kind = 'finished' and f.status <> 'canceled' and f.actual_in > f.actual_out
        then round(extract(epoch from (f.actual_in - f.actual_out)) / 60)::int end,
      case when g.kind <> 'finished' or f.status in ('canceled', 'diverted') then 0
        else greatest(0, coalesce(round(extract(epoch from
          (coalesce(f.actual_in, f.actual_on) - f.scheduled_in)) / 60)::int, 0)) end,
      case when g.kind <> 'finished' then 'completed'::public.past_flight_status
           when f.status = 'canceled' then 'canceled'::public.past_flight_status
           when f.status = 'diverted' then 'diverted'::public.past_flight_status
           else 'completed'::public.past_flight_status end,
      o.tz
    from gone g
    join public.flights f on f.id = g.flight_id
    left join public.profiles p on p.user_id = g.user_id
    left join lateral (
      select a.icao, a.lat, a.lon, a.tz from public.airports a
      where a.icao = f.origin_icao or a.iata = f.origin_iata
      order by (a.icao = f.origin_icao) desc nulls last limit 1) o on true
    left join lateral (
      select a.icao, a.lat, a.lon from public.airports a
      where a.icao = f.destination_icao or a.iata = f.destination_iata
      order by (a.icao = f.destination_icao) desc nulls last limit 1) d on true
    where g.kind <> 'stuck_unflown' and coalesce(p.status, 'active') = 'active'
    on conflict (user_id, flight_id) do nothing
    returning 1
  )
  select (select count(*) from ins), (select count(*) from gone where kind = 'stuck_unflown')
    into n, n_dropped;
  if n_dropped > 0 then
    raise log 'archive_landed_flights: % follow(s) of stuck flights never seen leaving removed', n_dropped;
  end if;
  return n;
end;
$$;

-- Flights still holding a provider alert while nobody follows them (archived, or an unfollow whose
-- provider delete failed). Random order, so flights whose delete keeps failing cannot starve the rest.
create function public.orphan_alert_flights(p_limit int)
returns setof uuid
language sql volatile set search_path = '' as $$
  select f.id from public.flights f
  where f.alert_id is not null
    and not exists (select 1 from public.user_flights uf where uf.flight_id = f.id)
  order by random()
  limit p_limit;
$$;

-- Daily housekeeping. Each table is deleted in batches of p_batch rows until a batch comes back
-- short, at most p_max_loops batches per table per run. Returns the count per table.
create function public.prune_maintenance(p_batch int default 5000, p_max_loops int default 20)
returns jsonb
language plpgsql set search_path = '' as $$
declare
  n int; i int;
  n_rate int := 0; n_route int := 0; n_snap int := 0; n_lease int := 0; n_inbox int := 0; n_events int := 0;
begin
  -- Rate limits look back at most an hour.
  for i in 1..p_max_loops loop
    delete from public.rate_events where id in (
      select id from public.rate_events where at < now() - interval '2 hours' limit p_batch);
    get diagnostics n = row_count; n_rate := n_rate + n;
    exit when n < p_batch;
  end loop;
  -- Route searches are reused for 10 minutes (flight-lookup ROUTE_CACHE_MINUTES); an hour is past it.
  for i in 1..p_max_loops loop
    delete from public.route_cache where (origin_icao, destination_icao, date) in (
      select origin_icao, destination_icao, date from public.route_cache
      where fetched_at < now() - interval '1 hour' limit p_batch);
    get diagnostics n = row_count; n_route := n_route + n;
    exit when n < p_batch;
  end loop;
  -- Snapshots of airports nobody opened for a week.
  for i in 1..p_max_loops loop
    delete from public.airport_snapshots where (icao, kind) in (
      select icao, kind from public.airport_snapshots
      where coalesce(last_viewed_at, fetched_at) < now() - interval '7 days' limit p_batch);
    get diagnostics n = row_count; n_snap := n_snap + n;
    exit when n < p_batch;
  end loop;
  for i in 1..p_max_loops loop
    delete from public.airport_refresh_leases where (icao, kind) in (
      select icao, kind from public.airport_refresh_leases
      where until < now() - interval '1 hour' limit p_batch);
    get diagnostics n = row_count; n_lease := n_lease + n;
    exit when n < p_batch;
  end loop;
  -- Processed deliveries after 30 days. Failed rows awaiting replay (processed_at null) stay.
  for i in 1..p_max_loops loop
    delete from public.webhook_inbox where id in (
      select id from public.webhook_inbox
      where processed_at is not null and received_at < now() - interval '30 days' limit p_batch);
    get diagnostics n = row_count; n_inbox := n_inbox + n;
    exit when n < p_batch;
  end loop;
  -- Events older than 90 days of flights nobody follows.
  for i in 1..p_max_loops loop
    delete from public.flight_events where id in (
      select e.id from public.flight_events e
      where e.received_at < now() - interval '90 days'
        and not exists (select 1 from public.user_flights uf where uf.flight_id = e.flight_id)
      limit p_batch);
    get diagnostics n = row_count; n_events := n_events + n;
    exit when n < p_batch;
  end loop;
  return jsonb_build_object(
    'rate_events', n_rate, 'route_cache', n_route, 'airport_snapshots', n_snap,
    'airport_refresh_leases', n_lease, 'webhook_inbox', n_inbox, 'flight_events', n_events);
end;
$$;

-- Spend alert, one per UTC day. usage-alert claims the day (claimed_at) before sending and sets
-- sent_at after a good send. A failed send deletes the claim; a claim left by a crash (sent_at null,
-- claimed_at 15 minutes old) is taken over by a later run.
create table usage_alerts (
  day        date primary key,
  total      numeric(10,4) not null,
  claimed_at timestamptz not null default now(),
  sent_at    timestamptz
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

-- Task 2 leftover: the signup trigger function gets an empty search_path (the body is qualified).
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (user_id) values (new.id) on conflict do nothing;
  return new;
end;
$$;

-- Grants. No function in public is a client API: every one is closed to PUBLIC, anon and
-- authenticated (archive_test.sql guards this), and new ones created by postgres in public start
-- without anon/authenticated grants. The global PUBLIC default is left alone on purpose (it also
-- covers extension functions), so a new function still needs its own revoke; the guard catches it.
do $$
declare f regprocedure;
begin
  for f in
    select p.oid::regprocedure from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
  end loop;
end;
$$;
alter default privileges for role postgres in schema public
  revoke execute on functions from anon, authenticated;
grant execute on function
  public.haversine_km(float8, float8, float8, float8),
  public.archive_landed_flights(),
  public.orphan_alert_flights(int),
  public.prune_maintenance(int, int),
  public.invoke_edge_function(text, text)
to service_role;

-- Schedules (UTC). cron.schedule upserts by name, so a rerun does not duplicate. usage-alert runs
-- four times from 08:00: pg_net ignores the answer, so a failed send is retried by the next run,
-- and the day claim keeps it to one email.
select cron.schedule('archive-landed-flights', '0 * * * *',
  $$select public.archive_landed_flights()$$);
select cron.schedule('maintenance-alerts', '5 * * * *',
  $$select public.invoke_edge_function('maintenance', 'mode=alerts')$$);
select cron.schedule('maintenance-prune', '30 3 * * *',
  $$select public.invoke_edge_function('maintenance', 'mode=prune')$$);
select cron.schedule('usage-alert', '0 8-11 * * *',
  $$select public.invoke_edge_function('usage-alert')$$);
select cron.schedule('cron-history-prune', '45 3 * * *',
  $$delete from cron.job_run_details where end_time < now() - interval '7 days'$$);
