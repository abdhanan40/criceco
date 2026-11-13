-- CricEco · migration 1/4 · ADOPT the existing public.profiles  (additive only)
-- ERD v8 "UserAuth" → public.profiles, keyed by auth.users.id.
--
-- The live project already has public.profiles (id, created_at, full_name,
-- phone, role, profile_completed) with 5 rows, all matching auth.users; the
-- id foreign key is already ON DELETE CASCADE; RLS is on with own-row
-- INSERT / SELECT / UPDATE policies for authenticated. This migration keeps
-- that table, its rows, its existing columns, constraints, policies and
-- grants exactly as they are, and only ADDS:
--   * 3 columns (nullable or with a constant default — existing values untouched)
--   * a CHECK on the new date_of_birth column only
--   * helper / validation / sign-up functions and their triggers
-- Rules on the EXISTING columns and the grant review are NOT here: see
-- supabase/review/20261027090400_profiles_hardening_REVIEW.sql.
--
-- The app's Role Selection value stays in the existing "role" column
-- ('player' | 'club_owner'); no column is renamed.
--
-- NOT APPLIED. Run 00b_inspect_existing_profiles.sql and
-- 00c_profiles_fingerprint.sql first (see supabase/README.md).

-- ---------------------------------------------------------------------------
-- New columns. ADD COLUMN IF NOT EXISTS never touches existing values; the
-- constant / now() defaults are stored as metadata (no table rewrite).
-- ---------------------------------------------------------------------------
alter table public.profiles
  add column if not exists date_of_birth date,
  -- "Permanent address same as current?" (the app's default is Yes).
  add column if not exists permanent_same_as_current boolean not null default true,
  add column if not exists last_updated_at timestamptz not null default now();

-- A rule on the NEW column only (every existing row has NULL, so it can't
-- affect them): a date of birth, when given, is 1900 or later.
alter table public.profiles
  add constraint profiles_date_of_birth_check
    check (date_of_birth is null or date_of_birth >= date '1900-01-01');

comment on column public.profiles.role is
  'Role chosen on Role Selection: player | club_owner (NULL until chosen).';
comment on column public.profiles.profile_completed is
  'User Profile Setup finished. Rows from before this migration may predate the address step.';

-- ---------------------------------------------------------------------------
-- Shared helper: last_updated_at follows every UPDATE; created_at can't change.
-- ---------------------------------------------------------------------------
create or replace function public.set_last_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.created_at := old.created_at;
  new.last_updated_at := now();
  return new;
end;
$$;

create trigger profiles_set_last_updated_at
  before update on public.profiles
  for each row execute function public.set_last_updated_at();

-- ---------------------------------------------------------------------------
-- Validation (new writes only — existing rows are never re-checked):
--   * a date of birth can't be in the future;
--   * when a profile BECOMES completed (insert as completed, or false / NULL → true),
--     name, phone and date of birth must be present.
-- Migration 2 replaces this function to also require both addresses.
-- ---------------------------------------------------------------------------
create or replace function public.profiles_validate()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.date_of_birth is not null and new.date_of_birth > current_date then
    raise exception 'date_of_birth cannot be in the future' using errcode = '23514';
  end if;
  if new.profile_completed and (tg_op = 'INSERT' or old.profile_completed is not true) then
    if new.full_name is null or new.phone is null or new.date_of_birth is null then
      raise exception 'profile_completed requires full_name, phone and date_of_birth' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;

create trigger profiles_validate
  before insert or update on public.profiles
  for each row execute function public.profiles_validate();

-- ---------------------------------------------------------------------------
-- Sign-up: every NEW auth user gets an empty profile row in the same
-- transaction. ON CONFLICT DO NOTHING: an existing row is never touched
-- (the 5 current users already have theirs).
-- Requires every profiles column other than id to be nullable or defaulted
-- (check query 1 of 00b_inspect_existing_profiles.sql).
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id) values (new.id) on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- These are trigger functions (RETURNS trigger): Postgres refuses to call
-- them directly, so they aren't callable through the API / RPC. Their
-- EXECUTE grants are left as is — sign-up runs this trigger as Supabase's
-- auth role, and must not be blocked.

-- RLS stays on (no-op if it already is). The existing policies are kept.
alter table public.profiles enable row level security;
