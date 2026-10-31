begin;
create extension if not exists pgtap with schema extensions;
select plan(24);

-- users A and B (profile trigger fires on insert)
insert into auth.users (id, instance_id, aud, role, email)
values
  ('aaaaaaaa-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'a@test.local'),
  ('bbbbbbbb-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'b@test.local');

-- service role (postgres here) seeds rows for A
insert into flights (id, provider_id, ident)
values ('11111111-1111-1111-1111-111111111111', 'fa-test-1', 'AF84');
insert into user_flights (user_id, flight_id)
values ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111');
insert into past_flights (user_id, date, ident, origin_icao, destination_icao)
values ('aaaaaaaa-0000-0000-0000-000000000001', '2026-01-01', 'AF84', 'LFPG', 'KJFK');
insert into push_tokens (user_id, token, kind, platform)
values ('aaaaaaaa-0000-0000-0000-000000000001', 'tok-a', 'alert', 'ios'),
       ('bbbbbbbb-0000-0000-0000-000000000002', 'tok-b', 'alert', 'ios');
update profiles set display_name = 'Ada' where user_id = 'aaaaaaaa-0000-0000-0000-000000000001';

-- as B
set local role authenticated;
set local request.jwt.claims = '{"sub":"bbbbbbbb-0000-0000-0000-000000000002","role":"authenticated"}';

select is((select count(*) from user_flights), 0::bigint, 'B sees no user_flights');
select is((select count(*) from past_flights), 0::bigint, 'B sees no past_flights');
select is((select count(*) from push_tokens), 1::bigint, 'B sees only own push_tokens');
select is((select count(*) from flights), 1::bigint, 'B reads shared flights');
select throws_ok(
  $$insert into flights(provider_id, ident) values ('x','X1')$$,
  '42501', null, 'clients cannot write flights');
select throws_ok(
  $$select * from webhook_inbox$$,
  '42501', null, 'clients cannot read webhook_inbox');

-- WITH CHECK: B cannot write rows for A, nor raise its own plan.
select throws_ok(
  $$insert into user_flights (user_id, flight_id)
    values ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111')$$,
  '42501', null, 'B cannot follow a flight as A');
select throws_ok(
  $$insert into past_flights (user_id, date, ident, origin_icao, destination_icao)
    values ('aaaaaaaa-0000-0000-0000-000000000001', now(), 'XX1', 'LFPG', 'KJFK')$$,
  '42501', null, 'B cannot add a past flight for A');
insert into past_flights (user_id, date, ident, origin_icao, destination_icao)
values ('bbbbbbbb-0000-0000-0000-000000000002', now(), 'BB1', 'LFPG', 'KJFK');
select throws_ok(
  $$update past_flights set user_id = 'aaaaaaaa-0000-0000-0000-000000000001'$$,
  '42501', null, 'B cannot hand its past flights to A');
select throws_ok(
  $$update profiles set plan = 'pro' where user_id = 'bbbbbbbb-0000-0000-0000-000000000002'$$,
  '42501', null, 'B cannot change its plan');
update profiles set display_name = 'Mallory' where user_id = 'aaaaaaaa-0000-0000-0000-000000000001';
select is((select display_name from profiles where user_id = 'bbbbbbbb-0000-0000-0000-000000000002'),
  null::text, 'B update of A''s profile touches nothing');

-- as A
set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000001","role":"authenticated"}';
select is((select count(*) from user_flights), 1::bigint, 'A sees own user_flights');

-- anon: no table in public is readable or writable, and reads fail outright.
reset role;
select is_empty(
  $$select c.relname::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r', 'v', 'm', 'p')
      and (has_table_privilege('anon', c.oid, 'select') or has_table_privilege('anon', c.oid, 'insert')
        or has_table_privilege('anon', c.oid, 'update') or has_table_privilege('anon', c.oid, 'delete'))$$,
  'anon has no privilege on any public table');
set local role anon;
set local request.jwt.claims = '{"role":"anon"}';
select throws_ok($$select * from flights$$, '42501', null, 'anon cannot read flights');
select throws_ok($$select * from past_flights$$, '42501', null, 'anon cannot read past_flights');
select throws_ok($$select * from profiles$$, '42501', null, 'anon cannot read profiles');
select throws_ok(
  $$insert into user_flights (user_id, flight_id)
    values ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111')$$,
  '42501', null, 'anon cannot follow');

reset role;
select is((select count(*) from profiles), 2::bigint, 'profile trigger created both profiles');

-- deletion path: the profile has no FK to auth.users, so it survives; user rows cascade away.
-- (delete-account marks the profile first, then deletes the auth user.)
update profiles set status = 'deleted', display_name = null
where user_id = 'aaaaaaaa-0000-0000-0000-000000000001';
delete from auth.users where id = 'aaaaaaaa-0000-0000-0000-000000000001';

select is((select count(*) from user_flights where user_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  0::bigint, 'deleting the auth user removes user_flights');
select is((select count(*) from past_flights where user_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  0::bigint, 'deleting the auth user removes past_flights');
select is((select count(*) from push_tokens where user_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  0::bigint, 'deleting the auth user removes push_tokens');
select is((select count(*) from push_tokens where user_id = 'bbbbbbbb-0000-0000-0000-000000000002'),
  1::bigint, 'B keeps push_tokens after A is deleted');
select is((select count(*) from profiles), 2::bigint, 'both profiles remain after A is deleted');
select results_eq(
  $$select status::text, display_name from profiles where user_id = 'aaaaaaaa-0000-0000-0000-000000000001'$$,
  $$values ('deleted'::text, null::text)$$,
  'profile survives as deleted with no display name');

select * from finish();
rollback;
