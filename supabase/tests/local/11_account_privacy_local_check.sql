-- CricEco · LOCAL TEST ONLY — migrations 13 (phone sharing consent) and 14
-- (account deletion data) on a DISPOSABLE plain PostgreSQL 17 database, after
-- 00_auth_stub.sql, 02_legacy_profiles_fixture.sql, migrations 1–12 (+ the D1
-- location seed) and migrations 13–14. Synthetic accounts only (ids d…).
-- Run with psql:  psql -X -v ON_ERROR_STOP=1 -f 11_account_privacy_local_check.sql
-- Every check prints "PASS: …"; the first failure stops the run ("FAIL: …").
-- Refuses to run on a real Supabase project (its auth.users has passwords).
\set ON_ERROR_STOP on

do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password') then
    raise exception 'LOCAL ONLY: this looks like a real Supabase project — refusing';
  end if;
  if to_regprocedure('public.set_phone_sharing(boolean)') is null or to_regprocedure('public.delete_account_data(uuid)') is null then
    raise exception 'apply migrations 13 and 14 first';
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
-- Synthetic accounts: owner O (club X), members M1 M2, applicant A,
-- second owner P (club Y, with M2 also a member there).
-- ---------------------------------------------------------------------------
\set o  'd0000000-0000-4000-8000-000000000001'
\set m1 'd0000000-0000-4000-8000-000000000002'
\set m2 'd0000000-0000-4000-8000-000000000003'
\set a  'd0000000-0000-4000-8000-000000000004'
\set p  'd0000000-0000-4000-8000-000000000005'

do $$
declare
  u uuid;
  i int := 0;
begin
  foreach u in array array['d0000000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000002',
                           'd0000000-0000-4000-8000-000000000003', 'd0000000-0000-4000-8000-000000000004',
                           'd0000000-0000-4000-8000-000000000005']::uuid[] loop
    i := i + 1;
    insert into auth.users (id, email) values (u, format('privacy%s@local.test', i));
    insert into public.current_addresses (user_id, city, area, address) values (u, 'Lahore', 'Gulberg', 'Street 1');
    insert into public.permanent_addresses (user_id, city, area, address) values (u, 'Lahore', 'Gulberg', 'Street 1');
    update public.profiles
       set full_name = format('Privacy Person %s', i),
           phone = format('+923%s', lpad((200000000 + i)::text, 9, '0')),
           date_of_birth = date '2000-05-01',
           profile_completed = true
     where id = u;
    insert into public.player_profiles (user_id, player_role, batting_style, bowling_style, is_wicketkeeper)
    values (u, 'all_rounder', 'right_handed', 'right_arm_fast', false);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- A. The secure default and the user's own switch
-- ---------------------------------------------------------------------------
select t.ok((select bool_and(not share_phone_with_clubs) from public.profiles where id::text like 'd0000000%'),
            'A1 new and existing profiles do not share their phone (default false)');

set role anon;
select t.expect_error('select public.my_privacy_settings()', '%permission denied%', 'A2 anon cannot read privacy settings');
select t.expect_error('select public.set_phone_sharing(true)', '%permission denied%', 'A3 anon cannot change privacy settings');
reset role;

set role authenticated;
select set_config('request.jwt.claims', '', false);
select t.expect_error('select public.set_phone_sharing(true)', '%not authenticated%', 'A4 no session: refused');
select t.as_user(:'m1');
select t.ok(public.my_privacy_settings() = false, 'A5 my_privacy_settings: false by default');
select t.expect_error('select public.set_phone_sharing(null)', '%invalid%', 'A6 NULL is refused');
select t.ok(public.set_phone_sharing(true) = true, 'A7 set_phone_sharing(true)');
select t.ok(public.my_privacy_settings() = true, 'A8 the change is read back');
reset role;
select t.ok((select share_phone_with_clubs from public.profiles where id = :'m1') and
            not (select share_phone_with_clubs from public.profiles where id = :'m2'),
            'A9 only the caller''s own row changed');

