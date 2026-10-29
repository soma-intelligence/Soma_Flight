begin;
create extension if not exists pgtap with schema extensions;
select plan(9);

select is((select public from storage.buckets where id = 'brand-assets'), false, 'brand-assets bucket is private');
select is((select count(*) from pg_policies where schemaname = 'storage' and tablename = 'objects'
  and (qual ilike '%brand-assets%' or with_check ilike '%brand-assets%')), 0::bigint,
  'no client storage policy mentions brand-assets');
select is((select array_agg(e.enumlabel::text order by e.enumsortorder) from pg_enum e
  join pg_type t on t.oid = e.enumtypid where t.typname = 'brand_asset_kind'),
  array['logo', 'logo_dark', 'tail', 'side_view'], 'brand_asset_kind labels');

insert into airline_assets (icao, kind, path, format, width, version, provider, fetched_at, checked_at)
values ('UAL', 'logo', 'logos/UAL/logo-v1.svg', 'svg', 512, 'v1', 'test', now(), now());

set local role authenticated;
select is((select count(*) from airline_assets where icao = 'UAL'), 1::bigint, 'authenticated can read airline_assets');
select throws_ok(
  $$insert into airline_assets (icao, kind, path, format, version, provider, fetched_at, checked_at)
    values ('UAL', 'tail', 'x', 'svg', 'v1', 't', now(), now())$$,
  '42501', null, 'authenticated cannot insert');
select throws_ok($$update airline_assets set version = 'v2'$$, '42501', null, 'authenticated cannot update');
select throws_ok($$delete from airline_assets$$, '42501', null, 'authenticated cannot delete');
reset role;

select throws_ok(
  $$insert into airline_assets (icao, kind, path, format, version, provider, fetched_at, checked_at)
    values ('UAL', 'tail', 'x', 'gif', 'v1', 't', now(), now())$$,
  '23514', null, 'format is svg, pdf or png');

set local role anon;
select throws_ok($$select 1 from airline_assets$$, '42501', null, 'anon cannot read airline_assets');

select * from finish();
rollback;
