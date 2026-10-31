begin;
create extension if not exists pgtap with schema extensions;
select plan(14);

insert into auth.users (id, instance_id, aud, role, email) values
  ('a6a6a6a6-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated',
   'authenticated', 'sms-a@test.local'),
  ('a6a6a6a6-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated',
   'authenticated', 'sms-b@test.local');

-- Service role (postgres here) writes rows, as sms-verify would.
insert into sms_alerts (user_id, phone_e164, verified_at, enabled) values
  ('a6a6a6a6-0000-0000-0000-000000000001', '+14155550100', now(), true);
insert into sms_alerts (user_id, phone_e164, code_hash, code_expires_at) values
  ('a6a6a6a6-0000-0000-0000-000000000002', '+14155550102', repeat('a', 64), now() + interval '10 minutes');

select has_table('public', 'sms_alerts', 'sms_alerts exists');
select is((select relrowsecurity from pg_class where oid = 'public.sms_alerts'::regclass), true, 'RLS is on');
select hasnt_column('public', 'sms_alerts', 'code', 'the code itself is never stored');
select throws_ok($$update sms_alerts set phone_e164 = '4155550100' where user_id = 'a6a6a6a6-0000-0000-0000-000000000002'$$,
  '23514', null, 'numbers are E.164');
select throws_ok($$update sms_alerts set enabled = true where user_id = 'a6a6a6a6-0000-0000-0000-000000000002'$$,
  '23514', null, 'an unverified number cannot be switched on');
select throws_ok($$update sms_alerts set opted_out_at = now() where user_id = 'a6a6a6a6-0000-0000-0000-000000000001'$$,
  '23514', null, 'a STOP must switch texts off in the same write');
select lives_ok($$update sms_alerts set opted_out_at = now(), enabled = false
  where user_id = 'a6a6a6a6-0000-0000-0000-000000000001'$$, 'STOP switches off');
select throws_ok($$update sms_alerts set code_expires_at = null where user_id = 'a6a6a6a6-0000-0000-0000-000000000002'$$,
  '23514', null, 'a pending code has its expiry');
select throws_ok($$update sms_alerts set phone_e164 = '+14155550100', verified_at = now()
  where user_id = 'a6a6a6a6-0000-0000-0000-000000000002'$$,
  '23505', null, 'a number is verified for one account only');

-- As the first user.
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a6a6a6a6-0000-0000-0000-000000000001","role":"authenticated"}', true);
select is((select count(*)::int from sms_alerts), 1, 'an owner sees only their own row');
select throws_ok($$select code_hash from sms_alerts$$, '42501', null, 'the code hash is not readable');
select throws_ok($$update sms_alerts set enabled = true$$, '42501', null, 'owners cannot switch texts on themselves');
delete from sms_alerts where user_id = 'a6a6a6a6-0000-0000-0000-000000000002';
reset role;
select is((select count(*)::int from sms_alerts), 2, 'an owner cannot delete another row');
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"a6a6a6a6-0000-0000-0000-000000000001","role":"authenticated"}', true);
delete from sms_alerts;
reset role;
select is((select count(*)::int from sms_alerts), 1, 'an owner may delete their own row, forgetting the number');

select * from finish();
rollback;
