-- CricEco · LOCAL TEST ONLY — how the 5 pre-existing profiles behave after
-- migrations 1–4 (and, when applied, review section A). Uses the ids from
-- 02_legacy_profiles_fixture.sql. One transaction, rolled back.

do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password') then
    raise exception 'LOCAL ONLY: this looks like a real Supabase auth schema';
  end if;
end $$;

begin;

-- 1. A new sign-up still gets a profile row (legacy columns NULL / default).
set local role supabase_auth_admin;
insert into auth.users (id, email) values ('b0000000-0000-4000-8000-000000000009', 'new@local.test');
reset role;
do $$
begin
  if not exists (select 1 from public.profiles
                 where id = 'b0000000-0000-4000-8000-000000000009'
                   and role is null and profile_completed is not true and full_name is null) then
    raise exception 'FAIL: sign-up did not create an empty profile';
  end if;
  raise notice 'PASS: sign-up trigger works alongside the legacy columns';
end $$;

-- 2. Legacy completed rows stay editable as they are: Owner Two (phone
--    "0312 9020000", no date of birth, no addresses) and the completed
--    player WITHOUT a name.
select set_config('request.jwt.claims',
  json_build_object('sub', 'a0000000-0000-4000-8000-000000000002', 'role', 'authenticated')::text, true);
set local role authenticated;
update public.profiles set full_name = 'Owner Two Edited';
reset role;
select set_config('request.jwt.claims',
  json_build_object('sub', 'a0000000-0000-4000-8000-000000000004', 'role', 'authenticated')::text, true);
set local role authenticated;
update public.profiles set role = 'player';
reset role;
do $$
begin
  if (select full_name from public.profiles where id = 'a0000000-0000-4000-8000-000000000002') <> 'Owner Two Edited'
     or (select phone from public.profiles where id = 'a0000000-0000-4000-8000-000000000002') <> '0312 9020000' then
    raise exception 'FAIL: legacy row 2 not editable / phone rewritten';
  end if;
  raise notice 'PASS: legacy completed rows (03 phone, missing name) stay editable';
end $$;

-- 3. Legacy user 1 finishes the new Profile Setup: phone becomes +92,
--    addresses added, still completed.
select set_config('request.jwt.claims',
  json_build_object('sub', 'a0000000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);
set local role authenticated;
select public.save_profile_setup('Owner One', '03001234567', date '1990-01-01',
  'Lahore', 'Gulberg', 'House 3', true);
do $$
begin
  if (select phone from public.profiles) <> '+923001234567'
     or not (select profile_completed from public.profiles)
     or not exists (select 1 from public.current_addresses)
     or not exists (select 1 from public.permanent_addresses) then
    raise exception 'FAIL: legacy user could not complete the new Profile Setup';
  end if;
  raise notice 'PASS: legacy user completes Profile Setup; phone normalised to +92';
end $$;
reset role;

-- 4. Legacy incomplete row (no phone, no role; profile_completed false, or
--    NULL with 02b) can't flip the flag directly, but completes through the
--    function.
select set_config('request.jwt.claims',
  json_build_object('sub', 'a0000000-0000-4000-8000-000000000005', 'role', 'authenticated')::text, true);
set local role authenticated;
do $$
begin
  begin
    update public.profiles set profile_completed = true;
    raise exception 'FAIL: completed without phone / date of birth / addresses';
  exception when check_violation then
    raise notice 'PASS: incomplete legacy row can''t be marked completed directly';
  end;
  begin
    update public.profiles set id = 'c0000000-0000-4000-8000-00000000000c';
    raise exception 'FAIL: profile id changed';
  exception when insufficient_privilege then
    raise notice 'PASS: legacy UPDATE policy blocks changing the id';
  end;
  if exists (select 1 from public.profiles where id <> 'a0000000-0000-4000-8000-000000000005') then
    raise exception 'FAIL: sees other profiles';
  end if;
  update public.profiles set full_name = 'x' where id = 'a0000000-0000-4000-8000-000000000003';
  if found then raise exception 'FAIL: changed another user''s profile'; end if;
  raise notice 'PASS: legacy policies keep users to their own row';
end $$;
select public.save_profile_setup('Not Done', '0300-7654321', date '2001-07-07',
  'Karachi', 'Clifton', 'Flat 9', false, 'Hyderabad', 'Latifabad', 'House 2');
do $$
begin
  if not (select profile_completed from public.profiles) or (select phone from public.profiles) <> '+923007654321' then
    raise exception 'FAIL: incomplete legacy row could not complete';
  end if;
  raise notice 'PASS: incomplete legacy row completes through save_profile_setup';
end $$;
reset role;

-- 5. Untouched legacy row is exactly as it was.
do $$
begin
  if (select row(full_name, phone, role, profile_completed) from public.profiles
       where id = 'a0000000-0000-4000-8000-000000000003')
     is distinct from row('Owner Three'::text, '0333-1112223'::text, 'club_owner'::text, true) then
    raise exception 'FAIL: an untouched legacy row changed';
  end if;
  raise notice 'PASS: untouched legacy row unchanged';
end $$;

-- 6. NULL profile_completed: with a nullable column and no default (02b), a
--    new sign-up starts with NULL — it must still not be markable completed
--    directly (NULL → true is a transition, like false → true).
do $$
declare
  v_nullable boolean;
  v_default  text;
begin
  select is_nullable = 'YES', column_default into v_nullable, v_default
    from information_schema.columns
   where table_schema = 'public' and table_name = 'profiles' and column_name = 'profile_completed';
  raise notice 'shape: profile_completed nullable = %, default = %', v_nullable, coalesce(v_default, 'none');
  if v_nullable and v_default is null
     and (select profile_completed from public.profiles
           where id = 'b0000000-0000-4000-8000-000000000009') is not null then
    raise exception 'FAIL: expected the new sign-up to start with NULL';
  end if;
end $$;
select set_config('request.jwt.claims',
  json_build_object('sub', 'b0000000-0000-4000-8000-000000000009', 'role', 'authenticated')::text, true);
set local role authenticated;
do $$
declare
  v_start text := (select coalesce(profile_completed::text, 'NULL') from public.profiles
                    where id = 'b0000000-0000-4000-8000-000000000009');
begin
  begin
    update public.profiles set profile_completed = true where id = 'b0000000-0000-4000-8000-000000000009';
    raise exception 'FAIL: new sign-up (profile_completed %) marked completed without any data', v_start;
  exception when check_violation then null; end;
  perform public.save_profile_setup('New User', '0300 1112222', date '2002-02-02',
    'Lahore', 'Gulberg', 'House 5', true);
  if not (select profile_completed from public.profiles where id = 'b0000000-0000-4000-8000-000000000009') then
    raise exception 'FAIL: new sign-up could not complete Profile Setup';
  end if;
  raise notice 'PASS: new sign-up (profile_completed %) completes only through Profile Setup', v_start;
end $$;
reset role;

select 'ALL LEGACY ADOPTION CHECKS PASSED' as result;

rollback;
