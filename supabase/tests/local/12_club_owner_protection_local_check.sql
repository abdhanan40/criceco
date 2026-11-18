-- CricEco · LOCAL TEST ONLY — migration 15 (club owners can't be deleted;
-- deletion attempts throttled) on a DISPOSABLE plain PostgreSQL 17 database,
-- after 00_auth_stub.sql, 02_legacy_profiles_fixture.sql, migrations 1–14
-- (+ the D1 location seed) and migration 15. Synthetic accounts only (ids e…).
-- Run with psql:  psql -X -v ON_ERROR_STOP=1 -f 12_club_owner_protection_local_check.sql
-- Every check prints "PASS: …"; the first failure stops the run ("FAIL: …").
-- Refuses to run on a real Supabase project (its auth.users has passwords).
\set ON_ERROR_STOP on

do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password') then
    raise exception 'LOCAL ONLY: this looks like a real Supabase project — refusing';
  end if;
  if to_regclass('public.account_deletion_attempts') is null then
    raise exception 'apply migration 15 first';
  end if;
end $$;

create schema if not exists t;
grant usage on schema t to anon, authenticated, service_role;

create or replace function t.ok(p_cond boolean, p_name text) returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_name; end if;
  raise notice 'PASS: %', p_name;
end $$;

create or replace function t.expect_error(p_sql text, p_like text, p_name text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm like p_like or sqlstate like p_like then
      raise notice 'PASS: % [% %]', p_name, sqlstate, sqlerrm;
      return;
    end if;
    raise exception 'FAIL: % — unexpected error [% %]', p_name, sqlstate, sqlerrm;
  end;
  raise exception 'FAIL: % — no error', p_name;
end $$;

create or replace function t.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, false);
$$;
grant execute on all functions in schema t to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Synthetic accounts: owner O (club X), members M1 M2 (in X, M1 captain of a
-- team), plain user U, owner P (club Y).
-- ---------------------------------------------------------------------------
\set o  'e0000000-0000-4000-8000-000000000001'
\set m1 'e0000000-0000-4000-8000-000000000002'
\set m2 'e0000000-0000-4000-8000-000000000003'
\set u  'e0000000-0000-4000-8000-000000000004'
\set p  'e0000000-0000-4000-8000-000000000005'

do $$
declare
  v uuid;
  i int := 0;
begin
  foreach v in array array['e0000000-0000-4000-8000-000000000001', 'e0000000-0000-4000-8000-000000000002',
                           'e0000000-0000-4000-8000-000000000003', 'e0000000-0000-4000-8000-000000000004',
                           'e0000000-0000-4000-8000-000000000005']::uuid[] loop
    i := i + 1;
    insert into auth.users (id, email) values (v, format('owners%s@local.test', i));
    insert into public.current_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
    insert into public.permanent_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
    update public.profiles
       set full_name = format('Owner Test %s', i),
           phone = format('+923%s', lpad((300000000 + i)::text, 9, '0')),
           date_of_birth = date '2000-05-01',
           profile_completed = true
     where id = v;
    insert into public.player_profiles (user_id, player_role, batting_style, bowling_style, is_wicketkeeper)
    values (v, 'all_rounder', 'right_handed', 'right_arm_fast', false);
  end loop;
end $$;

set role authenticated;
select t.as_user(:'o');
select code as code_x, id as club_x from public.create_club('Owner Test Lions', 'Lahore', 'corporate') \gset
select t.as_user(:'p');
select code as code_y, id as club_y from public.create_club('Owner Test Kings', 'Karachi', 'professional') \gset
select t.as_user(:'m1');
select public.request_to_join_club(:'code_x');
select t.as_user(:'m2');
select public.request_to_join_club(:'code_x');
select t.as_user(:'o');
select public.decide_join_request(r.request_id, true, 'player', null) from public.club_join_requests(:'club_x') r;
select id as team_x from public.create_team(:'club_x', 'Owner Test XI', 't20') \gset
reset role;
select (select id from public.club_members where club_id = :'club_x' and user_id = :'m1') as mem_m1 \gset
select (select id from public.club_members where club_id = :'club_x' and user_id = :'m2') as mem_m2 \gset
set role authenticated;
select t.as_user(:'o');
select public.save_team(:'team_x', 'Owner Test XI', 't20', null, :'mem_m1', :'mem_m2',
                        jsonb_build_array(jsonb_build_object('member_id', :'mem_m1', 'selection', 'playing'),
                                          jsonb_build_object('member_id', :'mem_m2', 'selection', 'playing')));
