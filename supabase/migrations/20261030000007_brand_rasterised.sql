-- Brand sync review round 2.
-- SVG is never stored: vectors are rasterised to PNG at sync. The asset row points at the 384 px PNG
-- (path) and, for rendered vectors, a 192 px one (path_small, null for provider rasters).
alter table airline_assets add column path_small text;

-- A miss belongs to the provider that missed: a Commons miss no longer overwrites an Airhex one.
alter table airline_asset_misses drop constraint airline_asset_misses_pkey;
alter table airline_asset_misses add primary key (icao, kind, aircraft_type, provider);
