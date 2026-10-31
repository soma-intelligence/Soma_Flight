-- Alerts by text message (iMessage or SMS through the Soma Linq line): the table only. OFF.
--
-- Nothing reads this table to send yet: push-sender's hook (_shared/sms_alerts.ts) returns before any read
-- while the SMS_ALERTS_ENABLED secret is unset and no sender is wired, which is how this ships. Turning texts
-- on is the owner's call (docs/sms-alerts.md): a Linq sender, an sms-verify function, the privacy label.
--
-- One row per account. A number is pending until the traveller types back the six digit code sent to it:
-- the code is stored only as a SHA-256 of the number, the code and a server secret (code_hash), for ten
-- minutes and five tries. Texts go only to a row that is verified, switched on and not stopped: a STOP
-- reply sets opted_out_at and switches it off, and only a new verification turns it back on. Deleting the
-- account deletes the row (on delete cascade).
create table sms_alerts (
  user_id          uuid primary key references auth.users (id) on delete cascade,
  phone_e164       text check (phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  code_hash        text check (code_hash ~ '^[0-9a-f]{64}$'),
  code_expires_at  timestamptz,
  attempts         int not null default 0 check (attempts between 0 and 10),
  verified_at      timestamptz,
  enabled          boolean not null default false,
  opted_out_at     timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  -- A pending code has both its hash and its expiry, or neither.
  check ((code_hash is null) = (code_expires_at is null)),
  -- Texts go only to a verified number that has not said STOP.
  check (not enabled or (phone_e164 is not null and verified_at is not null and opted_out_at is null))
);
-- One account per verified number: a number cannot be verified twice to text two accounts.
create unique index sms_alerts_verified_phone_idx on sms_alerts (phone_e164) where verified_at is not null;

alter table sms_alerts enable row level security;
-- Owners may see their own row (never the code hash) and delete it, which forgets the number. Every other
-- write goes through a service role function (sms-verify, and the Linq STOP webhook), none built yet.
create policy sms_alerts_owner_read on sms_alerts for select to authenticated
  using (auth.uid() = user_id);
create policy sms_alerts_owner_delete on sms_alerts for delete to authenticated
  using (auth.uid() = user_id);
revoke all on sms_alerts from anon, authenticated;
grant select (user_id, phone_e164, verified_at, enabled, opted_out_at, created_at, updated_at)
  on sms_alerts to authenticated;
grant delete on sms_alerts to authenticated;

create or replace function sms_alerts_touch() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
create trigger sms_alerts_touch before update on sms_alerts
  for each row execute function sms_alerts_touch();
