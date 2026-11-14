-- CricEco · migration 10 (least-privilege grants on public.profiles): the
-- privileges, and that signed-in users can still do everything the app
-- does. Everything runs inside one transaction and is ROLLED BACK at the
-- end: no data is kept. Run after migration 10 (with or without 6–9).
--
-- PART 1 (catalog) is read-only and needs no test user. PART 2 needs ONE
-- FRESH test user (Profile Setup not done): create it in Dashboard →
-- Authentication → Users → Add user (auto-confirm) and search-replace
-- USER_A below with its UUID. It is checked to be fresh (the sign-up
-- trigger's bare profile: no name, Profile Setup not done, no address rows)
-- before anything is written. Afterwards delete the test user.
-- Excess privileges (DELETE, TRUNCATE, …) are checked in the catalog only —
-- never attempted here: on a database without migration 10 the attempt
-- itself would be the danger. tests/local/09 attempts them, locally.
-- Run the WHOLE script at once; after a failing check run `rollback;` on
-- its own.

begin;

-- ===================== PART 1 — as the database owner (read-only) =====================
do $$
declare
  t constant regclass := 'public.profiles'::regclass;
  privs text[] := array['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER'];
  p text;
begin
  if current_setting('server_version_num')::int >= 170000 then
    privs := array_append(privs, 'MAINTAIN');
  end if;
  foreach p in array privs loop
    if has_table_privilege('anon', t, p) then
      raise exception 'FAIL G1: anon holds % on profiles', p;
    end if;
    if has_table_privilege('public', t, p) then
      raise exception 'FAIL G2: PUBLIC holds % on profiles', p;
    end if;
    if has_table_privilege('authenticated', t, p) <> (p in ('SELECT', 'INSERT', 'UPDATE')) then
      raise exception 'FAIL G3: authenticated % on profiles is not as intended (SELECT / INSERT / UPDATE only)', p;
    end if;
  end loop;
  raise notice 'PASS G1–G3: anon and PUBLIC hold nothing; authenticated exactly SELECT / INSERT / UPDATE (direct, PUBLIC and inherited grants counted)';

  if exists (select 1 from pg_attribute a, aclexplode(a.attacl) x
              where a.attrelid = t and a.attnum > 0 and not a.attisdropped
                and (x.grantee = 0 or x.grantee in (to_regrole('anon'), to_regrole('authenticated')))) then
    raise exception 'FAIL G4: a column-level grant on profiles for anon / authenticated / PUBLIC';
  end if;
  if exists (select 1 from aclexplode((select relacl from pg_class where oid = t)) x
              where x.grantee = to_regrole('authenticated') and x.is_grantable) then
    raise exception 'FAIL G4: authenticated holds a grant option on profiles';
  end if;
  raise notice 'PASS G4: no column-level grants, no grant option';

  if not (has_table_privilege('service_role', t, 'SELECT') and has_table_privilege('service_role', t, 'INSERT')
          and has_table_privilege('service_role', t, 'UPDATE') and has_table_privilege('service_role', t, 'DELETE')) then
    raise exception 'FAIL G5: service_role lost a privilege on profiles';
  end if;
  raise notice 'PASS G5: service_role keeps its privileges (compare result "profiles_fingerprint" with 00h)';

  if not (select relrowsecurity from pg_class where oid = t) then
    raise exception 'FAIL G6: row level security is not enabled on profiles';
  end if;
  if (select count(distinct p.polcmd) from pg_policy p
       where p.polrelid = t and p.polcmd in ('r', 'a', 'w')
         and (0::oid = any (p.polroles) or to_regrole('authenticated') = any (p.polroles))) <> 3 then
    raise exception 'FAIL G6: the own-row SELECT / INSERT / UPDATE policies are not all there';
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'on_auth_user_created'
                  and tgrelid = 'auth.users'::regclass and tgenabled <> 'D') then
    raise exception 'FAIL G6: the sign-up trigger on auth.users is missing or disabled';
  end if;
  if not has_function_privilege('authenticated',
           'public.save_profile_setup(text, text, date, text, text, text, boolean, text, text, text)', 'execute') then
    raise exception 'FAIL G6: authenticated lost EXECUTE on save_profile_setup';
  end if;
  raise notice 'PASS G6: RLS on, the own-row policies, the sign-up trigger and save_profile_setup''s privilege as before';
end $$;

