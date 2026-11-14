-- CricEco · ROLLBACK of migration 20261110090100_create_user_roles.sql (Stage 4.2).
--
-- Removes only what that migration added: the four triggers on
-- player_profiles / clubs, their functions, user_roles and the app_role type.
-- Touches no other table, column, policy, grant or row: profiles.role,
-- player_profiles and clubs stay as they are. No user data is lost — every
-- role can be rebuilt from player_profiles / clubs by re-applying migration 7.
-- Roll back the app build that reads user_roles FIRST (its account read
-- embeds user_roles and would fail without it).

begin;

drop trigger if exists player_profiles_grant_role on public.player_profiles;
drop trigger if exists player_profiles_revoke_role on public.player_profiles;
drop trigger if exists clubs_grant_owner_role on public.clubs;
drop trigger if exists clubs_revoke_owner_role on public.clubs;

drop function if exists public.player_profiles_grant_role();
drop function if exists public.player_profiles_revoke_role();
drop function if exists public.clubs_grant_owner_role();
drop function if exists public.clubs_revoke_owner_role();

-- Dropping the table drops its policy, constraints, index and grants.
drop table if exists public.user_roles;
drop type if exists public.app_role;

notify pgrst, 'reload schema';

commit;
