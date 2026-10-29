begin;
create extension if not exists pgtap with schema extensions;
select plan(12);

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
insert into past_flights (user_id, date, ident)
values ('aaaaaaaa-0000-0000-0000-000000000001', '2026-01-01', 'AF84');
insert into push_tokens (user_id, token, kind, platform)
values ('aaaaaaaa-0000-0000-0000-000000000001', 'tok-a', 'alert', 'ios');

-- as B
set local role authenticated;
set local request.jwt.claims = '{"sub":"bbbbbbbb-0000-0000-0000-000000000002","role":"authenticated"}';

select is((select count(*) from user_flights), 0::bigint, 'B sees no user_flights');
select is((select count(*) from past_flights), 0::bigint, 'B sees no past_flights');
select is((select count(*) from push_tokens), 0::bigint, 'B sees no push_tokens');
select is((select count(*) from flights), 1::bigint, 'B reads shared flights');
select throws_ok(
  $$insert into flights(provider_id, ident) values ('x','X1')$$,
  '42501', null, 'clients cannot write flights');
select throws_ok(
  $$select * from webhook_inbox$$,
  '42501', null, 'clients cannot read webhook_inbox');

-- as A
set local request.jwt.claims = '{"sub":"aaaaaaaa-0000-0000-0000-000000000001","role":"authenticated"}';
select is((select count(*) from user_flights), 1::bigint, 'A sees own user_flights');

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
select results_eq(
  $$select status::text, display_name from profiles where user_id = 'aaaaaaaa-0000-0000-0000-000000000001'$$,
  $$values ('deleted'::text, null::text)$$,
  'profile survives as deleted with no display name');

select * from finish();
rollback;
