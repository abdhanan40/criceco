-- CricEco · ROLLBACK of migration 20261109090000_create_clubs.sql (Stage 2).
--
-- Removes only what that migration added: public.clubs (and its data — every
-- club), create_club() and the three clubs_* trigger functions. Touches no
-- other table, column, policy, grant or row. In particular profiles.role is
-- left as it is: owners keep role = club_owner (the app doesn't read it).
-- DESTRUCTIVE for club data. Run only on purpose, after a backup.
--
-- Order: run this BEFORE rollback/20261027_rollback_profile_schema.sql if both
-- are ever needed — clubs uses public.set_last_updated_at() from migration 1,
-- so that rollback stops while clubs still exists.

begin;

drop function if exists public.create_club(text, text, text, text, text, text, text);

-- Dropping the table drops its triggers, policies, constraints and grants.
drop table if exists public.clubs;

drop function if exists public.clubs_set_owner_role();
drop function if exists public.clubs_validate();
drop function if exists public.clubs_assign_code();

commit;
