-- Gate history, for the flight sheet's gate prediction (core/flightcore/src/predict.rs): the departure
-- gate each flight number used on each local day at its origin. Nothing is fetched for it: a trigger on
-- flights keeps it, so every path that already stores a gate feeds it unchanged (process_alert's merge
-- of a webhook delivery, upsert_provider_flights after a lookup). The app reads it through
-- gate_history(); the table itself is service role only.
--
-- flight_gate_days  one row per flight number, origin and local day: the last gate seen that day (a
--                   gate change replaces it, since the plane left from the new one). Rows older than
--                   30 days are pruned daily.
-- gate_history()    the flight number's days before a given day, and the airline's departures there
--                   by gate over the last two weeks.

create table public.flight_gate_days (
  ident       text not null,
  origin_icao text not null,
  -- Local day of the scheduled departure at the origin (UTC when the airport's zone is unknown).
  day         date not null,
  operator    text,
  gate        text not null check (length(gate) between 1 and 12),
  terminal    text check (terminal is null or length(terminal) between 1 and 40),
  updated_at  timestamptz not null default now(),
  primary key (ident, origin_icao, day)
);
create index flight_gate_days_airline_idx on public.flight_gate_days (origin_icao, operator, day);
alter table public.flight_gate_days enable row level security;
-- No policy and no client grants: service role only. Reassert in case default privileges change.
revoke all on public.flight_gate_days from anon, authenticated;

-- Records the departure gate of a flights row. Canceled flights left from no gate and are skipped. A
-- failure here only logs a warning: a gate history row is never worth losing the flight write it rides
-- on (process_alert, upsert_provider_flights).
create function public.record_gate_day() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_tz text;
  v_gate text := nullif(btrim(new.gate_origin), '');
  v_terminal text := nullif(btrim(new.terminal_origin), '');
begin
  if v_gate is null or new.origin_icao is null or new.scheduled_out is null
     or new.status = 'canceled' then
    return new;
  end if;
  if tg_op = 'UPDATE'
     and (new.gate_origin, new.terminal_origin, new.scheduled_out, new.ident, new.origin_icao, new.status)
       is not distinct from (old.gate_origin, old.terminal_origin, old.scheduled_out, old.ident, old.origin_icao, old.status) then
    return new;
  end if;
  begin
    select a.tz into v_tz from public.airports a where a.icao = new.origin_icao;
    insert into public.flight_gate_days (ident, origin_icao, day, operator, gate, terminal)
    values (new.ident, new.origin_icao,
            (new.scheduled_out at time zone coalesce(v_tz, 'UTC'))::date,
            new.operator, left(v_gate, 12), left(v_terminal, 40))
    on conflict (ident, origin_icao, day) do update set
      gate = excluded.gate,
      terminal = excluded.terminal,
      operator = coalesce(excluded.operator, public.flight_gate_days.operator),
      updated_at = now();
  exception when others then
    raise warning 'record_gate_day % %: %', new.ident, new.origin_icao, sqlerrm;
  end;
  return new;
end;
$$;
revoke execute on function public.record_gate_day() from public, anon, authenticated;

create trigger flights_record_gate_day
  after insert or update of gate_origin, terminal_origin, scheduled_out, status on public.flights
  for each row execute function public.record_gate_day();

-- What the gate prediction reads, as one JSON object:
--   days     the flight number's days at p_origin in the p_days (1 to 30) days before p_day, newest
--            first: [{ "day": "2026-10-29", "gate": "B22", "terminal": "2" }]
--   airline  p_operator's departures at p_origin in the 14 days before p_day, by gate, busiest first,
--            at most 100 gates: [{ "gate": "B22", "terminal": "2", "flights": 9 }]; empty without
--            an operator.
-- Gates are public information (airport screens show them), so any signed-in user may ask.
create function public.gate_history(
  p_ident text, p_origin text, p_operator text, p_day date, p_days int default 7
) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'days', coalesce((
      select jsonb_agg(jsonb_build_object('day', d.day, 'gate', d.gate, 'terminal', d.terminal)
                       order by d.day desc)
      from public.flight_gate_days d
      where d.ident = p_ident and d.origin_icao = p_origin
        and d.day < p_day and d.day >= p_day - least(greatest(coalesce(p_days, 7), 1), 30)
    ), '[]'::jsonb),
    'airline', coalesce((
      select jsonb_agg(jsonb_build_object('gate', a.gate, 'terminal', a.terminal, 'flights', a.flights)
                       order by a.flights desc, a.gate)
      from (
        select d.gate, d.terminal, count(*)::int as flights
        from public.flight_gate_days d
        where p_operator is not null and d.operator = p_operator and d.origin_icao = p_origin
          and d.day < p_day and d.day >= p_day - 14
        group by d.gate, d.terminal
        order by count(*) desc, d.gate
        limit 100
      ) a
    ), '[]'::jsonb));
$$;
revoke execute on function public.gate_history(text, text, text, date, int) from public, anon;
grant execute on function public.gate_history(text, text, text, date, int) to authenticated;

-- A month is plenty: the prediction reads two weeks at most. cron.schedule upserts by name.
select cron.schedule('gate-history-prune', '40 3 * * *', $$
  delete from public.flight_gate_days where day < current_date - 30;
$$);
