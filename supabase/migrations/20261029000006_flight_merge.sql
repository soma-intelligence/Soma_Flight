-- One set of rules for every writer of a flights row from the provider: the webhook (process_alert)
-- and the lookups (flight-lookup through upsert_provider_flights). Before this, a lookup upserted the
-- provider's /flights snapshot over the row the webhook maintains, so a snapshot that lagged an alert
-- moved status and times backwards for every follower.
--
-- merge_flight(f, p_fields, p_event_code): the row f with p_fields applied under these rules.
--   scheduled_*: the new value when given, else kept.
--   actual_*: set once, never replaced.
--   estimated_*: ignored once the matching actual exists, else the new value when given.
--   text fields (gates, terminals, belt, aircraft, registration, airports, operator): the new value
--     when given and not empty, else kept.
--   status: canceled, diverted and arrived are sticky. Otherwise a cancel (event 'cancelled', field
--     cancelled = true or status 'canceled') or a diversion (same with diverted) wins; else the status
--     only rises along scheduled < departed < en_route < landed < arrived, taking the highest of the
--     current one, the one the actual times prove, and p_fields->>'status' (a lookup's own status).
--   Anything else (ident, position, alert_id, notified_delay_min, updated_at) is kept.
create function public.merge_flight(f public.flights, p_fields jsonb, p_event_code text default null)
returns public.flights
language plpgsql immutable set search_path = '' as $$
declare
  m public.flights := f;
  v_rank text[] := array['scheduled', 'departed', 'en_route', 'landed', 'arrived'];
  v_hint text := p_fields->>'status';
  v_probe text;
  v_best int;
begin
  m.scheduled_out := coalesce((p_fields->>'scheduled_out')::timestamptz, f.scheduled_out);
  m.scheduled_in := coalesce((p_fields->>'scheduled_in')::timestamptz, f.scheduled_in);
  m.actual_out := coalesce(f.actual_out, (p_fields->>'actual_out')::timestamptz);
  m.actual_off := coalesce(f.actual_off, (p_fields->>'actual_off')::timestamptz);
  m.actual_on := coalesce(f.actual_on, (p_fields->>'actual_on')::timestamptz);
  m.actual_in := coalesce(f.actual_in, (p_fields->>'actual_in')::timestamptz);
  m.estimated_out := case when m.actual_out is not null then f.estimated_out
    else coalesce((p_fields->>'estimated_out')::timestamptz, f.estimated_out) end;
  m.estimated_in := case when m.actual_in is not null then f.estimated_in
    else coalesce((p_fields->>'estimated_in')::timestamptz, f.estimated_in) end;
  m.gate_origin := coalesce(nullif(p_fields->>'gate_origin', ''), f.gate_origin);
  m.gate_destination := coalesce(nullif(p_fields->>'gate_destination', ''), f.gate_destination);
  m.terminal_origin := coalesce(nullif(p_fields->>'terminal_origin', ''), f.terminal_origin);
  m.terminal_destination := coalesce(nullif(p_fields->>'terminal_destination', ''), f.terminal_destination);
  m.baggage_belt := coalesce(nullif(p_fields->>'baggage_belt', ''), f.baggage_belt);
  m.aircraft_type := coalesce(nullif(p_fields->>'aircraft_type', ''), f.aircraft_type);
  m.registration := coalesce(nullif(p_fields->>'registration', ''), f.registration);
  m.operator := coalesce(nullif(p_fields->>'operator', ''), f.operator);
  m.origin_icao := coalesce(nullif(p_fields->>'origin_icao', ''), f.origin_icao);
  m.origin_iata := coalesce(nullif(p_fields->>'origin_iata', ''), f.origin_iata);
  m.destination_icao := coalesce(nullif(p_fields->>'destination_icao', ''), f.destination_icao);
  m.destination_iata := coalesce(nullif(p_fields->>'destination_iata', ''), f.destination_iata);

  if f.status in ('canceled', 'diverted', 'arrived') then
    m.status := f.status;
  elsif p_event_code = 'cancelled' or (p_fields->>'cancelled') = 'true' or v_hint = 'canceled' then
    m.status := 'canceled';
  elsif p_event_code = 'diverted' or (p_fields->>'diverted') = 'true' or v_hint = 'diverted' then
    m.status := 'diverted';
  else
    v_probe := case
      when m.actual_in is not null then 'arrived'
      when m.actual_on is not null then 'landed'
      when m.actual_off is not null then 'en_route'
      when m.actual_out is not null then 'departed'
      else null end;
    v_best := greatest(
      coalesce(array_position(v_rank, f.status::text), 0),
      coalesce(array_position(v_rank, v_probe), 0),
      coalesce(array_position(v_rank, v_hint), 0));
    if v_best > 0 then
      m.status := v_rank[v_best]::public.flight_status;
    end if;
  end if;
  return m;
end;
$$;

-- Lookup writes. p_rows: a json array of flight-lookup rows (FlightRow: provider_id, ident, operator,
-- airports, schedule, estimates, actuals, gates, terminals, baggage_belt, aircraft_type,
-- registration, status). A new provider_id is inserted as given. A known one is locked and merged
-- with merge_flight (no event code), so the webhook's monotonic fields never move backwards; it is
-- written only when something changed (updated_at moves then). Returns the stored rows.
create function public.upsert_provider_flights(p_rows jsonb)
returns setof public.flights
language plpgsql security definer set search_path = '' as $$
declare
  r jsonb;
  f public.flights;
  m public.flights;
begin
  for r in select value from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    select * into f from public.flights where provider_id = r->>'provider_id' for update;
    if not found then
      insert into public.flights (
        provider_id, ident, operator, origin_icao, origin_iata, destination_icao, destination_iata,
        scheduled_out, scheduled_in, estimated_out, estimated_in,
        actual_out, actual_off, actual_on, actual_in,
        gate_origin, gate_destination, terminal_origin, terminal_destination, baggage_belt,
        aircraft_type, registration, status)
      select x.provider_id, x.ident, x.operator, x.origin_icao, x.origin_iata, x.destination_icao,
        x.destination_iata, x.scheduled_out, x.scheduled_in, x.estimated_out, x.estimated_in,
        x.actual_out, x.actual_off, x.actual_on, x.actual_in,
        x.gate_origin, x.gate_destination, x.terminal_origin, x.terminal_destination, x.baggage_belt,
        x.aircraft_type, x.registration, coalesce(x.status, 'unknown')
      from jsonb_populate_record(null::public.flights, r) x
      on conflict (provider_id) do nothing
      returning * into f;
      if f.id is not null then
        return next f;
        continue;
      end if;
      -- Inserted meanwhile by someone else: merge into theirs.
      select * into f from public.flights where provider_id = r->>'provider_id' for update;
    end if;
    m := public.merge_flight(f, r, null);
    if m is distinct from f then
      m.updated_at := now();
      update public.flights set
        operator = m.operator,
        origin_icao = m.origin_icao, origin_iata = m.origin_iata,
        destination_icao = m.destination_icao, destination_iata = m.destination_iata,
        scheduled_out = m.scheduled_out, scheduled_in = m.scheduled_in,
        estimated_out = m.estimated_out, estimated_in = m.estimated_in,
        actual_out = m.actual_out, actual_off = m.actual_off, actual_on = m.actual_on, actual_in = m.actual_in,
        gate_origin = m.gate_origin, gate_destination = m.gate_destination,
        terminal_origin = m.terminal_origin, terminal_destination = m.terminal_destination,
        baggage_belt = m.baggage_belt, aircraft_type = m.aircraft_type, registration = m.registration,
        status = m.status, updated_at = m.updated_at
      where id = f.id
      returning * into m;
      return next m;
    else
      return next f;
    end if;
  end loop;
end;
$$;

-- process_alert, same contract as 20261028000004, now built on merge_flight, and with the flat
-- payload keys the app reads (docs/api-contract.md, "Flight event payload"):
--   gate        new departure gate, when this delivery changed it
--   minutes     delay in minutes against schedule (delay events), same value as delay_minutes
--   destination destination ICAO after this delivery, on a diversion or when it changed
-- Keys are single words so the app's snake_case key conversion leaves them as they are.
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

revoke execute on function
  public.merge_flight(public.flights, jsonb, text),
  public.upsert_provider_flights(jsonb)
from public, anon, authenticated;
grant execute on function
  public.merge_flight(public.flights, jsonb, text),
  public.upsert_provider_flights(jsonb)
to service_role;
