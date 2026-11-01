-- Signed arrival and departure delays on past flights, for the Delay Report (Passport). Until now a row
-- carried delay_minutes alone, 0 when the arrival time was unknown, so "on time" and "no data" looked the
-- same and no departure delay was kept.
--
-- arrival_delay_minutes: actual minus scheduled arrival in minutes, negative when early; gate times when
-- both are known, else runway times. Null when the actual arrival is unknown.
-- departure_delay_minutes: the same for the departure. Null when unknown.
--
-- Both are nullable and unchecked beyond a two day bound; the table grant already lets clients write
-- their own manual and imported rows. archive_landed_flights fills both from the flight's scheduled and
-- actual times, signed (below). delay_minutes stays as before (floored at 0) for older readers.

alter table past_flights
  add column arrival_delay_minutes int,
  add column departure_delay_minutes int,
  add constraint past_flights_delay_bounds_check check (
    (arrival_delay_minutes is null or arrival_delay_minutes between -2880 and 2880)
    and (departure_delay_minutes is null or departure_delay_minutes between -2880 and 2880));

-- archive_landed_flights as in 20261030000010, now also writing the two signed delays. A canceled flight
-- has neither; a diverted one has a departure delay only; a flight archived as stuck has a departure delay
-- when it was seen leaving.
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
      uf.seat_class, uf.seat, uf.reason, uf.booking_code, uf.notes, uf.seat_position
  ),
  tokens as (
    delete from public.push_tokens t using gone
    where t.kind = 'live_activity' and t.user_id = gone.user_id and t.flight_id = gone.flight_id
  ),
  ins as (
    insert into public.past_flights (
      user_id, flight_id, date, ident, origin_icao, destination_icao, airline, aircraft_type,
      registration, distance_km, block_minutes, delay_minutes, status, origin_tz,
      seat_class, seat, reason, booking_code, notes, seat_position,
      origin_country, destination_country, air_minutes,
      arrival_delay_minutes, departure_delay_minutes)
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
      g.seat_class, g.seat, g.reason, g.booking_code, g.notes, g.seat_position,
      o.country, d.country,
      case when f.actual_on > f.actual_off
        then round(extract(epoch from (f.actual_on - f.actual_off)) / 60)::int end,
      dl.arrival, dl.departure
    from gone g
    join public.flights f on f.id = g.flight_id
    left join public.profiles p on p.user_id = g.user_id
    -- Signed (negative: early) and clamped to the column's two day bound so one odd feed value cannot fail the
    -- whole batch. Gate times when both are known, else runway times; null when the actual is unknown.
    -- A canceled flight never left, a diverted one left but never reached its scheduled arrival.
    cross join lateral (
      select
        -- greatest and least skip nulls, so a null raw value must not reach them.
        case when raw.arrival is not null then greatest(-2880, least(2880, raw.arrival)) end as arrival,
        case when raw.departure is not null then greatest(-2880, least(2880, raw.departure)) end as departure
      from (select
        case when g.kind = 'finished' and f.status not in ('canceled', 'diverted')
             then round(extract(epoch from
               case when f.actual_in is not null and f.scheduled_in is not null then f.actual_in - f.scheduled_in
                    else f.actual_on - f.scheduled_on end) / 60)::int end as arrival,
        case when f.status <> 'canceled'
             then round(extract(epoch from
               case when f.actual_out is not null and f.scheduled_out is not null then f.actual_out - f.scheduled_out
                    else f.actual_off - f.scheduled_off end) / 60)::int end as departure) raw
    ) dl
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

revoke execute on function public.archive_landed_flights() from public, anon, authenticated;
grant execute on function public.archive_landed_flights() to service_role;
