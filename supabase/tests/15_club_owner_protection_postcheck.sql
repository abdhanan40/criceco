-- CricEco · post-check for migration 15 (club owners can't be deleted;
-- deletion attempts throttled). READ-ONLY: one SELECT, no DML/DDL, no
-- personal data (catalog facts and counts). Every row must say PASS.
-- Safe before the migration too (the new objects then FAIL / ABSENT).
with checks(check_name, expected, actual) as (
  values
    ('01 delete_account_data refuses owners and never deletes a club', 'true/false',
       coalesce((select (prosrc like '%CLUB_OWNERSHIP_TRANSFER_REQUIRED%')::text || '/'
                        || (prosrc like '%delete from public.clubs%')::text
                   from pg_proc where pronamespace = 'public'::regnamespace and proname = 'delete_account_data'), 'ABSENT')),
    ('02 delete_account_data: service_role only (authenticated no, anon no)', 'true/false/false',
       case when to_regprocedure('public.delete_account_data(uuid)') is null then 'ABSENT'
            else has_function_privilege('service_role', 'public.delete_account_data(uuid)', 'execute')::text || '/'
              || has_function_privilege('authenticated', 'public.delete_account_data(uuid)', 'execute')::text || '/'
              || has_function_privilege('anon', 'public.delete_account_data(uuid)', 'execute')::text end),
    ('03 trigger profiles_protect_club_owner: BEFORE DELETE on profiles, enabled', 'true',
       (exists (select 1 from pg_trigger t
                 where t.tgname = 'profiles_protect_club_owner' and t.tgrelid = 'public.profiles'::regclass
                   and t.tgenabled = 'O' and (t.tgtype & 2) = 2 and (t.tgtype & 8) = 8))::text),
    ('04 the 4 functions: SECURITY DEFINER, empty search_path', '4',
       (select count(*)::text from pg_proc p where p.pronamespace = 'public'::regnamespace
           and p.proname in ('delete_account_data', 'profiles_protect_club_owner',
                             'account_deletion_throttled', 'account_deletion_failed')
           and p.prosecdef and array_to_string(p.proconfig, ',') like '%search_path=""%')),
    ('05 throttle functions: service_role yes; authenticated / anon no', 'true/true/false/false/false/false',
       case when to_regprocedure('public.account_deletion_throttled(uuid)') is null then 'ABSENT'
            else has_function_privilege('service_role', 'public.account_deletion_throttled(uuid)', 'execute')::text || '/'
              || has_function_privilege('service_role', 'public.account_deletion_failed(uuid)', 'execute')::text || '/'
              || has_function_privilege('authenticated', 'public.account_deletion_throttled(uuid)', 'execute')::text || '/'
              || has_function_privilege('authenticated', 'public.account_deletion_failed(uuid)', 'execute')::text || '/'
              || has_function_privilege('anon', 'public.account_deletion_throttled(uuid)', 'execute')::text || '/'
              || has_function_privilege('anon', 'public.account_deletion_failed(uuid)', 'execute')::text end),
    ('06 the trigger function can''t be called by app roles', 'false/false',
       case when to_regprocedure('public.profiles_protect_club_owner()') is null then 'ABSENT'
            else has_function_privilege('authenticated', 'public.profiles_protect_club_owner()', 'execute')::text || '/'
              || has_function_privilege('anon', 'public.profiles_protect_club_owner()', 'execute')::text end),
    ('07 account_deletion_attempts: RLS on, no policy, no anon / authenticated grants', 'true',
       (to_regclass('public.account_deletion_attempts') is not null
        and (select relrowsecurity from pg_class where oid = to_regclass('public.account_deletion_attempts'))
        and not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'account_deletion_attempts')
        and not exists (select 1 from information_schema.role_table_grants where table_schema = 'public'
                          and table_name = 'account_deletion_attempts' and grantee in ('anon', 'authenticated', 'PUBLIC')))::text),
    ('08 account_deletion_attempts cascades with the profile', 'c',
       (select confdeltype::text from pg_constraint where conname = 'account_deletion_attempts_user_id_fkey')),
    ('09 one club per owner (clubs_owner_id_key unique) still in place', 'true',
       (exists (select 1 from pg_constraint where conname = 'clubs_owner_id_key' and contype = 'u'))::text),
    ('10 no deletion attempts recorded yet', '0',
       case when to_regclass('public.account_deletion_attempts') is null then 'ABSENT'
            else (xpath('/row/v/text()', query_to_xml(
              'select count(*)::text as v from public.account_deletion_attempts', false, true, '')))[1]::text end)
)
select check_name, expected, actual,
       case when actual is not distinct from expected then 'PASS' else 'FAIL' end as result
  from checks
 order by check_name;
