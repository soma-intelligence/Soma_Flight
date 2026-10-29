-- Follows are written by follow-flight and delete-account (service role) only. A direct client
-- insert would skip the free plan limit (try_follow) and the alert bookkeeping (ensureAlert), a
-- direct delete would skip releaseAlert, and a notify flip would bypass the function. Clients keep
-- select, scoped to their own rows by the owner policy.
revoke insert, update, delete on user_flights from anon, authenticated;
