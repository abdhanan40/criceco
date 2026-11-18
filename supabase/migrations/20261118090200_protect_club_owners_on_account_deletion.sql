-- CricEco · migration 15 · club owners can't be deleted; deletion attempts throttled
--
-- NOT APPLIED. Requires migration 14 exactly as verified on production
-- (delete_account_data source md5 2162f8e31acc97c4ab7013ee3b9663af). Review
-- first; apply only with separate approval, after a fresh backup, inside
--   begin; set local lock_timeout = '5s'; <this file> commit;
-- Rollback: supabase/rollback/20261118_rollback_protect_club_owners.sql.
-- Read-only check: supabase/tests/15_club_owner_protection_postcheck.sql.
--
-- Approved policy (2026-11-18): club ownership must be TRANSFERRED before an
-- account can be deleted. An owner's club, its memberships, teams and other
-- club data are never deleted as a side effect of deleting the account.
--
-- Migration 14 did the opposite (it deleted the clubs the user owned), and
-- clubs.owner_id references profiles ON DELETE CASCADE, so ANY deletion of an
-- owner's profile — also deleting the Auth user in the Dashboard — would
-- cascade to the club. This migration closes both paths:
--   1. delete_account_data(p_user_id): locks the user's profile row, refuses
--      with CLUB_OWNERSHIP_TRANSFER_REQUIRED while the user owns a club (or
--      holds an owner membership), and never deletes a club.
--   2. Trigger profiles_protect_club_owner (BEFORE DELETE on profiles): no
--      profile of a club owner can be deleted at all, whoever deletes it
--      (cascade from auth.users included) — that deletion fails instead.
--   3. account_deletion_attempts + account_deletion_throttled(uuid) /
--      account_deletion_failed(uuid): at most 5 wrong deletion passwords per
--      user per 15 minutes, checked by the delete-account Edge Function
--      before it tries the password.
-- All new functions: SECURITY DEFINER, empty search_path; only service_role
-- may execute them (the trigger function: nobody). anon / authenticated get
-- nothing.
--
-- Race safety: delete_account_data takes FOR UPDATE on the profile row first.
-- Creating a club, or a future ownership transfer TO this user, needs a KEY
-- SHARE lock on that row (the clubs.owner_id foreign key), so it waits; once
-- the profile is gone it fails. A transfer AWAY from the user that commits
-- first is seen by the ownership check (READ COMMITTED, after the lock).

do $$
declare
  v_src text;
begin
  select replace(prosrc, chr(13), '') into v_src from pg_proc
   where pronamespace = 'public'::regnamespace and proname = 'delete_account_data';
  if v_src is null then
    raise exception 'migration 15: migration 14 (delete_account_data) is required';
  end if;
  if md5(v_src) <> '2162f8e31acc97c4ab7013ee3b9663af' then
    raise exception 'migration 15: delete_account_data is not migration 14''s version — nothing changed';
  end if;
  if to_regclass('public.account_deletion_attempts') is not null
     or exists (select 1 from pg_trigger where tgname = 'profiles_protect_club_owner') then
    raise exception 'migration 15: already applied — nothing changed';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Deleting the data: never for a club owner, never a club
-- ---------------------------------------------------------------------------
create or replace function public.delete_account_data(p_user_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_owned        integer;
  v_memberships  integer;
  v_requests     integer;
  v_profile      integer;
begin
  if p_user_id is null then
    raise exception 'account_delete: user required' using errcode = '22023';
  end if;

  -- Serialise with anything that could make this user an owner meanwhile.
  perform 1 from public.profiles where id = p_user_id for update;

  select count(*) into v_owned from public.clubs where owner_id = p_user_id;
  if v_owned = 0 then
    select count(*) into v_owned from public.club_members
     where user_id = p_user_id and member_role = 'owner' and status = 'active';
  end if;
  if v_owned > 0 then
    raise exception 'account_delete: CLUB_OWNERSHIP_TRANSFER_REQUIRED'
      using errcode = 'P0001',
            detail = format('owned clubs: %s', v_owned),
            hint = 'Transfer the ownership of every club to another member first.';
  end if;

  -- Their places in other clubs (squads and leader roles follow) and requests.
  delete from public.club_members where user_id = p_user_id;
  get diagnostics v_memberships = row_count;
  delete from public.join_requests where user_id = p_user_id;
  get diagnostics v_requests = row_count;

  -- The profile and everything that hangs off it (addresses, player profile,
  -- roles, code and deletion attempts); references in other rows become NULL.
  delete from public.profiles where id = p_user_id;
  get diagnostics v_profile = row_count;

  return jsonb_build_object(
    'clubs', 0,
    'memberships', v_memberships,
    'join_requests', v_requests,
    'profile', v_profile
  );
end;
$$;

comment on function public.delete_account_data(uuid) is
  'Deletes a user''s app data (account deletion step 1). Refuses club owners (CLUB_OWNERSHIP_TRANSFER_REQUIRED) and never deletes a club. Service role only.';

-- (CREATE OR REPLACE kept migration 14's privileges: service_role only.)

-- ---------------------------------------------------------------------------
-- 2. No club owner's profile can be deleted, by any route
-- ---------------------------------------------------------------------------
create or replace function public.profiles_protect_club_owner()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.clubs where owner_id = old.id) then
    raise exception 'account_delete: CLUB_OWNERSHIP_TRANSFER_REQUIRED'
      using errcode = 'P0001',
            hint = 'Transfer the ownership of every club to another member before deleting this account.';
  end if;
  return old;
end;
$$;

create trigger profiles_protect_club_owner
  before delete on public.profiles
  for each row execute function public.profiles_protect_club_owner();

-- ---------------------------------------------------------------------------
-- 3. Throttle wrong deletion passwords (5 per user per 15 minutes)
-- ---------------------------------------------------------------------------
create table public.account_deletion_attempts (
  user_id       uuid not null
                constraint account_deletion_attempts_user_id_fkey references public.profiles (id) on delete cascade,
  attempted_at  timestamptz not null default now()
);

comment on table public.account_deletion_attempts is
  'Wrong passwords given to delete an account (throttle). Written and read only by service-role functions.';

create index account_deletion_attempts_user_time_idx
  on public.account_deletion_attempts (user_id, attempted_at);

alter table public.account_deletion_attempts enable row level security;
-- No policy: only the definer functions below touch it.
revoke all on table public.account_deletion_attempts from public, anon, authenticated;

create or replace function public.account_deletion_throttled(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select count(*) >= 5
    from public.account_deletion_attempts
   where user_id = p_user_id
     and attempted_at > now() - interval '15 minutes';
$$;

create or replace function public.account_deletion_failed(p_user_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  delete from public.account_deletion_attempts
   where user_id = p_user_id and attempted_at < now() - interval '1 day';
  insert into public.account_deletion_attempts (user_id)
  select p_user_id where exists (select 1 from public.profiles where id = p_user_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Privileges: service_role only; the trigger function: nobody
-- ---------------------------------------------------------------------------
revoke execute on function public.profiles_protect_club_owner() from public, anon, authenticated, service_role;
revoke execute on function public.account_deletion_throttled(uuid) from public, anon, authenticated;
revoke execute on function public.account_deletion_failed(uuid) from public, anon, authenticated;
grant execute on function public.account_deletion_throttled(uuid) to service_role;
grant execute on function public.account_deletion_failed(uuid) to service_role;

notify pgrst, 'reload schema';
