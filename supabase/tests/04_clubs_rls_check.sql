-- CricEco · clubs: RLS, grants, create_club() and role precedence.
-- Everything runs inside one transaction and is ROLLED BACK at the end: no
-- data is kept. Run after migration 5 (20261109090000_create_clubs.sql).
--
-- Before running: create two FRESH test users (Profile Setup not done) in
-- Dashboard → Authentication → Users → Add user (auto-confirm), copy their
-- UUIDs into USER_A / USER_B below (search-replace both placeholders).
-- Run the WHOLE script at once in the SQL Editor — never a highlighted part.
-- Each check prints a NOTICE; a failing check raises an exception and stops
-- the script. If it stops with an error, run `rollback;` on its own first.
-- Safety: every block first checks it is running as the expected role and
-- test user (it stops otherwise), and every write names the test users' rows
-- explicitly, so no other profile or club can be touched.
-- Afterwards delete both test users (Authentication → Users): their profile,
-- address and club rows go with them (ON DELETE CASCADE).

begin;

-- ---- As the database owner: catalog checks (read-only) ----
do $$
begin
  if not (select relrowsecurity from pg_class where oid = 'public.clubs'::regclass) then
    raise exception 'FAIL: RLS is not enabled on clubs';
  end if;
  if has_table_privilege('anon', 'public.clubs', 'select')
     or has_table_privilege('anon', 'public.clubs', 'insert')
     or has_table_privilege('anon', 'public.clubs', 'update')
     or has_table_privilege('anon', 'public.clubs', 'delete') then
    raise exception 'FAIL: anon holds a privilege on clubs';
  end if;
  if has_table_privilege('authenticated', 'public.clubs', 'delete')
     or has_table_privilege('authenticated', 'public.clubs', 'truncate') then
    raise exception 'FAIL: authenticated may delete / truncate clubs';
  end if;
  if has_column_privilege('authenticated', 'public.clubs', 'id', 'insert')
     or has_column_privilege('authenticated', 'public.clubs', 'code', 'insert')
     or has_column_privilege('authenticated', 'public.clubs', 'created_at', 'insert')
     or has_column_privilege('authenticated', 'public.clubs', 'last_updated_at', 'insert') then
    raise exception 'FAIL: authenticated may set id / code / timestamps on insert';
  end if;
  if has_column_privilege('authenticated', 'public.clubs', 'id', 'update')
     or has_column_privilege('authenticated', 'public.clubs', 'owner_id', 'update')
     or has_column_privilege('authenticated', 'public.clubs', 'code', 'update')
     or has_column_privilege('authenticated', 'public.clubs', 'created_at', 'update')
     or has_column_privilege('authenticated', 'public.clubs', 'last_updated_at', 'update') then
    raise exception 'FAIL: authenticated may change id / owner_id / code / timestamps';
  end if;
  if (select prosecdef from pg_proc where oid = 'public.create_club(text, text, text, text, text, text, text)'::regprocedure) then
    raise exception 'FAIL: create_club must be SECURITY INVOKER';
  end if;
  if has_function_privilege('anon', 'public.create_club(text, text, text, text, text, text, text)', 'execute') then
    raise exception 'FAIL: anon holds EXECUTE on create_club';
  end if;
  raise notice 'PASS: RLS on; no anon access; protected columns not writable; create_club runs as the caller';
end $$;

-- ---- Act as USER_A (a fresh authenticated user) ----
select set_config('request.jwt.claims',
  json_build_object('sub', 'USER_A', 'role', 'authenticated')::text, true);
set local role authenticated;

-- A club needs a completed User Profile Setup — through the function or not.
do $$
begin
  if current_user <> 'authenticated' or auth.uid() is distinct from 'USER_A'::uuid then
    raise exception 'UNSAFE: not running as test user USER_A — stopping (nothing written)';
  end if;
  begin
    perform public.create_club('Test Club A', 'Lahore', 'corporate');
    raise exception 'FAIL: a club was created before Profile Setup';
  exception when check_violation then
    if sqlerrm not like 'profile_completed requires%' then raise; end if;
  end;
  begin
    insert into public.clubs (owner_id, name, city, club_type)
    values ('USER_A', 'Test Club A', 'Lahore', 'corporate');
    raise exception 'FAIL: a direct insert skipped the Profile Setup rule';
  exception when check_violation then
    if sqlerrm not like 'profile_completed requires%' then raise; end if;
  end;
  raise notice 'PASS: no club before User Profile Setup is complete';
end $$;

select public.save_profile_setup(
  'Test User A', '+923001234567', date '2000-05-01',
  'Lahore', 'Gulberg', 'House 1, Street 2',
  true);

-- A creates a club: own row, generated code, role NULL → club_owner.
do $$
declare
  c public.clubs;
