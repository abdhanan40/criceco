-- CricEco · LOCAL TEST ONLY — sign-up trigger and ON DELETE CASCADE.
-- Creates and deletes an auth user, so it refuses to run on a real Supabase
-- project (whose auth.users has an encrypted_password column). Rolled back.

do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password') then
    raise exception 'LOCAL ONLY: this looks like a real Supabase auth schema';
  end if;
end $$;

begin;

-- Sign-up as Supabase Auth does it: the auth role has no rights on
-- public.profiles, yet the trigger still creates the row.
do $$
begin
  if has_table_privilege('supabase_auth_admin', 'public.profiles', 'insert') then
    raise exception 'FAIL: test is meaningless — supabase_auth_admin can insert profiles directly';
  end if;
end $$;
set local role supabase_auth_admin;
insert into auth.users (id, email) values ('33333333-3333-4333-8333-333333333333', 'user-c@local.test');
reset role;

select set_config('request.jwt.claims',
  json_build_object('sub', '33333333-3333-4333-8333-333333333333', 'role', 'authenticated')::text, true);
set local role authenticated;
select public.save_profile_setup('Test User C', '0321 5550000', date '1998-03-03',
  'Karachi', 'Clifton', 'Flat 2', false, 'Hyderabad', 'Latifabad', 'House 7');
insert into public.player_profiles (player_role, bowling_style) values ('bowler', 'left_arm_fast');
reset role;

do $$
declare
  c uuid := '33333333-3333-4333-8333-333333333333';
begin
  if (select count(*) from public.profiles where id = c) <> 1
     or (select count(*) from public.current_addresses where user_id = c) <> 1
     or (select count(*) from public.permanent_addresses where user_id = c) <> 1
     or (select count(*) from public.player_profiles where user_id = c) <> 1 then
    raise exception 'FAIL: rows for C were not created';
  end if;
  raise notice 'PASS: sign-up trigger ran as supabase_auth_admin; C saved a full profile';
end $$;

-- Deleting the auth user removes everything of theirs.
set local role supabase_auth_admin;
delete from auth.users where id = '33333333-3333-4333-8333-333333333333';
reset role;

do $$
declare
  c uuid := '33333333-3333-4333-8333-333333333333';
begin
  if exists (select 1 from public.profiles where id = c)
     or exists (select 1 from public.current_addresses where user_id = c)
     or exists (select 1 from public.permanent_addresses where user_id = c)
     or exists (select 1 from public.player_profiles where user_id = c) then
    raise exception 'FAIL: rows survived deleting the auth user';
  end if;
  raise notice 'PASS: ON DELETE CASCADE removed profile, addresses and player profile';
end $$;

select 'ALL CASCADE CHECKS PASSED' as result;

rollback;
