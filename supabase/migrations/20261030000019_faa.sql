-- FAA advisories: the National Airspace System status (ground stops, ground delay programs, delays,
-- closures at US airports, from nasstatus.faa.gov) and decoded NOTAMs (FAA NOTAM API). Both sources
-- are free. Functions: faa-status and faa-notams (docs/api-contract.md).
--
-- faa_status_cache: the whole parsed feed, one row ('nas'). Every airport shares it, so the FAA is
--   asked at most once per 5 minutes whatever the number of phones. A row older than that is served,
--   marked stale, for up to 30 minutes while the feed is down.
-- faa_notam_cache: the decoded notices of one airport, stored whole for 15 minutes (configured: false
--   answers are never stored, so setting the key takes effect at once).
-- faa-status-sweep: every 5 minutes, faa-status?mode=sweep refreshes the feed and sends the program
--   alerts (a new ground stop, ground delay program or closure at a followed flight's airport) through
--   push-sender, which dedupes them in alert_log like every other alert.
create table faa_status_cache (
  id         text primary key check (id = 'nas'),
  payload    jsonb not null,
  fetched_at timestamptz not null default now()
);
alter table faa_status_cache enable row level security;
-- No policy and no client grants: service role only. Reassert in case default privileges change.
revoke all on faa_status_cache from anon, authenticated;

create table faa_notam_cache (
  airport_icao text primary key references airports(icao) on delete cascade,
  payload      jsonb not null,
  fetched_at   timestamptz not null default now()
);
alter table faa_notam_cache enable row level security;
revoke all on faa_notam_cache from anon, authenticated;

-- cron.schedule upserts by name.
select cron.schedule('faa-status-sweep', '*/5 * * * *',
  $$select public.invoke_edge_function('faa-status', 'mode=sweep')$$);
select cron.schedule('faa-notam-cache-prune', '57 3 * * *', $$
  delete from public.faa_notam_cache where fetched_at < now() - interval '1 day';
$$);
