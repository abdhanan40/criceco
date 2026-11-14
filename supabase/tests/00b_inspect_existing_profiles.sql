-- CricEco · inspect the EXISTING public.profiles (READ-ONLY, changes nothing).
-- Run in the Supabase SQL Editor and send the results back before any
-- migration. Queries 1–7 return structure only; 8 returns counts only —
-- no names or phone numbers are printed.

-- 1. Columns: type, nullability, default.
--    Key question: is any column NOT NULL without a default? (The sign-up
--    trigger inserts only "id"; such a column would break sign-up.)
select column_name, data_type, udt_name, is_nullable, column_default, character_maximum_length
from information_schema.columns
where table_schema = 'public' and table_name = 'profiles'
order by ordinal_position;

-- 2. Constraints (PK, FK with its ON DELETE rule, CHECK, UNIQUE).
select conname, contype, convalidated, pg_get_constraintdef(oid) as definition
from pg_constraint
where conrelid = 'public.profiles'::regclass
order by contype, conname;

-- 3. Indexes.
select indexname, indexdef
from pg_indexes
where schemaname = 'public' and tablename = 'profiles';

-- 4. RLS state and policies.
select relrowsecurity as rls_enabled, relforcerowsecurity as rls_forced
from pg_class where oid = 'public.profiles'::regclass;

select policyname, cmd, permissive, roles, qual, with_check
from pg_policies
where schemaname = 'public' and tablename = 'profiles'
order by cmd, policyname;

-- 5. Grants (effective privileges for the API roles).
select r.role,
       has_table_privilege(r.role, 'public.profiles', 'select')   as can_select,
       has_table_privilege(r.role, 'public.profiles', 'insert')   as can_insert,
       has_table_privilege(r.role, 'public.profiles', 'update')   as can_update,
       has_table_privilege(r.role, 'public.profiles', 'delete')   as can_delete,
       has_table_privilege(r.role, 'public.profiles', 'truncate') as can_truncate
from (values ('anon'), ('authenticated'), ('service_role')) as r(role);

-- 6. Triggers on profiles (and, again, on auth.users).
select event_object_schema, event_object_table, trigger_name, action_timing, event_manipulation, action_statement
from information_schema.triggers
where (event_object_schema = 'public' and event_object_table = 'profiles')
   or (event_object_schema = 'auth' and event_object_table = 'users');

-- 7. Custom types used by profiles columns (e.g. if "role" is an enum).
select c.column_name, t.typname, t.typtype,
       (select string_agg(e.enumlabel, ', ' order by e.enumsortorder)
          from pg_enum e where e.enumtypid = t.oid) as enum_values
from information_schema.columns c
join pg_type t on t.typname = c.udt_name
where c.table_schema = 'public' and c.table_name = 'profiles' and t.typtype = 'e';

-- 8. Data shape — COUNTS ONLY (decides which new rules existing rows already meet).
select
  count(*)                                                        as total_rows,
  count(*) filter (where profile_completed)                       as completed,
  count(*) filter (where full_name is null)                       as no_name,
  count(*) filter (where full_name is not null
                   and char_length(btrim(full_name)) not between 2 and 100) as name_out_of_range,
  count(*) filter (where phone is null)                           as no_phone,
  count(*) filter (where phone ~ '^\+923[0-9]{9}$')               as phone_plus92,
  count(*) filter (where regexp_replace(phone, '[\s-]', '', 'g') ~ '^03[0-9]{9}$') as phone_03_format,
  count(*) filter (where phone is not null
                   and phone !~ '^\+923[0-9]{9}$'
                   and regexp_replace(phone, '[\s-]', '', 'g') !~ '^(03|923|\+923)[0-9]{9}$') as phone_other,
  count(*) filter (where p.id not in (select id from auth.users)) as without_auth_user
from public.profiles p;

-- 8b. Distinct role values with counts (values are app codes, not personal data).
select role::text as role_value, count(*) from public.profiles group by 1 order by 1;
