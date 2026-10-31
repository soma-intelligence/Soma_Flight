begin;
create extension if not exists pgtap with schema extensions;
select plan(16);

insert into auth.users (id, instance_id, aud, role, email)
values ('a3a3a3a3-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 'security-a@test.local');

-- Service role (postgres here) loads checkpoints and throughput, and caches answers, as security-wait does.
insert into security_checkpoints (airport_icao, id, name, terminal, precheck)
values ('KSFO', 't1', 'Harvey Milk Terminal 1', '1', true);
insert into security_throughput (airport_icao, checkpoint_id, weekday, hour, passengers)
values ('KSFO', 't1', 2, 7, 900);
insert into security_wait_cache (airport_icao, payload) values ('KSFO', '{"available": true}');

select has_table('public', 'security_checkpoints', 'security_checkpoints exists');
select is((select count(*) from pg_class where oid in ('public.security_checkpoints'::regclass,
  'public.security_throughput'::regclass, 'public.security_wait_cache'::regclass) and relrowsecurity), 3::bigint,
  'all three tables have RLS on');
select is((select count(*) from pg_policies
  where tablename in ('security_checkpoints', 'security_throughput', 'security_wait_cache')), 0::bigint,
  'no policy on any of them');
select throws_ok($$insert into security_checkpoints (airport_icao, id, name) values ('KSFO', 'Bad Id', 'x')$$,
  '23514', null, 'checkpoint ids are lower case slugs');
select throws_ok($$insert into security_checkpoints (airport_icao, id, name) values ('ZZZZ', 'a', 'x')$$,
  '23503', null, 'a checkpoint needs a known airport');
select throws_ok($$insert into security_throughput values ('KSFO', 't1', 7, 0, 1)$$, '23514', null,
  'weekdays run 0 to 6');
select throws_ok($$insert into security_throughput values ('KSFO', 't1', 0, 24, 1)$$, '23514', null,
  'hours run 0 to 23');
select throws_ok($$insert into security_throughput values ('KSFO', 't1', 0, 1, -1)$$, '23514', null,
  'passengers are never negative');
select throws_ok($$insert into security_throughput values ('KSFO', 'nope', 0, 1, 1)$$, '23503', null,
  'throughput needs a known checkpoint');

-- Clients see nothing and write nothing, signed in or not.
set local role authenticated;
set local request.jwt.claims = '{"sub":"a3a3a3a3-0000-0000-0000-000000000001","role":"authenticated"}';
select throws_ok($$select * from security_checkpoints$$, '42501', null, 'a user cannot read checkpoints');
select throws_ok($$select * from security_throughput$$, '42501', null, 'a user cannot read throughput');
select throws_ok($$delete from security_wait_cache$$, '42501', null, 'a user cannot touch the cache');
reset role;

set local role anon;
select throws_ok($$select * from security_wait_cache$$, '42501', null, 'anon cannot read the cache');
reset role;

-- A checkpoint that goes takes its hours with it.
delete from security_checkpoints where airport_icao = 'KSFO' and id = 't1';
select is((select count(*) from security_throughput where airport_icao = 'KSFO' and checkpoint_id = 't1'), 0::bigint,
  'deleting a checkpoint deletes its throughput');
select is((select count(*) from security_wait_cache where airport_icao = 'KSFO'), 1::bigint,
  'the cache is kept per airport');

select is((select count(*) from cron.job where jobname = 'security-wait-cache-prune'), 1::bigint,
  'old cache rows are pruned daily');

select * from finish();
rollback;
