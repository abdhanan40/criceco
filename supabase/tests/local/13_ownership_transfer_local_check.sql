-- CricEco · LOCAL TEST ONLY — migration 16 (club ownership transfer) on a
-- DISPOSABLE plain PostgreSQL 17 database, after 00_auth_stub.sql,
-- 02_legacy_profiles_fixture.sql, migrations 1–15 (+ the D1 location seed)
-- and migration 16. Synthetic accounts only (ids f…).
-- Run with psql:  psql -X -v ON_ERROR_STOP=1 -f 13_ownership_transfer_local_check.sql
-- Every check prints "PASS: …"; the first failure stops the run ("FAIL: …").
-- Refuses to run on a real Supabase project (its auth.users has passwords).
\set ON_ERROR_STOP on

do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password') then
    raise exception 'LOCAL ONLY: this looks like a real Supabase project — refusing';
  end if;
  if to_regclass('public.club_ownership_transfers') is null then
    raise exception 'apply migration 16 first';
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
-- Synthetic accounts: owner O (club X); members A, B, C of X (C's profile is
-- made incomplete later); owner P (club Y, also a member of X); outsider U.
-- ---------------------------------------------------------------------------
\set o 'f0000000-0000-4000-8000-000000000001'
\set a 'f0000000-0000-4000-8000-000000000002'
\set b 'f0000000-0000-4000-8000-000000000003'
\set c 'f0000000-0000-4000-8000-000000000004'
\set p 'f0000000-0000-4000-8000-000000000005'
\set u 'f0000000-0000-4000-8000-000000000006'

do $$
declare
  v uuid;
  i int := 0;
begin
  foreach v in array array['f0000000-0000-4000-8000-000000000001', 'f0000000-0000-4000-8000-000000000002',
                           'f0000000-0000-4000-8000-000000000003', 'f0000000-0000-4000-8000-000000000004',
                           'f0000000-0000-4000-8000-000000000005', 'f0000000-0000-4000-8000-000000000006']::uuid[] loop
    i := i + 1;
    insert into auth.users (id, email) values (v, format('transfer%s@local.test', i));
    insert into public.current_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
    insert into public.permanent_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
    update public.profiles
       set full_name = format('Transfer Person %s', i),
           phone = format('+923%s', lpad((400000000 + i)::text, 9, '0')),
           date_of_birth = date '2000-05-01',
           profile_completed = true
     where id = v;
    insert into public.player_profiles (user_id, player_role, batting_style, bowling_style, is_wicketkeeper)
    values (v, 'all_rounder', 'right_handed', 'right_arm_fast', false);
  end loop;
end $$;

set role authenticated;
select t.as_user(:'o');
select code as code_x, id as club_x from public.create_club('Transfer Lions', 'Lahore', 'corporate') \gset
select t.as_user(:'p');
select code as code_y, id as club_y from public.create_club('Transfer Kings', 'Karachi', 'professional') \gset
select t.as_user(:'a'); select public.request_to_join_club(:'code_x');
select t.as_user(:'b'); select public.request_to_join_club(:'code_x');
select t.as_user(:'c'); select public.request_to_join_club(:'code_x');
select t.as_user(:'p'); select public.request_to_join_club(:'code_x');
select t.as_user(:'o');
select public.decide_join_request(r.request_id, true, 'player', null) from public.club_join_requests(:'club_x') r;
select id as team_x from public.create_team(:'club_x', 'Transfer XI', 't20') \gset
reset role;
select (select id from public.club_members where club_id = :'club_x' and user_id = :'o') as mem_o \gset
select (select id from public.club_members where club_id = :'club_x' and user_id = :'a') as mem_a \gset
select (select id from public.club_members where club_id = :'club_x' and user_id = :'b') as mem_b \gset
select (select id from public.club_members where club_id = :'club_x' and user_id = :'c') as mem_c \gset
select (select id from public.club_members where club_id = :'club_x' and user_id = :'p') as mem_p \gset
set role authenticated;
select t.as_user(:'o');
select public.save_team(:'team_x', 'Transfer XI', 't20', null, :'mem_a', :'mem_b',
                        jsonb_build_array(jsonb_build_object('member_id', :'mem_o', 'selection', 'playing'),
                                          jsonb_build_object('member_id', :'mem_a', 'selection', 'playing'),
                                          jsonb_build_object('member_id', :'mem_b', 'selection', 'sub')));
