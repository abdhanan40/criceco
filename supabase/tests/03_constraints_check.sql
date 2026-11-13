-- CricEco · constraints, triggers and save_profile_setup() edge cases.
-- One transaction, ROLLED BACK at the end: no data is kept.
-- Uses one test user (replace USER_A with its UUID; the user must not have
-- completed Profile Setup yet — a freshly created test user is ideal).
-- Every check raises on failure, so reaching "ALL CONSTRAINT CHECKS PASSED"
-- means all passed.
--
-- Run the WHOLE script at once — never a highlighted part. If it stops with
-- an error, run `rollback;` on its own before anything else.
-- Safety: every block first checks it is running as the signed-in test user
-- (it stops otherwise), and every write names USER_A's rows explicitly, so
-- no other profile can be touched even if the role switch did not happen.

begin;

select set_config('request.jwt.claims',
  json_build_object('sub', 'USER_A', 'role', 'authenticated')::text, true);
set local role authenticated;

-- ---------------------------------------------------------------------------
-- player_profiles: role rules and allowed values
-- ---------------------------------------------------------------------------
do $$
declare
  bad record;
begin
  if current_user <> 'authenticated' or auth.uid() is distinct from 'USER_A'::uuid then
    raise exception 'UNSAFE: not running as test user USER_A — stopping (nothing written)';
  end if;

  for bad in
    select * from (values
      ('batsman without batting style',    'batsman',     null,           null,             false),
      ('batsman with bowling style',       'batsman',     'right_handed', 'right_arm_fast', false),
      ('bowler without bowling style',     'bowler',      null,           null,             false),
      ('bowler with batting style',        'bowler',      'left_handed',  'left_arm_fast',  false),
      ('all-rounder without bowling',      'all_rounder', 'right_handed', null,             false),
      ('all-rounder without batting',      'all_rounder', null,           'left_arm_orthodox', false),
      ('bowler as wicket keeper',          'bowler',      null,           'right_arm_fast', true),
      ('all-rounder as wicket keeper',     'all_rounder', 'right_handed', 'right_arm_fast', true),
      ('"wicketkeeper" as a role',         'wicketkeeper', 'right_handed', null,            false),
      ('ERD label "Right-hand"',           'batsman',     'Right-hand',   null,             false),
      ('unknown bowling style',            'bowler',      null,           'spin',           false)
    ) as t(label, role, bat, bowl, wk)
  loop
    begin
      insert into public.player_profiles (user_id, player_role, batting_style, bowling_style, is_wicketkeeper)
      values ('USER_A', bad.role, bad.bat, bad.bowl, bad.wk);
      raise exception 'FAIL: accepted %', bad.label;
    exception when check_violation then
      null; -- rejected, as expected
    end;
  end loop;
  raise notice 'PASS: 11 invalid player profiles rejected';

  -- Valid: Batsman + wicket keeper, then a role change to All-Rounder.
  insert into public.player_profiles (user_id, player_role, batting_style, is_wicketkeeper)
  values ('USER_A', 'batsman', 'right_handed', true);
  update public.player_profiles
     set player_role = 'all_rounder', bowling_style = 'right_arm_off_spin', is_wicketkeeper = false
   where user_id = 'USER_A';
  begin
    insert into public.player_profiles (user_id, player_role, batting_style) values ('USER_A', 'batsman', 'left_handed');
    raise exception 'FAIL: a second player profile was accepted';
  exception when unique_violation then
    null;
  end;
  raise notice 'PASS: valid profile, role change and one-per-user';
end $$;

-- ---------------------------------------------------------------------------
-- profiles: direct writes (outside save_profile_setup)
-- ---------------------------------------------------------------------------
do $$
declare
  v_created timestamptz;
  v_updated timestamptz;
