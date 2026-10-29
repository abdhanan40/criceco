-- CricEco · preflight (READ-ONLY: catalog queries, changes nothing).
-- Run BEFORE migrations 1–4.
-- Expected on the CricEco project (verified 2026-10-27):
--   query 1 → exactly ONE row: public.profiles (the existing table, kept).
--            Any of current_addresses / permanent_addresses / player_profiles
--            here means a previous attempt left it behind — stop.
--   query 2 → 0 rows (none of the four functions exists yet).
--   query 3 → 0 rows (no trigger on auth.users yet).
--   query 4 → 0 rows (no trigger on public.profiles yet).
--   query 5 → 0 rows (same as 3, read straight from the catalog: 3 only lists
--            triggers on tables this session holds more than SELECT on).
--   query 6 → true (this session may create the sign-up trigger on
--            auth.users; false means migration 1 would fail — stop).

-- 1. Tables the migrations create or adopt.
select table_schema, table_name
from information_schema.tables
where table_schema = 'public'
  and table_name in ('profiles', 'current_addresses', 'permanent_addresses', 'player_profiles');

-- 2. Functions the migrations create (or replace).
select n.nspname as schema, p.proname as function_name, pg_get_function_identity_arguments(p.oid) as args
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('set_last_updated_at', 'profiles_validate', 'handle_new_user', 'save_profile_setup');

-- 3. Existing triggers on auth.users (on_auth_user_created must not exist).
select trigger_name, action_timing, event_manipulation, action_statement
from information_schema.triggers
where event_object_schema = 'auth' and event_object_table = 'users';

-- 4. Existing triggers on public.profiles (profiles_validate /
--    profiles_set_last_updated_at must not exist).
select trigger_name, action_timing, event_manipulation, action_statement
from information_schema.triggers
where event_object_schema = 'public' and event_object_table = 'profiles';

-- 5. Triggers on auth.users straight from the catalog (expect 0 rows).
select tgname as trigger_name
from pg_trigger
where tgrelid = 'auth.users'::regclass and not tgisinternal;

-- 6. Can this session create the sign-up trigger? (expect true)
select has_table_privilege('auth.users', 'TRIGGER') as can_create_auth_trigger;
