begin;
create extension if not exists pgtap with schema extensions;
select plan(12);

-- A asks. B shares their Passport with A; C is a friend who does not; D shares but paused all sharing;
-- E is a stranger. Everyone flew through KSFO.
insert into auth.users (id, instance_id, aud, role, email) values
  ('a7000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ra@test.local'),
  ('a7000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rb@test.local'),
  ('a7000000-0000-0000-0000-00000000000c', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rc@test.local'),
  ('a7000000-0000-0000-0000-00000000000d', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rd@test.local'),
  ('a7000000-0000-0000-0000-00000000000e', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 're@test.local');
update profiles set display_name = 'Bea', emoji = '🌊' where user_id = 'a7000000-0000-0000-0000-00000000000b';

select public.friendship_make('a7000000-0000-0000-0000-00000000000a', 'a7000000-0000-0000-0000-00000000000b');
select public.friendship_make('a7000000-0000-0000-0000-00000000000a', 'a7000000-0000-0000-0000-00000000000c');
select public.friendship_make('a7000000-0000-0000-0000-00000000000a', 'a7000000-0000-0000-0000-00000000000d');
update friendships set share_passport = true
  where friend_id = 'a7000000-0000-0000-0000-00000000000a'
    and user_id in ('a7000000-0000-0000-0000-00000000000b', 'a7000000-0000-0000-0000-00000000000d');
select public.friend_settings_ensure('a7000000-0000-0000-0000-00000000000d');
update friend_settings set sharing_paused = true where user_id = 'a7000000-0000-0000-0000-00000000000d';

insert into past_flights (user_id, date, ident, origin_icao, destination_icao, status) values
  ('a7000000-0000-0000-0000-00000000000a', '2026-03-04', 'UA1', 'KSFO', 'KJFK', 'completed'),
  ('a7000000-0000-0000-0000-00000000000a', '2026-03-09', 'UA2', 'KJFK', 'KSFO', 'completed'),
  ('a7000000-0000-0000-0000-00000000000a', '2026-05-01', 'UA3', 'KSFO', 'KDEN', 'canceled'),
  ('a7000000-0000-0000-0000-00000000000a', '2026-06-01', 'UA4', 'KDEN', 'KORD', 'completed'),
  ('a7000000-0000-0000-0000-00000000000b', '2026-01-02', 'AF1', 'LFPG', 'KSFO', 'completed'),
  ('a7000000-0000-0000-0000-00000000000b', '2026-02-02', 'AF2', 'KSFO', 'LFPG', 'completed'),
  ('a7000000-0000-0000-0000-00000000000b', '2026-08-20', 'AF3', 'LFPG', 'KSFO', 'diverted'),
  ('a7000000-0000-0000-0000-00000000000c', '2026-01-01', 'DL1', 'KSFO', 'KATL', 'completed'),
  ('a7000000-0000-0000-0000-00000000000d', '2026-01-01', 'DL2', 'KSFO', 'KATL', 'completed'),
  ('a7000000-0000-0000-0000-00000000000e', '2026-01-01', 'DL3', 'KSFO', 'KATL', 'completed');

select has_function('public', 'airport_regulars', array['text'], 'airport_regulars exists');
select ok(not has_function_privilege('anon', 'public.airport_regulars(text)', 'execute'),
  'anon cannot call airport_regulars');
select ok(has_function_privilege('authenticated', 'public.airport_regulars(text)', 'execute'),
  'signed-in users can call airport_regulars');

set local role authenticated;
set local request.jwt.claims = '{"sub":"a7000000-0000-0000-0000-00000000000a","role":"authenticated"}';

select is((select array_agg(user_id order by visits desc, user_id) from public.airport_regulars('KSFO')),
  array['a7000000-0000-0000-0000-00000000000b', 'a7000000-0000-0000-0000-00000000000a']::uuid[],
  'only the caller and the friend who shares their Passport (not C, not paused D, not stranger E)');
select is((select visits from public.airport_regulars('KSFO') where is_me), 2::bigint,
  'canceled flights are not visits');
select is((select visits from public.airport_regulars('ksfo') where not is_me), 3::bigint,
  'the code is matched in upper case; a diversion that ended at the airport counts');
select is((select last_visit from public.airport_regulars('KSFO') where not is_me), '2026-08-01'::date,
  'the latest visit is given to the month only');
select is((select (display_name, emoji)::text from public.airport_regulars('KSFO') where not is_me), '(Bea,🌊)',
  'the friend''s name and emoji come along');
select is((select count(*) from public.airport_regulars('KORD')), 1::bigint, 'one airport, one visit');
select is((select count(*) from public.airport_regulars('EGLL')), 0::bigint, 'nobody went there');
reset role;

-- B unshares: B drops out of A's list.
update friendships set share_passport = false
  where user_id = 'a7000000-0000-0000-0000-00000000000b' and friend_id = 'a7000000-0000-0000-0000-00000000000a';
set local role authenticated;
set local request.jwt.claims = '{"sub":"a7000000-0000-0000-0000-00000000000a","role":"authenticated"}';
select is((select count(*) from public.airport_regulars('KSFO') where not is_me), 0::bigint,
  'a friend who stops sharing their Passport leaves the list');
reset role;

-- Signed out (no sub): nothing at all.
set local role authenticated;
set local request.jwt.claims = '{"role":"authenticated"}';
select is((select count(*) from public.airport_regulars('KSFO')), 0::bigint, 'no caller, no rows');
reset role;

select * from finish();
rollback;