-- ---------------------------------------------------------------------------
-- B. Clubs, members, a pending applicant
-- ---------------------------------------------------------------------------
set role authenticated;
select t.as_user(:'o');
select code as code_x, id as club_x from public.create_club('Privacy Lions CC', 'Lahore', 'corporate') \gset
select t.as_user(:'p');
select code as code_y, id as club_y from public.create_club('Privacy Kings CC', 'Karachi', 'professional') \gset
select t.as_user(:'m1');
select public.request_to_join_club(:'code_x');
select t.as_user(:'m2');
select public.request_to_join_club(:'code_x');
select t.as_user(:'o');
select public.decide_join_request(r.request_id, true, 'player', null) from public.club_join_requests(:'club_x') r;
select t.as_user(:'m2');
select public.request_to_join_club(:'code_y');
select t.as_user(:'p');
select public.decide_join_request(r.request_id, true, 'player', null)
  from public.club_join_requests(:'club_y') r where r.status = 'pending';
select t.as_user(:'a');
select public.request_to_join_club(:'code_x');
reset role;

-- ---------------------------------------------------------------------------
-- C. The owner sees a phone only with consent
-- ---------------------------------------------------------------------------
set role authenticated;
select t.as_user(:'o');
select t.ok((select phone from public.club_member_list(:'club_x') where user_id = :'m1') = '+923200000002',
            'C1 a member who agreed: the owner sees the phone');
select t.ok((select phone from public.club_member_list(:'club_x') where user_id = :'m2') is null,
            'C2 a member who did not agree: no phone');
select t.ok((select phone from public.club_member_list(:'club_x') where user_id = :'o') = '+923200000001',
            'C3 the owner''s own row keeps their own phone');
select t.ok((select phone from public.club_join_requests(:'club_x') where status = 'pending') is null,
            'C4 an applicant who did not agree: no phone in the request');
select t.ok((select full_name from public.club_join_requests(:'club_x') where status = 'pending') = 'Privacy Person 4',
            'C5 the rest of the request is unchanged (name)');
select t.as_user(:'a');
select public.set_phone_sharing(true);
select t.as_user(:'o');
select t.ok((select phone from public.club_join_requests(:'club_x') where status = 'pending') = '+923200000004',
            'C6 after the applicant agrees, the owner sees the phone');
select t.as_user(:'m1');
select public.set_phone_sharing(false);
select t.as_user(:'o');
select t.ok((select phone from public.club_member_list(:'club_x') where user_id = :'m1') is null,
            'C7 consent withdrawn: hidden again at once');
select t.as_user(:'m2');
select t.expect_error(format('select * from public.club_member_list(%L)', :'club_x'), '%not allowed%',
                      'C8 a member (not the owner) cannot read the member list');
select t.expect_error(format('select * from public.club_join_requests(%L)', :'club_x'), '%not allowed%',
                      'C9 a member (not the owner) cannot read the requests');
select t.as_user(:'a');
select t.ok((select count(*) from public.profiles where id <> :'a') = 0,
            'C10 RLS: an applicant cannot read other people''s profile rows (phones included)');
reset role;

-- ---------------------------------------------------------------------------
-- D. Account deletion: service role only
-- ---------------------------------------------------------------------------
set role authenticated;
select t.as_user(:'m1');
select t.expect_error(format('select public.delete_account_data(%L)', :'m1'), '%permission denied%',
                      'D1 a signed-in user cannot call delete_account_data (no password check)');
reset role;
set role anon;
select t.expect_error(format('select public.delete_account_data(%L)', :'m1'), '%permission denied%',
                      'D2 anon cannot call delete_account_data');
reset role;

