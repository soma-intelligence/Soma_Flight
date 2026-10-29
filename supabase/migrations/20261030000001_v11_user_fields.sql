-- v1.1 data model: user fields on follows and past flights, countries and air time on past flights,
-- off and on times on flights, the aircraft table.

create type seat_class as enum ('economy', 'premium_economy', 'business', 'first');
create type trip_reason as enum ('personal', 'business');

-- User fields. Clients write them on user_flights through PostgREST (column-level update below);
-- archive_landed_flights copies them to past_flights.
alter table user_flights
  add column seat_class seat_class,
  add column seat text check (seat ~ '^[0-9]{1,3}[A-K]$'),
  add column reason trip_reason,
  add column booking_code text check (booking_code ~ '^[A-Z0-9]{5,8}$'),
  add column notes text check (char_length(notes) <= 2000);

alter table past_flights
  add column seat_class seat_class,
  add column reason trip_reason,
  add column booking_code text check (booking_code ~ '^[A-Z0-9]{5,8}$'),
  add column notes text check (char_length(notes) <= 2000),
  add column origin_country text,
  add column destination_country text,
  add column air_minutes int,
  -- not valid: rows already stored (manual entries) are not checked, every new write is.
  add constraint past_flights_seat_check check (seat ~ '^[0-9]{1,3}[A-K]$') not valid;

-- Backfill from airports, matched on ICAO else IATA (the ICAO match wins), like archive_landed_flights,
-- and from the flight's own off and on times.
update past_flights p set origin_country = (
  select a.country from airports a where a.icao = p.origin_icao or a.iata = p.origin_icao
  order by (a.icao = p.origin_icao) desc limit 1)
  where p.origin_country is null;
update past_flights p set destination_country = (
  select a.country from airports a where a.icao = p.destination_icao or a.iata = p.destination_icao
  order by (a.icao = p.destination_icao) desc limit 1)
  where p.destination_country is null;
update past_flights p
  set air_minutes = round(extract(epoch from (f.actual_on - f.actual_off)) / 60)::int
  from flights f
  where f.id = p.flight_id and f.actual_on > f.actual_off and p.air_minutes is null;

alter table flights
  add column scheduled_off timestamptz,
  add column scheduled_on timestamptz,
  add column estimated_off timestamptz,
  add column estimated_on timestamptz;

-- Clients keep no insert or delete on user_flights (20261029000005). They may update exactly the five
-- user fields on their own follow: the owner policy user_flights_owner (for all, using and with check
-- on auth.uid() = user_id) scopes the rows, the column grant scopes the columns.
grant update (seat_class, seat, reason, booking_code, notes) on user_flights to authenticated;

-- Reference data about airframes, filled by the service role only.
create table aircraft (
  registration text primary key,
  aircraft_type text,
  airline_icao text,
  delivered_on date,
  name text
);
alter table aircraft enable row level security;
create policy aircraft_read on aircraft for select to authenticated using (true);
grant select on aircraft to authenticated;

-- merge_flight: the four new times follow the rules of their scheduled and estimated siblings.
create or replace function public.merge_flight(f public.flights, p_fields jsonb, p_event_code text default null)
returns public.flights
language plpgsql immutable set search_path = '' as $$
declare
  m public.flights := f;
  v_rank text[] := array['scheduled', 'departed', 'en_route', 'landed', 'arrived'];
  v_hint text := p_fields->>'status';
  v_probe text;
  v_best int;
