-- sms_alerts_touch (20261031000024) is a trigger function only: clients never call it. Functions are
-- executable by PUBLIC when created, so revoke it like every other internal function (archive_test guard).
revoke execute on function public.sms_alerts_touch() from public, anon, authenticated;
