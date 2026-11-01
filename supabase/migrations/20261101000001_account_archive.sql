-- Deleting an account keeps an archive of it (owner's call, 2026-11-01). delete-account still erases the
-- live rows and the sign-in, so the app meets App Store in-app deletion, but first copies everything the
-- user owned into archive.deleted_accounts: one row per account, the email and a jsonb snapshot of each
-- table, plus the profile photo moved to deleted/<user_id>/avatar.jpg in the avatars bucket.
--
-- The archive schema is not exposed to the API and no client role has any right on it; only the service
-- role reaches it, through archive_account() below.

create schema if not exists archive;
revoke all on schema archive from public, anon, authenticated;
grant usage on schema archive to service_role;

create table archive.deleted_accounts (
  id bigint generated always as identity primary key,
  user_id uuid not null unique,
  email text,
  archived_at timestamptz not null default now(),
  data jsonb not null
);
revoke all on archive.deleted_accounts from public, anon, authenticated;
grant select, insert on archive.deleted_accounts to service_role;

-- Snapshots every table the user owns (rows where user_id is theirs) into one archive row. A retry after a
-- partial deletion finds the row already there and keeps it, so the first, complete snapshot wins.
create function public.archive_account(p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_table text;
  v_rows jsonb;
  v_data jsonb := '{}'::jsonb;
begin
  if exists (select 1 from archive.deleted_accounts where user_id = p_user) then
    return;
  end if;
  foreach v_table in array array['profiles', 'past_flights', 'user_flights', 'friendships', 'friend_settings',
    'flight_shares', 'notification_preferences', 'push_tokens', 'sms_alerts', 'sms_flight_prefs', 'sms_log']
  loop
    execute format('select coalesce(jsonb_agg(to_jsonb(t)), ''[]''::jsonb) from public.%I t where t.user_id = $1',
                   v_table)
      into v_rows using p_user;
    v_data := v_data || jsonb_build_object(v_table, v_rows);
  end loop;
  insert into archive.deleted_accounts (user_id, email, data)
  values (p_user, (select email from auth.users where id = p_user), v_data)
  on conflict (user_id) do nothing;
end; $$;
revoke all on function public.archive_account(uuid) from public, anon, authenticated;
grant execute on function public.archive_account(uuid) to service_role;
