-- Logo and brand colour sync (Task 8). The brand-assets-sync function does the work; this adds the
-- queue marker it needs and the hourly job that calls it.
--
-- airlines.logo_checked_at: when the sync last looked at this airline, found logos or not. The sync
-- takes the airlines never checked or checked over 7 days ago, so an airline the provider has no
-- logo for is still only revisited weekly instead of taking a slot in every batch.
alter table airlines add column logo_checked_at timestamptz;

-- Hourly at minute 17, 50 airlines a run: 2,050 airlines are all checked within two days, then each
-- again once 7 days old, which is the weekly refresh. Without a provider configured the function
-- answers { skipped } and does nothing. cron.schedule upserts by name.
select cron.schedule('brand-logos-sync', '17 * * * *',
  $$select public.invoke_edge_function('brand-assets-sync', 'mode=logos&limit=50')$$);
