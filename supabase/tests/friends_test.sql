begin;
create extension if not exists pgtap with schema extensions;
select plan(87);

-- A shares with friends B and D; C is a stranger; E answers invitations.
insert into auth.users (id, instance_id, aud, role, email) values
  ('f1000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'fa@test.local'),
  ('f1000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'fb@test.local'),
  ('f1000000-0000-0000-0000-00000000000c', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'fc@test.local'),
  ('f1000000-0000-0000-0000-00000000000d', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'fd@test.local'),
  ('f1000000-0000-0000-0000-00000000000e', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'fe@test.local');
update profiles set display_name = 'Ada', emoji = '🌿' where user_id = 'f1000000-0000-0000-0000-00000000000a';

-- A follows an upcoming flight (with a seat and a booking code) and one that landed two days ago.
insert into flights (id, provider_id, ident, origin_icao, destination_icao, scheduled_out, scheduled_in, status) values
  ('f2000000-0000-0000-0000-000000000001', 'friends-1', 'AF84', 'LFPG', 'KSFO', now() + interval '5 hours', now() + interval '16 hours', 'scheduled'),
  ('f2000000-0000-0000-0000-000000000002', 'friends-2', 'UA990', 'KSFO', 'LFPG', now() - interval '60 hours', now() - interval '49 hours', 'arrived');
insert into user_flights (user_id, flight_id, seat, booking_code, notes) values
  ('f1000000-0000-0000-0000-00000000000a', 'f2000000-0000-0000-0000-000000000001', '23A', 'ABC123', 'secret'),
  ('f1000000-0000-0000-0000-00000000000a', 'f2000000-0000-0000-0000-000000000002', null, null, null);
insert into past_flights (user_id, date, ident, origin_icao, destination_icao, airline, distance_km, block_minutes,
                          origin_country, destination_country) values
  ('f1000000-0000-0000-0000-00000000000a', '2026-01-01', 'AF84', 'LFPG', 'KSFO', 'AFR', 8950, 680, 'FR', 'US'),
  ('f1000000-0000-0000-0000-00000000000a', '2026-02-01', 'AF83', 'KSFO', 'LFPG', 'AFR', 8950, 640, 'US', 'FR');

-- ---------------------------------------------------------------------------------------------------
-- Shape
select has_table('public', 'friendships', 'friendships exists');
select has_table('public', 'friend_invitations', 'friend_invitations exists');
select has_table('public', 'friend_settings', 'friend_settings exists');
select is((select bool_and(relrowsecurity) from pg_class
           where oid in ('public.friendships'::regclass, 'public.friend_invitations'::regclass,
                         'public.friend_settings'::regclass)), true, 'RLS is on for all three');
select hasnt_column('public', 'friend_invitations', 'token', 'the invitation token itself is never stored');
select ok(public.friend_code_new() ~ '^[0-9A-HJKMNP-TV-Z]{8}$', 'friend codes are 8 Crockford characters');
select ok(pg_get_function_result('public.friend_flights(uuid)'::regprocedure) !~ '(seat|booking|notes|pass)',
  'friend_flights returns no seat, booking code, notes or pass');
select throws_ok($$insert into friendships (user_id, friend_id) values
  ('f1000000-0000-0000-0000-00000000000a', 'f1000000-0000-0000-0000-00000000000a')$$, '23514', null,
  'nobody is their own friend');

-- Friends A-B and A-D (the server makes pairs).
select lives_ok($$select public.friendship_make('f1000000-0000-0000-0000-00000000000a', 'f1000000-0000-0000-0000-00000000000b')$$,
  'a friendship is made');
select lives_ok($$select public.friendship_make('f1000000-0000-0000-0000-00000000000a', 'f1000000-0000-0000-0000-00000000000d')$$,
  'another friendship is made');
select is((select count(*) from friendships where 'f1000000-0000-0000-0000-00000000000b' in (user_id, friend_id)), 2::bigint,
  'a friendship is two rows');
select is((select (share_flights, share_passport, alerts)::text from friendships
           where user_id = 'f1000000-0000-0000-0000-00000000000a' and friend_id = 'f1000000-0000-0000-0000-00000000000b'),
  '(t,f,f)', 'flights shared, Passport not, no alerts by default');

-- ---------------------------------------------------------------------------------------------------
-- B, a friend
set local role authenticated;
set local request.jwt.claims = '{"sub":"f1000000-0000-0000-0000-00000000000b","role":"authenticated"}';
select is((select count(*) from public.friend_flights('f1000000-0000-0000-0000-00000000000a')), 1::bigint,
  'a friend sees the upcoming flight, not the one long landed');
select is((select ident from public.friend_flights(null)), 'AF84', 'and every friend at once gives the same');
select is((select count(*) from user_flights), 0::bigint, 'a friend still reads none of the follows themselves');
select is((select count(*) from public.friend_passport('f1000000-0000-0000-0000-00000000000a')), 0::bigint,
  'Passport totals are not shared by default');
select is((select count(*) from friendships), 1::bigint, 'a user reads only their own friendship rows');
select is((select display_name || emoji from public.friends_list()), 'Ada🌿', 'the list carries name and emoji');
select is((select shares_flights from public.friends_list()), true, 'and says the friend shares flights');
select is((select count(*) from friend_settings), 0::bigint, 'nobody reads another user''s friend settings');
select throws_ok($$insert into friendships (user_id, friend_id) values
  ('f1000000-0000-0000-0000-00000000000b', 'f1000000-0000-0000-0000-00000000000c')$$, '42501', null,
  'a user cannot make a friendship directly');
select throws_ok($$delete from friendships$$, '42501', null, 'a user cannot delete rows directly');
select throws_ok($$update friendships set friend_id = 'f1000000-0000-0000-0000-00000000000c'$$, '42501', null,
  'a user cannot change who a friendship is with');
update friendships set share_flights = false where user_id = 'f1000000-0000-0000-0000-00000000000a';
select throws_ok($$select token_hash from friend_invitations$$, '42501', null, 'token hashes are never readable');
select throws_ok($$insert into friend_invitations (kind, from_user, to_user, expires_at)
  values ('code', 'f1000000-0000-0000-0000-00000000000b', 'f1000000-0000-0000-0000-00000000000c', now() + interval '1 day')$$,
  '42501', null, 'a user cannot write invitations directly');
select throws_ok($$select public.friend_invite_create('f1000000-0000-0000-0000-00000000000b', repeat('a', 64))$$,
  '42501', null, 'invitations are made by the edge function only');
select throws_ok($$select public.friend_alert_watchers('f2000000-0000-0000-0000-000000000001')$$, '42501', null,
  'the alert fan-out is the server''s');
select throws_ok($$select public.friend_request_by_code('f1000000-0000-0000-0000-00000000000b', 'AAAAAAAA')$$, '42501', null,
  'code requests go through the edge function');
select lives_ok($$update profiles set emoji = '✈️', display_name = 'Bo'$$, 'a user sets their own name and emoji');
select throws_ok($$update profiles set display_name = repeat('x', 41)$$, '23514', null, 'a name is 40 characters at most');
select throws_ok($$update profiles set plan = 'pro'$$, '42501', null, 'the profile grant stays narrow');
reset role;
select is((select share_flights from friendships where user_id = 'f1000000-0000-0000-0000-00000000000a'
           and friend_id = 'f1000000-0000-0000-0000-00000000000b'), true, 'a user cannot change their friend''s switches');

-- C, a stranger
set local role authenticated;
set local request.jwt.claims = '{"sub":"f1000000-0000-0000-0000-00000000000c","role":"authenticated"}';
select is((select count(*) from public.friend_flights('f1000000-0000-0000-0000-00000000000a')), 0::bigint,
  'a non-friend reads no flights');
select is((select count(*) from public.friend_flights(null)), 0::bigint, 'nor any flight of anyone');
select is((select count(*) from public.friend_passport('f1000000-0000-0000-0000-00000000000a')), 0::bigint,
  'nor Passport totals');
select is((select count(*) from public.friends_list()), 0::bigint, 'and has no friends listed');
select is((select count(*) from friendships), 0::bigint, 'and reads no friendship rows');
select is((select count(*) from profiles where user_id = 'f1000000-0000-0000-0000-00000000000a'), 0::bigint,
  'and cannot read the profile behind it');
reset role;

set local role anon;
select throws_ok($$select * from public.friends_list()$$, '42501', null, 'anon calls nothing');
select throws_ok($$select * from friendships$$, '42501', null, 'anon reads nothing');
reset role;

-- A's switches: Passport on, flights off for B, then a pause of everything.
set local role authenticated;
set local request.jwt.claims = '{"sub":"f1000000-0000-0000-0000-00000000000a","role":"authenticated"}';
select lives_ok($$update friendships set share_passport = true, alerts = true
  where friend_id = 'f1000000-0000-0000-0000-00000000000b'$$, 'a user changes their own switches');
select is((select friend_code from public.friends_me()) ~ '^[0-9A-HJKMNP-TV-Z]{8}$', true, 'friends_me makes a code');
select throws_ok($$update friend_settings set friend_code = 'AAAAAAAA'$$, '42501', null, 'a user cannot pick their code');
reset role;

set local role authenticated;
set local request.jwt.claims = '{"sub":"f1000000-0000-0000-0000-00000000000b","role":"authenticated"}';
select is((select (flights, distance_km, airports, countries, airlines)::text
           from public.friend_passport('f1000000-0000-0000-0000-00000000000a')), '(2,17900,2,2,1)',
  'shared Passport totals count flights, distance, airports, countries, airlines');
reset role;

update friendships set share_flights = false
  where user_id = 'f1000000-0000-0000-0000-00000000000a' and friend_id = 'f1000000-0000-0000-0000-00000000000b';
set local role authenticated;
set local request.jwt.claims = '{"sub":"f1000000-0000-0000-0000-00000000000b","role":"authenticated"}';
select is((select count(*) from public.friend_flights(null)), 0::bigint, 'switched off for one friend, they see nothing');
reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"f1000000-0000-0000-0000-00000000000d","role":"authenticated"}';
select is((select count(*) from public.friend_flights(null)), 1::bigint, 'while another friend still does');
reset role;
update friendships set share_flights = true where user_id = 'f1000000-0000-0000-0000-00000000000a';

set local role authenticated;
set local request.jwt.claims = '{"sub":"f1000000-0000-0000-0000-00000000000a","role":"authenticated"}';
update friend_settings set sharing_paused = true;
reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"f1000000-0000-0000-0000-00000000000b","role":"authenticated"}';
select is((select count(*) from public.friend_flights(null)), 0::bigint, 'a pause hides every flight');
select is((select count(*) from public.friend_passport('f1000000-0000-0000-0000-00000000000a')), 0::bigint,
  'and the Passport totals');
