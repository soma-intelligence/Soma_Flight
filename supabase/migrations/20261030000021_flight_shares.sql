-- Live flight sharing: a link (https://somalabs.me/f/<token>) that shows one flight to anyone who has it,
-- without an account, until 24 hours after the flight arrives or until the sharer stops sharing.
--
-- share-flight (signed in) creates and revokes shares; flight-page (public) reads them by token. Both use
-- the service role. The token itself is never stored: only its SHA-256 (hex), so a read of this table does
-- not hand out working links. A share belongs to one flight and one sharer, and the page it opens shows
-- flight data only (never the sharer's seat, booking code or notes, which live on user_flights).
--
-- Expiry is not stored: it follows the flight's latest arrival time (a delay keeps the link alive longer),
-- computed by both functions from the flights row (_shared/share.ts, shareExpiresAt). Revoking sets
-- revoked_at; the row stays so the page can answer "no longer shared" and the sharer's history is honest.
create table flight_shares (
  id          uuid primary key default gen_random_uuid(),
  token_hash  text not null unique check (token_hash ~ '^[0-9a-f]{64}$'),
  flight_id   uuid not null references flights (id) on delete cascade,
  user_id     uuid not null references auth.users (id) on delete cascade,
  created_at  timestamptz not null default now(),
  revoked_at  timestamptz,
  check (revoked_at is null or revoked_at >= created_at)
);
-- The sharer's live shares of a flight: what "Stop Sharing" revokes and the sheet asks about.
create index flight_shares_live_idx on flight_shares (user_id, flight_id) where revoked_at is null;
create index flight_shares_flight_id_idx on flight_shares (flight_id);

alter table flight_shares enable row level security;
-- Sharers may read their own shares (not the hashes); every write goes through share-flight.
create policy flight_shares_owner_read on flight_shares for select to authenticated
  using (auth.uid() = user_id);
revoke all on flight_shares from anon, authenticated;
grant select (id, flight_id, user_id, created_at, revoked_at) on flight_shares to authenticated;

-- Shares of flights long gone are worth nothing: a month after the flight's last known time (or after
-- revocation) the row goes. Generous on purpose: the functions decide expiry, this only cleans up.
select cron.schedule('flight-shares-prune', '35 4 * * *', $$
  delete from public.flight_shares s
  using public.flights f
  where f.id = s.flight_id
    and (s.revoked_at < now() - interval '30 days'
      or coalesce(f.actual_in, f.actual_on, f.estimated_in, f.scheduled_in, f.estimated_out, f.scheduled_out,
                  s.created_at) < now() - interval '30 days');
$$);
