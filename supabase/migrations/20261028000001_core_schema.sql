-- Soma Flight core schema. Shared flight data is written by the service role only;
-- user data is owner-only through RLS.

create type flight_status as enum
  ('scheduled', 'departed', 'en_route', 'landed', 'arrived', 'canceled', 'diverted', 'unknown');
create type flight_event_kind as enum
  ('gate_change', 'delay', 'departure', 'arrival', 'cancel', 'diversion', 'position');
create type snapshot_kind as enum ('departures', 'arrivals', 'stats', 'weather');
create type push_token_kind as enum ('alert', 'live_activity');
create type plan as enum ('free', 'pro');
create type account_status as enum ('active', 'deleted');

create table airports (
  icao    text primary key,
  iata    text unique,
  name    text not null,
  city    text,
  country text,
  lat     float8 not null,
  lon     float8 not null,
  tz      text
);

create table flights (
  id                       uuid primary key default gen_random_uuid(),
  provider_id              text unique not null,
  ident                    text not null,
  operator                 text,
  origin_icao              text,
  origin_iata              text,
  destination_icao         text,
  destination_iata         text,
  scheduled_out            timestamptz,
  scheduled_in             timestamptz,
  estimated_out            timestamptz,
  estimated_in             timestamptz,
  actual_out               timestamptz,
  actual_off               timestamptz,
  actual_on                timestamptz,
  actual_in                timestamptz,
  gate_origin              text,
  gate_destination         text,
  terminal_origin          text,
  terminal_destination     text,
  baggage_belt             text,
  aircraft_type            text,
  registration             text,
  status                   flight_status not null default 'unknown',
  position_lat             float8,
  position_lon             float8,
  position_altitude_ft     int,
  position_ground_speed_kt int,
  position_heading         int,
  position_at              timestamptz,
  alert_id                 bigint,
  updated_at               timestamptz not null default now()
);
create index flights_ident_scheduled_out_idx on flights (ident, scheduled_out);

create table flight_events (
  id                uuid primary key default gen_random_uuid(),
  flight_id         uuid not null references flights (id) on delete cascade,
  provider_event_id text unique,
  kind              flight_event_kind not null,
  payload           jsonb not null default '{}'::jsonb,
  received_at       timestamptz not null default now()
);
create index flight_events_flight_id_received_at_idx on flight_events (flight_id, received_at);

create table webhook_inbox (
  id           bigserial primary key,
  body         jsonb not null,
  received_at  timestamptz not null default now(),
  processed_at timestamptz,
  error        text
);

create table user_flights (
  user_id    uuid not null references auth.users (id) on delete cascade,
  flight_id  uuid not null references flights (id) on delete cascade,
  created_at timestamptz not null default now(),
  notify     boolean not null default true,
  primary key (user_id, flight_id)
);
create index user_flights_flight_id_idx on user_flights (flight_id);

create table past_flights (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references auth.users (id) on delete cascade,
  flight_id        uuid references flights (id) on delete set null,
  date             date not null,
  ident            text,
  origin_icao      text,
  destination_icao text,
  airline          text,
  aircraft_type    text,
  registration     text,
  seat             text,
  distance_km      int,
  block_minutes    int,
  delay_minutes    int,
  created_at       timestamptz not null default now()
);
create index past_flights_user_id_date_idx on past_flights (user_id, date desc);

create table airport_snapshots (
  icao           text not null,
  kind           snapshot_kind not null,
  payload        jsonb not null default '{}'::jsonb,
  fetched_at     timestamptz not null default now(),
  last_viewed_at timestamptz,
  primary key (icao, kind)
);

create table push_tokens (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users (id) on delete cascade,
  token      text not null,
  kind       push_token_kind not null,
  flight_id  uuid references flights (id) on delete cascade,
  platform   text not null default 'ios',
  updated_at timestamptz not null default now(),
  unique (token, kind)
);
create index push_tokens_user_id_idx on push_tokens (user_id);

create table usage_counters (
  day            date not null,
  endpoint       text not null,
  calls          int not null default 0,
  estimated_cost numeric(10,4) not null default 0,
  primary key (day, endpoint)
);

create table rate_events (
  id       bigserial primary key,
  user_id  uuid,
  endpoint text not null,
  at       timestamptz not null default now()
);
create index rate_events_user_endpoint_at_idx on rate_events (user_id, endpoint, at);

-- No FK to auth.users: the row survives auth user deletion (status = deleted).
create table profiles (
  user_id      uuid primary key,
  display_name text,
  units        text not null default 'metric',
  plan         plan not null default 'free',
  created_at   timestamptz not null default now(),
  status       account_status not null default 'active'
);

create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (user_id) values (new.id) on conflict do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- RLS everywhere; default-deny without a policy.
alter table airports          enable row level security;
alter table flights           enable row level security;
alter table flight_events     enable row level security;
alter table webhook_inbox     enable row level security;
alter table user_flights      enable row level security;
alter table past_flights      enable row level security;
alter table airport_snapshots enable row level security;
alter table push_tokens       enable row level security;
alter table usage_counters    enable row level security;
alter table rate_events       enable row level security;
alter table profiles          enable row level security;

-- Shared, read-only for signed-in users.
create policy airports_read          on airports          for select to authenticated using (true);
create policy flights_read           on flights           for select to authenticated using (true);
create policy flight_events_read     on flight_events     for select to authenticated using (true);
create policy airport_snapshots_read on airport_snapshots for select to authenticated using (true);

-- Owner only.
create policy user_flights_owner on user_flights for all to authenticated
  using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy past_flights_owner on past_flights for all to authenticated
  using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy push_tokens_owner on push_tokens for all to authenticated
  using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy profiles_read_own on profiles for select to authenticated
  using (auth.uid() = user_id);
create policy profiles_update_own on profiles for update to authenticated
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Grants: strip the defaults, then give back only what clients need.
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;

grant select on airports, flights, flight_events, airport_snapshots to authenticated;
grant select, insert, update, delete on user_flights, past_flights, push_tokens to authenticated;
grant select on profiles to authenticated;
grant update (display_name, units) on profiles to authenticated;
-- webhook_inbox, usage_counters, rate_events: service role only (no client grants).

-- Realtime: clients subscribe to flight changes.
alter publication supabase_realtime add table flights;
