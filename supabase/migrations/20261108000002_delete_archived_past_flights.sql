-- The traveller can delete any of their own past flights, archived ones too (2026-11-08). Insert and
-- update still refuse archived rows: an archived flight stays as the archive wrote it until it is deleted.
-- The hourly archive removes the followed flight when it archives it, so a deleted archived row does not
-- come back.
drop policy past_flights_delete_own on past_flights;
create policy past_flights_delete_own on past_flights for delete to authenticated
  using (auth.uid() = user_id);
