begin;
create extension if not exists pgtap with schema extensions;
select plan(8);

insert into auth.users (id, instance_id, aud, role, email)
values
  ('a2a2a2a2-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'chips-a@test.local'),
  ('b2b2b2b2-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'chips-b@test.local');

-- H1: KSFO to LFPG, arrived 25 hours ago. A follows it.
insert into flights (id, provider_id, ident, origin_icao, destination_icao, status,
  scheduled_out, scheduled_in, actual_out, actual_off, actual_on, actual_in)
values ('c2000000-0000-0000-0000-000000000001', 'CHIPS-H1', 'AFR85', 'KSFO', 'LFPG', 'arrived',
  now() - interval '40 hours', now() - interval '25 hours',
  now() - interval '40 hours', now() - interval '39 hours', now() - interval '32 hours',
  now() - interval '31 hours');
insert into user_flights (user_id, flight_id) values
  ('a2a2a2a2-0000-0000-0000-000000000001', 'c2000000-0000-0000-0000-000000000001');

set local role authenticated;
set local request.jwt.claims = '{"sub":"a2a2a2a2-0000-0000-0000-000000000001","role":"authenticated"}';

select lives_ok(
  $$update user_flights set seat_class = 'private', reason = 'crew', seat_position = 'jumpseat', seat = null
    where flight_id = 'c2000000-0000-0000-0000-000000000001'$$,
  'A sets private, crew and a cockpit position without a seat');
select results_eq(
  $$select seat_class::text, reason::text, seat_position::text from user_flights
    where flight_id = 'c2000000-0000-0000-0000-000000000001'$$,
  $$values ('private'::text, 'crew'::text, 'jumpseat'::text)$$,
  'the three values are stored');
select throws_ok($$update user_flights set seat_position = 'wing'$$, '22P02', null,
  'seat_position takes only its six values');
select lives_ok(
  $$update user_flights set seat_position = 'pilot' where flight_id = 'c2000000-0000-0000-0000-000000000001'$$,
  'A changes the position');

-- As user B: A's row is out of reach.
set local request.jwt.claims = '{"sub":"b2b2b2b2-0000-0000-0000-000000000002","role":"authenticated"}';
update user_flights set seat_position = 'window';
reset role;
select is((select seat_position::text from user_flights
  where flight_id = 'c2000000-0000-0000-0000-000000000001'), 'pilot', 'B changes none of A''s rows');

select is(public.archive_landed_flights(), 1, 'the landed follow is archived');
select results_eq(
  $$select seat_class::text, reason::text, seat_position::text, seat from past_flights
    where flight_id = 'c2000000-0000-0000-0000-000000000001'$$,
  $$values ('private'::text, 'crew'::text, 'pilot'::text, null::text)$$,
  'the archived row carries class, reason and position');
select col_type_is('past_flights', 'seat_position', 'seat_position', 'past_flights.seat_position is the enum');

select * from finish();
rollback;