begin
  if current_user <> 'authenticated' or auth.uid() is distinct from 'USER_A'::uuid then
    raise exception 'UNSAFE: not running as test user USER_A — stopping (nothing written)';
  end if;
  if (select role from public.profiles where id = 'USER_A') is not null then
    raise exception 'FAIL: test needs a fresh USER_A (role must start NULL)';
  end if;
  c := public.create_club('  Test Club A  ', 'Lahore', 'corporate',
                          'Test User A', 'Mian Mir Road', '', 'g_pindi');
  if c.owner_id is distinct from 'USER_A'::uuid then raise exception 'FAIL: wrong owner'; end if;
  if c.name <> 'Test Club A' or c.city <> 'Lahore' or c.club_type <> 'corporate' then
    raise exception 'FAIL: club values not stored (trimmed)';
  end if;
  if c.code !~ '^[A-HJ-NP-Z2-9]{6}$' then
    raise exception 'FAIL: join code % is not 6 characters from the code alphabet', c.code;
  end if;
  if c.email is not null or c.short_name is not null or c.home_ground_id <> 'g_pindi'
     or c.established_year <> extract(year from now())::smallint then
    raise exception 'FAIL: optional values / defaults are wrong';
  end if;
  if (select role from public.profiles where id = 'USER_A') is distinct from 'club_owner' then
    raise exception 'FAIL: role NULL did not become club_owner';
  end if;
  if (select count(*) from public.clubs) <> 1 then
    raise exception 'FAIL: A should see exactly 1 club (their own)';
  end if;
  raise notice 'PASS: create_club stores the club, a generated code and role = club_owner';
end $$;

-- Retrying returns the same club unchanged: never a second club.
do $$
declare
  first  public.clubs;
  second public.clubs;
begin
  if current_user <> 'authenticated' or auth.uid() is distinct from 'USER_A'::uuid then
    raise exception 'UNSAFE: not running as test user USER_A — stopping (nothing written)';
  end if;
  select * into strict first from public.clubs where owner_id = 'USER_A';
  second := public.create_club('Another Name', 'Karachi', 'professional');
  if second.id <> first.id or second.code <> first.code or second.name <> 'Test Club A' then
    raise exception 'FAIL: a retry changed or replaced the club';
  end if;
  if (select count(*) from public.clubs where owner_id = 'USER_A') <> 1 then
    raise exception 'FAIL: a retry created a second club';
  end if;
  begin
    insert into public.clubs (owner_id, name, city, club_type)
    values ('USER_A', 'Second Club', 'Lahore', 'corporate');
    raise exception 'FAIL: a second club for the same owner was accepted';
  exception when unique_violation then
    null;
  end;
  raise notice 'PASS: one club per owner; a retry returns the existing club';
end $$;

-- A edits the editable columns; protected ones can't change; no delete.
do $$
begin
  if current_user <> 'authenticated' or auth.uid() is distinct from 'USER_A'::uuid then
    raise exception 'UNSAFE: not running as test user USER_A — stopping (nothing written)';
  end if;
  update public.clubs
     set name = 'Test Club A Renamed', email = 'club@example.com', established_year = 2001
   where owner_id = 'USER_A';
  if not found then raise exception 'FAIL: A could not update their own club'; end if;

  begin
    update public.clubs set owner_id = 'USER_B' where owner_id = 'USER_A';
    raise exception 'FAIL: owner_id was changed';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.clubs set code = 'AAAAAA' where owner_id = 'USER_A';
    raise exception 'FAIL: code was changed';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.clubs set created_at = now() - interval '1 day' where owner_id = 'USER_A';
    raise exception 'FAIL: created_at was changed';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.clubs set last_updated_at = now() - interval '1 day' where owner_id = 'USER_A';
    raise exception 'FAIL: last_updated_at was changed';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.clubs set id = gen_random_uuid() where owner_id = 'USER_A';
    raise exception 'FAIL: id was changed';
  exception when insufficient_privilege then null;
  end;
  begin
    delete from public.clubs where owner_id = 'USER_A';
    raise exception 'FAIL: A could delete the club';
  exception when insufficient_privilege then null;
  end;
  -- A code sent with an insert is never used (and not even allowed).
  begin
    insert into public.clubs (owner_id, name, city, club_type, code)
    values ('USER_A', 'X', 'Lahore', 'corporate', 'AAAAAA');
    raise exception 'FAIL: a client-chosen code was accepted';
  exception when insufficient_privilege then null;
  end;
  raise notice 'PASS: editable columns update; id / owner_id / code / timestamps protected; no delete';
end $$;

