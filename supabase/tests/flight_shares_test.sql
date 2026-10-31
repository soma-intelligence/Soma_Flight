begin;
create extension if not exists pgtap with schema extensions;
select plan(20);

insert into auth.users (id, instance_id, aud, role, email) values
  ('a5a5a5a5-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated',
   'authenticated', 'share-a@test.local'),
  ('a5a5a5a5-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated',
   'authenticated', 'share-b@test.local');
insert into flights (id, provider_id, ident, scheduled_in)
values ('f5f5f5f5-0000-0000-0000-000000000001', 'share-test-1', 'AF84', now() + interval '10 hours');

-- Service role (postgres here) writes shares, as share-flight does.
insert into flight_shares (id, token_hash, flight_id, user_id) values
  ('e5e5e5e5-0000-0000-0000-000000000001', repeat('a', 64), 'f5f5f5f5-0000-0000-0000-000000000001',
   'a5a5a5a5-0000-0000-0000-000000000001'),
  ('e5e5e5e5-0000-0000-0000-000000000002', repeat('b', 64), 'f5f5f5f5-0000-0000-0000-000000000001',
   'a5a5a5a5-0000-0000-0000-000000000002');

select has_table('public', 'flight_shares', 'flight_shares exists');
select is((select relrowsecurity from pg_class where oid = 'public.flight_shares'::regclass), true, 'RLS is on');
select hasnt_column('public', 'flight_shares', 'token', 'the token itself is never stored');
select throws_ok($$insert into flight_shares (token_hash, flight_id, user_id)
  values ('not-a-hash', 'f5f5f5f5-0000-0000-0000-000000000001', 'a5a5a5a5-0000-0000-0000-000000000001')$$,
  '23514', null, 'token_hash is a SHA-256 in hex');
select throws_ok($$insert into flight_shares (token_hash, flight_id, user_id)
  values (repeat('a', 64), 'f5f5f5f5-0000-0000-0000-000000000001', 'a5a5a5a5-0000-0000-0000-000000000002')$$,
  '23505', null, 'a token hash opens one share only');
select throws_ok($$insert into flight_shares (token_hash, flight_id, user_id)
  values (repeat('c', 64), 'f5f5f5f5-0000-0000-0000-00000000dead', 'a5a5a5a5-0000-0000-0000-000000000001')$$,
  '23503', null, 'a share needs a known flight');
select throws_ok($$insert into flight_shares (token_hash, flight_id, user_id, created_at, revoked_at)
  values (repeat('d', 64), 'f5f5f5f5-0000-0000-0000-000000000001', 'a5a5a5a5-0000-0000-0000-000000000001',
          now(), now() - interval '1 hour')$$,
  '23514', null, 'a share cannot be revoked before it was made');

-- A signed-in user sees their own shares, never the hashes, and writes nothing.
set local role authenticated;
set local request.jwt.claims = '{"sub":"a5a5a5a5-0000-0000-0000-000000000001","role":"authenticated"}';
select is((select count(*) from flight_shares), 1::bigint, 'a user sees only their own shares');
select is((select id from flight_shares), 'e5e5e5e5-0000-0000-0000-000000000001'::uuid, 'and it is theirs');
select throws_ok($$select token_hash from flight_shares$$, '42501', null, 'a user cannot read token hashes');
select throws_ok($$insert into flight_shares (token_hash, flight_id, user_id)
  values (repeat('e', 64), 'f5f5f5f5-0000-0000-0000-000000000001', 'a5a5a5a5-0000-0000-0000-000000000001')$$,
  '42501', null, 'a user cannot create a share directly');
select throws_ok($$update flight_shares set revoked_at = now()$$, '42501', null,
  'a user cannot revoke directly (share-flight does)');
select throws_ok($$delete from flight_shares$$, '42501', null, 'a user cannot delete shares');
reset role;

set local role anon;
select throws_ok($$select id from flight_shares$$, '42501', null, 'anon reads nothing');
reset role;

-- A revoked share stays (the page answers "no longer shared"), and the live index skips it.
update flight_shares set revoked_at = now() where id = 'e5e5e5e5-0000-0000-0000-000000000001';
select is((select count(*) from flight_shares where flight_id = 'f5f5f5f5-0000-0000-0000-000000000001'), 2::bigint,
  'revoking keeps the row');
select ok(exists(select 1 from pg_indexes where indexname = 'flight_shares_live_idx'
  and indexdef like '%WHERE (revoked_at IS NULL)%'), 'live shares have their own index');

-- Shares go with their flight and with their sharer.
delete from auth.users where id = 'a5a5a5a5-0000-0000-0000-000000000002';
select is((select count(*) from flight_shares where user_id = 'a5a5a5a5-0000-0000-0000-000000000002'), 0::bigint,
  'deleting the account deletes its shares');
delete from flights where id = 'f5f5f5f5-0000-0000-0000-000000000001';
select is((select count(*) from flight_shares), 0::bigint, 'deleting the flight deletes its shares');

select is((select count(*) from cron.job where jobname = 'flight-shares-prune'), 1::bigint,
  'old shares are pruned daily');
select is((select count(*) from pg_policies where tablename = 'flight_shares'), 1::bigint,
  'one policy: the owner reads');

select * from finish();
rollback;
