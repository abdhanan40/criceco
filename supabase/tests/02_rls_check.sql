-- CricEco · RLS behaviour check. Everything runs inside one transaction and
-- is ROLLED BACK at the end: no data is kept.
--
-- Before running: create two test users in Dashboard → Authentication →
-- Users → Add user (auto-confirm), copy their UUIDs into USER_A / USER_B
-- below (search-replace both placeholders).
-- Run the WHOLE script at once in the SQL Editor — never a highlighted part.
-- Each check prints a NOTICE; a failing check raises an exception and stops
-- the script. If it stops with an error, run `rollback;` on its own first.
-- Safety: every block first checks it is running as the expected role and
-- test user (it stops otherwise), and every write names the test user's rows
-- explicitly, so no other profile can be touched even if a role switch did
-- not happen.
-- Afterwards delete both test users (Authentication → Users): their profile
-- and address rows go with them (ON DELETE CASCADE), so nothing is left even
-- if the script stopped early.

begin;

-- ---- Act as USER_A (an authenticated user) ----
select set_config('request.jwt.claims',
  json_build_object('sub', 'USER_A', 'role', 'authenticated')::text, true);
set local role authenticated;

-- A can complete Profile Setup through the function (it writes only the
-- caller's rows: id / user_id = auth.uid()).
select public.save_profile_setup(
  'Test User A', '+923001234567', date '2000-05-01',
  'Lahore', 'Gulberg', 'House 1, Street 2',
  false, 'Multan', 'Cantt', 'Street 9');

do $$
begin
  if current_user <> 'authenticated' or auth.uid() is distinct from 'USER_A'::uuid then
    raise exception 'UNSAFE: not running as test user USER_A — stopping (nothing written)';
  end if;
  if (select count(*) from public.profiles) <> 1 then
    raise exception 'FAIL: A should see exactly 1 profile (their own)';
  end if;
  if (select permanent_same_as_current from public.profiles where id = 'USER_A') is not false then
    raise exception 'FAIL: same-as-current should be false';
  end if;
  if (select city from public.permanent_addresses where user_id = 'USER_A') is distinct from 'Multan' then
    raise exception 'FAIL: separate permanent address not saved';
  end if;
  raise notice 'PASS: A sees and saves only their own rows';
end $$;

-- A can add a player profile; a Bowler with a batting style is rejected.
do $$
begin
  if current_user <> 'authenticated' or auth.uid() is distinct from 'USER_A'::uuid then
    raise exception 'UNSAFE: not running as test user USER_A — stopping (nothing written)';
  end if;
  insert into public.player_profiles (user_id, player_role, bowling_style)
  values ('USER_A', 'bowler', 'right_arm_fast');
  begin
    update public.player_profiles set batting_style = 'right_handed' where user_id = 'USER_A';
    raise exception 'FAIL: a Bowler accepted a batting style';
  exception when check_violation then
    raise notice 'PASS: role rules enforced (Bowler has no batting style)';
  end;
end $$;

-- A cannot write a row for B.
do $$
begin
  if current_user <> 'authenticated' or auth.uid() is distinct from 'USER_A'::uuid then
    raise exception 'UNSAFE: not running as test user USER_A — stopping (nothing written)';
  end if;
  begin
    insert into public.current_addresses (user_id, city, area, address)
    values ('USER_B', 'Karachi', 'Clifton', 'x');
    raise exception 'FAIL: A wrote an address for B';
  exception when insufficient_privilege then
    raise notice 'PASS: A cannot write rows for another user';
  end;
  begin
    update public.current_addresses set user_id = 'USER_B' where user_id = 'USER_A';
    raise exception 'FAIL: A moved their address to B';
  exception when insufficient_privilege then
    raise notice 'PASS: A cannot hand a row to another user';
  end;
end $$;

-- ---- Act as USER_B ----
reset role;
select set_config('request.jwt.claims',
  json_build_object('sub', 'USER_B', 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
begin
  if current_user <> 'authenticated' or auth.uid() is distinct from 'USER_B'::uuid then
    raise exception 'UNSAFE: not running as test user USER_B — stopping (nothing written)';
  end if;
  if exists (select 1 from public.current_addresses where user_id = 'USER_A') then
    raise exception 'FAIL: B can read A''s address';
  end if;
  update public.profiles set full_name = 'Hacked' where id = 'USER_A';
  if found then raise exception 'FAIL: B updated A''s profile'; end if;
  raise notice 'PASS: B can neither read nor change A''s rows';
end $$;

-- B can't mark the profile completed directly (no addresses yet).
do $$
begin
  if current_user <> 'authenticated' or auth.uid() is distinct from 'USER_B'::uuid then
    raise exception 'UNSAFE: not running as test user USER_B — stopping (nothing written)';
  end if;
  begin
    update public.profiles
       set full_name = 'Test User B', phone = '+923331112223', date_of_birth = date '1999-01-01',
           profile_completed = true
     where id = 'USER_B';
    raise exception 'FAIL: completed without addresses';
  exception when check_violation then
    raise notice 'PASS: profile_completed needs both addresses';
  end;
end $$;

-- B saves their own Profile Setup — with the phone as the app shows it.
select public.save_profile_setup(
  'Test User B', '0333 1112223', date '1999-01-01',
  'Karachi', 'Clifton', 'Flat 4, Block 5',
  true);

-- ---- As the database owner: B's save touched only B's rows (read-only) ----
reset role;
do $$
begin
  if (select full_name from public.profiles where id = 'USER_A') is distinct from 'Test User A'
     or (select city from public.current_addresses where user_id = 'USER_A') is distinct from 'Lahore'
     or (select city from public.permanent_addresses where user_id = 'USER_A') is distinct from 'Multan' then
    raise exception 'FAIL: B''s save changed A''s data';
  end if;
  if (select phone from public.profiles where id = 'USER_B') is distinct from '+923331112223'
     or (select profile_completed from public.profiles where id = 'USER_B') is not true
     or (select city from public.permanent_addresses where user_id = 'USER_B') is distinct from 'Karachi' then
    raise exception 'FAIL: B''s save (phone normalised, same-as-current copy) is wrong';
  end if;
  raise notice 'PASS: save_profile_setup writes only the caller''s rows';
end $$;

-- ---- Anonymous (signed out): no user id in the request, as in a real call ----
select set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
set local role anon;
do $$
begin
  if current_user <> 'anon' or auth.uid() is not null then
    raise exception 'UNSAFE: not running as anon — stopping (nothing written)';
  end if;
  -- No grant (after review section B) or no visible rows (RLS) both pass.
  begin
    if exists (select 1 from public.profiles) then
      raise exception 'FAIL: anon can read profiles';
    end if;
    raise notice 'PASS: anon sees no profiles (RLS)';
  exception when insufficient_privilege then
    raise notice 'PASS: anon has no table access';
  end;
  begin
    if exists (select 1 from public.current_addresses) then
      raise exception 'FAIL: anon can read addresses';
    end if;
    raise exception 'FAIL: anon has a grant on current_addresses';
  exception when insufficient_privilege then
    raise notice 'PASS: anon has no access to the new tables';
  end;
  -- (The function's own "not authenticated" error has the same code, so the
  -- grant itself is checked too.)
  if has_function_privilege('public.save_profile_setup(text, text, date, text, text, text, boolean, text, text, text)',
                            'execute') then
    raise exception 'FAIL: anon holds EXECUTE on save_profile_setup';
  end if;
  begin
    perform public.save_profile_setup('X', '+923001234567', date '2000-01-01', 'Lahore', 'Gulberg', 'x', true);
    raise exception 'FAIL: anon can call save_profile_setup';
  exception when insufficient_privilege then
    raise notice 'PASS: anon cannot call save_profile_setup';
  end;
end $$;

-- Reaching this line means every check above passed (any failure stops the
-- script with an error).
-- (Printed only when still in the transaction's last step, as anon.)
select 'ALL RLS CHECKS PASSED' as result
where current_user = 'anon';

rollback;