reset role;
-- C's profile is incomplete (no date of birth) — an ineligible recipient.
update public.profiles set profile_completed = false where id = :'c';

select count(*) as members_before from public.club_members where club_id = :'club_x' \gset
select count(*) as squad_before from public.team_players where team_id = :'team_x' \gset
select count(*) as requests_before from public.join_requests where club_id = :'club_x' \gset

-- ---------------------------------------------------------------------------
-- A. Who may offer, and to whom
-- ---------------------------------------------------------------------------
set role anon;
select t.expect_error(format('select public.offer_club_ownership(%L, %L)', :'club_x', :'mem_a'), '%permission denied%',
                      'A1 anon cannot call offer_club_ownership');
reset role;
set role authenticated;
select t.as_user(:'a');
select t.expect_error(format('select public.offer_club_ownership(%L, %L)', :'club_x', :'mem_b'), '%not allowed%',
                      'A2 a member (not the owner) cannot offer the club');
select t.as_user(:'u');
select t.expect_error(format('select public.offer_club_ownership(%L, %L)', :'club_x', :'mem_a'), '%not allowed%',
                      'A3 an outsider cannot offer the club');
select t.as_user(:'o');
select t.expect_error(format('select public.offer_club_ownership(%L, %L)', :'club_x', :'mem_o'), '%self transfer%',
                      'A4 self-transfer refused');
select t.expect_error(format('select public.offer_club_ownership(%L, %L)', :'club_x', :'mem_p'), '%recipient owns a club%',
                      'A5 a member who owns another club is refused (one club per owner)');
select t.expect_error(format('select public.offer_club_ownership(%L, %L)', :'club_x', :'mem_c'), '%recipient profile incomplete%',
                      'A6 a member with an incomplete profile is refused');
select t.expect_error(format('select public.offer_club_ownership(%L, %L)', :'club_x', 'f0000000-0000-4000-8000-0000000000ff'),
                      '%not a member%', 'A7 a non-member id is refused');
select t.expect_error(format('select public.offer_club_ownership(%L, %L)', :'club_y', :'mem_a'), '%not allowed%',
                      'A8 another owner''s club cannot be offered');
select t.expect_error(format('select public.offer_club_ownership(%L, %L, %L)', :'club_x', :'mem_a', 'owner'), '%invalid%',
                      'A9 the old owner''s new role must be player, coach or manager');
select transfer_id_1 from (select id as transfer_id_1 from public.offer_club_ownership(:'club_x', :'mem_a', 'manager')) s \gset
reset role;
select t.ok((select owner_id from public.clubs where id = :'club_x') = :'o'
            and (select member_role from public.club_members where id = :'mem_o') = 'owner'
            and (select member_role from public.club_members where id = :'mem_a') = 'player',
            'A10 an offer alone changes nothing (owner, roles)');
set role authenticated;
select t.as_user(:'o');
select t.expect_error(format('select public.offer_club_ownership(%L, %L)', :'club_x', :'mem_b'), '%already pending%',
                      'A11 a second pending offer for the club is refused');
reset role;

-- ---------------------------------------------------------------------------
-- B. Direct writes and visibility
-- ---------------------------------------------------------------------------
set role authenticated;
select t.as_user(:'a');
select t.expect_error(format('update public.club_ownership_transfers set status = %L where id = %L', 'accepted', :'transfer_id_1'),
                      '%permission denied%', 'B1 nobody can update an offer directly');
select t.expect_error(format('insert into public.club_ownership_transfers (club_id, to_user_id) values (%L, %L)', :'club_x', :'a'),
                      '%permission denied%', 'B2 nobody can insert an offer directly');
select t.expect_error(format('update public.clubs set owner_id = %L where id = %L', :'a', :'club_x'), '%permission denied%',
                      'B3 a member cannot set clubs.owner_id');
