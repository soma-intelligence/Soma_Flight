-- Brand asset store: a private Storage bucket and the index of what it holds. The logo sync
-- (Task 8) writes objects and rows with the service role; the app only reads rows and gets signed
-- URLs from the brand-asset function, so the provider licence key never reaches a device.
-- Object paths: logos/<ICAO>/<kind>-<version>.<ext> and side-views/<ICAO>/<TYPE>-<version>.<ext>.
-- The version is part of the name, so a change is a new object and caches never mix versions.

-- Private bucket. storage.objects has RLS on and no policy here: clients cannot list or read it.
insert into storage.buckets (id, name, public)
values ('brand-assets', 'brand-assets', false)
on conflict (id) do update set public = false;

create type brand_asset_kind as enum ('logo', 'logo_dark', 'tail', 'side_view');

create table airline_assets (
  icao text not null references airlines (icao),
  kind brand_asset_kind not null,
  aircraft_type text not null default '', -- side views only
  path text not null,
  format text not null check (format in ('svg', 'pdf', 'png')),
  width int,
  version text not null,
  etag text,
  provider text not null,
  fetched_at timestamptz not null,
  checked_at timestamptz not null,
  primary key (icao, kind, aircraft_type)
);

alter table airline_assets enable row level security;
create policy airline_assets_read on airline_assets for select to authenticated using (true);
revoke all on airline_assets from public, anon, authenticated;
grant select on airline_assets to authenticated;
