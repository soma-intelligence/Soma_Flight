-- Security (TSA) wait times for US airports: the checkpoints of an airport, the hourly passenger
-- throughput they usually see, and the cache of security-wait answers.
--
-- No free live source may be used today (docs/data-sources.md, "Security wait times"): TSA's MyTSA web
-- service redirects to tsa.gov, and the airports that show live waits on their websites publish them
-- for their own pages, not for reuse. So security-wait answers with an estimate, and says so. The
-- estimate reads the hours below: TSA's weekly FOIA throughput report (passengers screened per airport,
-- checkpoint and hour, a work of the US government) reduced to a typical week per checkpoint. With no
-- row for an airport the function falls back to a typical US day, still labelled an estimate.
--
-- security_checkpoints: one row per checkpoint, named as the TSA report names it. terminal is how the
-- airport names the terminal the checkpoint serves ("1", "B", "International"), null when it serves
-- several or is unknown. precheck is true when the checkpoint has TSA PreCheck lanes, false when it has
-- none, null when we do not know.
create table security_checkpoints (
  airport_icao text not null references airports(icao) on delete cascade,
  id           text not null check (id ~ '^[a-z0-9-]{1,40}$'),
  name         text not null check (length(name) between 1 and 80),
  terminal     text check (length(terminal) between 1 and 40),
  precheck     boolean,
  primary key (airport_icao, id)
);
alter table security_checkpoints enable row level security;
-- No policy and no client grants: service role only. Reassert in case default privileges change.
revoke all on security_checkpoints from anon, authenticated;

-- security_throughput: the typical passengers a checkpoint screens in one local hour of one weekday
-- (0 is Sunday, as extract(dow)), e.g. the median of that hour over the last weeks of the report.
create table security_throughput (
  airport_icao  text not null,
  checkpoint_id text not null,
  weekday       smallint not null check (weekday between 0 and 6),
  hour          smallint not null check (hour between 0 and 23),
  passengers    integer not null check (passengers >= 0),
  primary key (airport_icao, checkpoint_id, weekday, hour),
  foreign key (airport_icao, checkpoint_id) references security_checkpoints (airport_icao, id) on delete cascade
);
alter table security_throughput enable row level security;
revoke all on security_throughput from anon, authenticated;

-- One answer per airport, stored whole (not-available answers included) for a few minutes, so a
-- departure lounge full of phones asks the sources once.
create table security_wait_cache (
  airport_icao text primary key references airports(icao) on delete cascade,
  payload      jsonb not null,
  fetched_at   timestamptz not null default now()
);
alter table security_wait_cache enable row level security;
revoke all on security_wait_cache from anon, authenticated;

-- Answers live for minutes: a row nobody asked for in a day is worth nothing. cron.schedule upserts by name.
select cron.schedule('security-wait-cache-prune', '55 3 * * *', $$
  delete from public.security_wait_cache where fetched_at < now() - interval '1 day';
$$);
