begin;
create extension if not exists pgtap with schema extensions;
select plan(16);

insert into auth.users (id, instance_id, aud, role, email) values
  ('a7a7a7a7-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated',
   'authenticated', 'inflight-a@test.local'),
  ('a7a7a7a7-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated',
   'authenticated', 'inflight-b@test.local');
insert into flights (id, provider_id, ident, status) values
  ('a7a7a7a7-1111-0000-0000-000000000001', 'SMSTEST-1793600000-schedule-1p', 'AF84', 'en_route');
insert into user_flights (user_id, flight_id) values
  ('a7a7a7a7-0000-0000-0000-000000000001', 'a7a7a7a7-1111-0000-0000-000000000001'),
  ('a7a7a7a7-0000-0000-0000-000000000002', 'a7a7a7a7-1111-0000-0000-000000000001');
insert into sms_alerts (user_id, phone_e164, verified_at, enabled, in_flight) values
  ('a7a7a7a7-0000-0000-0000-000000000001', '+14155550110', now(), false, true);
insert into sms_alerts (user_id, phone_e164, code_hash, code_expires_at) values
  ('a7a7a7a7-0000-0000-0000-000000000002', '+14155550112', repeat('b', 64), now() + interval '10 minutes');

select has_column('public', 'sms_alerts', 'in_flight', 'the account has an in-flight mode');
select throws_ok($$update sms_alerts set in_flight = true where user_id = 'a7a7a7a7-0000-0000-0000-000000000002'$$,
  '23514', null, 'an unverified number cannot turn in-flight texts on');
select throws_ok($$update sms_alerts set opted_out_at = now(), enabled = false
  where user_id = 'a7a7a7a7-0000-0000-0000-000000000001'$$,
  '23514', null, 'a STOP must switch in-flight texts off in the same write');
select lives_ok($$update sms_alerts set in_flight = true where user_id = 'a7a7a7a7-0000-0000-0000-000000000001'$$,
  'a verified number may have in-flight texts on');

-- Per flight switches belong to a follow.
insert into sms_flight_prefs (user_id, flight_id, in_flight) values
  ('a7a7a7a7-0000-0000-0000-000000000001', 'a7a7a7a7-1111-0000-0000-000000000001', false);
select throws_ok($$insert into sms_flight_prefs (user_id, flight_id, in_flight) values
  ('a7a7a7a7-0000-0000-0000-000000000002', gen_random_uuid(), true)$$,
  '23503', null, 'a flight switch needs a follow');

-- Claims: once per alert, capped per hour.
select is(claim_sms('a7a7a7a7-0000-0000-0000-000000000001', 'a7a7a7a7-1111-0000-0000-000000000001', 'landing'),
  true, 'the first claim of an alert text wins');
select is(claim_sms('a7a7a7a7-0000-0000-0000-000000000001', 'a7a7a7a7-1111-0000-0000-000000000001', 'landing'),
  false, 'the same alert is never texted twice');
select is(claim_sms('a7a7a7a7-0000-0000-0000-000000000001', 'a7a7a7a7-1111-0000-0000-000000000001', 'b1', 2, 30),
  true, 'a second alert passes under the cap');
select is(claim_sms('a7a7a7a7-0000-0000-0000-000000000001', 'a7a7a7a7-1111-0000-0000-000000000001', 'b2', 2, 30),
  false, 'the hourly cap stops the third text');

-- Codes: three an hour per account and per number.
select is(sms_code_allowed('a7a7a7a7-0000-0000-0000-000000000002', repeat('c', 64)), true, 'code 1');
select is(sms_code_allowed('a7a7a7a7-0000-0000-0000-000000000002', repeat('c', 64)), true, 'code 2');
select is(sms_code_allowed('a7a7a7a7-0000-0000-0000-000000000002', repeat('d', 64)), true, 'code 3, another number');
select is(sms_code_allowed('a7a7a7a7-0000-0000-0000-000000000002', repeat('e', 64)), false,
  'the fourth code of the hour for one account is refused');
select is(sms_code_allowed('a7a7a7a7-0000-0000-0000-000000000001', repeat('c', 64)), true,
  'the number allows a third code from another account');

-- As the first user.
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a7a7a7a7-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is((select count(*)::int from sms_flight_prefs), 1, 'an owner reads their own flight switches');
select throws_ok($$select claim_sms('a7a7a7a7-0000-0000-0000-000000000001', 'a7a7a7a7-1111-0000-0000-000000000001', 'x')$$,
  '42501', null, 'clients cannot claim texts');
reset role;

select * from finish();
rollback;
