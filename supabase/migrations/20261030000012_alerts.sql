-- Wider push alerts. push-sender now derives every alert (delays per side, schedule, gates,
-- terminals, belt, gate out, take-off, landing, gate in, cancel, reinstated, diversion, inbound
-- aircraft late) from the `changes` of a flight event (supabase/functions/_shared/alerts.ts). This
-- migration gives it what it needs:
--
--   flight_event_kind 'update'  an event for a delivery that changed something an alert is made from
--                               but is none of the named kinds (take-off, landing, a schedule move,
--                               an estimate move, a reinstated flight). The app shows no timeline row
--                               for it.
--   flights.inbound_provider_id the provider id of the leg that brings this flight's aircraft, from
--                               the delivery's inbound_fa_flight_id. Read only when that leg is in
--                               flights too (nothing is fetched for it).
--   alert_log                   one row per alert sent (dedupe, and the last delay sent per side).
--   notification_preferences    the categories a user turned off. No row means everything on.
--   process_alert               as in 20261029000006, plus the update event, the inbound id and a
--                               cancel lifted by a later filed delivery.

alter type public.flight_event_kind add value if not exists 'update';

alter table public.flights add column inbound_provider_id text;
create index flights_inbound_provider_id_idx on public.flights (inbound_provider_id)
  where inbound_provider_id is not null;

-- One row per alert push-sender claimed for a flight. `key` is unique per flight: an alert that may
-- happen once (take-off, first gate) has a fixed key, any other carries the delivery it came from, so
-- a retried push-sender call or the two events of one delivery never send it twice. `minutes` is the
-- delay a delay alert announced, the baseline for the next one. Service role only.
create table public.alert_log (
  flight_id uuid not null references public.flights (id) on delete cascade,
  key       text not null,
  kind      text not null,
  minutes   int,
  sent_at   timestamptz not null default now(),
  primary key (flight_id, key)
);
create index alert_log_flight_kind_sent_idx on public.alert_log (flight_id, kind, sent_at desc);
alter table public.alert_log enable row level security;

-- The alert categories a user wants. Every column defaults to true and a user with no row gets
-- everything, so the row only has to exist once something is turned off. `reminders` is read by the
-- app, which schedules those notifications on the device; the server never sends them.
create table public.notification_preferences (
  user_id         uuid primary key references auth.users (id) on delete cascade,
  delays          boolean not null default true,
  gates           boolean not null default true,
  takeoff_landing boolean not null default true,
  baggage         boolean not null default true,
  cancellations   boolean not null default true,
  reminders       boolean not null default true,
  updated_at      timestamptz not null default now()
);
alter table public.notification_preferences enable row level security;
create policy notification_preferences_owner on public.notification_preferences for all to authenticated
  using (auth.uid() = user_id) with check (auth.uid() = user_id);
grant select, insert, delete on public.notification_preferences to authenticated;
grant update (delays, gates, takeoff_landing, baggage, cancellations, reminders, updated_at)
  on public.notification_preferences to authenticated;

