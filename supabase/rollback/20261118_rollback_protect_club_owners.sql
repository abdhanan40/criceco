-- CricEco · ROLLBACK of migration 15 (club-owner protection, deletion throttle).
-- Only with explicit approval, inside
--   begin; set local lock_timeout = '5s'; <this file> commit;
--
-- WARNING: this restores migration 14's delete_account_data, which DELETES
-- the clubs a user owns (with their members, requests and teams), and removes
-- the trigger that stops a club owner's profile — or Auth user — from being
-- deleted. Undeploy / disable the delete-account Edge Function FIRST, so
-- nothing can delete an owner while migration 14's behaviour is back.

do $$
begin
  if to_regclass('public.account_deletion_attempts') is null
     and not exists (select 1 from pg_trigger where tgname = 'profiles_protect_club_owner') then
    raise exception 'rollback 15: migration 15 is not applied — nothing changed';
  end if;
end $$;

drop trigger if exists profiles_protect_club_owner on public.profiles;
drop function if exists public.profiles_protect_club_owner();
drop function if exists public.account_deletion_failed(uuid);
drop function if exists public.account_deletion_throttled(uuid);
drop table if exists public.account_deletion_attempts;

-- delete_account_data exactly as in migration 14 (privileges are kept by
-- CREATE OR REPLACE: service_role only).
create or replace function public.delete_account_data(p_user_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_clubs        integer;
  v_memberships  integer;
  v_requests     integer;
  v_profile      integer;
begin
  if p_user_id is null then
    raise exception 'account_delete: user required' using errcode = '22023';
  end if;

  -- The user's own clubs, and with them everything in those clubs.
  delete from public.clubs where owner_id = p_user_id;
  get diagnostics v_clubs = row_count;

  -- Their places in other clubs (squads and leader roles follow) and requests.
  delete from public.club_members where user_id = p_user_id;
  get diagnostics v_memberships = row_count;
  delete from public.join_requests where user_id = p_user_id;
  get diagnostics v_requests = row_count;

  -- The profile and everything that hangs off it (addresses, player profile,
  -- roles, code attempts); references in other people's rows become NULL.
  delete from public.profiles where id = p_user_id;
  get diagnostics v_profile = row_count;

  return jsonb_build_object(
    'clubs', v_clubs,
    'memberships', v_memberships,
    'join_requests', v_requests,
    'profile', v_profile
  );
end;
$$;

comment on function public.delete_account_data(uuid) is
  'Deletes a user''s app data (account deletion step 1). Service role only: called by the delete-account Edge Function after the password check.';

notify pgrst, 'reload schema';