begin
  m.scheduled_out := coalesce((p_fields->>'scheduled_out')::timestamptz, f.scheduled_out);
  m.scheduled_in := coalesce((p_fields->>'scheduled_in')::timestamptz, f.scheduled_in);
  m.actual_out := coalesce(f.actual_out, (p_fields->>'actual_out')::timestamptz);
  m.actual_off := coalesce(f.actual_off, (p_fields->>'actual_off')::timestamptz);
  m.actual_on := coalesce(f.actual_on, (p_fields->>'actual_on')::timestamptz);
  m.actual_in := coalesce(f.actual_in, (p_fields->>'actual_in')::timestamptz);
  m.estimated_out := case when m.actual_out is not null then f.estimated_out
    else coalesce((p_fields->>'estimated_out')::timestamptz, f.estimated_out) end;
  m.estimated_in := case when m.actual_in is not null then f.estimated_in
    else coalesce((p_fields->>'estimated_in')::timestamptz, f.estimated_in) end;
  m.scheduled_off := coalesce((p_fields->>'scheduled_off')::timestamptz, f.scheduled_off);
  m.scheduled_on := coalesce((p_fields->>'scheduled_on')::timestamptz, f.scheduled_on);
  m.estimated_off := case when m.actual_off is not null then f.estimated_off
    else coalesce((p_fields->>'estimated_off')::timestamptz, f.estimated_off) end;
  m.estimated_on := case when m.actual_on is not null then f.estimated_on
    else coalesce((p_fields->>'estimated_on')::timestamptz, f.estimated_on) end;
  m.gate_origin := coalesce(nullif(p_fields->>'gate_origin', ''), f.gate_origin);
  m.gate_destination := coalesce(nullif(p_fields->>'gate_destination', ''), f.gate_destination);
  m.terminal_origin := coalesce(nullif(p_fields->>'terminal_origin', ''), f.terminal_origin);
  m.terminal_destination := coalesce(nullif(p_fields->>'terminal_destination', ''), f.terminal_destination);
  m.baggage_belt := coalesce(nullif(p_fields->>'baggage_belt', ''), f.baggage_belt);
  m.aircraft_type := coalesce(nullif(p_fields->>'aircraft_type', ''), f.aircraft_type);
  m.registration := coalesce(nullif(p_fields->>'registration', ''), f.registration);
  m.operator := coalesce(nullif(p_fields->>'operator', ''), f.operator);
  m.origin_icao := coalesce(nullif(p_fields->>'origin_icao', ''), f.origin_icao);
  m.origin_iata := coalesce(nullif(p_fields->>'origin_iata', ''), f.origin_iata);
  m.destination_icao := coalesce(nullif(p_fields->>'destination_icao', ''), f.destination_icao);
  m.destination_iata := coalesce(nullif(p_fields->>'destination_iata', ''), f.destination_iata);

  if f.status in ('canceled', 'diverted', 'arrived') then
    m.status := f.status;
  elsif p_event_code = 'cancelled' or (p_fields->>'cancelled') = 'true' or v_hint = 'canceled' then
    m.status := 'canceled';
  elsif p_event_code = 'diverted' or (p_fields->>'diverted') = 'true' or v_hint = 'diverted' then
    m.status := 'diverted';
  else
    v_probe := case
      when m.actual_in is not null then 'arrived'
      when m.actual_on is not null then 'landed'
      when m.actual_off is not null then 'en_route'
      when m.actual_out is not null then 'departed'
      else null end;
    v_best := greatest(
      coalesce(array_position(v_rank, f.status::text), 0),
      coalesce(array_position(v_rank, v_probe), 0),
      coalesce(array_position(v_rank, v_hint), 0));
    if v_best > 0 then
      m.status := v_rank[v_best]::public.flight_status;
    end if;
  end if;
  return m;
end;
$$;

-- upsert_provider_flights: also stores the four new times, and takes its row locks in provider_id
-- order (the parked deadlock: two lookups overlapping on several flights locked in input order).
-- Rows come back in input order; when one batch repeats a provider_id, every occurrence returns the
-- final stored row (read after the loop), not the state at that step.

create or replace function public.upsert_provider_flights(p_rows jsonb)
returns setof public.flights
language plpgsql security definer set search_path = '' as $$
declare
  r jsonb;
  v_ord bigint;
  f public.flights;
  m public.flights;
  v_ords bigint[] := '{}';
  v_ids uuid[] := '{}';
