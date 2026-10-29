begin;
create extension if not exists pgtap with schema extensions;
select plan(23);

insert into auth.users (id, instance_id, aud, role, email)
values ('d1d1d1d1-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated', 'final@test.local');
insert into flights (id, provider_id, ident, status)
values ('d1000000-0000-0000-0000-000000000001', 'fa-final-1', 'AF7', 'scheduled'),
       ('d1000000-0000-0000-0000-000000000002', 'fa-final-2', 'AF8', 'scheduled');
insert into user_flights (user_id, flight_id)
values ('d1d1d1d1-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001');

-- F5: clients read their follows, never write them.
set local role authenticated;
set local request.jwt.claims = '{"sub":"d1d1d1d1-0000-0000-0000-000000000001","role":"authenticated"}';
select is((select count(*) from user_flights), 1::bigint, 'a user reads its own follows');
select throws_ok(
  $$insert into user_flights (user_id, flight_id)
    values ('d1d1d1d1-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000002')$$,
  '42501', null, 'a user cannot insert its own follow');
select throws_ok(
  $$update user_flights set notify = false$$,
  '42501', null, 'a user cannot flip notify directly');
select throws_ok(
  $$delete from user_flights$$,
  '42501', null, 'a user cannot delete a follow directly');
reset role;
select ok(not has_table_privilege('authenticated', 'public.user_flights', 'insert')
  and not has_table_privilege('authenticated', 'public.user_flights', 'update')
  and not has_table_privilege('authenticated', 'public.user_flights', 'delete')
  and has_table_privilege('authenticated', 'public.user_flights', 'select'),
  'authenticated holds select only on user_flights');

-- F11: a lookup never moves the webhook's fields backwards.
update flights set status = 'departed', actual_out = '2026-11-03T22:40:00Z',
  estimated_in = '2026-11-04T09:20:00Z', gate_origin = 'K42'
where id = 'd1000000-0000-0000-0000-000000000001';
select is(
  (select status::text from upsert_provider_flights(jsonb_build_array(jsonb_build_object(
    'provider_id', 'fa-final-1', 'ident', 'AF7', 'status', 'scheduled',
    'actual_out', null, 'estimated_out', '2026-11-03T22:30:00Z', 'gate_origin', null,
    'estimated_in', '2026-11-04T09:05:00Z')))),
  'departed', 'a lagging lookup keeps the departed status');
select results_eq(
  $$select actual_out, estimated_in, gate_origin from flights where provider_id = 'fa-final-1'$$,
  $$values ('2026-11-03T22:40:00Z'::timestamptz, '2026-11-04T09:05:00Z'::timestamptz, 'K42'::text)$$,
  'actuals and gates stay, a newer estimate is taken');
select is(
  (select status::text from upsert_provider_flights(jsonb_build_array(jsonb_build_object(
    'provider_id', 'fa-final-1', 'ident', 'AF7', 'status', 'en_route',
    'actual_off', '2026-11-03T22:55:00Z')))),
  'en_route', 'a lookup that is ahead raises the status');
update flights set status = 'canceled' where id = 'd1000000-0000-0000-0000-000000000002';
select is(
  (select status::text from upsert_provider_flights(jsonb_build_array(jsonb_build_object(
    'provider_id', 'fa-final-2', 'ident', 'AF8', 'status', 'scheduled')))),
  'canceled', 'canceled is sticky against a lookup');
select is(
  (select status::text from upsert_provider_flights(jsonb_build_array(jsonb_build_object(
    'provider_id', 'fa-final-3', 'ident', 'AF9', 'status', 'scheduled',
    'origin_icao', 'LFPG', 'destination_icao', 'KJFK')))),
  'scheduled', 'an unknown provider_id is inserted as given');
select is((select count(*) from flights where provider_id = 'fa-final-3'), 1::bigint,
  'the new flight is stored once');
select is(
  (select (merge_flight(f, '{"cancelled": true}'::jsonb, null)).status::text
   from flights f where provider_id = 'fa-final-3'),
  'canceled', 'merge_flight: a cancel wins over the rank');
select is(
  (select (merge_flight(f, '{"estimated_out": "2026-11-03T23:30:00Z"}'::jsonb, null)).estimated_out
   from flights f where provider_id = 'fa-final-1'),
  (select estimated_out from flights where provider_id = 'fa-final-1'),
  'merge_flight: an estimate is ignored once the actual exists');

-- F2: one position refresh per flight per window.
select ok(claim_position_refresh('d1000000-0000-0000-0000-000000000001', 120), 'first viewer claims the window');
select ok(not claim_position_refresh('d1000000-0000-0000-0000-000000000001', 120), 'a second viewer does not');
update position_refresh_leases set until = now() - interval '1 second'
where flight_id = 'd1000000-0000-0000-0000-000000000001';
select ok(claim_position_refresh('d1000000-0000-0000-0000-000000000001', 120), 'an expired window is claimed again');

-- F6: the daily cap.
delete from usage_counters where day = '2001-01-01';
select ok(charge_usage('2001-01-01', '/flights/{ident}', 0.005, 0.01), 'under the cap the call is counted');
select ok(charge_usage('2001-01-01', '/flights/{ident}', 0.005, 0.01), 'reaching the cap exactly is allowed');
select ok(not charge_usage('2001-01-01', '/flights/{id}/position', 0.01, 0.01), 'past the cap the call is refused');
select ok(charge_usage('2001-01-01', '/alerts/{id}', 0, 0.01), 'free calls pass over the cap');
select results_eq(
  $$select sum(calls)::int, sum(estimated_cost) from usage_counters where day = '2001-01-01'$$,
  $$values (3, 0.0100::numeric)$$,
  'a refused call is not counted');
select is((select schedule from cron.job where jobname = 'usage-alert-cap'), '20 * * * *',
  'the cap alert runs hourly');
select ok(not has_function_privilege('authenticated', 'public.charge_usage(date, text, numeric, numeric)', 'execute')
  and not has_function_privilege('authenticated', 'public.upsert_provider_flights(jsonb)', 'execute')
  and not has_function_privilege('authenticated', 'public.claim_position_refresh(uuid, int)', 'execute'),
  'the new functions are service only');

select * from finish();
rollback;
