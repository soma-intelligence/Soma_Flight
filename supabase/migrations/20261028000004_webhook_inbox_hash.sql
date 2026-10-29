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

-- One transaction per accepted delivery: duplicate check, event claim, flights update, usage cost
-- and inbox marking commit together, so a crash anywhere leaves nothing half done and the
-- provider's retry is processed from scratch. The advisory lock serialises identical bodies.
-- p_update keys (all optional, null never overwrites): the flight columns below, status and
-- notified_delay_min. p_kind null = update the flight only. p_flight null = unmatched delivery.
-- Returns {"duplicate": bool, "event_id": uuid|null}.
create function public.process_alert(
  p_inbox bigint, p_hash text, p_flight uuid, p_kind text, p_payload jsonb,
  p_update jsonb, p_note text, p_day date, p_cost numeric
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_event uuid;
begin
  perform pg_advisory_xact_lock(hashtextextended('alert:' || p_hash, 0));
  if exists (
    select 1 from public.webhook_inbox
    where body_sha256 = p_hash and processed_at is not null and id <> p_inbox
  ) then
    update public.webhook_inbox
      set processed_at = now(), note = 'duplicate delivery', error = null where id = p_inbox;
    return jsonb_build_object('duplicate', true, 'event_id', null);
  end if;

  if p_flight is not null then
    if p_kind is not null then
      insert into public.flight_events (flight_id, provider_event_id, kind, payload)
      values (p_flight, p_hash, p_kind::public.flight_event_kind, p_payload)
      on conflict (provider_event_id) do nothing
      returning id into v_event;
      if v_event is null then
        update public.webhook_inbox
          set processed_at = now(), note = 'duplicate delivery', error = null where id = p_inbox;
        return jsonb_build_object('duplicate', true, 'event_id', null);
      end if;
    end if;
    if p_update is not null and p_update <> '{}'::jsonb then
      update public.flights f set
        scheduled_out = coalesce((p_update->>'scheduled_out')::timestamptz, f.scheduled_out),
        scheduled_in = coalesce((p_update->>'scheduled_in')::timestamptz, f.scheduled_in),
        estimated_out = coalesce((p_update->>'estimated_out')::timestamptz, f.estimated_out),
        estimated_in = coalesce((p_update->>'estimated_in')::timestamptz, f.estimated_in),
        actual_out = coalesce((p_update->>'actual_out')::timestamptz, f.actual_out),
        actual_off = coalesce((p_update->>'actual_off')::timestamptz, f.actual_off),
        actual_on = coalesce((p_update->>'actual_on')::timestamptz, f.actual_on),
        actual_in = coalesce((p_update->>'actual_in')::timestamptz, f.actual_in),
        gate_origin = coalesce(p_update->>'gate_origin', f.gate_origin),
        gate_destination = coalesce(p_update->>'gate_destination', f.gate_destination),
        terminal_origin = coalesce(p_update->>'terminal_origin', f.terminal_origin),
        terminal_destination = coalesce(p_update->>'terminal_destination', f.terminal_destination),
        baggage_belt = coalesce(p_update->>'baggage_belt', f.baggage_belt),
        aircraft_type = coalesce(p_update->>'aircraft_type', f.aircraft_type),
        registration = coalesce(p_update->>'registration', f.registration),
        origin_icao = coalesce(p_update->>'origin_icao', f.origin_icao),
        origin_iata = coalesce(p_update->>'origin_iata', f.origin_iata),
        destination_icao = coalesce(p_update->>'destination_icao', f.destination_icao),
        destination_iata = coalesce(p_update->>'destination_iata', f.destination_iata),
        status = coalesce((p_update->>'status')::public.flight_status, f.status),
        notified_delay_min = case when p_update ? 'notified_delay_min'
          then (p_update->>'notified_delay_min')::int else f.notified_delay_min end,
        updated_at = now()
      where f.id = p_flight;
    end if;
  end if;

  perform public.increment_usage(p_day, 'alert_delivery', p_cost);
  -- Earlier attempts of this same body that failed are settled by this success.
  update public.webhook_inbox
    set processed_at = now(), note = 'superseded by a successful retry', error = null
    where body_sha256 = p_hash and processed_at is null and id <> p_inbox;
  update public.webhook_inbox
    set processed_at = now(), note = p_note, error = null where id = p_inbox;
  return jsonb_build_object('duplicate', false, 'event_id', v_event);
end;
$$;

revoke execute on function public.process_alert(bigint, text, uuid, text, jsonb, jsonb, text, date, numeric)
  from public, anon, authenticated;
grant execute on function public.process_alert(bigint, text, uuid, text, jsonb, jsonb, text, date, numeric)
  to service_role;
