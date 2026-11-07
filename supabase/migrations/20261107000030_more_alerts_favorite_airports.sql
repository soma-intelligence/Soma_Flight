-- More alert kinds and favorite airports.
--
-- 1. notification_preferences gets three switches, all on by default (a user with no row has everything
--    on): boarding (boarding started, boarding time change), aircraft (aircraft or registration swap) and
--    favorite_airports (disruptions at airports the user follows). Early departure and long taxi out ride
--    on `delays`. push-sender reads these columns by name (CATEGORIES in push-sender/handler.ts).
-- 2. favorite_airports: the airports a user follows, whatever their flights. Owner only (RLS). At most
--    50 per user, so a client cannot grow the sweep without bound.
-- 3. favorite_alert_log: one row per user and event once a favorite airport push was claimed. alert_log
--    is keyed by flight, and a favorite airport event has no flight, so it gets its own log with the
--    same claim-then-send rule. Service role only.
-- 4. favorite-airports-sweep: every 5 minutes at minute 2 (after faa-status-sweep refreshed the shared
--    FAA cache), favorite-airports?mode=sweep sends each new program to the users who follow that airport.
--    The function answers { skipped } and does nothing unless FAVORITE_AIRPORT_ALERTS_ENABLED is "true".
-- Not applied by the author: the controller applies it. cron.schedule upserts by name.
alter table public.notification_preferences
  add column boarding boolean not null default true,
  add column aircraft boolean not null default true,
  add column favorite_airports boolean not null default true;

create table public.favorite_airports (
  user_id      uuid not null references auth.users (id) on delete cascade,
  airport_icao text not null references public.airports (icao) on delete cascade,
  created_at   timestamptz not null default now(),
  primary key (user_id, airport_icao)
);
create index favorite_airports_airport_idx on public.favorite_airports (airport_icao);
alter table public.favorite_airports enable row level security;
create policy favorite_airports_owner on public.favorite_airports for all to authenticated
  using (auth.uid() = user_id) with check (auth.uid() = user_id);
revoke all on public.favorite_airports from anon;
grant select, insert, delete on public.favorite_airports to authenticated;
grant select on public.favorite_airports to service_role;

create function public.favorite_airports_cap() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if (select count(*) from public.favorite_airports where user_id = new.user_id) >= 50 then
    raise exception 'too many favorite airports' using errcode = '54000';
  end if;
  return new;
end; $$;
revoke all on function public.favorite_airports_cap() from public, anon, authenticated;
create trigger favorite_airports_cap before insert on public.favorite_airports
  for each row execute function public.favorite_airports_cap();

create table public.favorite_alert_log (
  user_id uuid not null references auth.users (id) on delete cascade,
  key     text not null,
  kind    text not null,
  sent_at timestamptz not null default now(),
  primary key (user_id, key)
);
alter table public.favorite_alert_log enable row level security;
-- No policy and no client grants: service role only. Reassert in case default privileges change.
revoke all on public.favorite_alert_log from anon, authenticated;
grant select, insert on public.favorite_alert_log to service_role;

select cron.schedule('favorite-airports-sweep', '2-59/5 * * * *',
  $$select public.invoke_edge_function('favorite-airports', 'mode=sweep')$$);
-- A program key carries its start, so a week old row can never match a live program again.
select cron.schedule('favorite-alert-log-prune', '25 4 * * *', $$
  delete from public.favorite_alert_log where sent_at < now() - interval '7 days';
$$);

-- An account archive keeps the followed airports too (same function as 20261101000001, one table more).
create or replace function public.archive_account(p_user uuid) returns void
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
    'flight_shares', 'notification_preferences', 'push_tokens', 'sms_alerts', 'sms_flight_prefs', 'sms_log',
    'favorite_airports']
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