select is((select shares_flights from public.friends_list()), false, 'and the list says so');
reset role;
select is((select count(*) from public.friend_alert_watchers('f2000000-0000-0000-0000-000000000001')), 0::bigint,
  'a pause stops friend alerts too');
update friend_settings set sharing_paused = false where user_id = 'f1000000-0000-0000-0000-00000000000a';

-- Alerts: B asked for A's flights.
update friendships set alerts = true
  where user_id = 'f1000000-0000-0000-0000-00000000000b' and friend_id = 'f1000000-0000-0000-0000-00000000000a';
select is((select watcher_id::text || ' ' || owner_name from public.friend_alert_watchers('f2000000-0000-0000-0000-000000000001')),
  'f1000000-0000-0000-0000-00000000000b Ada', 'a friend who asked for alerts hears about the flight');
insert into user_flights (user_id, flight_id) values
  ('f1000000-0000-0000-0000-00000000000b', 'f2000000-0000-0000-0000-000000000001');
select is((select count(*) from public.friend_alert_watchers('f2000000-0000-0000-0000-000000000001')), 0::bigint,
  'unless they follow it themselves');
delete from user_flights where user_id = 'f1000000-0000-0000-0000-00000000000b';
update friendships set alerts = false
  where user_id = 'f1000000-0000-0000-0000-00000000000b' and friend_id = 'f1000000-0000-0000-0000-00000000000a';
