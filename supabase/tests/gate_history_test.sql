begin;
create extension if not exists pgtap with schema extensions;
select plan(22);

insert into auth.users (id, instance_id, aud, role, email)
values ('a4a4a4a4-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 'gates-a@test.local');

select has_table('public', 'flight_gate_days', 'flight_gate_days exists');
select is((select relrowsecurity from pg_class where oid = 'public.flight_gate_days'::regclass), true,
  'RLS is on');
select is((select count(*) from pg_policies where tablename = 'flight_gate_days'), 0::bigint, 'no policy');

-- KSFO is in the airports seed with America/Los_Angeles: 2026-10-29T03:30Z is still the 28th there.
insert into flights (id, provider_id, ident, operator, origin_icao, destination_icao, status, scheduled_out)
values ('c4000000-0000-0000-0000-000000000001', 'GH-1', 'AF84', 'AF', 'KSFO', 'LFPG', 'scheduled',
        '2026-10-29T03:30:00Z');
select is((select count(*) from flight_gate_days where ident = 'AF84'), 0::bigint,
  'a flight without a gate records nothing');

update flights set gate_origin = 'A10', terminal_origin = 'International'
where id = 'c4000000-0000-0000-0000-000000000001';
select results_eq(
  $$select day, gate, terminal, operator from flight_gate_days where ident = 'AF84'$$,
  $$values ('2026-10-28'::date, 'A10', 'International', 'AF')$$,
  'the first gate is recorded on the local day at the origin');

update flights set gate_origin = ' A12 ' where id = 'c4000000-0000-0000-0000-000000000001';
select results_eq($$select gate from flight_gate_days where ident = 'AF84'$$, $$values ('A12')$$,
  'a gate change replaces the day''s gate, trimmed');

update flights set gate_origin = '' where id = 'c4000000-0000-0000-0000-000000000001';
select results_eq($$select gate from flight_gate_days where ident = 'AF84'$$, $$values ('A12')$$,
  'a blank gate keeps the last one seen');

-- The next day's flight, inserted with its gate.
insert into flights (id, provider_id, ident, operator, origin_icao, destination_icao, status, scheduled_out,
                     gate_origin, terminal_origin)
values ('c4000000-0000-0000-0000-000000000002', 'GH-2', 'AF84', 'AF', 'KSFO', 'LFPG', 'scheduled',
        '2026-10-30T03:30:00Z', 'A12', 'International');
select is((select count(*) from flight_gate_days where ident = 'AF84'), 2::bigint,
  'an insert with a gate records its day too');

-- Canceled flights left from no gate; an airport with no known zone counts in UTC.
insert into flights (id, provider_id, ident, operator, origin_icao, destination_icao, status, scheduled_out,
                     gate_origin)
values ('c4000000-0000-0000-0000-000000000003', 'GH-3', 'AF86', 'AF', 'KSFO', 'LFPG', 'canceled',
        '2026-10-29T20:00:00Z', 'A3');
select is((select count(*) from flight_gate_days where ident = 'AF86'), 0::bigint, 'a canceled flight records nothing');
insert into flights (id, provider_id, ident, origin_icao, destination_icao, status, scheduled_out, gate_origin)
values ('c4000000-0000-0000-0000-000000000004', 'GH-4', 'ZZ1', 'ZZZZ', 'KSFO', 'scheduled',
        '2026-10-29T03:30:00Z', '7');
select results_eq($$select day from flight_gate_days where ident = 'ZZ1'$$, $$values ('2026-10-29'::date)$$,
  'an unknown airport counts the day in UTC');

-- A gate too long for the table is cut, never a failed flight write.
update flights set gate_origin = 'ABCDEFGHIJKLMNOP' where id = 'c4000000-0000-0000-0000-000000000004';
select results_eq($$select gate from flight_gate_days where ident = 'ZZ1'$$, $$values ('ABCDEFGHIJKL')$$,
  'a long gate is cut to 12 characters');

-- A flight write through process_alert's merge feeds it as well.
insert into user_flights (user_id, flight_id)
values ('a4a4a4a4-0000-0000-0000-000000000001', 'c4000000-0000-0000-0000-000000000002');
create function pg_temp.deliver(p_hash text, p_fields jsonb) returns jsonb
language plpgsql as $$
declare v_inbox bigint;
begin
  insert into webhook_inbox (body, body_sha256) values ('{}'::jsonb, p_hash) returning id into v_inbox;
  return process_alert(v_inbox, p_hash, 'GH-2', 'change', 1, '{}'::jsonb, p_fields, current_date, 0, 15);
end; $$;
select lives_ok($$select pg_temp.deliver('gh-h1', '{"gate_origin": "G91", "cancelled": false, "diverted": false}')$$,
  'a webhook delivery with a gate goes through');
select results_eq($$select gate from flight_gate_days where ident = 'AF84' and day = '2026-10-29'$$,
  $$values ('G91')$$, 'the webhook merge records the new gate');

-- Older days for the airline, straight into the table as the service role.
insert into flight_gate_days (ident, origin_icao, day, operator, gate, terminal) values
  ('AF84', 'KSFO', '2026-10-20', 'AF', 'A10', 'International'),
  ('AF84', 'KSFO', '2026-10-10', 'AF', 'A10', 'International'),
  ('AF90', 'KSFO', '2026-10-27', 'AF', 'A10', 'International'),
  ('AF90', 'KSFO', '2026-10-26', 'AF', 'A10', 'International'),
  ('DL1', 'KSFO', '2026-10-27', 'DL', 'C1', '1');

-- Clients: no table, but the function.
set local role authenticated;
set local request.jwt.claims = '{"sub":"a4a4a4a4-0000-0000-0000-000000000001","role":"authenticated"}';
select throws_ok($$select * from flight_gate_days$$, '42501', null, 'a user cannot read the table');
select throws_ok($$delete from flight_gate_days$$, '42501', null, 'a user cannot write the table');
select throws_ok($$select record_gate_day()$$, '42501', null, 'a user cannot call the trigger function');
select is(gate_history('AF84', 'KSFO', 'AF', '2026-10-30') -> 'days',
  '[{"day": "2026-10-29", "gate": "G91", "terminal": "International"},
    {"day": "2026-10-28", "gate": "A12", "terminal": "International"}]'::jsonb,
  'days come newest first, before the given day, inside 7 days');
select is(jsonb_array_length(gate_history('AF84', 'KSFO', 'AF', '2026-10-30', 30) -> 'days'), 4,
  'a longer window reaches further back');
select is(gate_history('AF84', 'KSFO', 'AF', '2026-10-30') -> 'airline' -> 0,
  '{"gate": "A10", "terminal": "International", "flights": 3}'::jsonb,
  'the airline''s busiest gate in the last 14 days comes first');
select is(gate_history('AF84', 'KSFO', null, '2026-10-30') -> 'airline', '[]'::jsonb,
  'no operator, no airline rows');
reset role;

set local role anon;
select throws_ok($$select gate_history('AF84', 'KSFO', 'AF', '2026-10-30')$$, '42501', null,
  'anon cannot call it');
reset role;

select is((select count(*) from cron.job where jobname = 'gate-history-prune'), 1::bigint,
  'old days are pruned daily');

select * from finish();
rollback;
