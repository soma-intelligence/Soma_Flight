-- BadDeviceToken is also what APNs answers for every token when APNS_SANDBOX does not match the
-- build, so a token is only deleted on its second strike. Reset to 0 on a good send or a new registration.
alter table push_tokens add column bad_count int not null default 0;
