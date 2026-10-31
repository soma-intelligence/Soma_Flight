-- Past flights the traveller adds by hand or imports from a CSV file. Until now past_flights was filled
-- only by archive_landed_flights; clients could already write it through the owner policy, but nothing
-- told their rows apart from archived ones or checked them.
--
-- source says where a row comes from: 'archive' (archive_landed_flights), 'manual' (the Add Past Flight
-- sheet) or 'import' (a CSV import). Clients insert, update and delete their own manual and imported
-- rows; archived rows stay read only for them. A row inserted with a flight_id is an archived row
-- (the archive is the only writer that knows the flight), which keeps archive_landed_flights unchanged.
--
-- Client rows are checked here (codes, flight number, aircraft, dates) and their derived fields
-- (distance, countries, origin time zone) are filled from airports when the client leaves them null.

create type past_flight_source as enum ('archive', 'manual', 'import');

alter table past_flights add column source past_flight_source not null default 'manual';
-- Rows stored so far: those tied to a flight came from the archive. (An archived row whose flight was
-- pruned since has lost its flight_id and reads as manual; the database is fresh, so there are none.)
update past_flights set source = 'archive' where flight_id is not null;

-- Clients may leave user_id out: the row is theirs.
alter table past_flights alter column user_id set default auth.uid();

-- Shape of client rows. The archive writes what the provider gives (an empty code when it is unknown),
-- so these apply to manual and imported rows only, except the distance which is never negative.
-- The date bound uses now(): it is checked when a row is written, which is the point (no flight
-- logged ahead of time). A day of slack covers a flight leaving later today in a zone ahead of UTC.
alter table past_flights
  add constraint past_flights_distance_check check (distance_km >= 0),
  add constraint past_flights_client_shape_check check (source = 'archive' or (
    flight_id is null
    and origin_icao ~ '^[A-Z0-9]{3,4}$'
    and destination_icao ~ '^[A-Z0-9]{3,4}$'
    and origin_icao <> destination_icao
    and ident ~ '^([A-Z0-9]{2,3}[0-9]{1,5}[A-Z]?)?$'
    and (airline is null or char_length(airline) between 1 and 80)
    and (aircraft_type is null or aircraft_type ~ '^[A-Z0-9]{2,4}$')
    and (registration is null or registration ~ '^[A-Z0-9-]{2,10}$')
    and (block_minutes is null or block_minutes >= 0)
    and (air_minutes is null or air_minutes >= 0)
    and date >= '1919-01-01T00:00:00Z'
    and date <= now() + interval '1 day'));

-- Row access: the owner reads every row of theirs, and writes only the ones that are not archived.
-- WITH CHECK runs after the BEFORE trigger below, so a client insert that carries a flight_id (turned
-- into an archived row by the trigger) is refused, and no update can turn a row into an archived one.
drop policy past_flights_owner on past_flights;
create policy past_flights_read_own on past_flights for select to authenticated
  using (auth.uid() = user_id);
create policy past_flights_insert_own on past_flights for insert to authenticated
  with check (auth.uid() = user_id and source <> 'archive');
create policy past_flights_update_own on past_flights for update to authenticated
  using (auth.uid() = user_id and source <> 'archive')
  with check (auth.uid() = user_id and source <> 'archive');
create policy past_flights_delete_own on past_flights for delete to authenticated
  using (auth.uid() = user_id and source <> 'archive');

-- Tidies and completes a client row before it is checked: codes and texts trimmed and upper cased, an
-- IATA airport code replaced by the airport's ICAO code, a null flight number or delay made empty or
-- zero, and the distance (great circle), both countries and the origin time zone filled from airports
-- when the client leaves them null (or 0 for the distance, the column default). When an update moves
-- the route and keeps the old derived values, they are worked out again. Archived rows pass untouched.
--
-- Security definer: haversine_km is service role only, and the airports read must not depend on the
-- caller. It reads airports and nothing else; a trigger function cannot be called directly.
create function public.past_flights_fill()
returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  o_icao text; o_lat float8; o_lon float8; o_tz text; o_country text;
  d_icao text; d_lat float8; d_lon float8; d_country text;
  moved boolean := false;
begin
  if tg_op = 'INSERT' and new.flight_id is not null then
    new.source := 'archive';
  end if;
  if new.source = 'archive' then
    return new;
  end if;

  new.ident := upper(regexp_replace(coalesce(new.ident, ''), '\s', '', 'g'));
  new.origin_icao := upper(btrim(coalesce(new.origin_icao, '')));
  new.destination_icao := upper(btrim(coalesce(new.destination_icao, '')));
  new.airline := nullif(btrim(new.airline), '');
  new.aircraft_type := nullif(upper(btrim(new.aircraft_type)), '');
  new.registration := nullif(upper(btrim(new.registration)), '');
  new.delay_minutes := coalesce(new.delay_minutes, 0);
  new.status := coalesce(new.status, 'completed');

  -- ICAO match wins over IATA, as in archive_landed_flights.
  select a.icao, a.lat, a.lon, a.tz, a.country into o_icao, o_lat, o_lon, o_tz, o_country
    from public.airports a where a.icao = new.origin_icao or a.iata = new.origin_icao
    order by (a.icao = new.origin_icao) desc limit 1;
  select a.icao, a.lat, a.lon, a.country into d_icao, d_lat, d_lon, d_country
    from public.airports a where a.icao = new.destination_icao or a.iata = new.destination_icao
    order by (a.icao = new.destination_icao) desc limit 1;
  new.origin_icao := coalesce(o_icao, new.origin_icao);
  new.destination_icao := coalesce(d_icao, new.destination_icao);

  if tg_op = 'UPDATE' then
    moved := (new.origin_icao, new.destination_icao) is distinct from (old.origin_icao, old.destination_icao);
  end if;

  if new.distance_km is null or new.distance_km = 0
     or (moved and new.distance_km = old.distance_km) then
    new.distance_km := coalesce(round(public.haversine_km(o_lat, o_lon, d_lat, d_lon))::int, 0);
  end if;
  if new.origin_country is null or (moved and new.origin_country is not distinct from old.origin_country) then
    new.origin_country := o_country;
  end if;
  if new.destination_country is null
     or (moved and new.destination_country is not distinct from old.destination_country) then
    new.destination_country := d_country;
  end if;
  if new.origin_tz is null or (moved and new.origin_tz is not distinct from old.origin_tz) then
    new.origin_tz := o_tz;
  end if;
  return new;
end;
$$;

revoke execute on function public.past_flights_fill() from public, anon, authenticated;

create trigger past_flights_fill
  before insert or update on past_flights
  for each row execute function public.past_flights_fill();
