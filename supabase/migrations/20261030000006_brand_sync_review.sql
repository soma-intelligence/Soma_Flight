-- Brand sync review round 1.
-- 1. airline_assets.format also allows webp (the validated mime allow-list is svg, png, webp).
-- 2. airline_asset_misses: a miss (the provider has no such file, or sent one validation refused) is
--    remembered for a day per airline, kind and aircraft type, so a retry after a partial run or an
--    outage does not ask again. Service role only.
alter table airline_assets drop constraint airline_assets_format_check;
alter table airline_assets add constraint airline_assets_format_check
  check (format in ('svg', 'pdf', 'png', 'webp'));

create table airline_asset_misses (
  icao text not null references airlines (icao) on delete cascade,
  kind brand_asset_kind not null,
  aircraft_type text not null default '',
  provider text not null,
  miss_until timestamptz not null,
  primary key (icao, kind, aircraft_type)
);
alter table airline_asset_misses enable row level security;
revoke all on airline_asset_misses from public, anon, authenticated;
