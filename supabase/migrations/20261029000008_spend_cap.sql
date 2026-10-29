-- Global AeroAPI spend ceiling (ruling F6).
--
-- charge_usage: counts one paid call like increment_usage, unless today's estimated spend plus this
-- call would pass p_cap, in which case it counts nothing and returns false (the caller refuses the
-- call with provider_unavailable and serves what it has cached). Free calls (cost 0, alert create
-- and delete) are always counted and allowed. The advisory lock serialises the check per day, so
-- concurrent callers cannot all pass on the same remaining budget. Alert deliveries are billed by the
-- provider whatever we do: process_alert counts them with increment_usage, and they use the budget.
create function public.charge_usage(p_day date, p_endpoint text, p_cost numeric, p_cap numeric)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare v_spent numeric;
begin
  if p_cost > 0 and p_cap is not null then
    perform pg_advisory_xact_lock(hashtextextended('usage:' || p_day::text, 0));
    select coalesce(sum(estimated_cost), 0) into v_spent
      from public.usage_counters where day = p_day;
    if v_spent + p_cost > p_cap then
      return false;
    end if;
  end if;
  perform public.increment_usage(p_day, p_endpoint, p_cost);
  return true;
end;
$$;

revoke execute on function public.charge_usage(date, text, numeric, numeric) from public, anon, authenticated;
grant execute on function public.charge_usage(date, text, numeric, numeric) to service_role;

-- usage_alerts now holds two kinds of email, each at most once per UTC day:
--   daily  yesterday's spend above USAGE_ALERT_USD (08:00 to 11:00 UTC, as before)
--   cap    today's running spend at 80% of AEROAPI_DAILY_CAP_USD (checked hourly)
alter table usage_alerts add column kind text not null default 'daily'
  check (kind in ('daily', 'cap'));
alter table usage_alerts drop constraint usage_alerts_pkey;
alter table usage_alerts add primary key (day, kind);

select cron.schedule('usage-alert-cap', '20 * * * *',
  $$select public.invoke_edge_function('usage-alert', 'mode=cap')$$);
