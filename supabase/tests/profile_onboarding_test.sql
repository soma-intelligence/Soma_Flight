begin;
create extension if not exists pgtap with schema extensions;
select plan(27);

-- A and B are friends; C is a stranger.
insert into auth.users (id, instance_id, aud, role, email) values
  ('a7000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'pa@privaterelay.appleid.com'),
  ('a7000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'pb@test.local'),
  ('a7000000-0000-0000-0000-00000000000c', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'pc@test.local');
select public.friendship_make('a7000000-0000-0000-0000-00000000000a', 'a7000000-0000-0000-0000-00000000000b');

-- Shape
select has_column('public', 'profiles', 'first_name', 'profiles has first_name');
select has_column('public', 'profiles', 'last_name', 'profiles has last_name');
select has_column('public', 'profiles', 'avatar_path', 'profiles has avatar_path');
select has_column('public', 'profiles', 'onboarded_at', 'profiles has onboarded_at');
select is((select public from storage.buckets where id = 'avatars'), false, 'the avatars bucket is private');
select is((select allowed_mime_types from storage.buckets where id = 'avatars'), array['image/jpeg'],
  'the avatars bucket takes JPEG only');

-- A fills in their profile and uploads a photo.
set local role authenticated;
set local request.jwt.claims = '{"sub":"a7000000-0000-0000-0000-00000000000a","role":"authenticated"}';
select lives_ok($$update profiles set first_name = 'Ada', last_name = 'Lovelace', display_name = 'Ada Lovelace',
  avatar_path = 'a7000000-0000-0000-0000-00000000000a/avatar.jpg', onboarded_at = now()$$,
  'a user saves their own name, photo path and onboarding time');
select throws_ok($$update profiles set first_name = repeat('x', 41)$$, '23514', null, 'a first name is 40 characters at most');
select throws_ok($$update profiles set last_name = '   '$$, '23514', null, 'a blank last name is refused');
select throws_ok($$update profiles set avatar_path = 'a7000000-0000-0000-0000-00000000000b/avatar.jpg'$$, '23514', null,
  'the photo path is always the owner''s own');
select throws_ok($$update profiles set plan = 'pro'$$, '42501', null, 'the profile grant stays narrow');
select lives_ok($$insert into storage.objects (bucket_id, name, owner, metadata)
  values ('avatars', 'a7000000-0000-0000-0000-00000000000a/avatar.jpg', 'a7000000-0000-0000-0000-00000000000a',
          '{"mimetype":"image/jpeg"}')$$, 'the owner uploads their photo');
select throws_ok($$insert into storage.objects (bucket_id, name, owner)
  values ('avatars', 'a7000000-0000-0000-0000-00000000000b/avatar.jpg', 'a7000000-0000-0000-0000-00000000000a')$$,
  '42501', null, 'nobody writes into another user''s folder');
select throws_ok($$insert into storage.objects (bucket_id, name, owner)
  values ('avatars', 'a7000000-0000-0000-0000-00000000000a/other.png', 'a7000000-0000-0000-0000-00000000000a')$$,
  '42501', null, 'and the owner writes only avatar.jpg');
select is((select count(*) from storage.objects where bucket_id = 'avatars'), 1::bigint, 'the owner reads their photo');
reset role;

-- B, a friend
set local role authenticated;
set local request.jwt.claims = '{"sub":"a7000000-0000-0000-0000-00000000000b","role":"authenticated"}';
select is((select count(*) from storage.objects where bucket_id = 'avatars'), 1::bigint, 'a friend can read the photo');
select is((select avatar_path from public.friend_avatars()), 'a7000000-0000-0000-0000-00000000000a/avatar.jpg',
  'friend_avatars lists the friend''s photo');
select is((select display_name from public.friends_list()), 'Ada Lovelace', 'friends see the typed name');
select throws_ok($$insert into storage.objects (bucket_id, name, owner)
  values ('avatars', 'a7000000-0000-0000-0000-00000000000a/avatar.jpg', 'a7000000-0000-0000-0000-00000000000b')$$,
  null, null, 'a friend cannot replace the photo');
reset role;

-- C, a stranger
set local role authenticated;
set local request.jwt.claims = '{"sub":"a7000000-0000-0000-0000-00000000000c","role":"authenticated"}';
select is((select count(*) from storage.objects where bucket_id = 'avatars'), 0::bigint, 'a stranger cannot read the photo');
select is((select count(*) from public.friend_avatars()), 0::bigint, 'and friend_avatars gives a stranger nothing');
select is((select count(*) from profiles where user_id = 'a7000000-0000-0000-0000-00000000000a'), 0::bigint,
  'nor the profile');
reset role;

set local role anon;
select throws_ok($$select * from public.friend_avatars()$$, '42501', null, 'anon calls nothing');
reset role;

-- After the friendship ends, the photo is private again.
set local request.jwt.claims = '{"sub":"a7000000-0000-0000-0000-00000000000a","role":"authenticated"}';
select ok(public.friend_remove('a7000000-0000-0000-0000-00000000000b'), 'the friendship ends');
set local role authenticated;
set local request.jwt.claims = '{"sub":"a7000000-0000-0000-0000-00000000000b","role":"authenticated"}';
select is((select count(*) from storage.objects where bucket_id = 'avatars'), 0::bigint,
  'a removed friend can no longer read the photo');
select is((select count(*) from public.friend_avatars()), 0::bigint, 'nor list it');
reset role;

-- A deleted account's photo is never listed.
update profiles set status = 'deleted' where user_id = 'a7000000-0000-0000-0000-00000000000a';
select is((select count(*) from public.friend_avatars()), 0::bigint, 'a deleted account''s photo is never listed');

select * from finish();
rollback;