-- A team in club X with M1 as captain and M2 as vice-captain.
set role authenticated;
select t.as_user(:'o');
select id as team_x from public.create_team(:'club_x', 'Privacy First XI', 't20') \gset
select (select id from public.club_members where club_id = :'club_x' and user_id = :'m1') as mem_m1 \gset
select (select id from public.club_members where club_id = :'club_x' and user_id = :'m2') as mem_m2 \gset
select public.save_team(:'team_x', 'Privacy First XI', 't20', null, :'mem_m1', :'mem_m2',
                        jsonb_build_array(jsonb_build_object('member_id', :'mem_m1', 'selection', 'playing'),
                                          jsonb_build_object('member_id', :'mem_m2', 'selection', 'playing')));
reset role;

select count(*) as others_before from public.profiles where id::text not like 'd0000000%' \gset

-- D3–D7: delete member M1 (in club X's squad as captain).
set role service_role;
select public.delete_account_data(:'m1') as summary_m1 \gset
reset role;
select t.ok((:'summary_m1')::jsonb = '{"clubs": 0, "memberships": 1, "join_requests": 1, "profile": 1}'::jsonb,
            'D3 deleting a member: their membership, request and profile');
select t.ok(not exists (select 1 from public.profiles where id = :'m1')
            and not exists (select 1 from public.current_addresses where user_id = :'m1')
            and not exists (select 1 from public.permanent_addresses where user_id = :'m1')
            and not exists (select 1 from public.player_profiles where user_id = :'m1')
            and not exists (select 1 from public.user_roles where user_id = :'m1')
            and not exists (select 1 from public.join_requests where user_id = :'m1'),
            'D4 no personal row of the deleted member is left');
select t.ok((select captain_member_id from public.teams where id = :'team_x') is null
            and (select vice_captain_member_id from public.teams where id = :'team_x') = :'mem_m2'
            and (select count(*) from public.team_players where team_id = :'team_x') = 1,
            'D5 the team keeps its other player; the deleted captain is cleared');
select t.ok((select count(*) from public.join_requests where club_id = :'club_x' and decided_by = :'o') >= 1,
            'D6 other people''s rows are untouched (owner decisions kept)');

-- D7: deleting it again changes nothing (idempotent retry).
set role service_role;
select public.delete_account_data(:'m1') as summary_again \gset
reset role;
select t.ok((:'summary_again')::jsonb = '{"clubs": 0, "memberships": 0, "join_requests": 0, "profile": 0}'::jsonb,
            'D7 a repeated call deletes nothing more');

-- D8–D11: delete owner O (club X with its team; M2 is also a member of Y).
set role service_role;
select public.delete_account_data(:'o') as summary_o \gset
reset role;
select t.ok((:'summary_o')::jsonb ->> 'clubs' = '1' and (:'summary_o')::jsonb ->> 'profile' = '1',
            'D8 deleting an owner deletes their club and profile');
select t.ok(not exists (select 1 from public.clubs where id = :'club_x')
            and not exists (select 1 from public.club_members where club_id = :'club_x')
            and not exists (select 1 from public.join_requests where club_id = :'club_x')
            and not exists (select 1 from public.teams where club_id = :'club_x')
            and not exists (select 1 from public.team_players where team_id = :'team_x'),
            'D9 the club''s members, requests, teams and squads go with it');
select t.ok(exists (select 1 from public.profiles where id = :'m2')
            and exists (select 1 from public.club_members where club_id = :'club_y' and user_id = :'m2' and status = 'active')
            and exists (select 1 from public.clubs where id = :'club_y'),
            'D10 other people keep their accounts and their other clubs');
select t.ok((select count(*) from public.profiles where id::text not like 'd0000000%') = :others_before,
            'D11 no profile outside this test was touched');
select t.ok(exists (select 1 from auth.users where id = :'o'),
            'D12 the Auth user is NOT deleted here (the Edge Function does that next)');
select t.expect_error('select public.delete_account_data(null)', '%user required%', 'D13 NULL user is refused');

-- Clean up the synthetic accounts (this database only).
delete from public.profiles where id::text like 'd0000000%';
delete from auth.users where id::text like 'd0000000%';
select t.ok(not exists (select 1 from public.profiles where id::text like 'd0000000%'), 'Z cleanup done');
