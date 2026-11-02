-- flight-schedules reads at most a few pages of a day's schedule. truncated is true when the provider
-- still had pages after them (a busy airport's whole day), so a cached answer says so as the first did.
-- A time of day narrows a search to hours around it and is its own key: "KSFO-*-*-*-2026-11-20-t1140".
alter table schedules_cache add column truncated boolean not null default false;
