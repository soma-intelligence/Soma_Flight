begin;
create extension if not exists pgtap with schema extensions;
select plan(36);

insert into auth.users (id, instance_id, aud, role, email)
values
  ('a1a1a1a1-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'v11-a@test.local'),
  ('b1b1b1b1-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'v11-b@test.local');

-- G1: KSFO to LFPG, arrived 25 hours ago, off and on 7 hours apart. A follows with fields, B without.
-- G2: a second flight, not yet landed, for the update tests.
insert into flights (id, provider_id, ident, origin_icao, destination_icao, status,
  scheduled_out, scheduled_in, actual_out, actual_off, actual_on, actual_in)
values ('c1000000-0000-0000-0000-000000000001', 'V11-G1', 'AFR85', 'KSFO', 'LFPG', 'arrived',
  now() - interval '40 hours', now() - interval '25 hours',
  now() - interval '40 hours', now() - interval '39 hours', now() - interval '32 hours',
  now() - interval '31 hours');
insert into flights (id, provider_id, ident, status, scheduled_out)
values ('c1000000-0000-0000-0000-000000000002', 'V11-G2', 'AFR86', 'scheduled', now() + interval '2 days');
insert into user_flights (user_id, flight_id) values
  ('a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001'),
  ('b1b1b1b1-0000-0000-0000-000000000002', 'c1000000-0000-0000-0000-000000000001'),
  ('a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000002');

-- As user A.
set local role authenticated;
set local request.jwt.claims = '{"sub":"a1a1a1a1-0000-0000-0000-000000000001","role":"authenticated"}';

select lives_ok(
  $$update user_flights set seat_class = 'business', seat = '12A', reason = 'business',
      booking_code = 'ABC123', notes = 'aisle please'
    where flight_id = 'c1000000-0000-0000-0000-000000000001'$$,
  'A updates the five user fields on own follow');
select results_eq(
  $$select seat_class::text, seat, reason::text, booking_code, notes from user_flights
    where flight_id = 'c1000000-0000-0000-0000-000000000001'$$,
  $$values ('business'::text, '12A'::text, 'business'::text, 'ABC123'::text, 'aisle please'::text)$$,
  'the five fields are stored');
select lives_ok(
  $$update user_flights set seat_class = null, seat = null, reason = null, booking_code = null, notes = null
    where flight_id = 'c1000000-0000-0000-0000-000000000002'$$,
  'A can clear the fields');
select throws_ok($$update user_flights set seat = 'hello'$$, '23514', null, 'seat must look like 12A');
select throws_ok($$update user_flights set seat = '1234A'$$, '23514', null, 'seat row is at most 3 digits');
select throws_ok($$update user_flights set booking_code = 'ab'$$, '23514', null, 'booking code: too short and lower case');
select throws_ok($$update user_flights set booking_code = 'ABCDEFGHI'$$, '23514', null, 'booking code: at most 8');
select throws_ok($$update user_flights set notes = repeat('x', 2001)$$, '23514', null, 'notes: at most 2000 characters');
select lives_ok($$update user_flights set notes = repeat('x', 2000) where flight_id = 'c1000000-0000-0000-0000-000000000002'$$,
  'notes: 2000 characters is fine');
select throws_ok($$update user_flights set user_id = 'b1b1b1b1-0000-0000-0000-000000000002'$$, '42501', null,
  'A cannot update user_id');
select throws_ok($$update user_flights set flight_id = 'c1000000-0000-0000-0000-000000000002'$$, '42501', null,
  'A cannot update flight_id');
select throws_ok($$update user_flights set notify = false$$, '42501', null, 'A cannot update notify');
select throws_ok(
  $$insert into user_flights (user_id, flight_id)
    values ('a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000002')$$,
  '42501', null, 'A cannot insert a follow');
select throws_ok($$delete from user_flights$$, '42501', null, 'A cannot delete a follow');

-- As user B: A's rows are invisible, the update touches nothing.
set local request.jwt.claims = '{"sub":"b1b1b1b1-0000-0000-0000-000000000002","role":"authenticated"}';
select lives_ok(
  $$update user_flights set seat = '1A' where flight_id = 'c1000000-0000-0000-0000-000000000002'$$,
  'B updating A''s follow raises nothing');

-- aircraft: readable by signed-in users, not writable.
select lives_ok($$select * from aircraft$$, 'aircraft is readable by authenticated');
select throws_ok($$insert into aircraft (registration) values ('F-TEST')$$, '42501', null,
  'aircraft is not writable by authenticated');
select throws_ok($$update aircraft set name = 'x'$$, '42501', null, 'aircraft is not updatable by authenticated');
reset role;
select is((select seat from user_flights where flight_id = 'c1000000-0000-0000-0000-000000000002'
    and user_id = 'a1a1a1a1-0000-0000-0000-000000000001'), null,
  'B''s update touched 0 rows: A''s seat is unchanged');

-- Archiving copies the fields, countries and air time.
select is(archive_landed_flights(), 2, 'both followers of the landed flight are archived');
select results_eq(
  $$select seat_class::text, seat, reason::text, booking_code, notes, origin_country, destination_country, air_minutes
    from past_flights where user_id = 'a1a1a1a1-0000-0000-0000-000000000001'$$,
  $$values ('business'::text, '12A'::text, 'business'::text, 'ABC123'::text, 'aisle please'::text,
       'US'::text, 'FR'::text, 420)$$,
  'A''s row carries the five fields, both countries and 420 air minutes');
select results_eq(
  $$select seat_class::text, seat, reason::text, booking_code, notes, origin_country, destination_country, air_minutes
    from past_flights where user_id = 'b1b1b1b1-0000-0000-0000-000000000002'$$,
  $$values (null::text, null::text, null::text, null::text, null::text, 'US'::text, 'FR'::text, 420)$$,
  'B''s row has null user fields, same countries and air time');

-- air_minutes stays null without both times or when on is not after off; countries null for unknown airports.
insert into flights (id, provider_id, ident, origin_icao, destination_icao, status,
  scheduled_out, scheduled_in, actual_out, actual_off, actual_on, actual_in)
values ('c1000000-0000-0000-0000-000000000003', 'V11-G3', 'AFR87', 'ZZZZ', 'LFPG', 'arrived',
  now() - interval '40 hours', now() - interval '25 hours',
  now() - interval '40 hours', null, now() - interval '32 hours', now() - interval '31 hours');
insert into user_flights (user_id, flight_id)
values ('a1a1a1a1-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000003');
select is(archive_landed_flights(), 1, 'flight without actual_off archives');
select results_eq(
  $$select air_minutes, origin_country, destination_country from past_flights
    where flight_id = 'c1000000-0000-0000-0000-000000000003'$$,
  $$values (null::int, null::text, 'FR'::text)$$,
  'no actual_off: air_minutes null; unknown origin airport: country null');

-- merge_flight and upsert_provider_flights: the new times, result order, and lock order. A trigger
-- logs the order in which new rows are inserted; the batch is fed in reverse provider_id order, so
-- the log is ascending only if the function sorts before it locks and inserts.
create table v11_ins_log (seq serial, pid text);
create function v11_log_ins() returns trigger language plpgsql set search_path = '' as $$
begin
  if new.provider_id like 'V11-%' then insert into public.v11_ins_log (pid) values (new.provider_id); end if;
  return new;
end; $$;
create trigger v11_log_ins before insert on flights for each row execute function v11_log_ins();
select results_eq(
  $$select provider_id from upsert_provider_flights(jsonb_build_array(
      jsonb_build_object('provider_id', 'V11-ZZ', 'ident', 'T2', 'scheduled_off', '2026-11-03T01:00:00Z',
        'estimated_on', '2026-11-03T11:00:00Z'),
      jsonb_build_object('provider_id', 'V11-MM', 'ident', 'T3'),
      jsonb_build_object('provider_id', 'V11-AA', 'ident', 'T1')))$$,
  $$values ('V11-ZZ'::text), ('V11-MM'::text), ('V11-AA'::text)$$,
  'upsert_provider_flights returns rows in input order');
select results_eq(
  $$select pid from v11_ins_log order by seq$$,
  $$values ('V11-AA'::text), ('V11-MM'::text), ('V11-ZZ'::text)$$,
  'rows are inserted (and so locked) in provider_id order, not input order');
select is((select scheduled_off from flights where provider_id = 'V11-ZZ'), '2026-11-03T01:00:00Z'::timestamptz,
  'a new flight stores scheduled_off');
select results_eq(
  $$select provider_id, estimated_off, estimated_on from upsert_provider_flights(jsonb_build_array(
      jsonb_build_object('provider_id', 'V11-ZZ', 'ident', 'T2', 'estimated_off', '2026-11-03T01:10:00Z',
        'actual_on', '2026-11-03T11:30:00Z'),
      jsonb_build_object('provider_id', 'V11-ZZ', 'ident', 'T2', 'estimated_on', '2026-11-03T12:00:00Z')))$$,
  $$values ('V11-ZZ'::text, '2026-11-03T01:10:00Z'::timestamptz, '2026-11-03T11:00:00Z'::timestamptz),
           ('V11-ZZ'::text, '2026-11-03T01:10:00Z'::timestamptz, '2026-11-03T11:00:00Z'::timestamptz)$$,
  'a known flight merges estimated_off; estimated_on is frozen once actual_on exists');

-- past_flights is client-writable for the owner: the same checks apply to manual entries.
set local role authenticated;
set local request.jwt.claims = '{"sub":"a1a1a1a1-0000-0000-0000-000000000001","role":"authenticated"}';
select lives_ok($$insert into past_flights (user_id, date, ident, origin_icao, destination_icao, seat, booking_code, notes)
  values ('a1a1a1a1-0000-0000-0000-000000000001', now(), 'MAN1', 'LFPG', 'KJFK', '3C', 'ABCDE', 'manual')$$,
  'owner inserts a manual past flight with valid fields');
select throws_ok($$insert into past_flights (user_id, date, ident, origin_icao, destination_icao, seat)
  values ('a1a1a1a1-0000-0000-0000-000000000001', now(), 'MAN2', 'LFPG', 'KJFK', 'Window')$$, '23514', null,
  'past_flights seat is checked on new writes');
select throws_ok($$insert into past_flights (user_id, date, ident, origin_icao, destination_icao, booking_code)
  values ('a1a1a1a1-0000-0000-0000-000000000001', now(), 'MAN3', 'LFPG', 'KJFK', 'abc')$$, '23514', null,
  'past_flights booking_code is checked');
select throws_ok($$insert into past_flights (user_id, date, ident, origin_icao, destination_icao, notes)
  values ('a1a1a1a1-0000-0000-0000-000000000001', now(), 'MAN4', 'LFPG', 'KJFK', repeat('x', 2001))$$, '23514', null,
  'past_flights notes are checked');
reset role;
select is((select convalidated from pg_constraint where conname = 'past_flights_seat_check'), false,
  'the seat check is NOT VALID: stored rows are not checked');

-- Backfill rule (same statement as the migration): ICAO or IATA, ICAO wins; unknown stays null.
insert into past_flights (id, user_id, date, ident, origin_icao, destination_icao) values
  ('d1000000-0000-0000-0000-000000000001', 'a1a1a1a1-0000-0000-0000-000000000001', now(), 'BF1', 'SFO', 'LFPG'),
  ('d1000000-0000-0000-0000-000000000002', 'a1a1a1a1-0000-0000-0000-000000000001', now(), 'BF2', 'ZZZZ', 'CDG');
update past_flights p set origin_country = (
  select a.country from airports a where a.icao = p.origin_icao or a.iata = p.origin_icao
  order by (a.icao = p.origin_icao) desc limit 1)
  where p.origin_country is null and p.id::text like 'd1000000%';
update past_flights p set destination_country = (
  select a.country from airports a where a.icao = p.destination_icao or a.iata = p.destination_icao
  order by (a.icao = p.destination_icao) desc limit 1)
  where p.destination_country is null and p.id::text like 'd1000000%';
select results_eq(
  $$select ident, origin_country, destination_country from past_flights
    where id::text like 'd1000000%' order by ident$$,
  $$values ('BF1'::text, 'US'::text, 'FR'::text), ('BF2'::text, null::text, 'FR'::text)$$,
  'backfill matches IATA as well as ICAO, unknown airports stay null');

-- anon has no access to aircraft.
set local role anon;
select throws_ok($$select * from aircraft$$, '42501', null, 'anon cannot read aircraft');
reset role;

-- Privileges of the functions this migration restates.
select ok(
  not has_function_privilege('authenticated', 'public.archive_landed_flights()', 'execute')
  and not has_function_privilege('anon', 'public.upsert_provider_flights(jsonb)', 'execute')
  and has_function_privilege('service_role', 'public.upsert_provider_flights(jsonb)', 'execute'),
  'restated functions keep their grants');

select * from finish();
rollback;
