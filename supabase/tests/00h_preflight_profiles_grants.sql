-- CricEco · Migration 10 PREFLIGHT (read-only). Run in the SQL Editor BEFORE
-- migration 10 (least-privilege grants on public.profiles). Changes
-- nothing: catalog reads and one row count — no personal data.
-- For extra safety, run it as:  begin transaction read only;  <this file>  rollback;
--
-- KEEP THE OUTPUT: result 3 is the exact record of the grants before
-- migration 10 (what its rollback restores, apart from any non-default
-- grantor / grant option detail listed there), and result 8 is the
-- fingerprint that tests/11_profiles_grants_check.sql must show unchanged
-- after it.
--
-- Expected before migration 10: every check in result 1 = OK.

-- 1. Checks.
select check_name, case when ok then 'OK' else 'STOP' end as result, detail
from (
  select 1 as n, 'public.profiles exists (a table)' as check_name,
         coalesce((select relkind = 'r' from pg_class where oid = to_regclass('public.profiles')), false) as ok,
         '' as detail
  union all
  select 2, 'roles anon / authenticated / service_role exist',
         to_regrole('anon') is not null and to_regrole('authenticated') is not null
           and to_regrole('service_role') is not null, ''
  union all
  select 3, 'row level security enabled on profiles',
         coalesce((select relrowsecurity from pg_class where oid = to_regclass('public.profiles')), false),
         'forced: ' || coalesce((select relforcerowsecurity::text from pg_class
                                  where oid = to_regclass('public.profiles')), '?')
  union all
  select 4, 'SELECT / INSERT / UPDATE policies for authenticated (own row)',
         (select count(distinct p.polcmd) from pg_policy p
           where p.polrelid = to_regclass('public.profiles') and p.polcmd in ('r', 'a', 'w')
             and (0::oid = any (p.polroles) or to_regrole('authenticated') = any (p.polroles))) = 3,
         (select count(*) from pg_policy where polrelid = to_regclass('public.profiles'))::text || ' policies in all'
  union all
  select 5, 'this role can manage the grants (member of the owner)',
         coalesce((select pg_has_role(current_user, relowner, 'usage') from pg_class
                    where oid = to_regclass('public.profiles')), false),
         'current_user = ' || current_user
  union all
  select 6, 'every anon / authenticated / PUBLIC grant was made by the owner (else REVOKE cannot remove it)',
         not exists (select 1 from pg_class c, aclexplode(c.relacl) a
                      where c.oid = to_regclass('public.profiles')
                        and (a.grantee = 0 or a.grantee in (to_regrole('anon'), to_regrole('authenticated')))
                        and a.grantor <> c.relowner)
           and not exists (select 1 from pg_attribute att, pg_class c, aclexplode(att.attacl) a
                            where c.oid = to_regclass('public.profiles') and att.attrelid = c.oid
                              and (a.grantee = 0 or a.grantee in (to_regrole('anon'), to_regrole('authenticated')))
                              and a.grantor <> c.relowner),
         ''
  union all
  select 7, 'migration 10 not applied yet (authenticated still holds TRUNCATE)',
         has_table_privilege('authenticated', 'public.profiles', 'TRUNCATE'),
         'informational: STOP here only means it already looks hardened'
) s order by n;

-- 2. Owner and server version.
select c.relowner::regrole as owner, current_setting('server_version') as server_version,
       (select count(*) from public.profiles) as profile_rows
  from pg_class c where c.oid = 'public.profiles'::regclass;

-- 3. Direct table grants (the record to keep). Grantee 0 = PUBLIC.
select case when a.grantee = 0 then 'PUBLIC' else a.grantee::regrole::text end as grantee,
       a.grantor::regrole as grantor, a.privilege_type, a.is_grantable
  from pg_class c, aclexplode(c.relacl) a
 where c.oid = 'public.profiles'::regclass
 order by 1, 3;

