-- Stampede guard for airport-board lazy refreshes. One lease per airport and snapshot kind:
-- the caller that wins the lease refreshes from the provider, the others serve the stale snapshot.
-- Service role only (RLS on, no policy, no client grants).
create table airport_refresh_leases (
  icao  text not null,
  kind  snapshot_kind not null,
  until timestamptz not null,
  primary key (icao, kind)
);
alter table airport_refresh_leases enable row level security;
revoke all on airport_refresh_leases from anon, authenticated;

-- True when the caller now holds the lease. An unexpired lease held by someone else returns false.
create function public.claim_airport_refresh(p_icao text, p_kind snapshot_kind, p_lease_seconds int)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare won boolean;
begin
  insert into public.airport_refresh_leases as l (icao, kind, until)
  values (p_icao, p_kind, now() + make_interval(secs => p_lease_seconds))
  on conflict (icao, kind) do update set until = excluded.until
    where l.until <= now()
  returning true into won;
  return coalesce(won, false);
end;
$$;

create function public.release_airport_refresh(p_icao text, p_kind snapshot_kind)
returns void
language sql security definer set search_path = '' as $$
  delete from public.airport_refresh_leases where icao = p_icao and kind = p_kind;
$$;

revoke execute on function
  public.claim_airport_refresh(text, snapshot_kind, int),
  public.release_airport_refresh(text, snapshot_kind)
from public, anon, authenticated;
grant execute on function
  public.claim_airport_refresh(text, snapshot_kind, int),
  public.release_airport_refresh(text, snapshot_kind)
to service_role;
