begin;
create extension if not exists pgtap with schema extensions;
select plan(9);

insert into auth.users (id, instance_id, aud, role, email)
values ('a7a7a7a7-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 'archive-a@test.local');
insert into past_flights (user_id, date, ident, origin_icao, destination_icao, status, source)
values ('a7a7a7a7-0000-0000-0000-000000000001', '2025-03-14T06:05:00Z', 'AF84', 'LFPG', 'KSFO', 'completed',
        'import');

select has_table('archive', 'deleted_accounts', 'archive.deleted_accounts exists');
select ok(not has_schema_privilege('anon', 'archive', 'usage'), 'anon cannot reach the archive schema');
select ok(not has_schema_privilege('authenticated', 'archive', 'usage'),
  'authenticated cannot reach the archive schema');
select ok(not has_function_privilege('authenticated', 'public.archive_account(uuid)', 'execute'),
  'authenticated cannot run archive_account');
select ok(not has_function_privilege('anon', 'public.archive_account(uuid)', 'execute'),
  'anon cannot run archive_account');

select public.archive_account('a7a7a7a7-0000-0000-0000-000000000001');
select is((select email from archive.deleted_accounts where user_id = 'a7a7a7a7-0000-0000-0000-000000000001'),
  'archive-a@test.local', 'the email is archived');
select is((select jsonb_array_length(data->'past_flights') from archive.deleted_accounts
           where user_id = 'a7a7a7a7-0000-0000-0000-000000000001'), 1, 'the past flights are archived');
select ok((select data ? 'profiles' and data ? 'friendships' from archive.deleted_accounts
           where user_id = 'a7a7a7a7-0000-0000-0000-000000000001'), 'every owned table has its key');

-- A retry after the rows were erased keeps the first, complete snapshot.
delete from past_flights where user_id = 'a7a7a7a7-0000-0000-0000-000000000001';
select public.archive_account('a7a7a7a7-0000-0000-0000-000000000001');
select is((select jsonb_array_length(data->'past_flights') from archive.deleted_accounts
           where user_id = 'a7a7a7a7-0000-0000-0000-000000000001'), 1, 'a retry keeps the first snapshot');

select * from finish();
rollback;
