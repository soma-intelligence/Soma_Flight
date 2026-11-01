-- Signed arrival and departure delays on past flights, for the Delay Report (Passport). Until now a row
-- carried delay_minutes alone, 0 when the arrival time was unknown, so "on time" and "no data" looked the
-- same and no departure delay was kept.
--
-- arrival_delay_minutes: actual minus scheduled arrival in minutes, negative when early; gate times when
-- both are known, else runway times. Null when the actual arrival is unknown.
-- departure_delay_minutes: the same for the departure. Null when unknown.
--
-- Both are nullable and unchecked beyond a two day bound; the table grant already lets clients write
-- their own manual and imported rows. archive_landed_flights does not fill them yet: archived rows keep
-- delay_minutes, which the app reads as before (follow-up: fill both from flights.actual_* there).

alter table past_flights
  add column arrival_delay_minutes int,
  add column departure_delay_minutes int,
  add constraint past_flights_delay_bounds_check check (
    (arrival_delay_minutes is null or arrival_delay_minutes between -2880 and 2880)
    and (departure_delay_minutes is null or departure_delay_minutes between -2880 and 2880));
