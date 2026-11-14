-- CricEco · preflight for migration 5 / clubs (READ-ONLY: catalog queries,
-- changes nothing). Run BEFORE migrations/20261109090000_create_clubs.sql.
-- Expected:
--   query 1 → clubs_table = NULL (no public.clubs yet).
--   query 2 → 0 rows (none of the four functions exists yet).
--   query 3 → 0 rows (no policies on a clubs table).
--   query 4 → 5 rows, every one present = true (migrations 1–4 applied:
--            what migration 5 depends on).
--   query 5 → profiles.role is text (club_owner is a plain value, no enum).
--   query 6 → true, true (gen_random_uuid / uuid_send available).

-- 1. The table migration 5 creates.
select to_regclass('public.clubs') as clubs_table;

-- 2. Functions migration 5 creates (or replaces).
select n.nspname as schema, p.proname as function_name,
       pg_get_function_identity_arguments(p.oid) as args
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('create_club', 'clubs_assign_code', 'clubs_validate', 'clubs_set_owner_role');

-- 3. Policies on any clubs table.
select schemaname, tablename, policyname
from pg_policies
where tablename = 'clubs';

-- 4. What migration 5 depends on.
select 'function public.set_last_updated_at' as item,
       exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'public' and p.proname = 'set_last_updated_at') as present
union all
select 'table public.current_addresses', to_regclass('public.current_addresses') is not null
union all
select 'table public.permanent_addresses', to_regclass('public.permanent_addresses') is not null
union all
select 'column profiles.date_of_birth',
       exists (select 1 from information_schema.columns
               where table_schema = 'public' and table_name = 'profiles' and column_name = 'date_of_birth')
union all
select 'column profiles.profile_completed',
       exists (select 1 from information_schema.columns
               where table_schema = 'public' and table_name = 'profiles' and column_name = 'profile_completed');

-- 5. The type of profiles.role.
select data_type, udt_name
from information_schema.columns
where table_schema = 'public' and table_name = 'profiles' and column_name = 'role';

-- 6. Built-ins the join-code generator uses.
select exists (select 1 from pg_proc where proname = 'gen_random_uuid') as has_gen_random_uuid,
       exists (select 1 from pg_proc where proname = 'uuid_send')        as has_uuid_send;
