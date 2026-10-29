begin;
create extension if not exists pgtap with schema extensions;
select plan(32);

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

-- F2: arrived 2 hours ago. F3: diverted (planned KSFO, landed KOAK) 30 hours ago.
-- F4: out 23:30, in 01:10 the next day, 10 minutes late. F5: canceled 3 days ago, no actuals.
insert into flights (id, provider_id, ident, origin_icao, destination_icao, status,
  scheduled_out, scheduled_in, estimated_in, actual_out, actual_in)
values
  ('f2000000-0000-0000-0000-000000000002', 'ARCH-F2', 'UAL1', 'KSFO', 'KJFK', 'arrived',
   now() - interval '8 hours', now() - interval '2 hours', null, now() - interval '8 hours', now() - interval '2 hours'),
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
  0::bigint, 'flight arrived 2 hours ago is not archived');
select is((select count(*) from user_flights where flight_id = 'f2000000-0000-0000-0000-000000000002'),
  1::bigint, 'its follow stays');
select results_eq(
  $$select destination_icao, status::text, origin_tz from past_flights
    where flight_id = 'f3000000-0000-0000-0000-000000000003'$$,
  $$values ('KOAK'::text, 'diverted'::text, 'America/Los_Angeles'::text)$$,
  'diverted flight: destination is where it landed, status diverted');
select results_eq(
  $$select block_minutes, delay_minutes from past_flights where flight_id = 'f4000000-0000-0000-0000-000000000004'$$,
  $$values (100, 10)$$,
  'overnight flight: block 100 minutes, delay 10');
select results_eq(
  $$select status::text, block_minutes, delay_minutes from past_flights
    where flight_id = 'f5000000-0000-0000-0000-000000000005'$$,
  $$values ('canceled'::text, null::int, 0)$$,
  'canceled flight: status canceled, block null');
select is((select count(*) from user_flights where user_id = 'a9a9a9a9-0000-0000-0000-000000000001'),
  1::bigint, 'only the recent follow is left');

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
select ok((prune_maintenance(5000) ->> 'rate_events')::int >= 1, 'prune reports its counts');
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

-- Grants: service role only, and new public functions start closed to clients.
select ok(not has_function_privilege('anon', 'public.archive_landed_flights()', 'execute')
  and not has_function_privilege('authenticated', 'public.archive_landed_flights()', 'execute')
  and not has_function_privilege('authenticated', 'public.invoke_edge_function(text, text)', 'execute')
  and has_function_privilege('service_role', 'public.archive_landed_flights()', 'execute'),
  'job functions are service role only');
select ok(not has_function_privilege('anon', 'public.handle_new_user()', 'execute')
  and not has_function_privilege('authenticated', 'public.handle_new_user()', 'execute'),
  'handle_new_user is not executable by clients');
create function public.t9_default_probe() returns int language sql as 'select 1';
select ok(not has_function_privilege('anon', 'public.t9_default_probe()', 'execute')
  and not has_function_privilege('authenticated', 'public.t9_default_probe()', 'execute'),
  'a new public function is not executable by anon or authenticated by default');

-- Cron jobs and the pg_net call through Vault (rolled back: nothing is sent).
select bag_has('select jobname::text from cron.job',
  $$values ('archive-landed-flights'), ('maintenance-alerts'), ('maintenance-prune'), ('usage-alert')$$,
  'the four jobs are scheduled');
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
