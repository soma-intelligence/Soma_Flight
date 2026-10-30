begin;
create extension if not exists pgtap with schema extensions;
select plan(16);

select is((select public from storage.buckets where id = 'brand-assets'), false, 'brand-assets bucket is private');
select is((select count(*) from pg_policies where schemaname = 'storage' and tablename = 'objects'
  and (qual ilike '%brand-assets%' or with_check ilike '%brand-assets%')), 0::bigint,
  'no client storage policy mentions brand-assets');
select is((select array_agg(e.enumlabel::text order by e.enumsortorder) from pg_enum e
  join pg_type t on t.oid = e.enumtypid where t.typname = 'brand_asset_kind'),
  array['logo', 'logo_dark', 'tail', 'side_view', 'wordmark'], 'brand_asset_kind labels');

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

select is((select schedule from cron.job where jobname = 'brand-logos-sync'), '17 * * * *', 'logo sync runs hourly at minute 17');

select is((select schedule from cron.job where jobname = 'brand-side-views-sync'), '41 * * * *', 'side view sync runs hourly at minute 41');
select is((select command from cron.job where jobname = 'brand-side-views-sync'),
  $$select public.invoke_edge_function('brand-assets-sync', 'mode=side_views&limit=100')$$, 'side view job calls mode=side_views');
select lives_ok(
  $$insert into airline_assets (icao, kind, path, format, version, provider, fetched_at, checked_at, note)
    values ('UAL', 'side_view', 'x', 'png', 'v1', 't', now(), now(), 'mirrored')$$, 'note accepts mirrored');
select lives_ok(
  $$insert into airline_assets (icao, kind, path, format, version, provider, fetched_at, checked_at)
    values ('UAL', 'tail', 'x', 'webp', 'v1', 't', now(), now())$$, 'webp is an allowed format');
select is((select relrowsecurity from pg_class where oid = 'public.airline_asset_misses'::regclass), true,
  'airline_asset_misses has RLS on');
select is((select count(*) from information_schema.role_table_grants where table_name = 'airline_asset_misses'
  and grantee in ('anon', 'authenticated', 'public')), 0::bigint, 'airline_asset_misses has no client grants');
select throws_ok(
  $$insert into airline_assets (icao, kind, path, format, version, provider, fetched_at, checked_at)
    values ('UAL', 'tail', 'x', 'gif', 'v1', 't', now(), now())$$,
  '23514', null, 'format is svg, pdf or png');

set local role anon;
select throws_ok($$select 1 from airline_assets$$, '42501', null, 'anon cannot read airline_assets');

select * from finish();
rollback;