-- process_alert. Changes from 20261029000006:
--   * inbound_provider_id is kept from the delivery (p_fields->>'inbound_provider_id').
--   * A canceled flight whose delivery is a 'filed' one with cancelled = false is back on the
--     schedule: its status is rebuilt from the actual times (scheduled when there are none). A
--     'change' body is not enough, since an older body can arrive after the cancel; a new flight plan
--     is filed only for a flight that flies.
--   * With no named event and no delay event, a delivery still makes an 'update' event when the
--     status moved, an actual time or a scheduled time was set or moved, the diversion airport moved
--     (diverted and change bodies only),
--     or an estimate moved by v_estimate_step minutes or more (push-sender decides whether that is
--     worth an alert; small estimate jitter makes no event at all). Canceled and diverted flights
--     only get one when their status or diversion airport changed.
create or replace function public.process_alert(
  p_inbox bigint, p_hash text, p_fa_flight_id text, p_event_code text, p_alert_id bigint,
  p_texts jsonb, p_fields jsonb, p_day date, p_cost numeric, p_delay_step int default 15
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  f public.flights%rowtype;
  m public.flights;
  v_events jsonb := '[]'::jsonb;
  v_note text;
  v_diff boolean := p_event_code in ('change','filed','minutes_out','out','off','on','in');
  v_followed boolean;
  v_status_to public.flight_status;
  v_place boolean; v_delay int; v_d_out int; v_d_in int; v_last int;
  v_primary public.flight_event_kind; v_want_delay boolean := false;
  v_changes jsonb; v_payload jsonb; v_id uuid; v_eid text;
  v_notified int;
  v_estimate_step interval := interval '5 minutes';
  v_moved boolean;
begin
  perform pg_advisory_xact_lock(hashtextextended('alert:' || p_hash, 0));
  if exists (
    select 1 from public.webhook_inbox
    where body_sha256 = p_hash and processed_at is not null and id <> p_inbox
  ) then
    update public.webhook_inbox
      set processed_at = now(), note = 'duplicate delivery', error = null where id = p_inbox;
    return jsonb_build_object('duplicate', true, 'flight_id', null, 'events', '[]'::jsonb);
  end if;

  select * into f from public.flights where provider_id = p_fa_flight_id for update;
  v_followed := found and exists (select 1 from public.user_flights where flight_id = f.id);

  if not v_followed then
    v_note := 'no followed flight for this fa_flight_id';
  else
    m := public.merge_flight(f, p_fields, p_event_code);
    m.inbound_provider_id := coalesce(nullif(p_fields->>'inbound_provider_id', ''), f.inbound_provider_id);
    -- Reinstated: a new flight plan for a flight we had as canceled.
    if f.status = 'canceled' and p_event_code = 'filed'
       and (p_fields->>'cancelled') = 'false' and coalesce(p_fields->>'diverted', 'false') = 'false' then
      m.status := case
        when m.actual_in is not null then 'arrived'
        when m.actual_on is not null then 'landed'
        when m.actual_off is not null then 'en_route'
        when m.actual_out is not null then 'departed'
        else 'scheduled' end;
    end if;
    v_place := (m.gate_origin, m.gate_destination, m.terminal_origin, m.terminal_destination, m.baggage_belt)
      is distinct from (f.gate_origin, f.gate_destination, f.terminal_origin, f.terminal_destination, f.baggage_belt);
    v_status_to := case when m.status in ('canceled', 'diverted') and m.status is distinct from f.status
      then m.status end;

    -- Delay against schedule: worst of out and in, actual if known else estimate.
    v_d_out := round(extract(epoch from (coalesce(m.actual_out, m.estimated_out) - m.scheduled_out)) / 60);
    v_d_in := round(extract(epoch from (coalesce(m.actual_in, m.estimated_in) - m.scheduled_in)) / 60);
    v_delay := greatest(v_d_out, v_d_in);
    v_last := f.notified_delay_min;
    if v_diff and v_delay is not null and m.status not in ('canceled', 'diverted', 'arrived') then
      v_want_delay := case when v_last is null then v_delay >= p_delay_step
        else abs(v_delay - v_last) >= p_delay_step end;
    end if;

    -- Primary event.
    if v_status_to = 'canceled'
       and not exists (select 1 from public.flight_events where flight_id = f.id and kind = 'cancel') then
      v_primary := 'cancel';
    elsif v_status_to = 'diverted'
       and not exists (select 1 from public.flight_events where flight_id = f.id and kind = 'diversion') then
      v_primary := 'diversion';
    elsif p_event_code = 'departure' and f.status not in ('canceled', 'diverted')
       and not exists (select 1 from public.flight_events where flight_id = f.id and kind = 'departure') then
      v_primary := 'departure';
    elsif p_event_code = 'arrival' and f.status not in ('canceled', 'diverted')
       and not exists (select 1 from public.flight_events where flight_id = f.id and kind = 'arrival') then
      v_primary := 'arrival';
    elsif v_diff and v_place then
      v_primary := 'gate_change';
    end if;

    -- Anything else an alert is made from.
    if v_primary is null and not v_want_delay then
      v_moved := m.status is distinct from f.status
        -- Only diversion and change bodies say where a diverted flight goes; a gate or runway body
        -- can be older than the diversion.
        or (m.status = 'diverted' and p_event_code in ('diverted', 'change')
            and m.destination_icao is distinct from f.destination_icao)
        or (m.status not in ('canceled', 'diverted') and (
          (m.actual_out, m.actual_off, m.actual_on, m.actual_in, m.scheduled_out, m.scheduled_in)
            is distinct from (f.actual_out, f.actual_off, f.actual_on, f.actual_in, f.scheduled_out, f.scheduled_in)
          or (m.estimated_out is distinct from f.estimated_out
              and (f.estimated_out is null or m.estimated_out is null
                   or abs(extract(epoch from m.estimated_out - f.estimated_out)) >= extract(epoch from v_estimate_step)))
          or (m.estimated_in is distinct from f.estimated_in
              and (f.estimated_in is null or m.estimated_in is null
                   or abs(extract(epoch from m.estimated_in - f.estimated_in)) >= extract(epoch from v_estimate_step)))));
      if v_moved then
        v_primary := 'update';
      end if;
    end if;

    -- Keep explicit nulls inside each entry ({"from": null, "to": ...}); drop only unchanged fields.
    v_changes := coalesce((select jsonb_object_agg(t.k, t.v) from (values
      ('scheduled_out', case when m.scheduled_out is distinct from f.scheduled_out then jsonb_build_object('from', f.scheduled_out, 'to', m.scheduled_out) end),
      ('scheduled_in', case when m.scheduled_in is distinct from f.scheduled_in then jsonb_build_object('from', f.scheduled_in, 'to', m.scheduled_in) end),
      ('estimated_out', case when m.estimated_out is distinct from f.estimated_out then jsonb_build_object('from', f.estimated_out, 'to', m.estimated_out) end),
      ('estimated_in', case when m.estimated_in is distinct from f.estimated_in then jsonb_build_object('from', f.estimated_in, 'to', m.estimated_in) end),
      ('actual_out', case when m.actual_out is distinct from f.actual_out then jsonb_build_object('from', f.actual_out, 'to', m.actual_out) end),
      ('actual_off', case when m.actual_off is distinct from f.actual_off then jsonb_build_object('from', f.actual_off, 'to', m.actual_off) end),
      ('actual_on', case when m.actual_on is distinct from f.actual_on then jsonb_build_object('from', f.actual_on, 'to', m.actual_on) end),
      ('actual_in', case when m.actual_in is distinct from f.actual_in then jsonb_build_object('from', f.actual_in, 'to', m.actual_in) end),
      ('gate_origin', case when m.gate_origin is distinct from f.gate_origin then jsonb_build_object('from', f.gate_origin, 'to', m.gate_origin) end),
      ('gate_destination', case when m.gate_destination is distinct from f.gate_destination then jsonb_build_object('from', f.gate_destination, 'to', m.gate_destination) end),
      ('terminal_origin', case when m.terminal_origin is distinct from f.terminal_origin then jsonb_build_object('from', f.terminal_origin, 'to', m.terminal_origin) end),
      ('terminal_destination', case when m.terminal_destination is distinct from f.terminal_destination then jsonb_build_object('from', f.terminal_destination, 'to', m.terminal_destination) end),
      ('baggage_belt', case when m.baggage_belt is distinct from f.baggage_belt then jsonb_build_object('from', f.baggage_belt, 'to', m.baggage_belt) end),
      ('aircraft_type', case when m.aircraft_type is distinct from f.aircraft_type then jsonb_build_object('from', f.aircraft_type, 'to', m.aircraft_type) end),
      ('registration', case when m.registration is distinct from f.registration then jsonb_build_object('from', f.registration, 'to', m.registration) end),
      ('origin_icao', case when m.origin_icao is distinct from f.origin_icao then jsonb_build_object('from', f.origin_icao, 'to', m.origin_icao) end),
      ('origin_iata', case when m.origin_iata is distinct from f.origin_iata then jsonb_build_object('from', f.origin_iata, 'to', m.origin_iata) end),
      ('destination_icao', case when m.destination_icao is distinct from f.destination_icao then jsonb_build_object('from', f.destination_icao, 'to', m.destination_icao) end),
      ('destination_iata', case when m.destination_iata is distinct from f.destination_iata then jsonb_build_object('from', f.destination_iata, 'to', m.destination_iata) end),
      ('inbound_provider_id', case when m.inbound_provider_id is distinct from f.inbound_provider_id then jsonb_build_object('from', f.inbound_provider_id, 'to', m.inbound_provider_id) end),
      ('status', case when m.status is distinct from f.status then jsonb_build_object('from', f.status, 'to', m.status) end)
    ) as t(k, v) where t.v is not null), '{}'::jsonb);
    v_payload := jsonb_build_object(
      'event_code', p_event_code, 'alert_id', p_alert_id,
      'short_description', p_texts->'short_description', 'summary', p_texts->'summary',
      'changes', v_changes);
    if m.gate_origin is distinct from f.gate_origin and m.gate_origin is not null then
      v_payload := v_payload || jsonb_build_object('gate', m.gate_origin);
    end if;
    if m.destination_icao is not null
       and (v_primary = 'diversion' or m.destination_icao is distinct from f.destination_icao) then
      v_payload := v_payload || jsonb_build_object('destination', m.destination_icao);
    end if;

    v_notified := f.notified_delay_min;
    if v_primary is not null then
      insert into public.flight_events (flight_id, provider_event_id, kind, payload)
      values (f.id, p_hash, v_primary, v_payload)
      on conflict (provider_event_id) do nothing returning id into v_id;
      if v_id is null then
        update public.webhook_inbox
          set processed_at = now(), note = 'duplicate delivery', error = null where id = p_inbox;
        return jsonb_build_object('duplicate', true, 'flight_id', null, 'events', '[]'::jsonb);
      end if;
      v_events := v_events || jsonb_build_array(jsonb_build_object('id', v_id, 'kind', v_primary));
    end if;
    if v_want_delay then
      v_eid := case when v_primary is null then p_hash else p_hash || ':delay' end;
      insert into public.flight_events (flight_id, provider_event_id, kind, payload)
      values (f.id, v_eid, 'delay', v_payload || jsonb_build_object(
        'delay_minutes', v_delay, 'previous_delay_minutes', v_last, 'minutes', v_delay))
      on conflict (provider_event_id) do nothing returning id into v_id;
      if v_id is null then
        if v_primary is null then
          update public.webhook_inbox
            set processed_at = now(), note = 'duplicate delivery', error = null where id = p_inbox;
          return jsonb_build_object('duplicate', true, 'flight_id', null, 'events', '[]'::jsonb);
        end if;
      else
        v_events := v_events || jsonb_build_array(jsonb_build_object('id', v_id, 'kind', 'delay'));
        v_notified := v_delay;
      end if;
    end if;

    if v_changes <> '{}'::jsonb or v_notified is distinct from f.notified_delay_min then
      update public.flights set
        scheduled_out = m.scheduled_out, scheduled_in = m.scheduled_in,
        estimated_out = m.estimated_out, estimated_in = m.estimated_in,
        actual_out = m.actual_out, actual_off = m.actual_off, actual_on = m.actual_on, actual_in = m.actual_in,
        gate_origin = m.gate_origin, gate_destination = m.gate_destination,
        terminal_origin = m.terminal_origin, terminal_destination = m.terminal_destination,
        baggage_belt = m.baggage_belt,
        aircraft_type = m.aircraft_type, registration = m.registration,
        origin_icao = m.origin_icao, origin_iata = m.origin_iata,
        destination_icao = m.destination_icao, destination_iata = m.destination_iata,
        inbound_provider_id = m.inbound_provider_id,
        status = m.status, notified_delay_min = v_notified, updated_at = now()
      where id = f.id;
    end if;
    if v_primary is null and not v_want_delay then
      v_note := p_event_code || ' produced no event';
    end if;
  end if;

  perform public.increment_usage(p_day, 'alert_delivery', p_cost);
  -- Earlier attempts of this same body that failed are settled by this success.
  update public.webhook_inbox
    set processed_at = now(), note = 'superseded by a successful retry', error = null
    where body_sha256 = p_hash and processed_at is null and id <> p_inbox;
  update public.webhook_inbox
    set processed_at = now(), note = v_note, error = null where id = p_inbox;
  return jsonb_build_object('duplicate', false,
    'flight_id', case when v_followed then f.id end, 'events', v_events);
end;
$$;