-- A Player save never overwrites club_owner (the app's setRoleIfUnset rule).
do $$
begin
  if current_user <> 'authenticated' or auth.uid() is distinct from 'USER_A'::uuid then
    raise exception 'UNSAFE: not running as test user USER_A — stopping (nothing written)';
  end if;
  update public.profiles set role = 'player' where id = 'USER_A' and role is null;
  perform public.create_club('Test Club A', 'Lahore', 'corporate');
  if (select role from public.profiles where id = 'USER_A') is distinct from 'club_owner' then
    raise exception 'FAIL: club_owner was downgraded';
  end if;
  raise notice 'PASS: club_owner is never downgraded';
end $$;

-- ---- Act as USER_B ----
reset role;
select set_config('request.jwt.claims',
  json_build_object('sub', 'USER_B', 'role', 'authenticated')::text, true);
set local role authenticated;

-- B can neither see nor change A's club, nor create one in A's name.
do $$
begin
  if current_user <> 'authenticated' or auth.uid() is distinct from 'USER_B'::uuid then
    raise exception 'UNSAFE: not running as test user USER_B — stopping (nothing written)';
  end if;
  if exists (select 1 from public.clubs) then
    raise exception 'FAIL: B can see another owner''s club';
  end if;
  update public.clubs set name = 'Hacked' where owner_id = 'USER_A';
  if found then raise exception 'FAIL: B updated A''s club'; end if;
  begin
    insert into public.clubs (owner_id, name, city, club_type)
    values ('USER_A', 'Hijack', 'Lahore', 'corporate');
    raise exception 'FAIL: B created a club owned by A';
  exception
    when insufficient_privilege or check_violation or unique_violation then null;
  end;
  raise notice 'PASS: B can neither read nor change A''s club, nor create one for A';
end $$;

-- B: a Player (role = player) who then creates a club → club_owner (D-C1).
select public.save_profile_setup(
  'Test User B', '0333 1112223', date '1999-01-01',
  'Karachi', 'Clifton', 'Flat 4, Block 5',
  true);

do $$
declare
  c public.clubs;
begin
  if current_user <> 'authenticated' or auth.uid() is distinct from 'USER_B'::uuid then
    raise exception 'UNSAFE: not running as test user USER_B — stopping (nothing written)';
  end if;
  update public.profiles set role = 'player' where id = 'USER_B' and role is null;
  if (select role from public.profiles where id = 'USER_B') is distinct from 'player' then
    raise exception 'FAIL: test needs a fresh USER_B (role must start NULL)';
  end if;
  c := public.create_club('Test Club B', 'Karachi', 'professional');
  if (select role from public.profiles where id = 'USER_B') is distinct from 'club_owner' then
    raise exception 'FAIL: role player did not become club_owner';
  end if;
  if (select count(*) from public.clubs) <> 1 or c.owner_id is distinct from 'USER_B'::uuid then
    raise exception 'FAIL: B should see exactly their own club';
  end if;
  raise notice 'PASS: player → club_owner when a Player creates a club; B sees only B''s club';
end $$;

-- ---- As the database owner: nothing leaked across owners (read-only) ----
reset role;
do $$
begin
  if (select name from public.clubs where owner_id = 'USER_A') is distinct from 'Test Club A Renamed'
     or (select email from public.clubs where owner_id = 'USER_A') is distinct from 'club@example.com' then
    raise exception 'FAIL: A''s club was changed by someone else (or A''s edit was lost)';
  end if;
  if (select count(*) from public.clubs where owner_id in ('USER_A', 'USER_B')) <> 2 then
    raise exception 'FAIL: expected exactly one club per test user';
  end if;
  if (select count(distinct code) from public.clubs where owner_id in ('USER_A', 'USER_B')) <> 2 then
    raise exception 'FAIL: two clubs share a join code';
  end if;
  raise notice 'PASS: each owner has exactly one club with its own code';
end $$;

-- ---- Signed in without a user id: refused ----
select set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, true);
set local role authenticated;
do $$
begin
  if current_user <> 'authenticated' or auth.uid() is not null then
    raise exception 'UNSAFE: expected an authenticated request without a user id — stopping';
  end if;
  begin
    perform public.create_club('X Club', 'Lahore', 'corporate');
    raise exception 'FAIL: create_club ran without a signed-in user';
  exception when insufficient_privilege then
    if sqlerrm <> 'not authenticated' then raise; end if;
  end;
  raise notice 'PASS: create_club needs a signed-in user';
end $$;

-- ---- Anonymous (signed out): no access at all ----
reset role;
select set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
set local role anon;
do $$
begin
  if current_user <> 'anon' or auth.uid() is not null then
    raise exception 'UNSAFE: not running as anon — stopping (nothing written)';
  end if;
  begin
    perform 1 from public.clubs;
    raise exception 'FAIL: anon can read clubs';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.create_club('X Club', 'Lahore', 'corporate');
    raise exception 'FAIL: anon can call create_club';
  exception when insufficient_privilege then null;
  end;
  raise notice 'PASS: anon can neither read clubs nor call create_club';
end $$;

-- Reaching this line means every check above passed (any failure stops the
-- script with an error).
select 'ALL CLUBS RLS CHECKS PASSED' as result
where current_user = 'anon';

rollback;
