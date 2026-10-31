begin;
create extension if not exists pgtap with schema extensions;
select plan(25);

insert into auth.users (id, instance_id, aud, role, email)
values
  ('a2a2a2a2-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'alerts-a@test.local'),
  ('b2b2b2b2-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'alerts-b@test.local');

-- notification_preferences: every column defaults to on.
insert into notification_preferences (user_id) values ('b2b2b2b2-0000-0000-0000-000000000002');
select results_eq(
  $$select delays, gates, takeoff_landing, baggage, cancellations, reminders from notification_preferences
    where user_id = 'b2b2b2b2-0000-0000-0000-000000000002'$$,
  $$values (true, true, true, true, true, true)$$,
  'a new row has every category on');

-- As user A.
set local role authenticated;
set local request.jwt.claims = '{"sub":"a2a2a2a2-0000-0000-0000-000000000001","role":"authenticated"}';
select is((select count(*)::int from notification_preferences), 0, 'A sees no row of B');
select lives_ok(
  $$insert into notification_preferences (user_id, delays, baggage)
    values ('a2a2a2a2-0000-0000-0000-000000000001', false, false)$$,
  'A inserts own row');
select results_eq(
  $$select delays, gates, baggage from notification_preferences$$,
  $$values (false, true, false)$$,
  'A reads own row back');
select lives_ok(
  $$update notification_preferences set gates = false, updated_at = now()$$,
  'A updates own row');
select is((select gates from notification_preferences), false, 'the update is stored');
select lives_ok(
  $$insert into notification_preferences (user_id, delays, gates)
    values ('a2a2a2a2-0000-0000-0000-000000000001', false, true)
    on conflict (user_id) do update set user_id = excluded.user_id, delays = excluded.delays,
      gates = excluded.gates$$,
  'A saves with an upsert on user_id, as the app does');
select throws_ok(
  $$insert into notification_preferences (user_id) values ('b2b2b2b2-0000-0000-0000-000000000002')$$,
  '42501', null, 'A cannot insert a row for B');
select throws_ok(
  $$update notification_preferences set user_id = 'b2b2b2b2-0000-0000-0000-000000000002'$$,
  '42501', null, 'A cannot move the row to another user');
select lives_ok(
  $$update notification_preferences set delays = false where user_id = 'b2b2b2b2-0000-0000-0000-000000000002'$$,
  'A updating B''s row raises nothing');
select lives_ok(
  $$delete from notification_preferences where user_id = 'b2b2b2b2-0000-0000-0000-000000000002'$$,
  'A deleting B''s row raises nothing');
select throws_ok($$select * from alert_log$$, '42501', null, 'alert_log is not readable by clients');

-- As user B.
set local request.jwt.claims = '{"sub":"b2b2b2b2-0000-0000-0000-000000000002","role":"authenticated"}';
select results_eq(
  $$select user_id::text, delays from notification_preferences$$,
  $$values ('b2b2b2b2-0000-0000-0000-000000000002'::text, true)$$,
  'B sees only own row, untouched by A');

-- Anonymous callers see nothing.
set local role anon;
select throws_ok($$select * from notification_preferences$$, '42501', null, 'anon cannot read preferences');
reset role;

select is((select delays from notification_preferences where user_id = 'a2a2a2a2-0000-0000-0000-000000000001'),
  false, 'A''s row is still there');

-- process_alert: the update event, the inbound id and the reinstatement.
insert into flights (id, provider_id, ident, origin_icao, destination_icao, status,
  scheduled_out, scheduled_in, estimated_out, estimated_in)
values ('c2000000-0000-0000-0000-000000000001', 'ALR-1', 'AFR84', 'LFPG', 'KSFO', 'scheduled',
  '2026-11-03T22:30:00Z', '2026-11-04T09:00:00Z', '2026-11-03T22:30:00Z', '2026-11-04T09:00:00Z');
insert into user_flights (user_id, flight_id)
values ('a2a2a2a2-0000-0000-0000-000000000001', 'c2000000-0000-0000-0000-000000000001');

create function pg_temp.deliver(p_hash text, p_code text, p_fields jsonb) returns jsonb
language plpgsql as $$
declare v_inbox bigint;
begin
  insert into webhook_inbox (body, body_sha256) values ('{}'::jsonb, p_hash) returning id into v_inbox;
  return process_alert(v_inbox, p_hash, 'ALR-1', p_code, 1, '{}'::jsonb, p_fields, current_date, 0, 15);
end; $$;

select is(jsonb_array_length(pg_temp.deliver('alr-h1', 'change',
    '{"estimated_out": "2026-11-03T22:33:00Z", "cancelled": false, "diverted": false}') -> 'events'),
  0, 'an estimate moved by 3 minutes makes no event');
select is(pg_temp.deliver('alr-h2', 'change',
    '{"estimated_out": "2026-11-03T22:40:00Z", "inbound_provider_id": "ALR-IN", "cancelled": false, "diverted": false}')
    -> 'events' -> 0 ->> 'kind',
  'update', 'an estimate moved by 7 minutes makes an update event');
select is((select inbound_provider_id from flights where id = 'c2000000-0000-0000-0000-000000000001'), 'ALR-IN',
  'the inbound id is stored');
select is(pg_temp.deliver('alr-h3', 'off',
    '{"actual_out": "2026-11-03T22:41:00Z", "actual_off": "2026-11-03T22:58:00Z", "cancelled": false, "diverted": false}')
    -> 'events' -> 0 ->> 'kind',
  'update', 'take-off makes an update event');
select is((select payload -> 'changes' -> 'actual_off' ->> 'to' from flight_events where provider_event_id = 'alr-h3'),
  '2026-11-03T22:58:00+00:00', 'the update event carries the changes');

-- Cancel, then an older change body (still canceled), then a new flight plan (back on the schedule).
update flights set status = 'scheduled', actual_out = null, actual_off = null
  where id = 'c2000000-0000-0000-0000-000000000001';
select is(pg_temp.deliver('alr-h4', 'cancelled', '{"cancelled": true, "diverted": false}') -> 'events' -> 0 ->> 'kind',
  'cancel', 'a cancel is a cancel event');
select is(jsonb_array_length(pg_temp.deliver('alr-h5', 'change',
    '{"gate_destination": "", "cancelled": false, "diverted": false}') -> 'events'),
  0, 'a change body with cancelled false does not lift the cancel');
select is((select status::text from flights where id = 'c2000000-0000-0000-0000-000000000001'), 'canceled',
  'still canceled');
select is(pg_temp.deliver('alr-h6', 'filed', '{"cancelled": false, "diverted": false}') -> 'events' -> 0 ->> 'kind',
  'update', 'a filed body lifts the cancel with an update event');
select is((select status::text from flights where id = 'c2000000-0000-0000-0000-000000000001'), 'scheduled',
  'reinstated as scheduled');

select * from finish();
rollback;
