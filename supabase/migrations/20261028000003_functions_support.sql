-- Support for flight-lookup and follow-flight: usage counter, rate limit, route cache, follow rules.
-- Every function here is service role only (default privileges let anon execute public functions).

-- Atomic daily counter for AeroAPI spend, called from the AeroApi onCall hook.
create function public.increment_usage(p_day date, p_endpoint text, p_cost numeric)
returns void
language sql security definer set search_path = public as $$
  insert into usage_counters (day, endpoint, calls, estimated_cost)
  values (p_day, p_endpoint, 1, p_cost)
  on conflict (day, endpoint) do update
    set calls = usage_counters.calls + 1,
        estimated_cost = usage_counters.estimated_cost + excluded.estimated_cost;
$$;

-- Sliding window rate limit on rate_events (RLS on, no client grants). Returns false when over the limit.
-- The advisory lock makes check and insert atomic per user and endpoint.
create function public.check_rate(p_user uuid, p_endpoint text, p_max int, p_window_minutes int)
returns boolean
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform pg_advisory_xact_lock(hashtextextended('rate:' || p_user::text || ':' || p_endpoint, 0));
  delete from rate_events
    where user_id = p_user and endpoint = p_endpoint and at < now() - interval '1 day';
  select count(*) into n from rate_events
    where user_id = p_user and endpoint = p_endpoint
      and at > now() - make_interval(mins => p_window_minutes);
  if n >= p_max then
    return false;
  end if;
  insert into rate_events (user_id, endpoint) values (p_user, p_endpoint);
  return true;
end;
$$;

-- Free plan: fewer than 3 active follows (flights not arrived or canceled). Pro: unlimited.
create function public.plan_follow_allowed(p_user uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when coalesce((select plan from profiles where user_id = p_user), 'free') = 'pro' then true
    else (
      select count(*) from user_flights uf
      join flights f on f.id = uf.flight_id
      where uf.user_id = p_user and f.status not in ('arrived', 'canceled')
    ) < 3
  end;
$$;

-- Follow with the plan limit enforced under a per-user lock, so parallel requests cannot pass it.
-- Returns 'ok' (new follow), 'exists' (already followed, notify updated when given) or 'plan_limit'.
create function public.try_follow(p_user uuid, p_flight uuid, p_notify boolean default null)
returns text
language plpgsql security definer set search_path = public as $$
begin
  perform pg_advisory_xact_lock(hashtextextended('follow:' || p_user::text, 0));
  if exists (select 1 from user_flights where user_id = p_user and flight_id = p_flight) then
    if p_notify is not null then
      update user_flights set notify = p_notify where user_id = p_user and flight_id = p_flight;
    end if;
    return 'exists';
  end if;
  if not plan_follow_allowed(p_user) then
    return 'plan_limit';
  end if;
  insert into user_flights (user_id, flight_id, notify)
  values (p_user, p_flight, coalesce(p_notify, true));
  return 'ok';
end;
$$;

-- Short shared cache of route searches (a route search costs about $0.02 a page).
create table route_cache (
  origin_icao      text not null,
  destination_icao text not null,
  date             date not null,
  provider_ids     text[] not null default '{}',
  fetched_at       timestamptz not null default now(),
  primary key (origin_icao, destination_icao, date)
);
alter table route_cache enable row level security;
-- No policy and no client grants: service role only. Reassert in case default privileges change.
revoke all on route_cache from anon, authenticated;

revoke execute on function
  public.increment_usage(date, text, numeric),
  public.check_rate(uuid, text, int, int),
  public.plan_follow_allowed(uuid),
  public.try_follow(uuid, uuid, boolean)
from public, anon, authenticated;
grant execute on function
  public.increment_usage(date, text, numeric),
  public.check_rate(uuid, text, int, int),
  public.plan_follow_allowed(uuid),
  public.try_follow(uuid, uuid, boolean)
to service_role;
