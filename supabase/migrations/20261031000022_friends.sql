-- Friends: mutual friendships made by invitation, and what each friend may see of the other.
--
-- Privacy model (GOAL.md): no contacts, no phone or email lookup. Two people become friends only when one
-- hands the other something on purpose: a single-use invitation link (https://somalabs.me/i/<token>) or the
-- short friend code shown in the Friends tab. A link is accepted or declined by whoever opens it; a code
-- sends a request the code's owner accepts or declines.
--
-- Tables:
--   friend_settings     one row per user: their friend code and the "pause all sharing" switch.
--   friendships         one row per direction (user_id -> friend_id). Both rows exist or neither does: only
--                       the functions below write them, always in pairs. The row user_id -> friend_id holds
--                       what user_id chooses about friend_id: share_flights (user_id's upcoming flights go to
--                       friend_id, on by default), share_passport (user_id's Passport totals, off by default)
--                       and alerts (user_id gets pushes for friend_id's flights, off by default).
--   friend_invitations  pending, accepted, declined and revoked invitations (links and code requests). A link
--                       keeps only the SHA-256 of its token, like flight_shares.
--
-- Reads of a friend's data go through security definer functions that check the friendship both ways, the
-- friend's switch and their pause: friend_flights (flight data only, never seats, booking codes, notes or
-- boarding passes, which live on user_flights and the device) and friend_passport (totals only). Writes of
-- invitations go through the `friends` edge function (service role, rate limited); a user changes their own
-- switches through PostgREST (column grants) or the authenticated functions.

-- Profile: a display name (already on profiles) and an optional emoji, shown to friends only.
alter table profiles
  add column emoji text check (emoji is null or char_length(emoji) between 1 and 8);
alter table profiles
  add constraint profiles_display_name_length
  check (display_name is null or char_length(btrim(display_name)) between 1 and 40) not valid;
grant update (emoji) on profiles to authenticated;

-- 8 characters of Crockford's base32 (no I, L, O, U): 40 bits, read aloud without confusion.
create function public.friend_code_new() returns text
language sql volatile set search_path = '' as $$
  select string_agg(substr('0123456789ABCDEFGHJKMNPQRSTVWXYZ', (get_byte(b, i) % 32) + 1, 1), '' order by i)
  from (select uuid_send(gen_random_uuid()) as b) r, generate_series(0, 7) as i;
$$;

create table friend_settings (
  user_id        uuid primary key references auth.users (id) on delete cascade,
  friend_code    text not null unique check (friend_code ~ '^[0-9A-HJKMNP-TV-Z]{8}$'),
  sharing_paused boolean not null default false,
  updated_at     timestamptz not null default now()
);
alter table friend_settings enable row level security;
create policy friend_settings_owner_read on friend_settings for select to authenticated
  using (auth.uid() = user_id);
create policy friend_settings_owner_update on friend_settings for update to authenticated
  using (auth.uid() = user_id) with check (auth.uid() = user_id);
revoke all on friend_settings from anon, authenticated;
grant select on friend_settings to authenticated;
-- The pause only: the code is the server's (friend_code_reset).
grant update (sharing_paused, updated_at) on friend_settings to authenticated;

create table friendships (
  user_id        uuid not null references auth.users (id) on delete cascade,
  friend_id      uuid not null references auth.users (id) on delete cascade,
  share_flights  boolean not null default true,
  share_passport boolean not null default false,
  alerts         boolean not null default false,
  created_at     timestamptz not null default now(),
  primary key (user_id, friend_id),
  check (user_id <> friend_id)
);
create index friendships_friend_id_idx on friendships (friend_id);
alter table friendships enable row level security;
create policy friendships_owner_read on friendships for select to authenticated
  using (auth.uid() = user_id);
create policy friendships_owner_update on friendships for update to authenticated
  using (auth.uid() = user_id) with check (auth.uid() = user_id);
revoke all on friendships from anon, authenticated;
grant select on friendships to authenticated;
-- A user's own three switches about a friend; never who the friend is (no insert, no delete, no friend_id).
grant update (share_flights, share_passport, alerts) on friendships to authenticated;

create type friend_invite_kind as enum ('link', 'code');
create type friend_invite_status as enum ('pending', 'accepted', 'declined', 'revoked');

create table friend_invitations (
  id           uuid primary key default gen_random_uuid(),
  kind         friend_invite_kind not null,
  from_user    uuid not null references auth.users (id) on delete cascade,
  -- Who answered a link (null until then); who a code request is for.
  to_user      uuid references auth.users (id) on delete cascade,
  token_hash   text unique check (token_hash ~ '^[0-9a-f]{64}$'),
  status       friend_invite_status not null default 'pending',
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null,
  responded_at timestamptz,
  check ((kind = 'link') = (token_hash is not null)),
  check (kind = 'link' or to_user is not null),
  check (to_user is null or to_user <> from_user),
  check ((status = 'pending') = (responded_at is null)),
  check (expires_at > created_at)
);
create index friend_invitations_from_idx on friend_invitations (from_user, status);
create index friend_invitations_to_idx on friend_invitations (to_user, status);
-- One pending code request per pair and direction.
create unique index friend_invitations_one_request_idx on friend_invitations (from_user, to_user)
  where kind = 'code' and status = 'pending';
alter table friend_invitations enable row level security;
create policy friend_invitations_party_read on friend_invitations for select to authenticated
  using (auth.uid() = from_user or auth.uid() = to_user);
revoke all on friend_invitations from anon, authenticated;
-- Never the token hash.
grant select (id, kind, from_user, to_user, status, created_at, expires_at, responded_at)
  on friend_invitations to authenticated;

-- Pending links one user may hold at once, and pending code requests one user may have sent.
create function public.friend_limits() returns table (max_links int, max_requests int, max_friends int)
language sql immutable set search_path = '' as $$ select 20, 20, 500 $$;

-- ---------------------------------------------------------------------------------------------------
-- Helpers (no client access)

-- The user's settings row, made with a fresh code on first use.
create function public.friend_settings_ensure(p_user uuid) returns public.friend_settings
language plpgsql security definer set search_path = '' as $$
declare r public.friend_settings;
begin
  select * into r from public.friend_settings where user_id = p_user;
  if found then return r; end if;
  loop
    begin
      insert into public.friend_settings (user_id, friend_code) values (p_user, public.friend_code_new())
        on conflict (user_id) do nothing;
      select * into r from public.friend_settings where user_id = p_user;
      return r;
    exception when unique_violation then
      -- The code was taken: draw another.
    end;
  end loop;
end;
$$;

-- True when both rows exist and neither account is deleted.
create function public.are_friends(p_a uuid, p_b uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.friendships where user_id = p_a and friend_id = p_b)
     and exists (select 1 from public.friendships where user_id = p_b and friend_id = p_a)
     and not exists (select 1 from public.profiles where user_id in (p_a, p_b) and status = 'deleted');
$$;

-- Makes the pair (idempotent). Refuses past max_friends.
create function public.friendship_make(p_a uuid, p_b uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare cap int := (select max_friends from public.friend_limits());
begin
  if p_a = p_b then raise exception 'friend_self' using errcode = 'P0001'; end if;
  if not public.are_friends(p_a, p_b) and (
       (select count(*) from public.friendships where user_id = p_a) >= cap
    or (select count(*) from public.friendships where user_id = p_b) >= cap) then
    raise exception 'friend_limit' using errcode = 'P0001';
  end if;
  insert into public.friendships (user_id, friend_id) values (p_a, p_b), (p_b, p_a)
    on conflict do nothing;
  -- Any other pending code request between the two is settled by this friendship.
  update public.friend_invitations set status = 'accepted', responded_at = now()
    where kind = 'code' and status = 'pending'
      and ((from_user = p_a and to_user = p_b) or (from_user = p_b and to_user = p_a));
end;
$$;

-- ---------------------------------------------------------------------------------------------------
-- Invitations: service role only, called by the `friends` edge function after its rate limit.

-- A new link invitation. The token is made and hashed by the function; only the hash arrives here.
create function public.friend_invite_create(p_user uuid, p_token_hash text, p_ttl_hours int default 168)
returns table (id uuid, expires_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare cap int := (select max_links from public.friend_limits());
begin
  perform pg_advisory_xact_lock(hashtextextended('friend-invite:' || p_user::text, 0));
  if (select count(*) from public.friend_invitations i
      where i.from_user = p_user and i.kind = 'link' and i.status = 'pending' and i.expires_at > now()) >= cap then
    raise exception 'too_many_invites' using errcode = 'P0001';
  end if;
  return query insert into public.friend_invitations (kind, from_user, token_hash, expires_at)
    values ('link', p_user, p_token_hash, now() + make_interval(hours => greatest(1, least(p_ttl_hours, 720))))
    returning friend_invitations.id, friend_invitations.expires_at;
end;
$$;

-- What a link says before it is answered: who sent it and whether it still works.
-- state: open, expired, used (accepted, declined or revoked), self, friends (already friends).
create function public.friend_invite_preview(p_user uuid, p_token_hash text)
returns table (invitation_id uuid, display_name text, emoji text, state text)
language sql stable security definer set search_path = '' as $$
  select i.id, p.display_name, p.emoji,
    case
      when i.from_user = p_user then 'self'
      when public.are_friends(i.from_user, p_user) then 'friends'
      when i.status <> 'pending' then 'used'
      when i.expires_at <= now() then 'expired'
      else 'open'
    end
  from public.friend_invitations i
  left join public.profiles p on p.user_id = i.from_user
  where i.token_hash = p_token_hash and i.kind = 'link'
    and coalesce(p.status, 'active') = 'active';
$$;

-- Answers a link. Returns the inviter on acceptance. Errors: invite_not_found, invite_closed, friend_self.
create function public.friend_invite_respond(p_user uuid, p_token_hash text, p_accept boolean)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare i public.friend_invitations;
begin
  select * into i from public.friend_invitations
    where token_hash = p_token_hash and kind = 'link' for update;
  if not found or exists (select 1 from public.profiles where user_id = i.from_user and status = 'deleted') then
    raise exception 'invite_not_found' using errcode = 'P0001';
  end if;
  if i.from_user = p_user then raise exception 'friend_self' using errcode = 'P0001'; end if;
  if i.status <> 'pending' or i.expires_at <= now() then
    raise exception 'invite_closed' using errcode = 'P0001';
  end if;
  -- Single use: whoever answers first closes it.
  update public.friend_invitations
    set status = case when p_accept then 'accepted'::public.friend_invite_status else 'declined' end,
        to_user = p_user, responded_at = now()
    where id = i.id;
  if p_accept then
    perform public.friendship_make(i.from_user, p_user);
    return i.from_user;
  end if;
  return null;
end;
$$;

-- A request to the owner of a code. Returns 'sent', or 'accepted' when that person had already asked the
-- caller (both asked: that is consent from both sides), or 'friends'. Errors: code_not_found, friend_self,
-- too_many_requests.
create function public.friend_request_by_code(p_user uuid, p_code text)
returns text
language plpgsql security definer set search_path = '' as $$
declare target uuid; cap int := (select max_requests from public.friend_limits()); back uuid;
begin
  select s.user_id into target from public.friend_settings s
    join public.profiles p on p.user_id = s.user_id and p.status = 'active'
    where s.friend_code = upper(btrim(p_code));
  if target is null then raise exception 'code_not_found' using errcode = 'P0001'; end if;
  if target = p_user then raise exception 'friend_self' using errcode = 'P0001'; end if;
  if public.are_friends(p_user, target) then return 'friends'; end if;
  select id into back from public.friend_invitations
    where kind = 'code' and status = 'pending' and from_user = target and to_user = p_user
      and expires_at > now() for update;
  if back is not null then
    perform public.friendship_make(p_user, target);
    return 'accepted';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('friend-request:' || p_user::text, 0));
  if (select count(*) from public.friend_invitations
      where from_user = p_user and kind = 'code' and status = 'pending' and expires_at > now()) >= cap then
    raise exception 'too_many_requests' using errcode = 'P0001';
  end if;
  -- An expired pending request to the same person is closed first, so the unique index lets a new one in.
  update public.friend_invitations set status = 'revoked', responded_at = now()
    where kind = 'code' and status = 'pending' and from_user = p_user and to_user = target and expires_at <= now();
  insert into public.friend_invitations (kind, from_user, to_user, expires_at)
    values ('code', p_user, target, now() + interval '30 days')
    on conflict do nothing;
  return 'sent';
end;
$$;

-- Answers a code request made to the caller. Returns true when it was pending and is now answered.
create function public.friend_request_respond(p_user uuid, p_invitation uuid, p_accept boolean)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare i public.friend_invitations;
begin
  select * into i from public.friend_invitations
    where id = p_invitation and kind = 'code' and to_user = p_user for update;
  if not found or i.status <> 'pending' or i.expires_at <= now() then return false; end if;
  update public.friend_invitations
    set status = case when p_accept then 'accepted'::public.friend_invite_status else 'declined' end,
        responded_at = now()
    where id = i.id;
  if p_accept then perform public.friendship_make(i.from_user, p_user); end if;
  return true;
end;
$$;

-- Withdraws a pending link or code request the caller made. True when one was pending.
create function public.friend_invite_revoke(p_user uuid, p_invitation uuid)
returns boolean
language sql security definer set search_path = '' as $$
  with r as (
    update public.friend_invitations set status = 'revoked', responded_at = now()
    where id = p_invitation and from_user = p_user and status = 'pending'
    returning 1)
  select exists (select 1 from r);
$$;

-- A new friend code; the old one stops working at once.
create function public.friend_code_reset(p_user uuid)
returns text
language plpgsql security definer set search_path = '' as $$
declare c text;
begin
  perform public.friend_settings_ensure(p_user);
  loop
    begin
      c := public.friend_code_new();
      update public.friend_settings set friend_code = c, updated_at = now() where user_id = p_user;
      return c;
    exception when unique_violation then
    end;
  end loop;
end;
$$;

-- Who hears about a friend's flight: for each friend who follows `p_flight`, shares flights with the
-- watcher, has not paused sharing, and whom the watcher asked alerts for. A watcher who follows the flight
-- themselves already hears about it and is left out. Used by push-sender.
create function public.friend_alert_watchers(p_flight uuid)
returns table (watcher_id uuid, owner_id uuid, owner_name text, owner_emoji text)
language sql stable security definer set search_path = '' as $$
  select w.user_id, o.user_id, p.display_name, p.emoji
  from public.user_flights uf
  join public.friendships o on o.user_id = uf.user_id and o.share_flights
  join public.friendships w on w.user_id = o.friend_id and w.friend_id = o.user_id and w.alerts
  left join public.friend_settings s on s.user_id = o.user_id
  left join public.profiles p on p.user_id = o.user_id
  where uf.flight_id = p_flight
    and not coalesce(s.sharing_paused, false)
    and coalesce(p.status, 'active') = 'active'
    and not exists (select 1 from public.profiles d where d.user_id = w.user_id and d.status = 'deleted')
    and not exists (select 1 from public.user_flights mine where mine.user_id = w.user_id and mine.flight_id = p_flight);
$$;

-- ---------------------------------------------------------------------------------------------------
-- The app's reads and own-row writes (authenticated, through auth.uid()).

-- The caller's friend code, pause, name and emoji; makes the settings row on first call.
create function public.friends_me()
returns table (friend_code text, sharing_paused boolean, display_name text, emoji text)
language plpgsql security definer set search_path = '' as $$
declare me uuid := auth.uid(); s public.friend_settings;
begin
  if me is null then raise exception 'not signed in' using errcode = '42501'; end if;
  s := public.friend_settings_ensure(me);
  return query select s.friend_code, s.sharing_paused, p.display_name, p.emoji
    from (select 1) x left join public.profiles p on p.user_id = me;
end;
$$;

-- The caller's friends: their name and emoji, the caller's three switches about them, and what they share
-- with the caller now (their switch, unless they paused all sharing).
create function public.friends_list()
returns table (friend_id uuid, display_name text, emoji text, since timestamptz,
               share_flights boolean, share_passport boolean, alerts boolean,
               shares_flights boolean, shares_passport boolean)
language sql stable security definer set search_path = '' as $$
  select mine.friend_id, p.display_name, p.emoji, greatest(mine.created_at, theirs.created_at),
         mine.share_flights, mine.share_passport, mine.alerts,
         theirs.share_flights and not coalesce(s.sharing_paused, false),
         theirs.share_passport and not coalesce(s.sharing_paused, false)
  from public.friendships mine
  join public.friendships theirs on theirs.user_id = mine.friend_id and theirs.friend_id = mine.user_id
  left join public.profiles p on p.user_id = mine.friend_id
  left join public.friend_settings s on s.user_id = mine.friend_id
  where mine.user_id = auth.uid() and coalesce(p.status, 'active') = 'active'
  order by lower(coalesce(p.display_name, '')), mine.friend_id;
$$;

-- Pending code requests involving the caller. An incoming one carries the sender's name; an outgoing one
-- does not (a code must not reveal whose it is).
create function public.friend_requests()
returns table (id uuid, incoming boolean, display_name text, emoji text, created_at timestamptz,
               expires_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select i.id, i.to_user = auth.uid(),
         case when i.to_user = auth.uid() then p.display_name end,
         case when i.to_user = auth.uid() then p.emoji end,
         i.created_at, i.expires_at
  from public.friend_invitations i
  left join public.profiles p on p.user_id = i.from_user
  where i.kind = 'code' and i.status = 'pending' and i.expires_at > now()
    and (i.to_user = auth.uid() or i.from_user = auth.uid())
    and coalesce(p.status, 'active') = 'active'
  order by i.created_at desc;
$$;

-- Ends a friendship, both directions at once. True when there was one.
create function public.friend_remove(p_friend uuid)
returns boolean
language sql security definer set search_path = '' as $$
  with gone as (
    delete from public.friendships
    where (user_id = auth.uid() and friend_id = p_friend) or (user_id = p_friend and friend_id = auth.uid())
    returning 1)
  select auth.uid() is not null and exists (select 1 from gone);
$$;

-- A friend's upcoming and in-air followed flights (one friend, or every friend when null): flight data only.
-- Empty unless both rows exist, the friend shares flights with the caller and has not paused sharing.
-- Flights that ended more than 6 hours ago are left out.
create function public.friend_flights(p_friend uuid default null)
returns table (
  friend_id uuid, id uuid, provider_id text, ident text, operator text,
  origin_icao text, origin_iata text, destination_icao text, destination_iata text,
  scheduled_out timestamptz, scheduled_in timestamptz, estimated_out timestamptz, estimated_in timestamptz,
  scheduled_off timestamptz, scheduled_on timestamptz, estimated_off timestamptz, estimated_on timestamptz,
  actual_out timestamptz, actual_off timestamptz, actual_on timestamptz, actual_in timestamptz,
  gate_origin text, gate_destination text, terminal_origin text, terminal_destination text, baggage_belt text,
  aircraft_type text, registration text, status public.flight_status,
  position_lat float8, position_lon float8, position_altitude_ft int, position_ground_speed_kt int,
  position_heading int, position_at timestamptz, updated_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select o.user_id, f.id, f.provider_id, f.ident, f.operator,
         f.origin_icao, f.origin_iata, f.destination_icao, f.destination_iata,
         f.scheduled_out, f.scheduled_in, f.estimated_out, f.estimated_in,
         f.scheduled_off, f.scheduled_on, f.estimated_off, f.estimated_on,
         f.actual_out, f.actual_off, f.actual_on, f.actual_in,
         f.gate_origin, f.gate_destination, f.terminal_origin, f.terminal_destination, f.baggage_belt,
         f.aircraft_type, f.registration, f.status,
         f.position_lat, f.position_lon, f.position_altitude_ft, f.position_ground_speed_kt,
         f.position_heading, f.position_at, f.updated_at
  from public.friendships o
  join public.friendships back on back.user_id = auth.uid() and back.friend_id = o.user_id
  join public.user_flights uf on uf.user_id = o.user_id
  join public.flights f on f.id = uf.flight_id
  left join public.friend_settings s on s.user_id = o.user_id
  left join public.profiles p on p.user_id = o.user_id
  where o.friend_id = auth.uid()
    and (p_friend is null or o.user_id = p_friend)
    and o.share_flights
    and not coalesce(s.sharing_paused, false)
    and coalesce(p.status, 'active') = 'active'
    and f.origin_icao is not null and f.destination_icao is not null
    and not (f.status in ('arrived', 'landed', 'canceled', 'diverted')
             and coalesce(f.actual_in, f.actual_on, f.estimated_in, f.scheduled_in, f.updated_at)
                 < now() - interval '6 hours')
  order by coalesce(f.actual_out, f.estimated_out, f.scheduled_out), f.id;
$$;

-- A friend's Passport totals, when they share them with the caller: no flight, date, seat or place.
create function public.friend_passport(p_friend uuid)
returns table (flights bigint, distance_km bigint, air_minutes bigint, airports bigint, countries bigint,
               airlines bigint)
language sql stable security definer set search_path = '' as $$
  select count(*), coalesce(sum(pf.distance_km), 0), coalesce(sum(coalesce(pf.air_minutes, pf.block_minutes)), 0),
         (select count(distinct a) from public.past_flights x,
            lateral (values (x.origin_icao), (x.destination_icao)) v(a)
          where x.user_id = p_friend and a is not null),
         (select count(distinct c) from public.past_flights x,
            lateral (values (x.origin_country), (x.destination_country)) v(c)
          where x.user_id = p_friend and c is not null),
         count(distinct pf.airline)
  from public.past_flights pf
  where pf.user_id = p_friend
    and exists (
      select 1 from public.friendships o
      join public.friendships back on back.user_id = auth.uid() and back.friend_id = o.user_id
      left join public.friend_settings s on s.user_id = o.user_id
      left join public.profiles p on p.user_id = o.user_id
      where o.user_id = p_friend and o.friend_id = auth.uid() and o.share_passport
        and not coalesce(s.sharing_paused, false) and coalesce(p.status, 'active') = 'active')
  having exists (
      select 1 from public.friendships o
      join public.friendships back on back.user_id = auth.uid() and back.friend_id = o.user_id
      left join public.friend_settings s on s.user_id = o.user_id
      where o.user_id = p_friend and o.friend_id = auth.uid() and o.share_passport
        and not coalesce(s.sharing_paused, false));
$$;

-- Grants: helpers and invitation writes for the service role, reads and own changes for signed-in users.
revoke execute on function
  public.friend_code_new(), public.friend_limits(), public.friend_settings_ensure(uuid),
  public.are_friends(uuid, uuid), public.friendship_make(uuid, uuid),
  public.friend_invite_create(uuid, text, int), public.friend_invite_preview(uuid, text),
  public.friend_invite_respond(uuid, text, boolean), public.friend_request_by_code(uuid, text),
  public.friend_request_respond(uuid, uuid, boolean), public.friend_invite_revoke(uuid, uuid),
  public.friend_code_reset(uuid), public.friend_alert_watchers(uuid),
  public.friends_me(), public.friends_list(), public.friend_requests(), public.friend_remove(uuid),
  public.friend_flights(uuid), public.friend_passport(uuid)
from public, anon, authenticated;
grant execute on function
  public.friend_invite_create(uuid, text, int), public.friend_invite_preview(uuid, text),
  public.friend_invite_respond(uuid, text, boolean), public.friend_request_by_code(uuid, text),
  public.friend_request_respond(uuid, uuid, boolean), public.friend_invite_revoke(uuid, uuid),
  public.friend_code_reset(uuid), public.friend_alert_watchers(uuid)
to service_role;
grant execute on function
  public.friends_me(), public.friends_list(), public.friend_requests(), public.friend_remove(uuid),
  public.friend_flights(uuid), public.friend_passport(uuid)
to authenticated, service_role;

-- Answered and expired invitations are worth nothing after a month.
select cron.schedule('friend-invitations-prune', '45 4 * * *', $$
  delete from public.friend_invitations
  where (status <> 'pending' and responded_at < now() - interval '30 days')
     or (status = 'pending' and expires_at < now() - interval '30 days');
$$);
