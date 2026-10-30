begin;
create extension if not exists pgtap with schema extensions;
select plan(32);

insert into auth.users (id, instance_id, aud, role, email)
values
  ('a3a3a3a3-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'manual-a@test.local'),
  ('b3b3b3b3-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'manual-b@test.local');

-- An archived row for A: SFO to CDG, landed, archived by the job.
insert into flights (id, provider_id, ident, origin_icao, destination_icao, status,
  scheduled_out, scheduled_in, actual_out, actual_off, actual_on, actual_in)
values ('c3000000-0000-0000-0000-000000000001', 'MANUAL-H1', 'AFR85', 'KSFO', 'LFPG', 'arrived',
  now() - interval '40 hours', now() - interval '25 hours',
  now() - interval '40 hours', now() - interval '39 hours', now() - interval '32 hours',
  now() - interval '31 hours');
insert into user_flights (user_id, flight_id) values
  ('a3a3a3a3-0000-0000-0000-000000000001', 'c3000000-0000-0000-0000-000000000001');
select is(public.archive_landed_flights(), 1, 'the landed follow is archived');
select is((select source::text from past_flights where flight_id = 'c3000000-0000-0000-0000-000000000001'),
  'archive', 'an archived row has source archive');

-- As A.
set local role authenticated;
set local request.jwt.claims = '{"sub":"a3a3a3a3-0000-0000-0000-000000000001","role":"authenticated"}';

-- Insert and fill-in: IATA codes become ICAO, the distance, countries and origin zone come from airports.
select lives_ok(
  $$insert into past_flights (id, date, ident, origin_icao, destination_icao, distance_km, seat, seat_class,
      reason, seat_position, notes)
    values ('e3000000-0000-0000-0000-000000000001', '2024-03-14T12:00:00Z', 'af 84', 'sfo', 'CDG', null,
      '12A', 'business', 'personal', 'window', 'Honeymoon')$$,
  'A adds a manual past flight without user_id and without derived fields');
select results_eq(
  $$select user_id::text, source::text, ident, origin_icao, destination_icao, distance_km between 8900 and 9000,
      origin_country, destination_country, origin_tz, delay_minutes, status::text
    from past_flights where id = 'e3000000-0000-0000-0000-000000000001'$$,
  $$values ('a3a3a3a3-0000-0000-0000-000000000001'::text, 'manual'::text, 'AF84'::text, 'KSFO'::text,
      'LFPG'::text, true, 'US'::text, 'FR'::text, 'America/Los_Angeles'::text, 0, 'completed'::text)$$,
  'the row is A''s, manual, tidied and completed from airports');
select lives_ok(
  $$insert into past_flights (date, origin_icao, destination_icao, distance_km, source)
    values ('2023-01-02T09:00:00Z', 'EGLL', 'KJFK', 5555, 'import')$$,
  'A imports a past flight with its own distance');
select results_eq(
  $$select ident, distance_km, origin_country from past_flights where source = 'import'$$,
  $$values (''::text, 5555, 'GB'::text)$$,
  'a distance given by the client is kept; a missing flight number is empty');
select lives_ok(
  $$insert into past_flights (date, origin_icao, destination_icao) values ('2022-05-05T10:00:00Z', 'ZZZZ', 'KJFK')$$,
  'an airport missing from airports is accepted as typed');
select results_eq(
  $$select distance_km, origin_country, destination_country, origin_tz from past_flights where origin_icao = 'ZZZZ'$$,
  $$values (0, null::text, 'US'::text, null::text)$$,
  'what airports does not know stays empty (distance 0)');

-- Update: the route moves, the derived fields follow; the owner can delete.
select lives_ok(
  $$update past_flights set destination_icao = 'JFK', notes = 'Moved'
    where id = 'e3000000-0000-0000-0000-000000000001'$$,
  'A edits its manual flight');
select results_eq(
  $$select destination_icao, distance_km between 4100 and 4200, destination_country, notes from past_flights
    where id = 'e3000000-0000-0000-0000-000000000001'$$,
  $$values ('KJFK'::text, true, 'US'::text, 'Moved'::text)$$,
  'a moved route recomputes distance and country');
select lives_ok(
  $$update past_flights set registration = 'f-gznb' where id = 'e3000000-0000-0000-0000-000000000001'$$,
  'A sets a registration');
select is((select distance_km between 4100 and 4200 from past_flights where id = 'e3000000-0000-0000-0000-000000000001'),
  true, 'an edit that keeps the route keeps the distance');

-- Archived rows stay read only.
select is((select count(*) from past_flights), 4::bigint, 'A reads its archived, manual and imported rows');
update past_flights set notes = 'mine now', seat = '1A' where source = 'archive';
select is((select count(*) from past_flights where source = 'archive' and notes is null), 1::bigint,
  'an update of an archived row changes nothing');
delete from past_flights where source = 'archive';
select is((select count(*) from past_flights where source = 'archive'), 1::bigint,
  'a delete of an archived row removes nothing');
select throws_ok(
  $$update past_flights set source = 'archive' where id = 'e3000000-0000-0000-0000-000000000001'$$,
  '42501', null, 'a manual row cannot become archived');
select throws_ok(
  $$insert into past_flights (date, origin_icao, destination_icao, source)
    values ('2024-01-01T00:00:00Z', 'KSFO', 'KJFK', 'archive')$$,
  '42501', null, 'a client cannot insert an archived row');
select throws_ok(
  $$insert into past_flights (flight_id, date, origin_icao, destination_icao)
    values ('c3000000-0000-0000-0000-000000000001', '2024-01-01T00:00:00Z', 'KSFO', 'KJFK')$$,
  '42501', null, 'a client row tied to a flight counts as archived and is refused');

-- Validation.
select throws_ok(
  $$insert into past_flights (date, origin_icao, destination_icao) values ('2024-01-01T00:00:00Z', 'KSFO', 'KSFO')$$,
  '23514', null, 'origin and destination differ');
select throws_ok(
  $$insert into past_flights (date, origin_icao, destination_icao) values ('2024-01-01T00:00:00Z', 'SF', 'KJFK')$$,
  '23514', null, 'airport codes are three or four letters and digits');
select throws_ok(
  $$insert into past_flights (date, origin_icao, destination_icao) values ('2024-01-01T00:00:00Z', '', 'KJFK')$$,
  '23514', null, 'a client row needs both airports');
select throws_ok(
  $$insert into past_flights (date, origin_icao, destination_icao) values (now() + interval '3 days', 'KSFO', 'KJFK')$$,
  '23514', null, 'a date in the future is refused');
select throws_ok(
  $$insert into past_flights (date, origin_icao, destination_icao) values ('1900-01-01T00:00:00Z', 'KSFO', 'KJFK')$$,
  '23514', null, 'a date before airline travel is refused');
select throws_ok(
  $$insert into past_flights (date, ident, origin_icao, destination_icao)
    values ('2024-01-01T00:00:00Z', 'NOT A FLIGHT', 'KSFO', 'KJFK')$$,
  '23514', null, 'the flight number is checked');
select throws_ok(
  $$insert into past_flights (date, origin_icao, destination_icao, distance_km)
    values ('2024-01-01T00:00:00Z', 'KSFO', 'KJFK', -5)$$,
  '23514', null, 'the distance is never negative');
select throws_ok(
  $$insert into past_flights (date, origin_icao, destination_icao, aircraft_type)
    values ('2024-01-01T00:00:00Z', 'KSFO', 'KJFK', 'Boeing 737')$$,
  '23514', null, 'the aircraft type is an ICAO designator');
select throws_ok(
  $$insert into past_flights (date, origin_icao, destination_icao, seat)
    values ('2024-01-01T00:00:00Z', 'KSFO', 'KJFK', 'aisle')$$,
  '23514', null, 'the seat format still applies');

-- As B: A's rows are out of reach, and B cannot write a row for A.
set local request.jwt.claims = '{"sub":"b3b3b3b3-0000-0000-0000-000000000002","role":"authenticated"}';
select is((select count(*) from past_flights), 0::bigint, 'B sees none of A''s past flights');
update past_flights set notes = 'B was here';
delete from past_flights;
select throws_ok(
  $$insert into past_flights (user_id, date, origin_icao, destination_icao)
    values ('a3a3a3a3-0000-0000-0000-000000000001', '2024-01-01T00:00:00Z', 'KSFO', 'KJFK')$$,
  '42501', null, 'B cannot add a past flight for A');
reset role;
select results_eq(
  $$select count(*), count(*) filter (where notes = 'B was here') from past_flights
    where user_id = 'a3a3a3a3-0000-0000-0000-000000000001'$$,
  $$values (4::bigint, 0::bigint)$$,
  'B changed and deleted none of A''s rows');

-- The owner deletes its own manual row.
set local role authenticated;
set local request.jwt.claims = '{"sub":"a3a3a3a3-0000-0000-0000-000000000001","role":"authenticated"}';
delete from past_flights where id = 'e3000000-0000-0000-0000-000000000001';
select is((select count(*) from past_flights where id = 'e3000000-0000-0000-0000-000000000001'), 0::bigint,
  'A deletes its manual flight');
reset role;

-- The trigger function is not callable by clients.
select ok(not has_function_privilege('authenticated', 'public.past_flights_fill()', 'execute'),
  'clients cannot call the fill-in function');

select * from finish();
rollback;
