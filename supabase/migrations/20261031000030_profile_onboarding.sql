-- Profile onboarding: a first and last name, a photo, and when the short onboarding after sign-in was
-- finished or put off. Friends already read `display_name` and `emoji` from profiles (20261031000022);
-- the app now writes `display_name` from the first and last name, so friends keep reading one column.
--
-- The photo: one JPEG per user in the private `avatars` bucket at `<user_id>/avatar.jpg` (about 512 px,
-- re-encoded on the device so no camera metadata travels). The owner writes it; the owner and their
-- accepted friends read it through signed URLs. Nobody else can list or read the bucket.

alter table profiles
  add column first_name   text check (first_name is null or char_length(btrim(first_name)) between 1 and 40),
  add column last_name    text check (last_name is null or char_length(btrim(last_name)) between 1 and 40),
  add column avatar_path  text,
  add column onboarded_at timestamptz;
-- The only path a photo may have: the owner's own folder, one fixed file name.
alter table profiles
  add constraint profiles_avatar_path_own check (avatar_path is null or avatar_path = user_id::text || '/avatar.jpg');

grant update (first_name, last_name, avatar_path, onboarded_at) on profiles to authenticated;

-- Private bucket, JPEG only, 1 MB at most (a 512 px JPEG is well under 200 KB).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', false, 1048576, array['image/jpeg'])
on conflict (id) do update set public = false, file_size_limit = 1048576, allowed_mime_types = array['image/jpeg'];

-- The owner writes, replaces and removes their own photo, and only at <user_id>/avatar.jpg.
create policy avatars_owner_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and name = (select auth.uid())::text || '/avatar.jpg');
create policy avatars_owner_update on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and name = (select auth.uid())::text || '/avatar.jpg')
  with check (bucket_id = 'avatars' and name = (select auth.uid())::text || '/avatar.jpg');
create policy avatars_owner_delete on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and name = (select auth.uid())::text || '/avatar.jpg');
-- Read (and so sign a URL): the owner, or a friend. The friendship check reads the caller's own row
-- (friendships RLS shows a user only rows they own); the server writes friendships in pairs, so the
-- caller's row exists exactly when the friendship does. A removed friend loses access at once.
create policy avatars_owner_or_friend_read on storage.objects for select to authenticated
  using (
    bucket_id = 'avatars'
    and (
      name = (select auth.uid())::text || '/avatar.jpg'
      or exists (
        select 1 from public.friendships f
        where f.user_id = (select auth.uid())
          and f.friend_id::text = split_part(name, '/', 1)
          and name = f.friend_id::text || '/avatar.jpg')
    )
  );

-- The caller's friends who have a photo, with when it last changed (the app's cache key). Same rules
-- as friends_list: both rows of the friendship, the friend's account active. No pause check: a paused
-- friend still shows their face, only their flights and Passport stop.
create function public.friend_avatars()
returns table (friend_id uuid, avatar_path text, updated_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select mine.friend_id, p.avatar_path, coalesce(o.updated_at, o.created_at)
  from public.friendships mine
  join public.friendships theirs on theirs.user_id = mine.friend_id and theirs.friend_id = mine.user_id
  join public.profiles p on p.user_id = mine.friend_id and p.status = 'active' and p.avatar_path is not null
  join storage.objects o on o.bucket_id = 'avatars' and o.name = p.avatar_path
  where mine.user_id = auth.uid()
  order by mine.friend_id;
$$;

revoke execute on function public.friend_avatars() from public, anon, authenticated;
grant execute on function public.friend_avatars() to authenticated, service_role;