select is((select count(*) from public.friend_alert_watchers('f2000000-0000-0000-0000-000000000001')), 0::bigint,
  'no alerts without the switch');

-- ---------------------------------------------------------------------------------------------------
-- Invitation links (service role, as the edge function calls them)
select is((select count(*) from public.friend_invite_create('f1000000-0000-0000-0000-00000000000a', repeat('1', 64))),
  1::bigint, 'a link invitation is made');
select is((select state || ' ' || display_name from public.friend_invite_preview('f1000000-0000-0000-0000-00000000000e', repeat('1', 64))),
  'open Ada', 'whoever opens it sees who sent it');
select is((select state from public.friend_invite_preview('f1000000-0000-0000-0000-00000000000a', repeat('1', 64))),
  'self', 'the sender sees their own link as theirs');
select throws_ok($$select public.friend_invite_respond('f1000000-0000-0000-0000-00000000000a', repeat('1', 64), true)$$,
  'P0001', 'friend_self', 'nobody accepts their own link');
select is(public.friend_invite_respond('f1000000-0000-0000-0000-00000000000e', repeat('1', 64), true),
  'f1000000-0000-0000-0000-00000000000a'::uuid, 'accepting returns the inviter');
select ok(public.are_friends('f1000000-0000-0000-0000-00000000000a', 'f1000000-0000-0000-0000-00000000000e'),
  'and makes them friends');
