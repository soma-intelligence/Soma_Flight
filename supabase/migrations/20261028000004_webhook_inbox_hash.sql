-- aeroapi-webhook support.
--
-- webhook_inbox.body_sha256: hex sha256 of the raw body, so a replayed delivery is recognised on
-- every path and billed once. webhook_inbox.note: non-failure remarks (duplicate, not followed...).
-- Replay rule: a row needs replay only when error is not null and processed_at is null. Rows that
-- cannot succeed on replay (malformed body, wrong shape) carry an error AND processed_at.
alter table webhook_inbox add column body_sha256 text;
alter table webhook_inbox add column note text;
create index webhook_inbox_body_sha256_idx on webhook_inbox (body_sha256)
  where processed_at is not null;

-- Last delay (minutes, against schedule) a delay event was emitted for. Null = none yet.
alter table flights add column notified_delay_min int;

-- One transaction per accepted delivery. The flight row is locked (after an advisory lock on the
-- body hash) and every decision is made against the locked row, so concurrent deliveries for one
-- flight serialise: an actual time is set once, an estimate is ignored once its actual exists,
-- status only rises (canceled, diverted and arrived are sticky), and the delay event is decided from
-- the locked notified_delay_min. Duplicate check, events, flights update, usage cost and inbox mark
-- commit together, so a crash leaves nothing half done and the provider's retry is processed.
--
-- p_fields: normalized delivery fields, all optional, null/empty never overwrites: scheduled_*,
-- estimated_*, actual_* (out/off/on/in, ISO strings), gate_origin, gate_destination,
-- terminal_origin, terminal_destination, baggage_belt, aircraft_type, registration, origin_icao,
-- origin_iata, destination_icao, destination_iata, cancelled (bool), diverted (bool).
-- p_texts: {short_description, summary}.
-- Events: one primary (cancel, diversion, departure, arrival or gate_change; id = hash) and a delay
-- (id = hash, or hash || ':delay' next to a primary). cancel, diversion, departure and arrival are
-- emitted once per flight. Delay: first at p_delay_step minutes, then whenever it moves that far
-- from notified_delay_min (either direction); only for change, filed, minutes_out, out, off, on, in.
-- Returns {"duplicate": bool, "flight_id": uuid|null, "events": [{"id", "kind"}]}.
create function public.process_alert(
  p_inbox bigint, p_hash text, p_fa_flight_id text, p_event_code text, p_alert_id bigint,
  p_texts jsonb, p_fields jsonb, p_day date, p_cost numeric, p_delay_step int default 15
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  f public.flights%rowtype;
  v_events jsonb := '[]'::jsonb;
  v_note text;
  v_diff boolean := p_event_code in ('change','filed','minutes_out','out','off','on','in');
  v_followed boolean;
  n_sched_out timestamptz; n_sched_in timestamptz; n_est_out timestamptz; n_est_in timestamptz;
  n_act_out timestamptz; n_act_off timestamptz; n_act_on timestamptz; n_act_in timestamptz;
  n_gate_o text; n_gate_d text; n_term_o text; n_term_d text; n_belt text;
  n_ac text; n_reg text; n_o_icao text; n_o_iata text; n_d_icao text; n_d_iata text;
  n_status public.flight_status;
  v_sticky boolean; v_probe public.flight_status; v_status_to public.flight_status;
  v_place boolean; v_delay int; v_d_out int; v_d_in int; v_last int;
  v_primary public.flight_event_kind; v_want_delay boolean := false;
  v_changes jsonb; v_payload jsonb; v_id uuid; v_eid text;
  v_notified int;
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
    n_sched_out := coalesce((p_fields->>'scheduled_out')::timestamptz, f.scheduled_out);
    n_sched_in := coalesce((p_fields->>'scheduled_in')::timestamptz, f.scheduled_in);
    n_act_out := coalesce(f.actual_out, (p_fields->>'actual_out')::timestamptz);
    n_act_off := coalesce(f.actual_off, (p_fields->>'actual_off')::timestamptz);
    n_act_on := coalesce(f.actual_on, (p_fields->>'actual_on')::timestamptz);
    n_act_in := coalesce(f.actual_in, (p_fields->>'actual_in')::timestamptz);
    n_est_out := case when n_act_out is not null then f.estimated_out
      else coalesce((p_fields->>'estimated_out')::timestamptz, f.estimated_out) end;
    n_est_in := case when n_act_in is not null then f.estimated_in
      else coalesce((p_fields->>'estimated_in')::timestamptz, f.estimated_in) end;
    n_gate_o := coalesce(nullif(p_fields->>'gate_origin', ''), f.gate_origin);
    n_gate_d := coalesce(nullif(p_fields->>'gate_destination', ''), f.gate_destination);
    n_term_o := coalesce(nullif(p_fields->>'terminal_origin', ''), f.terminal_origin);
    n_term_d := coalesce(nullif(p_fields->>'terminal_destination', ''), f.terminal_destination);
    n_belt := coalesce(nullif(p_fields->>'baggage_belt', ''), f.baggage_belt);
    n_ac := coalesce(nullif(p_fields->>'aircraft_type', ''), f.aircraft_type);
    n_reg := coalesce(nullif(p_fields->>'registration', ''), f.registration);
    n_o_icao := coalesce(nullif(p_fields->>'origin_icao', ''), f.origin_icao);
    n_o_iata := coalesce(nullif(p_fields->>'origin_iata', ''), f.origin_iata);
    n_d_icao := coalesce(nullif(p_fields->>'destination_icao', ''), f.destination_icao);
    n_d_iata := coalesce(nullif(p_fields->>'destination_iata', ''), f.destination_iata);
    v_place := (n_gate_o, n_gate_d, n_term_o, n_term_d, n_belt)
      is distinct from (f.gate_origin, f.gate_destination, f.terminal_origin, f.terminal_destination, f.baggage_belt);

    -- Status: sticky states never change; cancel/divert win; otherwise only upward.
    v_sticky := f.status in ('canceled', 'diverted', 'arrived');
    n_status := f.status;
    v_status_to := null;
    if not v_sticky then
      if p_event_code = 'cancelled' or (p_fields->>'cancelled') = 'true' then
        v_status_to := 'canceled';
      elsif p_event_code = 'diverted' or (p_fields->>'diverted') = 'true' then
        v_status_to := 'diverted';
      end if;
      if v_status_to is not null then
        n_status := v_status_to;
      else
        v_probe := case
          when n_act_in is not null then 'arrived'
          when n_act_on is not null then 'landed'
          when n_act_off is not null then 'en_route'
          when n_act_out is not null then 'departed'
          else null end;
        if v_probe is not null and
           array_position(array['scheduled','departed','en_route','landed','arrived'], v_probe::text)
           > coalesce(array_position(array['scheduled','departed','en_route','landed','arrived'], f.status::text), 0)
        then
          n_status := v_probe;
        end if;
      end if;
    end if;

    -- Delay against schedule: worst of out and in, actual if known else estimate.
    v_d_out := round(extract(epoch from (coalesce(n_act_out, n_est_out) - n_sched_out)) / 60);
    v_d_in := round(extract(epoch from (coalesce(n_act_in, n_est_in) - n_sched_in)) / 60);
    v_delay := greatest(v_d_out, v_d_in);
    v_last := f.notified_delay_min;
    if v_diff and v_delay is not null and n_status not in ('canceled', 'diverted', 'arrived') then
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

    -- Keep explicit nulls inside each entry ({"from": null, "to": ...}); drop only unchanged fields.
    v_changes := coalesce((select jsonb_object_agg(t.k, t.v) from (values
      ('scheduled_out', case when n_sched_out is distinct from f.scheduled_out then jsonb_build_object('from', f.scheduled_out, 'to', n_sched_out) end),
      ('scheduled_in', case when n_sched_in is distinct from f.scheduled_in then jsonb_build_object('from', f.scheduled_in, 'to', n_sched_in) end),
      ('estimated_out', case when n_est_out is distinct from f.estimated_out then jsonb_build_object('from', f.estimated_out, 'to', n_est_out) end),
      ('estimated_in', case when n_est_in is distinct from f.estimated_in then jsonb_build_object('from', f.estimated_in, 'to', n_est_in) end),
      ('actual_out', case when n_act_out is distinct from f.actual_out then jsonb_build_object('from', f.actual_out, 'to', n_act_out) end),
      ('actual_off', case when n_act_off is distinct from f.actual_off then jsonb_build_object('from', f.actual_off, 'to', n_act_off) end),
      ('actual_on', case when n_act_on is distinct from f.actual_on then jsonb_build_object('from', f.actual_on, 'to', n_act_on) end),
      ('actual_in', case when n_act_in is distinct from f.actual_in then jsonb_build_object('from', f.actual_in, 'to', n_act_in) end),
      ('gate_origin', case when n_gate_o is distinct from f.gate_origin then jsonb_build_object('from', f.gate_origin, 'to', n_gate_o) end),
      ('gate_destination', case when n_gate_d is distinct from f.gate_destination then jsonb_build_object('from', f.gate_destination, 'to', n_gate_d) end),
      ('terminal_origin', case when n_term_o is distinct from f.terminal_origin then jsonb_build_object('from', f.terminal_origin, 'to', n_term_o) end),
      ('terminal_destination', case when n_term_d is distinct from f.terminal_destination then jsonb_build_object('from', f.terminal_destination, 'to', n_term_d) end),
      ('baggage_belt', case when n_belt is distinct from f.baggage_belt then jsonb_build_object('from', f.baggage_belt, 'to', n_belt) end),
      ('aircraft_type', case when n_ac is distinct from f.aircraft_type then jsonb_build_object('from', f.aircraft_type, 'to', n_ac) end),
      ('registration', case when n_reg is distinct from f.registration then jsonb_build_object('from', f.registration, 'to', n_reg) end),
      ('origin_icao', case when n_o_icao is distinct from f.origin_icao then jsonb_build_object('from', f.origin_icao, 'to', n_o_icao) end),
      ('origin_iata', case when n_o_iata is distinct from f.origin_iata then jsonb_build_object('from', f.origin_iata, 'to', n_o_iata) end),
      ('destination_icao', case when n_d_icao is distinct from f.destination_icao then jsonb_build_object('from', f.destination_icao, 'to', n_d_icao) end),
      ('destination_iata', case when n_d_iata is distinct from f.destination_iata then jsonb_build_object('from', f.destination_iata, 'to', n_d_iata) end),
      ('status', case when n_status is distinct from f.status then jsonb_build_object('from', f.status, 'to', n_status) end)
    ) as t(k, v) where t.v is not null), '{}'::jsonb);
    v_payload := jsonb_build_object(
      'event_code', p_event_code, 'alert_id', p_alert_id,
      'short_description', p_texts->'short_description', 'summary', p_texts->'summary',
      'changes', v_changes);

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
        'delay_minutes', v_delay, 'previous_delay_minutes', v_last))
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
        scheduled_out = n_sched_out, scheduled_in = n_sched_in,
        estimated_out = n_est_out, estimated_in = n_est_in,
        actual_out = n_act_out, actual_off = n_act_off, actual_on = n_act_on, actual_in = n_act_in,
        gate_origin = n_gate_o, gate_destination = n_gate_d,
        terminal_origin = n_term_o, terminal_destination = n_term_d, baggage_belt = n_belt,
        aircraft_type = n_ac, registration = n_reg,
        origin_icao = n_o_icao, origin_iata = n_o_iata,
        destination_icao = n_d_icao, destination_iata = n_d_iata,
        status = n_status, notified_delay_min = v_notified, updated_at = now()
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

revoke execute on function public.process_alert(bigint, text, text, text, bigint, jsonb, jsonb, date, numeric, int)
  from public, anon, authenticated;
grant execute on function public.process_alert(bigint, text, text, text, bigint, jsonb, jsonb, date, numeric, int)
  to service_role;
