begin;
create extension if not exists pgtap with schema extensions;
select plan(13);

insert into auth.users (id, instance_id, aud, role, email)
values ('a3a3a3a3-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 'alternates-a@test.local');

-- Service role (postgres here) fills the cache, as alternate-flights does.
insert into alternates_cache (key, payload) values ('KSFO-KORD-2026-11-03T15', '{"flights": []}');

select has_table('public', 'alternates_cache', 'alternates_cache exists');
select ok((select relrowsecurity from pg_class where oid = 'public.alternates_cache'::regclass),
  'alternates_cache has RLS on');
select is((select count(*) from pg_policies where tablename = 'alternates_cache'), 0::bigint,
  'no policy on alternates_cache');
select throws_ok($$insert into alternates_cache (key, payload) values ('ksfo-kord-2026-11-03T15', '{}')$$,
  '23514', null, 'airport codes are upper case');
select throws_ok($$insert into alternates_cache (key, payload) values ('KSFO-KORD-2026-11-03', '{}')$$,
  '23514', null, 'the key carries the hour');
select throws_ok($$insert into alternates_cache (key) values ('KSFO-KORD-2026-11-03T16')$$, '23502', null,
  'a payload is required');

-- Clients see nothing and write nothing, signed in or not.
set local role authenticated;
set local request.jwt.claims = '{"sub":"a3a3a3a3-0000-0000-0000-000000000001","role":"authenticated"}';
select throws_ok($$select * from alternates_cache$$, '42501', null, 'a user cannot read alternates_cache');
select throws_ok($$insert into alternates_cache (key, payload) values ('KSFO-KLAX-2026-11-03T15', '{}')$$,
  '42501', null, 'a user cannot write alternates_cache');
select throws_ok($$delete from alternates_cache$$, '42501', null, 'a user cannot delete alternates_cache');
reset role;

set local role anon;
select throws_ok($$select * from alternates_cache$$, '42501', null, 'anon cannot read alternates_cache');
reset role;

-- The service role reads and writes it.
set local role service_role;
select is((select count(*) from alternates_cache where key = 'KSFO-KORD-2026-11-03T15'), 1::bigint,
  'service role reads alternates_cache');
select lives_ok($$update alternates_cache set payload = '{"flights": [1]}'$$, 'service role writes alternates_cache');
reset role;

select is((select count(*) from cron.job where jobname = 'alternates-cache-prune'), 1::bigint,
  'old cache rows are pruned daily');

select * from finish();
rollback;
