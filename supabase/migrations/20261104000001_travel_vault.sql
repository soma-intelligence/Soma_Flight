-- Travel documents backed up per account. The app seals both parts on the device with AES-GCM under a
-- key kept in the owner's iCloud Keychain, so this table only ever holds ciphertext (base64): the server,
-- its admins and a leaked backup cannot read a passport or loyalty number. profile = loyalty numbers and
-- the passport's country and expiry; identity = passport, Known Traveler and Redress numbers.
create table public.travel_vault (
  user_id uuid primary key references auth.users (id) on delete cascade,
  profile text check (profile is null or length(profile) < 65536),
  identity text check (identity is null or length(identity) < 8192),
  updated_at timestamptz not null default now()
);

alter table public.travel_vault enable row level security;

create policy travel_vault_select on public.travel_vault for select to authenticated
  using (user_id = (select auth.uid()));
create policy travel_vault_insert on public.travel_vault for insert to authenticated
  with check (user_id = (select auth.uid()));
create policy travel_vault_update on public.travel_vault for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy travel_vault_delete on public.travel_vault for delete to authenticated
  using (user_id = (select auth.uid()));

revoke all on public.travel_vault from public, anon, authenticated;
grant select, insert, update, delete on public.travel_vault to authenticated;
