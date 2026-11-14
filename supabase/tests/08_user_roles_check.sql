-- CricEco · user_roles (migration 7): schema, backfill, RLS, triggers.
-- Everything runs inside one transaction and is ROLLED BACK at the end: no
-- data is kept. Run after migration 7.
--
-- PART 1 (catalog + backfill) is read-only and needs no test users.
-- PART 2 needs two FRESH test users (Profile Setup not done, role NULL):
-- create them in Dashboard → Authentication → Users → Add user
-- (auto-confirm) and search-replace USER_A / USER_B below with their UUIDs.
-- Run the WHOLE script at once in the SQL Editor — never a highlighted part.
-- Each check prints a NOTICE; a failing check raises an exception and stops
-- the script. If it stops with an error, run `rollback;` on its own first.
-- Safety: every block in PART 2 first checks it is running as the expected
-- test user, and writes only that user's own rows.
-- Afterwards delete both test users (their rows go with them: ON DELETE CASCADE).

begin;

-- ===================== PART 1 — as the database owner (read-only) =====================
do $$
begin
  if to_regclass('public.user_roles') is null or to_regtype('public.app_role') is null then
    raise exception 'FAIL: user_roles / app_role missing';
  end if;
  if enum_range(null::public.app_role)::text <> '{player,club_owner,ground_owner,admin}' then
    raise exception 'FAIL: app_role values are %', enum_range(null::public.app_role);
  end if;
  if (select string_agg(a.attname, ',' order by k.ord)
        from pg_constraint c, unnest(c.conkey) with ordinality k(attnum, ord)
        join pg_attribute a on a.attrelid = 'public.user_roles'::regclass and a.attnum = k.attnum
       where c.conname = 'user_roles_pkey') <> 'user_id,role' then
    raise exception 'FAIL: primary key must be (user_id, role)';
  end if;
  if (select confdeltype from pg_constraint where conname = 'user_roles_user_id_fkey') <> 'c'
     or (select confdeltype from pg_constraint where conname = 'user_roles_granted_by_fkey') <> 'n'
     or (select confrelid from pg_constraint where conname = 'user_roles_user_id_fkey') <> 'public.profiles'::regclass then
    raise exception 'FAIL: user_roles foreign keys (user_id CASCADE, granted_by SET NULL, both → profiles)';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.user_roles'::regclass)
     or (select count(*) from pg_policies where schemaname = 'public' and tablename = 'user_roles') <> 1
     or not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'user_roles'
                       and policyname = 'user_roles: select own' and cmd = 'SELECT' and roles = '{authenticated}') then
    raise exception 'FAIL: RLS must be on with one policy: select own, to authenticated';
  end if;
  if has_table_privilege('anon', 'public.user_roles', 'select')
     or has_table_privilege('anon', 'public.user_roles', 'insert')
     or not has_table_privilege('authenticated', 'public.user_roles', 'select')
     or has_table_privilege('authenticated', 'public.user_roles', 'insert')
     or has_table_privilege('authenticated', 'public.user_roles', 'update')
     or has_table_privilege('authenticated', 'public.user_roles', 'delete')
     or has_table_privilege('authenticated', 'public.user_roles', 'truncate') then
    raise exception 'FAIL: privileges (anon none; authenticated SELECT only)';
  end if;
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.prosecdef and p.prorettype = 'trigger'::regtype
         and p.proname in ('player_profiles_grant_role', 'player_profiles_revoke_role',
                           'clubs_grant_owner_role', 'clubs_revoke_owner_role')) <> 4
     or (select count(*) from pg_trigger where not tgisinternal and tgname in ('player_profiles_grant_role',
          'player_profiles_revoke_role', 'clubs_grant_owner_role', 'clubs_revoke_owner_role')) <> 4 then
    raise exception 'FAIL: the 4 SECURITY DEFINER trigger functions and their triggers';
  end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname like '%role%' and p.prosecdef
                and p.proname in ('player_profiles_grant_role', 'clubs_grant_owner_role')
                and not ('search_path=""' = any (p.proconfig))) then
    raise exception 'FAIL: SECURITY DEFINER functions must pin search_path';
  end if;
  raise notice 'PASSED: type, keys, RLS, privileges, trigger functions';

  -- Backfill: exactly the rows, nothing from profiles.role.
  if exists (select 1 from public.player_profiles pp
              where not exists (select 1 from public.user_roles r where r.user_id = pp.user_id and r.role = 'player'))
     or exists (select 1 from public.clubs c
              where not exists (select 1 from public.user_roles r where r.user_id = c.owner_id and r.role = 'club_owner'))
     or exists (select 1 from public.user_roles r
              where (r.role = 'player' and not exists (select 1 from public.player_profiles pp where pp.user_id = r.user_id))
                 or (r.role = 'club_owner' and not exists (select 1 from public.clubs c where c.owner_id = r.user_id))
                 or r.role in ('ground_owner', 'admin')) then
    raise exception 'FAIL: user_roles must match player_profiles (player) and clubs (club_owner) exactly';
  end if;
  raise notice 'PASSED: roles match the data rows (% player, % club_owner)',
    (select count(*) from public.user_roles where role = 'player'),
    (select count(*) from public.user_roles where role = 'club_owner');