begin
  if current_user <> 'authenticated' or auth.uid() is distinct from 'USER_A'::uuid then
    raise exception 'UNSAFE: not running as test user USER_A — stopping (nothing written)';
  end if;

  -- Always enforced (migration 1: trigger + CHECK on the new column).
  begin update public.profiles set date_of_birth = current_date + 1 where id = 'USER_A';
        raise exception 'FAIL: future date of birth';
  exception when check_violation then null; end;
  begin update public.profiles set date_of_birth = date '1899-12-31' where id = 'USER_A';
        raise exception 'FAIL: date of birth before 1900';
  exception when check_violation then null; end;
  raise notice 'PASS: date of birth rules';

  -- Timestamps: created_at can't change; last_updated_at moves on update.
  -- (First successful update in this transaction: now() is fixed per
  -- transaction, so a later check could not see it move.)
  select created_at, last_updated_at into v_created, v_updated from public.profiles where id = 'USER_A';
  update public.profiles set role = 'player', created_at = timestamptz '2000-01-01' where id = 'USER_A';
  if (select created_at from public.profiles where id = 'USER_A') <> v_created then
    raise exception 'FAIL: created_at was changed';
  end if;
  if (select last_updated_at from public.profiles where id = 'USER_A') <= v_updated then
    raise exception 'FAIL: last_updated_at did not move';
  end if;
  raise notice 'PASS: created_at fixed, last_updated_at refreshed';

  -- A fresh profile can't be marked completed directly (nothing saved yet).
  begin update public.profiles set profile_completed = true where id = 'USER_A';
        raise exception 'FAIL: fresh profile marked completed without data';
  exception when check_violation then null; end;
  raise notice 'PASS: fresh profile can''t be marked completed directly';

  -- Field CHECKs on existing columns come from the review migration.
  if exists (select 1 from pg_constraint
             where conrelid = 'public.profiles'::regclass and conname = 'profiles_phone_check') then
    -- Legacy spellings stay valid (so legacy rows remain editable)…
    update public.profiles set phone = '0300 1234567' where id = 'USER_A';
    update public.profiles set phone = '03001234567' where id = 'USER_A';
    -- …anything that isn't a Pakistani mobile number does not.
    begin update public.profiles set phone = '+15551234567' where id = 'USER_A';
          raise exception 'FAIL: non-Pakistani phone stored directly';
    exception when check_violation then null; end;
    begin update public.profiles set phone = 'not a phone' where id = 'USER_A';
          raise exception 'FAIL: text stored as phone';
    exception when check_violation then null; end;
    raise notice 'PASS: phone rule (review A) accepts legacy spellings, rejects others';
  else
    raise notice 'SKIP: profiles_phone_check not applied (review migration pending)';
  end if;
  if exists (select 1 from pg_constraint
             where conrelid = 'public.profiles'::regclass and conname = 'profiles_full_name_check') then
    begin update public.profiles set full_name = 'A' where id = 'USER_A';
          raise exception 'FAIL: 1-character name';
    exception when check_violation then null; end;
    begin update public.profiles set full_name = repeat('x', 101) where id = 'USER_A';
          raise exception 'FAIL: 101-character name';
    exception when check_violation then null; end;
    raise notice 'PASS: name rule (review A)';
  else
    raise notice 'SKIP: profiles_full_name_check not applied';
  end if;
  if exists (select 1 from pg_constraint
             where conrelid = 'public.profiles'::regclass and conname = 'profiles_role_check') then
    begin update public.profiles set role = 'admin' where id = 'USER_A';
          raise exception 'FAIL: unknown role';
    exception when check_violation then null; end;
    raise notice 'PASS: role rule (review A)';
  else
    raise notice 'SKIP: profiles_role_check not applied';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- save_profile_setup(): phone normalisation, all-or-nothing, same-as-current
-- ---------------------------------------------------------------------------
do $$
declare
  v_phone text;
  ok      text;