select t.ok((select count(*) from public.club_ownership_transfers) = 1, 'B4 the recipient sees the offer (RLS)');
select t.ok((select count(*) from public.my_ownership_offers()) = 1, 'B5 my_ownership_offers lists it for the recipient');
select t.as_user(:'b');
select t.ok((select count(*) from public.club_ownership_transfers) = 0
            and (select count(*) from public.my_ownership_offers()) = 0
            and (select count(*) from public.club_ownership_transfers(:'club_x')) = 0,
            'B6 another member sees nothing');
select t.as_user(:'o');
select t.ok((select status from public.club_ownership_transfers(:'club_x') limit 1) = 'pending',
            'B7 the owner sees the pending offer');
reset role;

-- ---------------------------------------------------------------------------
-- C. Decline, cancel, who may do what
-- ---------------------------------------------------------------------------
set role authenticated;
select t.as_user(:'b');
select t.expect_error(format('select public.accept_ownership_transfer(%L)', :'transfer_id_1'), '%not allowed%',
                      'C1 someone else cannot accept the offer');
select t.expect_error(format('select public.reject_ownership_transfer(%L)', :'transfer_id_1'), '%not allowed%',
                      'C2 someone else cannot decline the offer');
select t.as_user(:'a');
select t.expect_error(format('select public.cancel_ownership_transfer(%L)', :'transfer_id_1'), '%not allowed%',
                      'C3 the recipient cannot cancel (they decline)');
select t.as_user(:'o');
select t.expect_error(format('select public.accept_ownership_transfer(%L)', :'transfer_id_1'), '%not allowed%',
                      'C4 the owner cannot accept their own offer');
select t.ok((select status from public.cancel_ownership_transfer(:'transfer_id_1')) = 'cancelled', 'C5 the owner cancels');
select t.expect_error(format('select public.cancel_ownership_transfer(%L)', :'transfer_id_1'), '%not pending%',
                      'C6 cancelling twice: not pending');
select id as transfer_id_2 from public.offer_club_ownership(:'club_x', :'mem_a', 'coach') \gset
select t.as_user(:'a');
select t.ok((select status from public.reject_ownership_transfer(:'transfer_id_2')) = 'rejected', 'C7 the recipient declines');
select t.expect_error(format('select public.accept_ownership_transfer(%L)', :'transfer_id_2'), '%not pending%',
                      'C8 a declined offer cannot be accepted');
reset role;
select t.ok((select owner_id from public.clubs where id = :'club_x') = :'o', 'C9 still the old owner after cancel / decline');

-- ---------------------------------------------------------------------------
-- D. Expiry
-- ---------------------------------------------------------------------------
set role authenticated;
select t.as_user(:'o');
select id as transfer_id_3 from public.offer_club_ownership(:'club_x', :'mem_a') \gset
reset role;
update public.club_ownership_transfers set created_at = now() - interval '8 days', expires_at = now() - interval '1 day'
 where id = :'transfer_id_3';
set role authenticated;
select t.as_user(:'a');
select t.ok((select count(*) from public.my_ownership_offers()) = 0, 'D1 an expired offer is no longer listed');
select t.ok((select status from public.accept_ownership_transfer(:'transfer_id_3')) = 'expired',
            'D2 accepting an expired offer: expired, nothing changes');
reset role;
select t.ok((select owner_id from public.clubs where id = :'club_x') = :'o', 'D3 still the old owner');

-- ---------------------------------------------------------------------------
-- E. Accept: ownership, roles and permissions move atomically
-- ---------------------------------------------------------------------------
set role authenticated;
select t.as_user(:'o');
select id as transfer_id_4 from public.offer_club_ownership(:'club_x', :'mem_a', 'manager') \gset
select t.as_user(:'a');
select t.ok((select status from public.accept_ownership_transfer(:'transfer_id_4')) = 'accepted', 'E1 the recipient accepts');
reset role;
select t.ok((select owner_id from public.clubs where id = :'club_x') = :'a', 'E2 clubs.owner_id is the new owner');
select t.ok((select owner_name from public.clubs where id = :'club_x') = 'Transfer Person 2', 'E3 owner_name follows');
select t.ok((select member_role from public.club_members where id = :'mem_a') = 'owner'
            and (select member_role from public.club_members where id = :'mem_o') = 'manager'
            and (select count(*) from public.club_members where club_id = :'club_x' and member_role = 'owner') = 1,
            'E4 roles: new owner = owner, old owner = manager (chosen role), exactly one owner');
