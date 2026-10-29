-- Side view sync (Task 9). The brand-assets-sync function (mode=side_views) does the work; this adds
-- the note column it writes and the hourly job that calls it.
--
-- airline_assets.note: how the stored image differs from the provider's file. 'mirrored' marks a side
-- view the provider drew nose to the right, flipped at upload so every stored side view points left.
alter table airline_assets add column note text check (note is null or note in ('mirrored'));

-- Hourly at minute 41 (logos run at minute 17), 100 files a run. Without SIDE_VIEW_PROVIDER set the
-- function answers { skipped } and does nothing. cron.schedule upserts by name.
select cron.schedule('brand-side-views-sync', '41 * * * *',
  $$select public.invoke_edge_function('brand-assets-sync', 'mode=side_views&limit=100')$$);
