begin;
create extension if not exists pgtap with schema extensions;
select plan(14);

select cmp_ok((select count(*) from airlines), '>=', 60::bigint, 'airlines has at least 60 rows');
select results_eq(
  $$select iata, alliance, colors_source from airlines where icao = 'UAL'$$,
  $$values ('UA'::text, 'star_alliance'::text, 'locked'::text)$$,
  'UAL is United, Star Alliance, colours locked');
select is((select array_agg(icao order by icao) from airlines where colors_source = 'locked'),
  array['AFR', 'RYR', 'UAL'], 'only the three livery seed airlines are locked');
select is((select count(*) from airlines where colors_source not in ('seed', 'locked')), 0::bigint,
  'every other row starts as seed');
select is((select count(*) from airlines where icao in
  ('UAL', 'DLH', 'AFR', 'ACA', 'TRA', 'TVF', 'BEL', 'FLE', 'RYR', 'AAL', 'ASA', 'DAL', 'FFT', 'JBU', 'NKS', 'SWA')),
  16::bigint, 'the history and fake carriers are all there');
select cmp_ok((select count(*) from aircraft_types), '>=', 70::bigint, 'aircraft_types has at least 70 rows');
select is((select count(*) from aircraft_types where family not in
  ('a220', 'a320', 'a330', 'a350', 'a380', 'b737', 'b737max', 'b747', 'b757', 'b767', 'b777', 'b787',
   'ejet', 'crj', 'atr', 'bizjet', 'other')), 0::bigint, 'every aircraft family is in the allowed set');
select results_eq(
  $$select family, manufacturer from aircraft_types where icao_type = 'B38M'$$,
  $$values ('b737max'::text, 'Boeing'::text)$$, 'B38M is a 737 MAX');

-- Writes are service role only.
set local role authenticated;
select is((select count(*) from airlines where icao = 'UAL'), 1::bigint, 'authenticated can read airlines');
select is((select count(*) from aircraft_types where icao_type = 'A320'), 1::bigint, 'authenticated can read aircraft_types');
select throws_ok(
  $$insert into airlines (icao, name, color_primary) values ('ZZZ', 'Test', '#000000')$$,
  '42501', null, 'authenticated cannot insert an airline');
select throws_ok($$update airlines set color_primary = '#000000' where icao = 'UAL'$$,
  '42501', null, 'authenticated cannot update an airline');
select throws_ok(
  $$insert into aircraft_types (icao_type, family, manufacturer, name) values ('ZZZZ', 'other', 'Test', 'Test')$$,
  '42501', null, 'authenticated cannot insert an aircraft type');
reset role;
set local role anon;
select throws_ok($$select 1 from airlines$$, '42501', null, 'anon cannot read airlines');

select * from finish();
rollback;
