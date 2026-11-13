-- CricEco · ROLLBACK of migrations 20261027090000–20261027090300 (and of the
-- review migration, if it was applied).
--
-- PRESERVES the pre-existing public.profiles table and its original rows and
-- columns (id, created_at, full_name, phone, role, profile_completed): the
-- table is never dropped. It removes only what these migrations added:
--   * current_addresses, permanent_addresses, player_profiles (and their data)
--   * save_profile_setup(), the triggers and helper functions
--   * the 3 added profiles columns (date_of_birth, permanent_same_as_current,
--     last_updated_at) and their values
--   * the date_of_birth CHECK and the review migration's CHECK constraints
--     (none of these names existed before — 00b showed only the PK and FK)
-- DESTRUCTIVE for that added data. Run only on purpose, after a backup.
-- Not undone: review section B's grant changes. To restore the original
-- (Supabase default) grants: grant all on table public.profiles to anon, authenticated;

begin;

drop function if exists public.save_profile_setup(text, text, date, text, text, text, boolean, text, text, text);

drop table if exists public.player_profiles;
drop table if exists public.permanent_addresses;
drop table if exists public.current_addresses;

drop trigger if exists on_auth_user_created on auth.users;
drop function if exists public.handle_new_user();

drop trigger if exists profiles_validate on public.profiles;
drop trigger if exists profiles_set_last_updated_at on public.profiles;
drop function if exists public.profiles_validate();
drop function if exists public.set_last_updated_at();

alter table public.profiles
  drop constraint if exists profiles_full_name_check,
  drop constraint if exists profiles_phone_check,
  drop constraint if exists profiles_role_check,
  drop constraint if exists profiles_date_of_birth_check,
  drop column if exists date_of_birth,
  drop column if exists permanent_same_as_current,
  drop column if exists last_updated_at;

commit;