select throws_ok($$select public.friend_invite_respond('f1000000-0000-0000-0000-00000000000c', repeat('1', 64), true)$$,
  'P0001', 'invite_closed', 'a link works once');
select is((select state from public.friend_invite_preview('f1000000-0000-0000-0000-00000000000c', repeat('1', 64))),
  'used', 'and says so afterwards');
select throws_ok($$select public.friend_invite_respond('f1000000-0000-0000-0000-00000000000c', repeat('9', 64), true)$$,
  'P0001', 'invite_not_found', 'an unknown link answers not found');

select lives_ok($$select public.friend_invite_create('f1000000-0000-0000-0000-00000000000a', repeat('2', 64))$$, 'another link');
select is(public.friend_invite_respond('f1000000-0000-0000-0000-00000000000c', repeat('2', 64), false), null::uuid,
  'declining returns nothing');
select ok(not public.are_friends('f1000000-0000-0000-0000-00000000000a', 'f1000000-0000-0000-0000-00000000000c'),
  'and makes no friendship');

insert into friend_invitations (kind, from_user, token_hash, created_at, expires_at)
  values ('link', 'f1000000-0000-0000-0000-00000000000a', repeat('3', 64), now() - interval '9 days', now() - interval '2 days');
select is((select state from public.friend_invite_preview('f1000000-0000-0000-0000-00000000000c', repeat('3', 64))),
  'expired', 'an old link says it expired');
select throws_ok($$select public.friend_invite_respond('f1000000-0000-0000-0000-00000000000c', repeat('3', 64), true)$$,
  'P0001', 'invite_closed', 'and cannot be accepted');

select lives_ok($$select public.friend_invite_create('f1000000-0000-0000-0000-00000000000a', repeat('4', 64))$$, 'another link');
select ok(public.friend_invite_revoke('f1000000-0000-0000-0000-00000000000a',
  (select id from friend_invitations where token_hash = repeat('4', 64))), 'the sender withdraws a link');