reset role;

select count(*) as others_before from public.profiles where id::text not like 'e0000000%' \gset

-- ---------------------------------------------------------------------------
-- A. Who may call what (direct RPC / impersonation)
-- ---------------------------------------------------------------------------
set role authenticated;
select t.as_user(:'u');
select t.expect_error(format('select public.delete_account_data(%L)', :'u'), '%permission denied%',
                      'A1 a signed-in user cannot call delete_account_data, not even for themselves');
select t.expect_error(format('select public.delete_account_data(%L)', :'o'), '%permission denied%',
                      'A2 impersonation: a signed-in user cannot delete someone else');
select t.expect_error(format('select public.account_deletion_throttled(%L)', :'u'), '%permission denied%',
                      'A3 authenticated cannot read the throttle');
select t.expect_error(format('select public.account_deletion_failed(%L)', :'o'), '%permission denied%',
                      'A4 authenticated cannot lock someone out (record failures)');
select t.expect_error(format('delete from public.profiles where id = %L', :'o'), '%permission denied%',
                      'A5 authenticated cannot delete a profile row directly');
select t.expect_error('select * from public.account_deletion_attempts', '%permission denied%',
                      'A6 authenticated cannot read deletion attempts');
reset role;
set role anon;
select t.expect_error(format('select public.delete_account_data(%L)', :'u'), '%permission denied%',
                      'A7 anon cannot call delete_account_data');
select t.expect_error(format('select public.account_deletion_throttled(%L)', :'u'), '%permission denied%',
                      'A8 anon cannot call the throttle');
reset role;

-- ---------------------------------------------------------------------------
-- B. Club owners are refused — by the function and by any other route
-- ---------------------------------------------------------------------------
set role service_role;
select t.expect_error(format('select public.delete_account_data(%L)', :'o'), '%CLUB_OWNERSHIP_TRANSFER_REQUIRED%',
                      'B1 owner of one club: CLUB_OWNERSHIP_TRANSFER_REQUIRED');
select t.expect_error(format('select public.delete_account_data(%L)', :'p'), '%CLUB_OWNERSHIP_TRANSFER_REQUIRED%',
                      'B2 another owner: refused too');
reset role;
select t.ok(exists (select 1 from public.profiles where id = :'o')
            and exists (select 1 from public.clubs where id = :'club_x')
            and (select count(*) from public.club_members where club_id = :'club_x') = 3
            and exists (select 1 from public.teams where id = :'team_x')
            and (select count(*) from public.team_players where team_id = :'team_x') = 2,
            'B3 after a refusal: the owner, club, memberships and team are all intact');
select t.expect_error(format('delete from auth.users where id = %L', :'o'), '%CLUB_OWNERSHIP_TRANSFER_REQUIRED%',
                      'B4 deleting the owner''s Auth user (e.g. from the Dashboard) is refused: no cascade to the club');
select t.expect_error(format('delete from public.profiles where id = %L', :'p'), '%CLUB_OWNERSHIP_TRANSFER_REQUIRED%',
                      'B5 deleting an owner''s profile directly (superuser) is refused');
select t.ok(exists (select 1 from public.clubs where id = :'club_x') and exists (select 1 from public.clubs where id = :'club_y'),
            'B6 both clubs still exist');
select t.expect_error(format('insert into public.clubs (owner_id, name, city, club_type) values (%L, %L, %L, %L)',
                             :'o', 'Second Club', 'Lahore', 'corporate'), '%clubs_owner_id_key%',
                      'B7 multiple clubs: the schema allows one club per owner (the check counts any number)');
-- An owner membership row without clubs.owner_id (inconsistent data) is refused too.
update public.club_members set member_role = 'owner'
 where club_id = :'club_y' and user_id = :'p';  -- already owner: no change; keeps the unique owner index intact
set role service_role;
select t.ok((select count(*) from public.account_deletion_attempts) = 0, 'B8 a refusal records no password attempt');
reset role;