begin
  -- Rows are locked (and inserted) in provider_id order, so two concurrent batches overlapping on
  -- several flights always take their locks in the same order and cannot deadlock. The result is
  -- still returned in input order.
  for r, v_ord in
    select e.value, e.ordinality from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb))
      with ordinality as e(value, ordinality)
    order by e.value->>'provider_id', e.ordinality
  loop
    select * into f from public.flights where provider_id = r->>'provider_id' for update;
    if not found then
      insert into public.flights (
        provider_id, ident, operator, origin_icao, origin_iata, destination_icao, destination_iata,
        scheduled_out, scheduled_in, estimated_out, estimated_in,
        scheduled_off, scheduled_on, estimated_off, estimated_on,
        actual_out, actual_off, actual_on, actual_in,
        gate_origin, gate_destination, terminal_origin, terminal_destination, baggage_belt,
        aircraft_type, registration, status)
      select x.provider_id, x.ident, x.operator, x.origin_icao, x.origin_iata, x.destination_icao,
        x.destination_iata, x.scheduled_out, x.scheduled_in, x.estimated_out, x.estimated_in,
        x.scheduled_off, x.scheduled_on, x.estimated_off, x.estimated_on,
        x.actual_out, x.actual_off, x.actual_on, x.actual_in,
        x.gate_origin, x.gate_destination, x.terminal_origin, x.terminal_destination, x.baggage_belt,
        x.aircraft_type, x.registration, coalesce(x.status, 'unknown')
      from jsonb_populate_record(null::public.flights, r) x
      on conflict (provider_id) do nothing
      returning * into f;
      if f.id is not null then
        v_ords := v_ords || v_ord;
        v_ids := v_ids || f.id;
        continue;
      end if;
      -- Inserted meanwhile by someone else: merge into theirs.
      select * into f from public.flights where provider_id = r->>'provider_id' for update;
    end if;
    m := public.merge_flight(f, r, null);
    if m is distinct from f then
      m.updated_at := now();
      update public.flights set
        operator = m.operator,
        origin_icao = m.origin_icao, origin_iata = m.origin_iata,
        destination_icao = m.destination_icao, destination_iata = m.destination_iata,
        scheduled_out = m.scheduled_out, scheduled_in = m.scheduled_in,
        estimated_out = m.estimated_out, estimated_in = m.estimated_in,
        scheduled_off = m.scheduled_off, scheduled_on = m.scheduled_on,
        estimated_off = m.estimated_off, estimated_on = m.estimated_on,
        actual_out = m.actual_out, actual_off = m.actual_off, actual_on = m.actual_on, actual_in = m.actual_in,
        gate_origin = m.gate_origin, gate_destination = m.gate_destination,
        terminal_origin = m.terminal_origin, terminal_destination = m.terminal_destination,
        baggage_belt = m.baggage_belt, aircraft_type = m.aircraft_type, registration = m.registration,
        status = m.status, updated_at = m.updated_at
      where id = f.id
      returning * into m;
      v_ords := v_ords || v_ord;
      v_ids := v_ids || m.id;
    else
      v_ords := v_ords || v_ord;
      v_ids := v_ids || f.id;
    end if;
  end loop;
  return query select x.* from unnest(v_ords, v_ids) as t(ord, id)
    join public.flights x on x.id = t.id order by t.ord;
end;
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
--
-- v1.1: each row also carries the follower's seat_class, seat, reason, booking_code and notes, the
-- origin and destination country (ISO alpha-2, from airports; null when the airport is unknown) and
-- air_minutes = actual_on - actual_off in minutes when both exist and on > off, else null.
create or replace function public.archive_landed_flights()
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
    returning uf.user_id, uf.flight_id, due.kind,
      uf.seat_class, uf.seat, uf.reason, uf.booking_code, uf.notes
  ),
  tokens as (
    delete from public.push_tokens t using gone
    where t.kind = 'live_activity' and t.user_id = gone.user_id and t.flight_id = gone.flight_id
  ),
  ins as (
    insert into public.past_flights (
      user_id, flight_id, date, ident, origin_icao, destination_icao, airline, aircraft_type,
      registration, distance_km, block_minutes, delay_minutes, status, origin_tz,
      seat_class, seat, reason, booking_code, notes,
      origin_country, destination_country, air_minutes)
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
      o.tz,
      g.seat_class, g.seat, g.reason, g.booking_code, g.notes,
      o.country, d.country,
      case when f.actual_on > f.actual_off
        then round(extract(epoch from (f.actual_on - f.actual_off)) / 60)::int end
    from gone g
    join public.flights f on f.id = g.flight_id
    left join public.profiles p on p.user_id = g.user_id
    left join lateral (
      select a.icao, a.lat, a.lon, a.tz, a.country from public.airports a
      where a.icao = f.origin_icao or a.iata = f.origin_iata
      order by (a.icao = f.origin_icao) desc nulls last limit 1) o on true
    left join lateral (
      select a.icao, a.lat, a.lon, a.country from public.airports a
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

revoke execute on function
  public.merge_flight(public.flights, jsonb, text),
  public.upsert_provider_flights(jsonb),
  public.archive_landed_flights()
from public, anon, authenticated;
grant execute on function
  public.merge_flight(public.flights, jsonb, text),
  public.upsert_provider_flights(jsonb),
  public.archive_landed_flights()
to service_role;
