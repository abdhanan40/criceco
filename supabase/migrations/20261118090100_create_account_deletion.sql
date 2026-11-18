-- CricEco · migration 14 · account deletion (data)
--
-- NOT APPLIED. Requires migrations 11–12. Review first; apply only with
-- separate approval, after a fresh backup, inside
--   begin; set local lock_timeout = '5s'; <this file> commit;
-- Rollback: supabase/rollback/20261118_rollback_account_deletion.sql.
-- Read-only check: supabase/tests/13_account_privacy_postcheck.sql.
--
-- Deletion runs in the `delete-account` Edge Function
-- (supabase/functions/delete-account), with the service role, after it has
-- re-checked the user's password:
--   1. public.delete_account_data(user id)  — this file: the app data;
--   2. auth.admin.deleteUser(user id)       — the Auth user.
-- Step 1 is idempotent, so a failure at step 2 can simply be retried by the
-- user (still signed in) with the same request.
--
-- Retention policy (docs/ACCOUNT_PRIVACY_AND_DELETION.md) — nothing personal
-- is kept, nothing of other people is lost silently:
--   * The clubs the user OWNS are deleted, with their members, join
--     requests, teams and squads (ON DELETE CASCADE from clubs). The app
--     names the club in the confirmation before anything is deleted.
--   * The user's memberships of other clubs and their join requests are
--     deleted; a squad loses that player and a captain / vice-captain role
--     held by them is cleared (team_players CASCADE, teams SET NULL).
--   * profile, both addresses, player profile, roles and code attempts are
--     deleted (CASCADE from profiles).
--   * Where another person's row only recorded this user as the one who
--     decided or removed something (join_requests.decided_by,
--     club_members.removed_by, user_roles.granted_by) it becomes NULL
--     (existing ON DELETE SET NULL).
-- Only the service role may execute it: not anon, not authenticated (a user
-- could otherwise delete without the password check).

do $$
begin
  if to_regclass('public.club_members') is null or to_regclass('public.teams') is null then
    raise exception 'migration 14: migrations 11 and 12 are required';
  end if;
  if to_regprocedure('public.delete_account_data(uuid)') is not null then
    raise exception 'migration 14: delete_account_data already exists — nothing changed';
  end if;
end $$;

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

revoke execute on function public.delete_account_data(uuid) from public, anon, authenticated;
grant execute on function public.delete_account_data(uuid) to service_role;

notify pgrst, 'reload schema';
