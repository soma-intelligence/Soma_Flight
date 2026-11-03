begin;
create extension if not exists pgtap with schema extensions;
select plan(58);

insert into auth.users (id, instance_id, aud, role, email)
values
  ('a9a9a9a9-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'arch-a@test.local'),
  ('b9b9b9b9-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'arch-b@test.local');

-- F1: CDG to SFO, arrived 25 hours ago, 20 minutes early, two followers.
insert into flights (id, provider_id, ident, operator, origin_icao, destination_icao, status,
  scheduled_out, scheduled_in, actual_out, actual_in, aircraft_type, registration)
values ('f1000000-0000-0000-0000-000000000001', 'ARCH-F1', 'AFR84', 'AFR', 'LFPG', 'KSFO', 'arrived',
  now() - interval '36 hours', now() - interval '24 hours 40 minutes',
  now() - interval '36 hours', now() - interval '25 hours', 'A359', 'F-HTYM');
insert into user_flights (user_id, flight_id) values
  ('a9a9a9a9-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001'),
  ('b9b9b9b9-0000-0000-0000-000000000002', 'f1000000-0000-0000-0000-000000000001');
insert into push_tokens (user_id, token, kind, flight_id) values
  ('a9a9a9a9-0000-0000-0000-000000000001', 'arch-la-1', 'live_activity', 'f1000000-0000-0000-0000-000000000001'),
  ('a9a9a9a9-0000-0000-0000-000000000001', 'arch-alert-1', 'alert', null);

select is(archive_landed_flights(), 2, 'landed flight with two followers: two rows archived');
select is((select count(*) from past_flights where flight_id = 'f1000000-0000-0000-0000-000000000001'),
  2::bigint, 'one past_flights row per follower');
select ok((select bool_and(distance_km between 8900 and 9000) from past_flights
  where flight_id = 'f1000000-0000-0000-0000-000000000001'), 'CDG to SFO distance is about 8950 km');
select is((select count(*) from user_flights where flight_id = 'f1000000-0000-0000-0000-000000000001'),
  0::bigint, 'follows of the archived flight are gone');
select results_eq(
  $$select ident, origin_icao, destination_icao, airline, aircraft_type, registration, status::text,
       origin_tz, block_minutes, delay_minutes
    from past_flights where flight_id = 'f1000000-0000-0000-0000-000000000001'
    and user_id = 'a9a9a9a9-0000-0000-0000-000000000001'$$,
  $$values ('AFR84'::text, 'LFPG'::text, 'KSFO'::text, 'AFR'::text, 'A359'::text, 'F-HTYM'::text,
       'completed'::text, 'Europe/Paris'::text, 660, 0)$$,
  'archived row carries the PastFlight fields, origin_tz from airports, early arrival is delay 0');
select results_eq(
  $$select arrival_delay_minutes, departure_delay_minutes from past_flights
    where flight_id = 'f1000000-0000-0000-0000-000000000001' order by user_id$$,
  $$values (-20, 0), (-20, 0)$$,
  'signed delays: 20 minutes early stays -20 (delay_minutes floors it at 0), on time out is 0');
select is((select date from past_flights where flight_id = 'f1000000-0000-0000-0000-000000000001' limit 1),
  now() - interval '36 hours', 'date is the departure instant');
select is((select count(*) from push_tokens where token = 'arch-la-1'), 0::bigint,
  'Live Activity token of the archived follow is removed');
select is((select count(*) from push_tokens where token = 'arch-alert-1'), 1::bigint,
  'alert token is kept');

-- Idempotency: a rerun archives nothing; even a follow that comes back cannot duplicate a row.
select is(archive_landed_flights(), 0, 'second run archives nothing');
insert into user_flights (user_id, flight_id)
values ('a9a9a9a9-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001');
select is(archive_landed_flights(), 0, 'a re-follow of an archived flight adds no row');
select is((select count(*) from past_flights where flight_id = 'f1000000-0000-0000-0000-000000000001'),
  2::bigint, 'still two rows after reruns');
select throws_ok(
  $$insert into past_flights (user_id, flight_id, date, ident)
    values ('a9a9a9a9-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001', now(), 'X')$$,
  '23505', null, 'unique on (user_id, flight_id)');

-- F2: arrived 30 minutes ago. F3: diverted (planned KSFO, landed KOAK) 30 hours ago.
-- F4: out 23:30, in 01:10 the next day, 10 minutes late. F5: canceled 3 days ago, no actuals.
insert into flights (id, provider_id, ident, origin_icao, destination_icao, status,
  scheduled_out, scheduled_in, estimated_in, actual_out, actual_in)
values
  ('f2000000-0000-0000-0000-000000000002', 'ARCH-F2', 'UAL1', 'KSFO', 'KJFK', 'arrived',
   now() - interval '6 hours', now() - interval '40 minutes', null, now() - interval '6 hours', now() - interval '30 minutes'),
  ('f3000000-0000-0000-0000-000000000003', 'ARCH-F3', 'UAL2', 'KLAX', 'KOAK', 'diverted',
   now() - interval '32 hours', now() - interval '31 hours', null, now() - interval '32 hours', now() - interval '30 hours'),
  ('f4000000-0000-0000-0000-000000000004', 'ARCH-F4', 'UAL3', 'KSFO', 'KLAX', 'arrived',
   '2026-10-01 23:30:00+00', '2026-10-02 01:00:00+00', null, '2026-10-01 23:30:00+00', '2026-10-02 01:10:00+00'),
  ('f5000000-0000-0000-0000-000000000005', 'ARCH-F5', 'UAL4', 'KSFO', 'KSEA', 'canceled',
   now() - interval '74 hours', now() - interval '72 hours', now() - interval '72 hours', null, null);
insert into user_flights (user_id, flight_id) values
  ('a9a9a9a9-0000-0000-0000-000000000001', 'f2000000-0000-0000-0000-000000000002'),
  ('a9a9a9a9-0000-0000-0000-000000000001', 'f3000000-0000-0000-0000-000000000003'),
  ('a9a9a9a9-0000-0000-0000-000000000001', 'f4000000-0000-0000-0000-000000000004'),
  ('a9a9a9a9-0000-0000-0000-000000000001', 'f5000000-0000-0000-0000-000000000005');
select is(archive_landed_flights(), 3, 'diverted, overnight and canceled flights archived');
select is((select count(*) from past_flights where flight_id = 'f2000000-0000-0000-0000-000000000002'),
  0::bigint, 'flight arrived 30 minutes ago is not archived');
select is((select count(*) from user_flights where flight_id = 'f2000000-0000-0000-0000-000000000002'),
  1::bigint, 'its follow stays');
select results_eq(
  $$select destination_icao, status::text, origin_tz, delay_minutes from past_flights
    where flight_id = 'f3000000-0000-0000-0000-000000000003'$$,
  $$values ('KOAK'::text, 'diverted'::text, 'America/Los_Angeles'::text, 0)$$,
  'diverted flight: destination is where it landed, status diverted, delay 0');
select results_eq(
  $$select block_minutes, delay_minutes from past_flights where flight_id = 'f4000000-0000-0000-0000-000000000004'$$,
  $$values (100, 10)$$,
  'overnight flight: block 100 minutes, delay 10');
select results_eq(
  $$select status::text, block_minutes, delay_minutes from past_flights
    where flight_id = 'f5000000-0000-0000-0000-000000000005'$$,
  $$values ('canceled'::text, null::int, 0)$$,
  'canceled flight: status canceled, block null');
select results_eq(
  $$select arrival_delay_minutes, departure_delay_minutes from past_flights
    where flight_id = 'f3000000-0000-0000-0000-000000000003'$$,
  $$values (null::int, 0)$$,
  'diverted: no arrival delay (the scheduled arrival never happened), departure delay kept');
select results_eq(
  $$select arrival_delay_minutes, departure_delay_minutes from past_flights
    where flight_id = 'f4000000-0000-0000-0000-000000000004'$$,
  $$values (10, 0)$$,
  'overnight flight: arrival delay 10, departure 0');
select results_eq(
  $$select arrival_delay_minutes, departure_delay_minutes from past_flights
    where flight_id = 'f5000000-0000-0000-0000-000000000005'$$,
  $$values (null::int, null::int)$$,
  'canceled flight: neither delay');
select is((select count(*) from user_flights where user_id = 'a9a9a9a9-0000-0000-0000-000000000001'),
  1::bigint, 'only the recent follow is left');

-- Edge cases. E1: IATA codes only. E2: unknown origin airport. E3: landed with actual_on only, 30
-- minutes late. E4: actual_in before actual_out (bad data). E5: stuck en_route with actual_out
-- (80 h, no update for 50 h). E6: stuck scheduled, never left. E7: stuck at 71 h (not yet).
-- E8: stuck time but updated 10 h ago (not yet). E9: finished, follower's profile is deleted.
insert into auth.users (id, instance_id, aud, role, email) values
  ('c9c9c9c9-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'arch-c@test.local');
update profiles set status = 'deleted' where user_id = 'c9c9c9c9-0000-0000-0000-000000000003';
insert into flights (id, provider_id, ident, origin_icao, origin_iata, destination_icao, destination_iata,
  status, scheduled_out, scheduled_in, actual_out, actual_on, actual_in, updated_at)
values
  ('e1000000-0000-0000-0000-000000000001', 'ARCH-E1', 'AFR1', null, 'CDG', null, 'SFO', 'arrived',
   now() - interval '40 hours', now() - interval '29 hours', now() - interval '40 hours', null, now() - interval '29 hours', now()),
  ('e2000000-0000-0000-0000-000000000002', 'ARCH-E2', 'XX2', 'ZZZZ', null, 'KSFO', null, 'arrived',
   now() - interval '40 hours', now() - interval '29 hours', now() - interval '40 hours', null, now() - interval '29 hours', now()),
  ('e3000000-0000-0000-0000-000000000003', 'ARCH-E3', 'XX3', 'KSFO', null, 'KLAX', null, 'landed',
   now() - interval '40 hours', now() - interval '39 hours', now() - interval '40 hours', now() - interval '38 hours 30 minutes', null, now()),
  ('e4000000-0000-0000-0000-000000000004', 'ARCH-E4', 'XX4', 'KSFO', null, 'KLAX', null, 'arrived',
   now() - interval '40 hours', now() - interval '39 hours', now() - interval '38 hours', null, now() - interval '39 hours', now()),
  ('e5000000-0000-0000-0000-000000000005', 'ARCH-E5', 'XX5', 'KSFO', null, 'KJFK', null, 'en_route',
   now() - interval '86 hours', now() - interval '80 hours', now() - interval '86 hours', null, null, now() - interval '50 hours'),
  ('e6000000-0000-0000-0000-000000000006', 'ARCH-E6', 'XX6', 'KSFO', null, 'KJFK', null, 'scheduled',
   now() - interval '86 hours', now() - interval '80 hours', null, null, null, now() - interval '50 hours'),
  ('e7000000-0000-0000-0000-000000000007', 'ARCH-E7', 'XX7', 'KSFO', null, 'KJFK', null, 'scheduled',
   now() - interval '77 hours', now() - interval '71 hours', null, null, null, now() - interval '50 hours'),
  ('e8000000-0000-0000-0000-000000000008', 'ARCH-E8', 'XX8', 'KSFO', null, 'KJFK', null, 'en_route',
   now() - interval '86 hours', now() - interval '80 hours', now() - interval '86 hours', null, null, now() - interval '10 hours'),
  ('e9000000-0000-0000-0000-000000000009', 'ARCH-E9', 'XX9', 'KSFO', null, 'KJFK', null, 'arrived',
   now() - interval '40 hours', now() - interval '35 hours', now() - interval '40 hours', null, now() - interval '35 hours', now());
insert into user_flights (user_id, flight_id)
select 'b9b9b9b9-0000-0000-0000-000000000002', id from flights where provider_id like 'ARCH-E%' and provider_id <> 'ARCH-E9';
insert into user_flights (user_id, flight_id)
values ('c9c9c9c9-0000-0000-0000-000000000003', 'e9000000-0000-0000-0000-000000000009');
insert into push_tokens (user_id, token, kind, flight_id) values
  ('b9b9b9b9-0000-0000-0000-000000000002', 'arch-la-e6', 'live_activity', 'e6000000-0000-0000-0000-000000000006');

select is(archive_landed_flights(), 5, 'E1 to E5 archived; E6 dropped without a row; E7, E8, E9 none');
select results_eq(
  $$select origin_icao, destination_icao, distance_km between 8900 and 9000, origin_tz from past_flights
    where flight_id = 'e1000000-0000-0000-0000-000000000001'$$,
  $$values ('LFPG'::text, 'KSFO'::text, true, 'Europe/Paris'::text)$$,
  'IATA-only flight: airports matched on IATA for codes, distance and origin_tz');
select results_eq(
  $$select origin_icao, distance_km, origin_tz from past_flights where flight_id = 'e2000000-0000-0000-0000-000000000002'$$,
  $$values ('ZZZZ'::text, 0, null::text)$$,
  'unknown airport: distance 0, origin_tz null');
select results_eq(
  $$select block_minutes, delay_minutes from past_flights where flight_id = 'e3000000-0000-0000-0000-000000000003'$$,
  $$values (null::int, 30)$$,
  'landed without actual_in: no block, delay from actual_on');
select is((select block_minutes from past_flights where flight_id = 'e4000000-0000-0000-0000-000000000004'),
  null::int, 'actual_in before actual_out: block null');
select results_eq(
  $$select status::text, block_minutes, delay_minutes, distance_km > 0 from past_flights
    where flight_id = 'e5000000-0000-0000-0000-000000000005'$$,
  $$values ('completed'::text, null::int, 0, true)$$,
  'stuck flight that left: completed, block null, delay 0');
select results_eq(
  $$select flight_id::text, arrival_delay_minutes, departure_delay_minutes from past_flights
    where flight_id in ('e3000000-0000-0000-0000-000000000003', 'e4000000-0000-0000-0000-000000000004',
      'e5000000-0000-0000-0000-000000000005') order by flight_id$$,
  $$values ('e3000000-0000-0000-0000-000000000003'::text, null::int, 0),
           ('e4000000-0000-0000-0000-000000000004'::text, 0, 120),
           ('e5000000-0000-0000-0000-000000000005'::text, null::int, 0)$$,
  'runway actual without a scheduled runway time: no arrival; bad data gives a departure of 120; stuck flight: departure only');
select is((select count(*) from past_flights where flight_id = 'e6000000-0000-0000-0000-000000000006'),
  0::bigint, 'stuck flight never seen leaving: no row');
select is((select count(*) from user_flights where flight_id = 'e6000000-0000-0000-0000-000000000006'),
  0::bigint, 'stuck flight never seen leaving: follow removed');
select is((select count(*) from push_tokens where token = 'arch-la-e6'), 0::bigint,
  'stuck flight never seen leaving: Live Activity token removed');
select is((select array_agg(flight_id::text order by flight_id) from user_flights
  where user_id = 'b9b9b9b9-0000-0000-0000-000000000002'),
  array['e7000000-0000-0000-0000-000000000007', 'e8000000-0000-0000-0000-000000000008'],
  'stuck at 71 hours or updated recently: follows kept');
select is((select count(*) from past_flights where user_id = 'c9c9c9c9-0000-0000-0000-000000000003'),
  0::bigint, 'deleted profile: no past row');
select is((select count(*) from user_flights where user_id = 'c9c9c9c9-0000-0000-0000-000000000003'),
  0::bigint, 'deleted profile: follow removed');

-- past_flights fields the app decodes as non-optional are not null with defaults. (Rows written by
-- the archive: client rows are checked and completed by past_flights_fill, 20261030000013.)
insert into past_flights (user_id, date, source) values ('a9a9a9a9-0000-0000-0000-000000000001', now(), 'archive');
select results_eq(
  $$select ident, origin_icao, destination_icao, distance_km, delay_minutes, status::text
    from past_flights where user_id = 'a9a9a9a9-0000-0000-0000-000000000001' and flight_id is null$$,
  $$values (''::text, ''::text, ''::text, 0, 0, 'completed'::text)$$,
  'a row without a flight gets defaults');
select throws_ok(
  $$insert into past_flights (user_id, date, distance_km, source)
    values ('a9a9a9a9-0000-0000-0000-000000000001', now(), null, 'archive')$$,
  '23502', null, 'distance_km cannot be null');
select is(haversine_km(0, 0, 0, 180)::int, 20015, 'antipodal pair does not raise');

-- Alert sweep candidates: an alert on a flight nobody follows; not one that is followed.
update flights set alert_id = 900001 where id = 'f1000000-0000-0000-0000-000000000001';
update flights set alert_id = 900002 where id = 'f2000000-0000-0000-0000-000000000002';
select ok('f1000000-0000-0000-0000-000000000001'::uuid in (select orphan_alert_flights(1000)),
  'unfollowed flight with an alert is an orphan');
select ok('f2000000-0000-0000-0000-000000000002'::uuid not in (select orphan_alert_flights(1000)),
  'followed flight is not an orphan');

-- Prune: old rows go, recent or still needed rows stay.
insert into rate_events (user_id, endpoint, at) values
  ('a9a9a9a9-0000-0000-0000-000000000001', 'arch-old', now() - interval '3 hours'),
  ('a9a9a9a9-0000-0000-0000-000000000001', 'arch-new', now() - interval '10 minutes');
insert into webhook_inbox (body, received_at, processed_at) values
  ('{"t":"arch-old-done"}', now() - interval '31 days', now() - interval '31 days'),
  ('{"t":"arch-old-failed"}', now() - interval '31 days', null);
insert into flight_events (flight_id, provider_event_id, kind, received_at) values
  ('f1000000-0000-0000-0000-000000000001', 'arch-ev-unfollowed', 'arrival', now() - interval '91 days'),
  ('f2000000-0000-0000-0000-000000000002', 'arch-ev-followed', 'arrival', now() - interval '91 days');
insert into airport_snapshots (icao, kind, fetched_at, last_viewed_at) values
  ('LFPG', 'departures', now() - interval '8 days', now() - interval '8 days'),
  ('KSFO', 'departures', now() - interval '8 days', now() - interval '1 day');
insert into route_cache (origin_icao, destination_icao, date, fetched_at) values
  ('LFPG', 'KSFO', '2026-10-01', now() - interval '2 hours');
insert into rate_events (user_id, endpoint, at)
select 'a9a9a9a9-0000-0000-0000-000000000001', 'arch-loop', now() - interval '5 hours' from generate_series(1, 5);
select ok((prune_maintenance(2) ->> 'rate_events')::int >= 6, 'prune loops batches until one comes back short');
select ok((prune_maintenance(5000) ->> 'rate_events')::int >= 0, 'prune reports its counts');
select is((select array_agg(endpoint order by endpoint) from rate_events
  where user_id = 'a9a9a9a9-0000-0000-0000-000000000001'), array['arch-new'], 'old rate events pruned');
select is((select array_agg(body->>'t') from webhook_inbox where body->>'t' like 'arch-%'),
  array['arch-old-failed'], 'processed inbox rows pruned, failed ones kept for replay');
select is((select array_agg(provider_event_id) from flight_events where provider_event_id like 'arch-ev-%'),
  array['arch-ev-followed'], 'old events pruned only for unfollowed flights');
select is((select array_agg(icao) from airport_snapshots where icao in ('LFPG', 'KSFO')),
  array['KSFO'], 'snapshots not viewed for 7 days pruned');
select is((select count(*) from route_cache where origin_icao = 'LFPG' and destination_icao = 'KSFO'),
  0::bigint, 'expired route cache pruned');

-- Signed delays, gate versus runway. G1: runway times only, 12 minutes early. G2: gate says 5 late, runway says
-- 8 early (gate wins). G3: departure 70 hours late (clamped to the column's 2880), landed 3 minutes early.
insert into flights (id, provider_id, ident, origin_icao, destination_icao, status,
  scheduled_off, actual_off, scheduled_on, actual_on, scheduled_out, scheduled_in, actual_out, actual_in)
values
  ('a1000000-0000-0000-0000-000000000001', 'ARCH-G1', 'GG1', 'KSFO', 'KLAX', 'arrived',
   now() - interval '40 hours', now() - interval '41 hours', now() - interval '38 hours', now() - interval '38 hours 12 minutes',
   null, null, null, null),
  ('a2000000-0000-0000-0000-000000000002', 'ARCH-G2', 'GG2', 'KSFO', 'KLAX', 'arrived',
   now() - interval '40 hours', now() - interval '40 hours', now() - interval '38 hours', now() - interval '38 hours 8 minutes',
   now() - interval '41 hours', now() - interval '38 hours', now() - interval '41 hours 10 minutes', now() - interval '37 hours 55 minutes'),
  ('a3000000-0000-0000-0000-000000000003', 'ARCH-G3', 'GG3', 'KSFO', 'KLAX', 'arrived',
   null, null, null, null,
   now() - interval '100 hours', now() - interval '30 hours 3 minutes', now() - interval '30 hours', now() - interval '30 hours 6 minutes');
insert into user_flights (user_id, flight_id)
select 'b9b9b9b9-0000-0000-0000-000000000002', id from flights where provider_id like 'ARCH-G%';
select is(archive_landed_flights(), 3, 'G1 to G3 archived');
select results_eq(
  $$select ident, arrival_delay_minutes, departure_delay_minutes from past_flights
    where flight_id::text like 'a_000000-0000-0000-0000-00000000000_' order by ident$$,
  $$values ('GG1'::text, -12, -60), ('GG2'::text, 5, -10), ('GG3'::text, -3, 2880)$$,
  'runway fallback, gate wins over runway, departure clamped to 2880');
select ok((select bool_and(delay_minutes >= 0) from past_flights where ident in ('GG1', 'GG2', 'GG3')),
  'delay_minutes keeps its floor at 0 beside the signed columns');

-- Grants: service role only, and new public functions start closed to clients.
select ok(not has_function_privilege('anon', 'public.archive_landed_flights()', 'execute')
  and not has_function_privilege('authenticated', 'public.archive_landed_flights()', 'execute')
  and not has_function_privilege('authenticated', 'public.invoke_edge_function(text, text)', 'execute')
  and has_function_privilege('service_role', 'public.archive_landed_flights()', 'execute'),
  'job functions are service role only');
select ok(not has_function_privilege('anon', 'public.handle_new_user()', 'execute')
  and not has_function_privilege('authenticated', 'public.handle_new_user()', 'execute'),
  'handle_new_user is not executable by clients');
-- Guard: no function in public may be executable by anon or authenticated (directly or through
-- PUBLIC). Allow-list for deliberate client RPCs: gate_history (gate prediction, 20261030000020) and the
-- Friends reads and own-row changes (20261031000022), friend_avatars (20261031000030) and airport_regulars
-- (20261031000035), each checking auth.uid() itself.
select is_empty(
  $$select p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and (has_function_privilege('anon', p.oid, 'execute')
           or has_function_privilege('authenticated', p.oid, 'execute'))
      and p.oid::regprocedure::text <> all (array['gate_history(text,text,text,date,integer)',
        'friends_me()', 'friends_list()', 'friend_requests()', 'friend_remove(uuid)', 'friend_flights(uuid)',
        'friend_passport(uuid)', 'friend_avatars()', 'airport_regulars(text)'])$$,
  'no public function is executable by anon or authenticated');

-- Guard: every function in public pins search_path to the empty string (extension-owned ones excepted).
select is(
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
      and not coalesce(p.proconfig @> array['search_path=""'], false)),
  0::bigint, 'every public function sets search_path to the empty string');

-- Cron jobs and the pg_net call through Vault (rolled back: nothing is sent).
select bag_has('select jobname::text from cron.job',
  $$values ('archive-landed-flights'), ('maintenance-alerts'), ('maintenance-prune'), ('usage-alert'),
    ('cron-history-prune')$$,
  'the five jobs are scheduled');
select is((select schedule from cron.job where jobname = 'usage-alert'), '0 8-11 * * *',
  'usage-alert retries hourly until 11:00');
-- Inside this transaction only: the rollback restores any real secrets of the same names.
delete from vault.secrets where name in ('functions_base_url', 'service_role_key');
select vault.create_secret('http://example.test/functions/v1/', 'functions_base_url');
select vault.create_secret('test-service-key', 'service_role_key');
create temp table t9_request on commit drop as
  select invoke_edge_function('maintenance', 'mode=alerts') as id;
select results_eq(
  $$select q.url, q.headers->>'Authorization' from net.http_request_queue q join t9_request r on q.id = r.id$$,
  $$values ('http://example.test/functions/v1/maintenance?mode=alerts'::text, 'Bearer test-service-key'::text)$$,
  'invoke_edge_function posts to the Vault URL with the Vault key');

select * from finish();
rollback;