-- 4. Column-level grants (expected: none).
select att.attname as column_name,
       case when a.grantee = 0 then 'PUBLIC' else a.grantee::regrole::text end as grantee,
       a.grantor::regrole as grantor, a.privilege_type, a.is_grantable
  from pg_attribute att, aclexplode(att.attacl) a
 where att.attrelid = 'public.profiles'::regclass and att.attnum > 0 and not att.attisdropped
 order by 1, 2, 4;

-- 5. Effective privileges (direct, PUBLIC and inherited together).
select r.role,
       has_table_privilege(r.role, 'public.profiles', 'SELECT')     as sel,
       has_table_privilege(r.role, 'public.profiles', 'INSERT')     as ins,
       has_table_privilege(r.role, 'public.profiles', 'UPDATE')     as upd,
       has_table_privilege(r.role, 'public.profiles', 'DELETE')     as del,
       has_table_privilege(r.role, 'public.profiles', 'TRUNCATE')   as trunc,
       has_table_privilege(r.role, 'public.profiles', 'REFERENCES') as refs,
       has_table_privilege(r.role, 'public.profiles', 'TRIGGER')    as trig,
       case when current_setting('server_version_num')::int >= 170000
            then has_table_privilege(r.role, 'public.profiles', 'MAINTAIN')::text else 'n/a' end as maintain
  from (values ('public'), ('anon'), ('authenticated'), ('service_role')) r(role)
 where r.role = 'public' or to_regrole(r.role) is not null;

-- 6. Roles anon / authenticated are members of (privileges they may inherit).
select m.member::regrole as member, m.roleid::regrole as member_of
  from pg_auth_members m
 where m.member in (to_regrole('anon'), to_regrole('authenticated'))
 order by 1, 2;

-- 7. Policies and triggers on profiles (must be unchanged by migration 10).
select 'policy' as kind, p.policyname as name, p.cmd as detail, array_to_string(p.roles, ',') as roles
  from pg_policies p where p.schemaname = 'public' and p.tablename = 'profiles'
union all
select 'trigger', t.tgname, t.tgenabled::text || ' ' || t.tgfoid::regproc::text, ''
  from pg_trigger t where t.tgrelid = 'public.profiles'::regclass and not t.tgisinternal
order by 1, 2;

-- 8. Fingerprint of everything migration 10 must NOT change on profiles:
--    columns, constraints, indexes, RLS flags, policies, triggers and their
--    functions, and the grants of every role other than anon /
--    authenticated / PUBLIC. tests/11_profiles_grants_check.sql prints the
--    same value after migration 10 — the two must be equal.
select md5(string_agg(x, '|' order by x)) as profiles_fingerprint
from (
  select 'col:' || attname || ':' || format_type(atttypid, atttypmod) || ':' || attnotnull as x
    from pg_attribute where attrelid = 'public.profiles'::regclass and attnum > 0 and not attisdropped
  union all select 'con:' || conname || ':' || pg_get_constraintdef(oid)
    from pg_constraint where conrelid = 'public.profiles'::regclass
  union all select 'idx:' || pg_get_indexdef(indexrelid)
    from pg_index where indrelid = 'public.profiles'::regclass
  union all select 'rls:' || relrowsecurity || ':' || relforcerowsecurity
    from pg_class where oid = 'public.profiles'::regclass
  union all select 'pol:' || polname || ':' || polcmd::text || ':' || polpermissive || ':' || polroles::text
                   || ':' || coalesce(pg_get_expr(polqual, polrelid), '') || ':' || coalesce(pg_get_expr(polwithcheck, polrelid), '')
    from pg_policy where polrelid = 'public.profiles'::regclass
  union all select 'trg:' || pg_get_triggerdef(t.oid) || ':' || t.tgenabled::text || ':' || md5(pg_get_functiondef(t.tgfoid))
    from pg_trigger t where t.tgrelid = 'public.profiles'::regclass and not t.tgisinternal
  union all select 'acl:' || a.grantee::regrole || '/' || a.grantor::regrole || '/' || a.privilege_type || '/' || a.is_grantable
    from pg_class c, aclexplode(c.relacl) a
   where c.oid = 'public.profiles'::regclass and a.grantee <> 0
     and a.grantee not in (to_regrole('anon'), to_regrole('authenticated'))
) s;
