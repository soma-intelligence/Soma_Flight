-- In-flight texts (iMessage or SMS through the Soma Linq line), on top of sms_alerts (20261031000024). OFF.
--
-- Nothing sends while the SMS_ALERTS_ENABLED secret is unset, and the Linq sender refuses without its
-- LINQ_API_KEY secret (docs/sms-alerts.md). This migration only adds what the code needs once it is on:
--
-- 1. sms_alerts.in_flight: the account's "In-Flight Texts" mode. Between boarding and arrival at the gate,
--    the alerts that matter on board (arrival delay, diversion, arrival gate and terminal, baggage belt,
--    connection, landed) go by text, for travellers on airline Wi-Fi that only lets messaging apps through.
--    Like `enabled`, it needs a verified number that has not said STOP.
-- 2. sms_flight_prefs: the flight sheet's "Text Me Updates In Flight" switch, one row per follow that
--    overrides the account mode for that flight (true turns it on, false off). Unfollowing deletes it.
-- 3. sms_log: one row per text sent for an alert (user, flight, alert key). claim_sms inserts it before
--    the send, so a retry of push-sender, or an alert both modes want, never texts twice; it also caps
--    the texts one account gets an hour and a day.
-- 4. sms_code_log and sms_code_allowed: three verification codes an hour per account and per number. The
--    number is kept only as a SHA-256 (with the code pepper), so the log opens nothing.
-- 5. sms_inbound_events: the Linq webhook's event ids, so a delivery Linq retries (at least once) is
--    acted on once.
--
-- Every write is service role (sms-verify, sms-inbound, push-sender). Owners read their own mode and
-- flight switches; nothing else is readable by clients.

alter table sms_alerts add column in_flight boolean not null default false;
alter table sms_alerts add constraint sms_alerts_in_flight_check
  check (not in_flight or (phone_e164 is not null and verified_at is not null and opted_out_at is null));
grant select (in_flight) on sms_alerts to authenticated;

create table sms_flight_prefs (
  user_id    uuid not null,
  flight_id  uuid not null,
  in_flight  boolean not null,
  updated_at timestamptz not null default now(),
  primary key (user_id, flight_id),
  foreign key (user_id, flight_id) references user_flights (user_id, flight_id) on delete cascade
);
create index sms_flight_prefs_flight_idx on sms_flight_prefs (flight_id);
alter table sms_flight_prefs enable row level security;
create policy sms_flight_prefs_owner_read on sms_flight_prefs for select to authenticated
  using (auth.uid() = user_id);
revoke all on sms_flight_prefs from anon, authenticated;
grant select on sms_flight_prefs to authenticated;

create table sms_log (
  id        bigint generated always as identity primary key,
  user_id   uuid not null references auth.users (id) on delete cascade,
  flight_id uuid not null references flights (id) on delete cascade,
  key       text not null check (length(key) between 1 and 200),
  sent_at   timestamptz not null default now(),
  unique (user_id, flight_id, key)
);
create index sms_log_user_sent_idx on sms_log (user_id, sent_at);
alter table sms_log enable row level security;
revoke all on sms_log from anon, authenticated;

create table sms_code_log (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users (id) on delete cascade,
  phone_hash text not null check (phone_hash ~ '^[0-9a-f]{64}$'),
  sent_at    timestamptz not null default now()
);
create index sms_code_log_user_idx on sms_code_log (user_id, sent_at);
create index sms_code_log_phone_idx on sms_code_log (phone_hash, sent_at);
alter table sms_code_log enable row level security;
revoke all on sms_code_log from anon, authenticated;

create table sms_inbound_events (
  event_id    text primary key check (length(event_id) between 1 and 200),
  received_at timestamptz not null default now()
);
alter table sms_inbound_events enable row level security;
revoke all on sms_inbound_events from anon, authenticated;

-- Claims one alert text for one account: false when it was already sent (same user, flight and alert key)
-- or when the account had p_max_hour texts in the last hour or p_max_day in the last day. Under a per-user
-- lock, so two push-sender calls racing for one user cannot pass the caps together.
create function public.claim_sms(p_user uuid, p_flight uuid, p_key text,
                                 p_max_hour int default 10, p_max_day int default 30)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare hour_n int; day_n int; got bigint;
begin
  perform pg_advisory_xact_lock(hashtextextended('sms:' || p_user::text, 0));
  delete from public.sms_log where user_id = p_user and sent_at < now() - interval '30 days';
  select count(*) filter (where sent_at > now() - interval '1 hour'),
         count(*) filter (where sent_at > now() - interval '1 day')
    into hour_n, day_n
    from public.sms_log where user_id = p_user;
  if hour_n >= p_max_hour or day_n >= p_max_day then
    return false;
  end if;
  insert into public.sms_log (user_id, flight_id, key) values (p_user, p_flight, p_key)
    on conflict (user_id, flight_id, key) do nothing
    returning id into got;
  return got is not null;
end;
$$;

-- Whether one more verification code may go out: fewer than p_max in the last hour for the account and
-- for the number (its hash). Counts the code when it may. Under one lock per number.
create function public.sms_code_allowed(p_user uuid, p_phone_hash text, p_max int default 3)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare by_user int; by_phone int;
begin
  perform pg_advisory_xact_lock(hashtextextended('smscode:' || p_phone_hash, 0));
  delete from public.sms_code_log where sent_at < now() - interval '1 day';
  select count(*) into by_user from public.sms_code_log
    where user_id = p_user and sent_at > now() - interval '1 hour';
  select count(*) into by_phone from public.sms_code_log
    where phone_hash = p_phone_hash and sent_at > now() - interval '1 hour';
  if by_user >= p_max or by_phone >= p_max then
    return false;
  end if;
  insert into public.sms_code_log (user_id, phone_hash) values (p_user, p_phone_hash);
  return true;
end;
$$;

revoke execute on function public.claim_sms(uuid, uuid, text, int, int) from public, anon, authenticated;
revoke execute on function public.sms_code_allowed(uuid, text, int) from public, anon, authenticated;
