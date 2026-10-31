-- Free and freemium flight data providers (docs/free-providers.md).
--
-- provider_quota: requests (OpenSky: credits) used per provider and counting period, so a free tier
-- is never exceeded. A period is identified by its first day: the 1st of the month for monthly
-- allowances (Aviationstack, FlightLabs), the day itself for daily ones (OpenSky). The polling
-- refresh also keeps a daily pace counter per provider (provider '<name>.poll') so a monthly
-- allowance is spread over the month instead of being spent in its first days.
--
-- charge_provider_quota: counts p_units unless that takes the period past p_limit, in which case it
-- counts nothing and returns false (the caller answers provider_unavailable and serves its cache).
-- The advisory lock serialises the check per provider and period, so concurrent callers cannot all
-- pass on the same remaining units.
create table provider_quota (
  provider     text not null check (provider ~ '^[a-z]+(\.[a-z]+)?$'),
  period_start date not null,
  used         int not null default 0 check (used >= 0),
  updated_at   timestamptz not null default now(),
  primary key (provider, period_start)
);
alter table provider_quota enable row level security;
-- No policy and no client grants: service role only.
revoke all on provider_quota from anon, authenticated;

create function public.charge_provider_quota(p_provider text, p_period date, p_units int, p_limit int)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare v_used int;
begin
  if p_units is null or p_units < 0 then
    raise exception 'units must be >= 0' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('quota:' || p_provider || ':' || p_period::text, 0));
  select used into v_used from public.provider_quota
    where provider = p_provider and period_start = p_period;
  if coalesce(v_used, 0) + p_units > p_limit then
    return false;
  end if;
  insert into public.provider_quota (provider, period_start, used)
  values (p_provider, p_period, p_units)
  on conflict (provider, period_start) do update
    set used = provider_quota.used + excluded.used, updated_at = now();
  return true;
end;
$$;
revoke execute on function public.charge_provider_quota(text, date, int, int) from public, anon, authenticated;
grant execute on function public.charge_provider_quota(text, date, int, int) to service_role;

-- provider_polls: when the polling refresh last asked the status provider about a followed flight.
-- Goes with the flight.
create table provider_polls (
  flight_id      uuid primary key references flights (id) on delete cascade,
  last_polled_at timestamptz not null,
  provider       text not null
);
alter table provider_polls enable row level security;
revoke all on provider_polls from anon, authenticated;

-- poll_candidates: followed flights still worth asking about (not arrived, canceled or diverted),
-- whose best departure time is within 30 hours back and 8 hours ahead, with their last poll. The
-- polling refresh decides which are due (_shared/providers/poll.ts). Soonest departure first.
create function public.poll_candidates(p_limit int default 500)
returns table (
  id uuid, provider_id text, ident text, operator text,
  origin_icao text, origin_iata text, destination_icao text, destination_iata text,
  scheduled_out timestamptz, scheduled_in timestamptz, estimated_out timestamptz,
  estimated_in timestamptz, actual_out timestamptz, actual_off timestamptz,
  actual_on timestamptz, actual_in timestamptz,
  gate_origin text, gate_destination text, terminal_origin text, terminal_destination text,
  baggage_belt text, aircraft_type text, registration text,
  status public.flight_status, updated_at timestamptz, last_polled_at timestamptz
)
language sql stable security definer set search_path = '' as $$
  select f.id, f.provider_id, f.ident, f.operator,
    f.origin_icao, f.origin_iata, f.destination_icao, f.destination_iata,
    f.scheduled_out, f.scheduled_in, f.estimated_out, f.estimated_in,
    f.actual_out, f.actual_off, f.actual_on, f.actual_in,
    f.gate_origin, f.gate_destination, f.terminal_origin, f.terminal_destination,
    f.baggage_belt, f.aircraft_type, f.registration,
    f.status, f.updated_at, p.last_polled_at
  from public.flights f
  left join public.provider_polls p on p.flight_id = f.id
  where f.status not in ('arrived', 'canceled', 'diverted')
    and exists (select 1 from public.user_flights uf where uf.flight_id = f.id)
    and coalesce(f.estimated_out, f.scheduled_out) between now() - interval '30 hours'
                                                      and now() + interval '8 hours'
  order by coalesce(f.estimated_out, f.scheduled_out)
  limit greatest(p_limit, 0);
$$;
revoke execute on function public.poll_candidates(int) from public, anon, authenticated;
grant execute on function public.poll_candidates(int) to service_role;

-- Every 5 minutes. The function answers { skipped } and calls nothing while STATUS_PROVIDER is
-- aeroapi (alerts come by webhook) or none. cron.schedule upserts by name.
select cron.schedule('provider-poll', '*/5 * * * *',
  $$select public.invoke_edge_function('maintenance', 'mode=poll')$$);

-- Counters older than three months and polls of flights nobody follows any more.
select cron.schedule('provider-quota-prune', '10 4 * * *', $$
  delete from public.provider_quota where period_start < (now() - interval '3 months')::date;
  delete from public.provider_polls p
    where not exists (select 1 from public.user_flights uf where uf.flight_id = p.flight_id);
$$);
