begin;
create extension if not exists pgtap with schema extensions;
select plan(20);

insert into auth.users (id, instance_id, aud, role, email)
values ('a2a2a2a2-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 'insights-a@test.local');

-- Service role (postgres here) fills both caches, as flight-insights does.
insert into flights (id, provider_id, ident)
values ('c2000000-0000-0000-0000-000000000001', 'INS-1', 'AF84');
insert into forecast_cache (ident, payload) values ('AF84', '{"forecast": null}');
insert into inbound_cache (flight_id, payload)
values ('c2000000-0000-0000-0000-000000000001', '{"legs": []}');

select has_table('public', 'forecast_cache', 'forecast_cache exists');
select has_table('public', 'inbound_cache', 'inbound_cache exists');
select ok((select relrowsecurity from pg_class where oid = 'public.forecast_cache'::regclass),
  'forecast_cache has RLS on');
select ok((select relrowsecurity from pg_class where oid = 'public.inbound_cache'::regclass),
  'inbound_cache has RLS on');
select is((select count(*) from pg_policies where tablename in ('forecast_cache', 'inbound_cache')), 0::bigint,
  'no policy on either cache');
select throws_ok($$insert into forecast_cache (ident, payload) values ('af84', '{}')$$, '23514', null,
  'idents are upper case designators');
select throws_ok($$insert into forecast_cache (ident, payload) values ('AF 84', '{}')$$, '23514', null,
  'idents have no spaces');
select throws_ok($$insert into forecast_cache (ident, payload) values ('AF84123', '{}')$$, '23514', null,
  'numbers have at most four figures');
select throws_ok($$insert into forecast_cache (ident) values ('LH400')$$, '23502', null,
  'a payload is required');
select throws_ok(
  $$insert into inbound_cache (flight_id, payload) values ('c2000000-0000-0000-0000-00000000ffff', '{}')$$,
  '23503', null, 'an inbound row needs a known flight');

-- Clients see nothing and write nothing, signed in or not.
set local role authenticated;
set local request.jwt.claims = '{"sub":"a2a2a2a2-0000-0000-0000-000000000001","role":"authenticated"}';
select throws_ok($$select * from forecast_cache$$, '42501', null, 'a user cannot read forecast_cache');
select throws_ok($$select * from inbound_cache$$, '42501', null, 'a user cannot read inbound_cache');
select throws_ok($$insert into forecast_cache (ident, payload) values ('UA990', '{}')$$, '42501', null,
  'a user cannot write forecast_cache');
select throws_ok($$delete from inbound_cache$$, '42501', null, 'a user cannot delete inbound_cache');
reset role;

set local role anon;
select throws_ok($$select * from forecast_cache$$, '42501', null, 'anon cannot read forecast_cache');
select throws_ok($$select * from inbound_cache$$, '42501', null, 'anon cannot read inbound_cache');
reset role;

-- The service role reads and writes both.
set local role service_role;
select is((select count(*) from forecast_cache where ident = 'AF84'), 1::bigint, 'service role reads forecast_cache');
select lives_ok($$update inbound_cache set payload = '{"legs": [1]}'$$, 'service role writes inbound_cache');
reset role;

-- A flight that goes takes its chain with it.
delete from flights where id = 'c2000000-0000-0000-0000-000000000001';
select is((select count(*) from inbound_cache where flight_id = 'c2000000-0000-0000-0000-000000000001'), 0::bigint,
  'deleting the flight deletes its inbound chain');

select is((select count(*) from cron.job where jobname = 'insights-cache-prune'), 1::bigint,
  'old cache rows are pruned daily');

select * from finish();
rollback;