begin
  if current_user <> 'authenticated' or auth.uid() is distinct from 'USER_A'::uuid then
    raise exception 'UNSAFE: not running as test user USER_A — stopping (nothing written)';
  end if;

  -- Missing permanent address under "No": the whole call fails and nothing
  -- of it is kept (no profile details, no current address, not completed).
  begin
    perform public.save_profile_setup('Test User A', '0300 1234567', date '2000-05-01',
      'Lahore', 'Gulberg', 'House 1', false);
    raise exception 'FAIL: saved without a permanent address under "No"';
  exception when not_null_violation then null; end;
  if exists (select 1 from public.current_addresses where user_id = 'USER_A')
     or (select profile_completed is true or full_name is not null
           from public.profiles where id = 'USER_A') then
    raise exception 'FAIL: a failed save left partial data';
  end if;
  raise notice 'PASS: a failed save keeps nothing (all-or-nothing)';

  -- Accepted phone spellings all become +923001234567.
  foreach ok in array array['0300 1234567', '0300-1234567', '03001234567',
                            '923001234567', '+92 300 1234567', '+923001234567'] loop
    perform public.save_profile_setup('Test User A', ok, date '2000-05-01',
      '  Lahore ', ' Gulberg ', ' House 1, Street 2 ', true);
    select phone into v_phone from public.profiles where id = 'USER_A';
    if v_phone is distinct from '+923001234567' then
      raise exception 'FAIL: phone "%" stored as "%"', ok, v_phone;
    end if;
  end loop;
  raise notice 'PASS: phone normalised from 6 spellings';

  -- Rejected phone spellings.
  foreach ok in array array['0300123', '+15551234567', '04001234567', 'phone'] loop
    begin
      perform public.save_profile_setup('Test User A', ok, date '2000-05-01',
        'Lahore', 'Gulberg', 'House 1', true);
      raise exception 'FAIL: phone "%" accepted', ok;
    exception when check_violation then null; end;
  end loop;
  raise notice 'PASS: 4 invalid phones rejected';

  -- Same as current: trimmed copy; re-saving updates in place (one row each).
  if (select (city, area, address) from public.permanent_addresses where user_id = 'USER_A')
     is distinct from (select (city, area, address) from public.current_addresses where user_id = 'USER_A')
     or (select city from public.permanent_addresses where user_id = 'USER_A') is distinct from 'Lahore'
     or (select count(*) from public.current_addresses where user_id = 'USER_A') <> 1
     or (select count(*) from public.permanent_addresses where user_id = 'USER_A') <> 1
     or (select profile_completed and permanent_same_as_current
           from public.profiles where id = 'USER_A') is not true then
    raise exception 'FAIL: same-as-current copy / upsert';
  end if;

  -- "No": a separate permanent address.
  perform public.save_profile_setup('Test User A', '0300 1234567', date '2000-05-01',
    'Lahore', 'Gulberg', 'House 1', false, 'Multan', 'Cantt', 'Street 9');
  if (select city from public.permanent_addresses where user_id = 'USER_A') is distinct from 'Multan'
     or (select permanent_same_as_current from public.profiles where id = 'USER_A') is not false then
    raise exception 'FAIL: separate permanent address';
  end if;
  raise notice 'PASS: same-as-current copy, separate permanent address, upsert in place';

  -- Later edits keep the profile completed (addresses exist).
  update public.profiles set full_name = 'Test User A Edited' where id = 'USER_A';
  if (select profile_completed from public.profiles where id = 'USER_A') is not true then
    raise exception 'FAIL: profile_completed lost on edit';
  end if;

  -- Address constraints.
  begin update public.current_addresses set area = '   ' where user_id = 'USER_A';
        raise exception 'FAIL: blank area';
  exception when check_violation then null; end;
  begin update public.current_addresses set address = repeat('x', 501) where user_id = 'USER_A';
        raise exception 'FAIL: 501-character address';
  exception when check_violation then null; end;
  begin insert into public.current_addresses (user_id, city, area, address) values ('USER_A', 'Lahore', 'DHA', 'x');
        raise exception 'FAIL: a second current address';
  exception when unique_violation then null; end;
  raise notice 'PASS: address constraints and one-per-user';
end $$;

-- (Printed only when still running as the test user, i.e. in one transaction.)
select 'ALL CONSTRAINT CHECKS PASSED' as result
where current_user = 'authenticated' and auth.uid() = 'USER_A'::uuid;

rollback;
