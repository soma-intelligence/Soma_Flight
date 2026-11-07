-- Cache for flight-brief, the language-model texts (door to door, why it is late, airport summary).
-- Switched off until the owner says yes on cost (LLM_ENABLED on the function).
--
-- One row per subject (a flight id, or an airport code), kind and facts hash: the hash is of the exact
-- facts the text was written from, so identical facts never pay twice and changed facts write a new
-- row. The text holds no personal data: the facts are typed values with no name, document or booking
-- field (supabase/functions/flight-brief/facts.ts). Service role only.
create table llm_brief_cache (
  subject    text not null check (subject ~ '^[A-Za-z0-9-]{3,40}$'),
  kind       text not null check (kind in ('door_to_door', 'delay_cause', 'airport_summary')),
  facts_hash text not null check (facts_hash ~ '^[0-9a-f]{64}$'),
  text       text not null check (char_length(text) between 20 and 600),
  facts_used text[] not null,
  created_at timestamptz not null default now(),
  primary key (subject, kind, facts_hash)
);
alter table llm_brief_cache enable row level security;
-- No policy and no client grants. Reassert in case default privileges change.
revoke all on llm_brief_cache from anon, authenticated;

-- A text older than a day is worth nothing: the app asks again with fresher facts. cron.schedule
-- upserts by name.
select cron.schedule('llm-brief-cache-prune', '55 3 * * *', $$
  delete from public.llm_brief_cache where created_at < now() - interval '1 day';
$$);