-- ---------------------------------------------------------------------------
-- C. Plain users and members are deleted (normal flow, retry)
-- ---------------------------------------------------------------------------
set role service_role;
select public.delete_account_data(:'u') as summary_u \gset
select public.delete_account_data(:'u') as summary_u_again \gset
select public.delete_account_data(:'m2') as summary_m2 \gset
reset role;
select t.ok((:'summary_u')::jsonb = '{"clubs": 0, "memberships": 0, "join_requests": 0, "profile": 1}'::jsonb,
            'C1 a user with no club: profile deleted');
select t.ok((:'summary_u_again')::jsonb = '{"clubs": 0, "memberships": 0, "join_requests": 0, "profile": 0}'::jsonb,
            'C2 retry after a partial failure: nothing more, no error');
select t.ok((:'summary_m2')::jsonb = '{"clubs": 0, "memberships": 1, "join_requests": 1, "profile": 1}'::jsonb,
            'C3 a member: membership, request and profile deleted');
select t.ok((select vice_captain_member_id from public.teams where id = :'team_x') is null
            and (select captain_member_id from public.teams where id = :'team_x') = :'mem_m1'
            and (select count(*) from public.team_players where team_id = :'team_x') = 1
            and exists (select 1 from public.clubs where id = :'club_x'),
            'C4 the club and team stay; the deleted member leaves the squad, the vice-captaincy is cleared');

-- ---------------------------------------------------------------------------
-- D. After an ownership transfer the former owner may be deleted
--    (simulated as superuser: the transfer workflow doesn't exist yet)
-- ---------------------------------------------------------------------------
update public.club_members set member_role = 'player' where club_id = :'club_x' and user_id = :'o';
update public.club_members set member_role = 'owner' where club_id = :'club_x' and user_id = :'m1';
update public.clubs set owner_id = :'m1' where id = :'club_x';
set role service_role;
select public.delete_account_data(:'o') as summary_o \gset
reset role;
select t.ok((:'summary_o')::jsonb ->> 'profile' = '1' and (:'summary_o')::jsonb ->> 'clubs' = '0',
            'D1 the former owner is deleted once the club is transferred');
select t.ok(exists (select 1 from public.clubs where id = :'club_x' and owner_id = :'m1')
            and exists (select 1 from public.teams where id = :'team_x')
            and (select count(*) from public.team_players where team_id = :'team_x') = 1
            and exists (select 1 from public.club_members where club_id = :'club_x' and user_id = :'m1' and member_role = 'owner'),
            'D2 the transferred club, its new owner and its team are untouched');
set role service_role;
select t.expect_error(format('select public.delete_account_data(%L)', :'m1'), '%CLUB_OWNERSHIP_TRANSFER_REQUIRED%',
                      'D3 the new owner is now the one who can''t be deleted');
reset role;

-- ---------------------------------------------------------------------------
-- E. Throttle: 5 wrong passwords in 15 minutes
-- ---------------------------------------------------------------------------
set role service_role;
select t.ok(public.account_deletion_throttled(:'p') = false, 'E1 not throttled at first');
select public.account_deletion_failed(:'p') from generate_series(1, 4);
select t.ok(public.account_deletion_throttled(:'p') = false, 'E2 four wrong passwords: still allowed');
select public.account_deletion_failed(:'p');
select t.ok(public.account_deletion_throttled(:'p') = true, 'E3 the fifth: throttled');
select t.ok(public.account_deletion_throttled(:'m1') = false, 'E4 another user is not affected');
select public.account_deletion_failed('e0000000-0000-4000-8000-0000000000ff');
reset role;
select t.ok((select count(*) from public.account_deletion_attempts where user_id = 'e0000000-0000-4000-8000-0000000000ff') = 0,
            'E5 an unknown user id records nothing (no error, no row)');
update public.account_deletion_attempts set attempted_at = now() - interval '20 minutes' where user_id = :'p';
set role service_role;
select t.ok(public.account_deletion_throttled(:'p') = false, 'E6 attempts older than 15 minutes no longer count');
reset role;

select t.ok((select count(*) from public.profiles where id::text not like 'e0000000%') = :others_before,
            'F1 no profile outside this test was touched');

-- Clean up (this database only): the remaining owners' clubs first.
delete from public.clubs where owner_id::text like 'e0000000%';
delete from public.profiles where id::text like 'e0000000%';
delete from auth.users where id::text like 'e0000000%';
select t.ok(not exists (select 1 from public.profiles where id::text like 'e0000000%'), 'Z cleanup done');
