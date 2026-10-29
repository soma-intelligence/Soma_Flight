-- aeroapi-webhook: hex sha256 of the raw body, so a replayed delivery is recognised on every path
-- (including deliveries that produce no flight_events row) and billed once.
alter table webhook_inbox add column body_sha256 text;
create index webhook_inbox_body_sha256_idx on webhook_inbox (body_sha256);
