begin;
create extension if not exists pgtap with schema extensions;
select plan(17);

insert into auth.users (id, instance_id, aud, role, email)
values ('a7a7a7a7-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 'providers-a@test.local');

-- charge_provider_quota counts up to the limit and refuses past it, without counting the refusal.
select ok(public.charge_provider_quota('aviationstack', '2001-01-01', 1, 2), 'first unit passes');
select ok(public.charge_provider_quota('aviationstack', '2001-01-01', 1, 2), 'second unit reaches the limit');
select ok(not public.charge_provider_quota('aviationstack', '2001-01-01', 1, 2), 'third unit is refused');
select is((select used from provider_quota where provider = 'aviationstack' and period_start = '2001-01-01'),
  2, 'a refusal counts nothing');
select ok(public.charge_provider_quota('aviationstack', '2001-02-01', 1, 2), 'a new period starts at zero');
select ok(not public.charge_provider_quota('opensky', '2001-01-01', 5, 4), 'a call larger than the limit is refused');
select ok(public.charge_provider_quota('aviationstack.poll', '2001-01-01', 1, 1), 'pace counters have their own row');
select throws_ok($$select public.charge_provider_quota('aviationstack', '2001-01-01', -1, 2)$$, '22023', null,
  'negative units are refused');
select throws_ok($$insert into provider_quota (provider, period_start) values ('Avi Stack', '2001-01-01')$$,
  '23514', null, 'provider names are lower case words');

-- poll_candidates: followed, not finished, departing within 30 h back and 8 h ahead.
insert into flights (id, provider_id, ident, scheduled_out, status) values
  ('c7000000-0000-0000-0000-000000000001', 'PRV-1', 'AF84', now() + interval '2 hours', 'scheduled'),
  ('c7000000-0000-0000-0000-000000000002', 'PRV-2', 'AF85', now() + interval '2 hours', 'scheduled'),
  ('c7000000-0000-0000-0000-000000000003', 'PRV-3', 'AF86', now() + interval '2 hours', 'arrived'),
  ('c7000000-0000-0000-0000-000000000004', 'PRV-4', 'AF87', now() + interval '3 days', 'scheduled');
insert into user_flights (user_id, flight_id) values
  ('a7a7a7a7-0000-0000-0000-000000000001', 'c7000000-0000-0000-0000-000000000001'),
  ('a7a7a7a7-0000-0000-0000-000000000001', 'c7000000-0000-0000-0000-000000000003'),
  ('a7a7a7a7-0000-0000-0000-000000000001', 'c7000000-0000-0000-0000-000000000004');
insert into provider_polls (flight_id, last_polled_at, provider)
values ('c7000000-0000-0000-0000-000000000001', now() - interval '1 hour', 'aviationstack');
select is(
  (select array_agg(provider_id order by provider_id) from public.poll_candidates(500) where provider_id like 'PRV-%'),
  array['PRV-1'], 'only the followed, unfinished flight in the window');
select ok(
  (select last_polled_at is not null from public.poll_candidates(500) where provider_id = 'PRV-1'),
  'with its last poll');
delete from flights where id = 'c7000000-0000-0000-0000-000000000001';
select is((select count(*) from provider_polls where flight_id = 'c7000000-0000-0000-0000-000000000001'),
  0::bigint, 'polls go with the flight');

-- Clients reach none of it.
set local role authenticated;
set local request.jwt.claims = '{"sub":"a7a7a7a7-0000-0000-0000-000000000001","role":"authenticated"}';
select throws_ok($$select * from provider_quota$$, '42501', null, 'a user cannot read provider_quota');
select throws_ok($$select * from provider_polls$$, '42501', null, 'a user cannot read provider_polls');
select throws_ok($$select public.charge_provider_quota('aviationstack', '2001-03-01', 1, 9)$$, '42501', null,
  'a user cannot charge a quota');
select throws_ok($$select * from public.poll_candidates(5)$$, '42501', null, 'a user cannot list candidates');
reset role;

select is((select count(*) from cron.job where jobname in ('provider-poll', 'provider-quota-prune')), 2::bigint,
  'the poll and prune jobs are scheduled');

select * from finish();
rollback;