select ok(not public.friend_invite_revoke('f1000000-0000-0000-0000-00000000000c',
  (select id from friend_invitations where token_hash = repeat('2', 64))), 'nobody else can');

-- ---------------------------------------------------------------------------------------------------
-- Friend codes
select is(public.friend_request_by_code('f1000000-0000-0000-0000-00000000000c',
  lower((select friend_code from friend_settings where user_id = 'f1000000-0000-0000-0000-00000000000a'))), 'sent',
  'a code (any case) sends a request');
select is(public.friend_request_by_code('f1000000-0000-0000-0000-00000000000c',
  (select friend_code from friend_settings where user_id = 'f1000000-0000-0000-0000-00000000000a')), 'sent',
  'sending it again keeps one request');
select is((select count(*) from friend_invitations where kind = 'code' and status = 'pending'), 1::bigint,
  'one pending request per pair');
select throws_ok($$select public.friend_request_by_code('f1000000-0000-0000-0000-00000000000c', 'ZZZZZZZZ')$$,
  'P0001', 'code_not_found', 'an unknown code answers not found');

set local role authenticated;
set local request.jwt.claims = '{"sub":"f1000000-0000-0000-0000-00000000000a","role":"authenticated"}';
select is((select incoming from public.friend_requests()), true, 'the code''s owner sees the request');
reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"f1000000-0000-0000-0000-00000000000c","role":"authenticated"}';
select is((select display_name from public.friend_requests()), null, 'the sender is not told whose code it was');
reset role;
select ok(not public.friend_request_respond('f1000000-0000-0000-0000-00000000000c',
  (select id from friend_invitations where kind = 'code' and status = 'pending'), true),
  'only the person asked can answer');
select ok(public.friend_request_respond('f1000000-0000-0000-0000-00000000000a',
  (select id from friend_invitations where kind = 'code' and status = 'pending'), true), 'the owner accepts');
select ok(public.are_friends('f1000000-0000-0000-0000-00000000000a', 'f1000000-0000-0000-0000-00000000000c'),
  'and they are friends');
select ok(public.friend_code_reset('f1000000-0000-0000-0000-00000000000a') ~ '^[0-9A-HJKMNP-TV-Z]{8}$',
  'a code can be replaced');

-- ---------------------------------------------------------------------------------------------------
-- Removing a friend
set local role authenticated;
set local request.jwt.claims = '{"sub":"f1000000-0000-0000-0000-00000000000d","role":"authenticated"}';
select ok(public.friend_remove('f1000000-0000-0000-0000-00000000000a'), 'a friend removes the friendship');
select is((select count(*) from public.friend_flights('f1000000-0000-0000-0000-00000000000a')), 0::bigint,
  'a removed friend reads no flights');
select is((select count(*) from public.friend_passport('f1000000-0000-0000-0000-00000000000a')), 0::bigint,
  'nor Passport totals');
reset role;
select is((select count(*) from friendships where 'f1000000-0000-0000-0000-00000000000d' in (user_id, friend_id)), 0::bigint,
  'both rows go');

-- A deleted account shows nothing, and the auth deletion takes its rows.
update profiles set status = 'deleted' where user_id = 'f1000000-0000-0000-0000-00000000000a';
set local role authenticated;
set local request.jwt.claims = '{"sub":"f1000000-0000-0000-0000-00000000000b","role":"authenticated"}';
select is((select count(*) from public.friend_flights(null)), 0::bigint, 'a deleted account shares nothing');
reset role;
delete from auth.users where id = 'f1000000-0000-0000-0000-00000000000a';
select is((select count(*) from friendships) + (select count(*) from friend_invitations where from_user = 'f1000000-0000-0000-0000-00000000000a'),
  0::bigint, 'deleting the account deletes its friendships and invitations');

select is((select count(*) from cron.job where jobname = 'friend-invitations-prune'), 1::bigint, 'old invitations are pruned');

select * from finish();
rollback;
