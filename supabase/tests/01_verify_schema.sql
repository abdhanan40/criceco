-- CricEco · schema verification (READ-ONLY: catalog queries, changes nothing).
-- Run in the Supabase SQL Editor after applying migrations 1–4.

-- 1. The four tables exist, with RLS enabled (expect 4 rows, rls_enabled = true).
select c.relname as table_name, c.relrowsecurity as rls_enabled
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in ('profiles', 'current_addresses', 'permanent_addresses', 'player_profiles')
order by 1;

-- 2. Policies (expect 9 new: select / insert / update own × 3 new tables, plus
--    the EXISTING profiles policies, unchanged — compare with 00b query 4).
select tablename, policyname, cmd, roles, qual, with_check
from pg_policies
where schemaname = 'public'
  and tablename in ('profiles', 'current_addresses', 'permanent_addresses', 'player_profiles')
order by tablename, cmd;

-- 3. Foreign keys and their ON DELETE action (CASCADE on the 3 new tables;
--    profiles_id_fkey as it was, unless review section D was applied).
select conrelid::regclass as table_name, conname, pg_get_constraintdef(oid) as definition
from pg_constraint
where contype = 'f'
  and conrelid::regclass::text in
      ('profiles', 'current_addresses', 'permanent_addresses', 'player_profiles')
order by 1, 2;

-- 4. CHECK and UNIQUE constraints (the profiles CHECKs appear only after the
--    review migration, with convalidated = false until validated).
select conrelid::regclass as table_name, conname, contype, pg_get_constraintdef(oid) as definition
from pg_constraint
where contype in ('c', 'u')
  and conrelid::regclass::text in
      ('profiles', 'current_addresses', 'permanent_addresses', 'player_profiles')
order by 1, 2;

-- 5. Triggers (expect on_auth_user_created on auth.users, profiles_validate,
--    and one *_set_last_updated_at per table).
select event_object_schema as schema, event_object_table as table_name, trigger_name,
       action_timing, string_agg(event_manipulation, ', ') as events
from information_schema.triggers
where (event_object_schema = 'public'
       and event_object_table in ('profiles', 'current_addresses', 'permanent_addresses', 'player_profiles'))
   or trigger_name = 'on_auth_user_created'
group by 1, 2, 3, 4
order by 1, 2, 3;

-- 6. Table privileges. Expect on the 3 new tables: anon all false;
--    authenticated select / insert / update true, delete / truncate false.
--    profiles keeps its existing grants until review section B is applied.
select t.tbl, r.role,
       has_table_privilege(r.role, t.tbl, 'select')   as can_select,
       has_table_privilege(r.role, t.tbl, 'insert')   as can_insert,
       has_table_privilege(r.role, t.tbl, 'update')   as can_update,
       has_table_privilege(r.role, t.tbl, 'delete')   as can_delete,
       has_table_privilege(r.role, t.tbl, 'truncate') as can_truncate
from (values ('public.profiles'), ('public.current_addresses'),
             ('public.permanent_addresses'), ('public.player_profiles')) as t(tbl)
cross join (values ('anon'), ('authenticated')) as r(role)
order by 1, 2;

-- 6b. save_profile_setup: anon false, authenticated true.
select r.role,
       has_function_privilege(r.role,
         'public.save_profile_setup(text, text, date, text, text, text, boolean, text, text, text)',
         'execute') as can_execute
from (values ('anon'), ('authenticated')) as r(role);

-- 7. Every auth user has a profile row (expect 0).
select count(*) as users_without_profile
from auth.users u left join public.profiles p on p.id = u.id
where p.id is null;
