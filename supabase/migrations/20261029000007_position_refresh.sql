-- Live position, fetched lazily (ruling F2). flight-position calls /flights/{id}/position ($0.01 a
-- call, counted in usage_counters) when someone views a followed flight that is departed or en
-- route, at most once per flight per lease: the lease is the shared 2 minute cache, so however many
-- followers have the flight open, the provider is asked once per window. The answer lands in
-- flights.position_* and reaches every viewer through Realtime. Service role only.
create table position_refresh_leases (
  flight_id uuid primary key references flights (id) on delete cascade,
  until     timestamptz not null
);
alter table position_refresh_leases enable row level security;
revoke all on position_refresh_leases from anon, authenticated;

-- True when the caller now holds the window for this flight. Never released: it expires.
create function public.claim_position_refresh(p_flight uuid, p_seconds int)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare won boolean;
begin
  insert into public.position_refresh_leases as l (flight_id, until)
  values (p_flight, now() + make_interval(secs => p_seconds))
  on conflict (flight_id) do update set until = excluded.until
    where l.until <= now()
  returning true into won;
  return coalesce(won, false);
end;
$$;

revoke execute on function public.claim_position_refresh(uuid, int) from public, anon, authenticated;
grant execute on function public.claim_position_refresh(uuid, int) to service_role;