end $$;

-- ===================== PART 2 — as two fresh test users =====================
select set_config('request.jwt.claims', json_build_object('sub', 'USER_A', 'role', 'authenticated')::text, true);
set local role authenticated;

select public.save_profile_setup('Test User A', '+923001234567', date '2000-05-01',
  'Lahore', 'Gulberg', 'House 1, Street 2', true);

do $$
declare
  c1 public.clubs;
  c2 public.clubs;
begin
  if current_user <> 'authenticated' or auth.uid() is distinct from 'USER_A'::uuid then
    raise exception 'UNSAFE: not running as test user USER_A — stopping (nothing written)';
  end if;
  if exists (select 1 from public.user_roles) or (select role from public.profiles where id = 'USER_A') is not null then
    raise exception 'FAIL: test needs a fresh USER_A (no roles, profiles.role NULL)';
  end if;

  -- A player profile grants player.
  insert into public.player_profiles (user_id, player_role, batting_style, bowling_style)
  values ('USER_A', 'batsman', 'right_handed', null);
  if array(select r.role::text from public.user_roles r order by r.role) <> array['player'] then
    raise exception 'FAIL: saving a player profile must grant player';
  end if;
  update public.player_profiles set batting_style = 'left_handed' where user_id = 'USER_A';
  if (select count(*) from public.user_roles) <> 1 then
    raise exception 'FAIL: updating the player profile must not add roles';
  end if;
  raise notice 'PASSED: player profile → player';

  -- Creating a club grants club_owner; profiles.role behaves as before (→ club_owner).
  c1 := public.create_club('Test Club A', 'Lahore', 'corporate');
  if array(select r.role::text from public.user_roles r order by r.role) <> array['player', 'club_owner'] then
    raise exception 'FAIL: create_club must grant club_owner (player kept): %',
      array(select r.role::text from public.user_roles r order by r.role);
  end if;
  if (select role from public.profiles where id = 'USER_A') is distinct from 'club_owner' then
    raise exception 'FAIL: profiles.role must still become club_owner (backward compatibility)';
  end if;
  c2 := public.create_club('Another Name', 'Multan', 'professional');
  if c2.id <> c1.id or (select count(*) from public.user_roles) <> 2 then
    raise exception 'FAIL: create_club retry must return the same club and add no role';
  end if;
  raise notice 'PASSED: create_club → club_owner; retry unchanged; profiles.role unchanged behaviour';

  -- No writes to roles, for oneself or anyone.
  begin
    insert into public.user_roles (user_id, role) values ('USER_A', 'admin');
    raise exception 'FAIL: a user inserted a role';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.user_roles set role = 'admin' where user_id = 'USER_A';
    raise exception 'FAIL: a user changed a role';
  exception when insufficient_privilege then null;
  end;
  begin
    delete from public.user_roles where user_id = 'USER_A';
    raise exception 'FAIL: a user deleted a role';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.clubs_grant_owner_role();
    raise exception 'FAIL: a trigger function was callable';
  exception when feature_not_supported or insufficient_privilege or undefined_function then null;
  end;
  raise notice 'PASSED: no role writes; trigger functions not callable';
end $$;

reset role;
select set_config('request.jwt.claims', json_build_object('sub', 'USER_B', 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
begin
  if current_user <> 'authenticated' or auth.uid() is distinct from 'USER_B'::uuid then
    raise exception 'UNSAFE: not running as test user USER_B — stopping (nothing written)';
  end if;
  if exists (select 1 from public.user_roles) then
    raise exception 'FAIL: USER_B can see roles that are not theirs';
  end if;
  if exists (select 1 from public.user_roles where user_id = 'USER_A') then
    raise exception 'FAIL: USER_B can read USER_A''s roles';
  end if;
  raise notice 'PASSED: USER_B sees no one else''s roles';
end $$;

reset role;
set local role anon;
do $$
begin
  begin
    perform count(*) from public.user_roles;
    raise exception 'FAIL: anon read user_roles';
  exception when insufficient_privilege then null;
  end;
  raise notice 'PASSED: anon has no access';
end $$;
reset role;

do $$ begin raise notice 'ALL 08_user_roles_check CHECKS PASSED (rolling back)'; end $$;

rollback;
