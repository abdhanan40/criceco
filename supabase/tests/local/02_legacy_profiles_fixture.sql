-- CricEco · LOCAL TEST ONLY — a stand-in for the live project's existing
-- public.profiles, matching the verified live findings:
--   6 columns; id PK → auth.users(id) ON DELETE CASCADE; only the PK index;
--   RLS on (not forced); own-row INSERT / SELECT / UPDATE policies for
--   authenticated; every privilege granted to anon / authenticated /
--   service_role (Supabase defaults, from 00_auth_stub.sql);
--   5 rows: 4 completed, 1 without full_name, 1 without phone,
--   4 phones in 03XXXXXXXXX form (spaced / dashed variants included), 0 in +92;
--   roles 3 club_owner, 1 player, 1 NULL.
-- Adversarial on purpose: the row without a name is a COMPLETED one.
-- Run after 00_auth_stub.sql on a fresh local database. Refuses to run if
-- profiles already exists or the auth schema looks real.

do $$
begin
  if to_regclass('public.profiles') is not null then
    raise exception 'LOCAL ONLY: public.profiles already exists';
  end if;
  if exists (select 1 from information_schema.columns
             where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password') then
    raise exception 'LOCAL ONLY: this looks like a real Supabase auth schema';
  end if;
end $$;

create table public.profiles (
  id                uuid primary key references auth.users (id) on delete cascade,
  created_at        timestamptz not null default now(),
  full_name         text,
  phone             text,
  role              text,
  profile_completed boolean not null default false
);

alter table public.profiles enable row level security;
create policy "Users can insert own profile" on public.profiles for insert to authenticated
  with check (auth.uid() = id);
create policy "Users can view own profile" on public.profiles for select to authenticated
  using (auth.uid() = id);
create policy "Users can update own profile" on public.profiles for update to authenticated
  using (auth.uid() = id);

insert into auth.users (id, email) values
  ('a0000000-0000-4000-8000-000000000001', 'legacy1@local.test'),
  ('a0000000-0000-4000-8000-000000000002', 'legacy2@local.test'),
  ('a0000000-0000-4000-8000-000000000003', 'legacy3@local.test'),
  ('a0000000-0000-4000-8000-000000000004', 'legacy4@local.test'),
  ('a0000000-0000-4000-8000-000000000005', 'legacy5@local.test');

insert into public.profiles (id, created_at, full_name, phone, role, profile_completed) values
  ('a0000000-0000-4000-8000-000000000001', timestamptz '2026-10-01 10:00+00', 'Owner One',   '03001234567',  'club_owner', true),
  ('a0000000-0000-4000-8000-000000000002', timestamptz '2026-10-02 10:00+00', 'Owner Two',   '0312 9020000', 'club_owner', true),
  ('a0000000-0000-4000-8000-000000000003', timestamptz '2026-10-03 10:00+00', 'Owner Three', '0333-1112223', 'club_owner', true),
  ('a0000000-0000-4000-8000-000000000004', timestamptz '2026-10-04 10:00+00', null,          '03451234567',  'player',     true),
  ('a0000000-0000-4000-8000-000000000005', timestamptz '2026-10-05 10:00+00', 'Not Done',    null,           null,         false);