-- The fingerprint of everything migration 10 must not change — the SAME
-- query as result 8 of 00h_preflight_profiles_grants.sql; the two values
-- must be equal.
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

-- The test user must be fresh (checked as the owner, before anything is written).
do $$
begin
  if not exists (select 1 from public.profiles where id = 'USER_A'::uuid
                  and full_name is null and not coalesce(profile_completed, false))
     or exists (select 1 from public.current_addresses where user_id = 'USER_A'::uuid)
     or exists (select 1 from public.permanent_addresses where user_id = 'USER_A'::uuid) then
    raise exception 'UNSAFE: USER_A is not a fresh test user (bare profile, no rows) — stopping (nothing written)';
  end if;
end $$;

-- ===================== PART 2 — as the signed-in test user (rolled back) =====================
select set_config('request.jwt.claims',
                  json_build_object('sub', 'USER_A', 'role', 'authenticated')::text, true);
set local role authenticated;
do $$
declare
  n int;
  v_uid uuid := 'USER_A'::uuid;
begin
  if current_user <> 'authenticated' or auth.uid() is distinct from v_uid then
    raise exception 'UNSAFE: not running as the test user — stopping';
  end if;
  -- The app's account read.
  select count(*) into n from public.profiles where id = v_uid;
  if n <> 1 then raise exception 'FAIL B1: the own profile row is not readable'; end if;
  select count(*) into n from public.profiles;
  if n <> 1 then raise exception 'FAIL B1: another profile is visible (RLS)'; end if;
  raise notice 'PASS B1: SELECT of the own row (and only it)';

  -- Profile Setup: save_profile_setup (SECURITY INVOKER) inserts / updates
  -- profiles and writes both address rows.
  perform public.save_profile_setup(
    p_full_name => 'Grant Check', p_phone => '03001234567', p_date_of_birth => date '2000-05-01',
    p_current_city => 'Lahore', p_current_area => 'Gulberg', p_current_address => 'Street 1',
    p_permanent_same_as_current => true, p_permanent_city => null, p_permanent_area => null,
    p_permanent_address => null);
  if not exists (select 1 from public.profiles where id = v_uid and full_name = 'Grant Check' and profile_completed) then
    raise exception 'FAIL B2: save_profile_setup did not save the profile';
  end if;
  raise notice 'PASS B2: save_profile_setup (INSERT … ON CONFLICT DO UPDATE on profiles) works';

  -- The app's direct role update (setRoleIfUnset) and an own-row update.
  update public.profiles set role = 'player' where id = v_uid and role is null;
  get diagnostics n = row_count;
  if n <> 1 then raise exception 'FAIL B3: the direct role update changed % rows', n; end if;
  update public.profiles set full_name = 'Grant Check Two' where id = v_uid;
  get diagnostics n = row_count;
  if n <> 1 then raise exception 'FAIL B3: the own-row update changed % rows', n; end if;
  raise notice 'PASS B3: UPDATE of the own row (role, full name)';

  -- Migration 9's row lock (FOR NO KEY UPDATE needs UPDATE).
  perform 1 from public.profiles where id = v_uid for no key update;
  raise notice 'PASS B4: SELECT … FOR NO KEY UPDATE on the own row';

  -- Migration 9 itself, when applied.
  if to_regprocedure('public.update_profile_details(text, text, date, text, integer, text, text, text, integer, text, text)') is not null then
    execute 'select public.update_profile_details(p_full_name => $1, p_phone => $2, p_date_of_birth => $3,
               p_current_city => null, p_current_city_id => null, p_current_area => null, p_current_address => null)'
      using 'Grant Check Three', '03001234567', date '2000-05-01';
    if not exists (select 1 from public.profiles where id = v_uid and full_name = 'Grant Check Three') then
      raise exception 'FAIL B5: update_profile_details did not save';
    end if;
    raise notice 'PASS B5: update_profile_details works';
  else
    raise notice 'SKIPPED B5: update_profile_details is not applied yet (run this test again after migration 9)';
  end if;
end $$;

-- ===================== Signed out: no access =====================
reset role;
select set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
set local role anon;
do $$
begin
  if current_user <> 'anon' or auth.uid() is not null then
    raise exception 'UNSAFE: not running as anon — stopping';
  end if;
  begin
    perform 1 from public.profiles;
    raise exception 'FAIL A1: anon can read profiles';
  exception when insufficient_privilege then null;
  end;
  raise notice 'PASS A1: anon has no access to profiles (42501)';
end $$;

reset role;
rollback;
