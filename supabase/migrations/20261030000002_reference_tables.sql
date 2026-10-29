-- Reference data the app and the functions read: airlines (with brand colours) and aircraft types.
-- Rows come from supabase/seed/*.csv through 20261030000003_reference_seed.sql; the logo sync
-- (Task 8) later adds every airline the provider lists and replaces seed colours.
-- Countries are app and core data only, no table.

create table airlines (
  icao text primary key check (icao ~ '^[A-Z]{3}$'),
  iata text check (iata ~ '^[A-Z0-9]{2}$'),
  name text not null,
  callsign text,
  alliance text check (alliance in ('star_alliance', 'oneworld', 'skyteam')),
  country text check (country ~ '^[A-Z]{2}$'),
  color_primary text not null check (color_primary ~ '^#[0-9A-F]{6}$'),
  color_secondary text check (color_secondary ~ '^#[0-9A-F]{6}$'),
  phone text,
  website text,
  x text,
  facebook text,
  -- seed, locked (livery seed, never overwritten by the sync), or the provider name
  colors_source text not null default 'seed',
  colors_updated_at timestamptz
);
create index airlines_iata_idx on airlines (iata);

create table aircraft_types (
  icao_type text primary key,
  family text not null check (family in (
    'a220', 'a320', 'a330', 'a350', 'a380', 'b737', 'b737max', 'b747', 'b757', 'b767', 'b777', 'b787',
    'ejet', 'crj', 'atr', 'other')),
  manufacturer text not null,
  name text not null
);

-- Read for signed-in users, writes for the service role only: no insert, update or delete grant and no policy.
alter table airlines enable row level security;
alter table aircraft_types enable row level security;
create policy airlines_read on airlines for select to authenticated using (true);
create policy aircraft_types_read on aircraft_types for select to authenticated using (true);
revoke all on airlines, aircraft_types from public, anon, authenticated;
grant select on airlines, aircraft_types to authenticated;