select t.ok(exists (select 1 from public.user_roles where user_id = :'a' and role = 'club_owner')
            and not exists (select 1 from public.user_roles where user_id = :'o' and role = 'club_owner'),
            'E5 user_roles: club_owner moved');
select t.ok((select count(*) from public.club_members where club_id = :'club_x') = :members_before
            and (select count(*) from public.team_players where team_id = :'team_x') = :squad_before
            and (select count(*) from public.join_requests where club_id = :'club_x') = :requests_before
            and (select captain_member_id from public.teams where id = :'team_x') = :'mem_a'
            and (select vice_captain_member_id from public.teams where id = :'team_x') = :'mem_b',
            'E6 members, join requests, team, squad, captain and vice-captain unchanged');
set role authenticated;
select t.as_user(:'o');
select t.expect_error(format('select * from public.club_member_list(%L)', :'club_x'), '%not allowed%',
                      'E7 the old owner lost owner functions (member list)');
select t.expect_error(format('select public.create_team(%L, %L, %L)', :'club_x', 'Old Owner XI', 't20'), '%not allowed%',
                      'E8 the old owner can no longer manage teams');
select t.ok((select count(*) from public.teams where club_id = :'club_x') = 0, 'E9 the old owner no longer reads the club''s teams (RLS)');
select t.ok((select count(*) from public.clubs where id = :'club_x') = 0, 'E10 the old owner no longer reads the club row (RLS)');
select t.ok((select count(*) from public.my_club_memberships() where club_id = :'club_x') = 1,
            'E11 the old owner is still a member (manager)');
select t.ok((select status from public.club_ownership_transfers(:'club_x') where transfer_id = :'transfer_id_4') = 'accepted',
            'E12 the old owner still sees the transfer in the history');
select t.ok((select from_me from public.club_ownership_transfers(:'club_x') where transfer_id = :'transfer_id_4'),
            'E12b from_me: true for the one who made the offer');
select t.as_user(:'a');
select t.ok((select count(*) from public.club_member_list(:'club_x')) = :members_before, 'E13 the new owner reads the member list');
select t.ok((select count(*) from public.teams where club_id = :'club_x') = 1, 'E14 the new owner reads the club''s teams');
select t.ok(public.is_club_owner(:'club_x'), 'E15 is_club_owner is true for the new owner');
select t.ok(not (select from_me from public.club_ownership_transfers(:'club_x') where transfer_id = :'transfer_id_4'),
            'E15b from_me: false for the recipient');
select t.ok((select count(*) from public.club_ownership_transfers(:'club_x')) = 4, 'E16 the new owner sees the club''s whole history');
select t.expect_error(format('select public.accept_ownership_transfer(%L)', :'transfer_id_4'), '%not pending%',
                      'E17 accepting twice: not pending');
reset role;

-- ---------------------------------------------------------------------------
-- F. Account deletion after a transfer (migration 15)
-- ---------------------------------------------------------------------------
set role service_role;
select t.expect_error(format('select public.delete_account_data(%L)', :'a'), '%CLUB_OWNERSHIP_TRANSFER_REQUIRED%',
                      'F1 the new owner cannot delete their account');
select public.delete_account_data(:'o') as summary_o \gset
reset role;
select t.ok((:'summary_o')::jsonb ->> 'profile' = '1', 'F2 the former owner can delete their account now');
select t.ok(exists (select 1 from public.clubs where id = :'club_x' and owner_id = :'a')
            and exists (select 1 from public.teams where id = :'team_x')
            and (select count(*) from public.club_ownership_transfers where club_id = :'club_x') = 4
            and (select count(*) from public.club_ownership_transfers where club_id = :'club_x' and from_user_id is null) = 4,
            'F3 the club, its team and its transfer history stay (the deleted person is removed from it)');

-- Clean up (this database only).
delete from public.clubs where owner_id::text like 'f0000000%';
delete from public.profiles where id::text like 'f0000000%';
delete from auth.users where id::text like 'f0000000%';
select t.ok(not exists (select 1 from public.profiles where id::text like 'f0000000%'), 'Z cleanup done');
