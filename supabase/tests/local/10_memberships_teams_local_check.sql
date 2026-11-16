-- CricEco · LOCAL TEST ONLY — migrations 11 (club memberships) and 12 (teams)
-- on a DISPOSABLE plain PostgreSQL 17 database, after 00_auth_stub.sql,
-- 02_legacy_profiles_fixture.sql, migrations 1–10 (+ the D1 location seed)
-- and migrations 11–12. Synthetic accounts only. Run with psql:
--   psql -X -v ON_ERROR_STOP=1 -f 10_memberships_teams_local_check.sql
-- Every check prints "PASS: …"; the first failure stops the run ("FAIL: …").
-- Refuses to run on a real Supabase project (its auth.users has passwords).
\set ON_ERROR_STOP on

do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password') then
    raise exception 'LOCAL ONLY: this looks like a real Supabase project — refusing';
  end if;
  if to_regclass('public.club_members') is null or to_regclass('public.teams') is null then
    raise exception 'apply migrations 11 and 12 first';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Test helpers (schema t, this database only)
-- ---------------------------------------------------------------------------
create schema if not exists t;
grant usage on schema t to anon, authenticated;

create or replace function t.ok(p_cond boolean, p_name text) returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_name; end if;
  raise notice 'PASS: %', p_name;
end $$;

-- Runs p_sql and expects an error whose SQLSTATE or message matches p_like.
create or replace function t.expect_error(p_sql text, p_like text, p_name text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm like p_like or sqlstate like p_like then
      raise notice 'PASS: % [% %]', p_name, sqlstate, sqlerrm;
      return;
    end if;
    raise exception 'FAIL: % — unexpected error % %', p_name, sqlstate, sqlerrm;
  end;
  raise exception 'FAIL: % — no error', p_name;
end $$;

-- The "signed-in" user for auth.uid() (request.jwt.claims, as PostgREST sets).
create or replace function t.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, false);
$$;
grant execute on all functions in schema t to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Synthetic accounts (superuser setup; never real data)
-- ---------------------------------------------------------------------------
\set owner1   'b0000000-0000-4000-8000-000000000001'
\set owner2   'b0000000-0000-4000-8000-000000000002'
\set outsider 'b0000000-0000-4000-8000-000000000003'
\set coach    'b0000000-0000-4000-8000-000000000004'
\set p01      'c0000000-0000-4000-8000-000000000001'
\set p02      'c0000000-0000-4000-8000-000000000002'
\set p03      'c0000000-0000-4000-8000-000000000003'
\set p16      'c0000000-0000-4000-8000-000000000016'
\set notdone  'a0000000-0000-4000-8000-000000000005'

do $$
declare
  ids uuid[] := array['b0000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000002',
                      'b0000000-0000-4000-8000-000000000003', 'b0000000-0000-4000-8000-000000000004']::uuid[];
  i int;
  u uuid;
begin
  for i in 1..17 loop
    ids := ids || format('c0000000-0000-4000-8000-%s', lpad(i::text, 12, '0'))::uuid;
  end loop;
  i := 0;
  foreach u in array ids loop
    i := i + 1;
    insert into auth.users (id, email) values (u, format('synthetic%s@local.test', i));
    -- profiles row: created by migration 1's sign-up trigger. Addresses
    -- first: a completed profile requires both.
    insert into public.current_addresses (user_id, city, area, address) values (u, 'Lahore', 'Gulberg', 'Street 1');
    insert into public.permanent_addresses (user_id, city, area, address) values (u, 'Lahore', 'Gulberg', 'Street 1');
    update public.profiles
       set full_name = format('Synthetic Person %s', i),
           phone = format('+923%s', lpad((100000000 + i)::text, 9, '0')),
           date_of_birth = date '2000-05-01',
           profile_completed = true
     where id = u;
    if u::text like 'c%' then
      insert into public.player_profiles (user_id, player_role, batting_style, bowling_style, is_wicketkeeper)
      values (u, 'all_rounder', 'right_handed', 'right_arm_fast', false);
    end if;
  end loop;
  -- The owners play too (owner rows join the pool like the app).
  insert into public.player_profiles (user_id, player_role, batting_style, bowling_style, is_wicketkeeper)
  values ('b0000000-0000-4000-8000-000000000001', 'batsman', 'right_handed', null, false);
end $$;

select t.ok((select count(*) from public.profiles where full_name like 'Synthetic Person %' and profile_completed) = 21,
            'setup: 21 synthetic accounts with completed profiles');

-- ---------------------------------------------------------------------------
-- A. Clubs and owner memberships
-- ---------------------------------------------------------------------------
set role authenticated;
select t.as_user(:'owner1');
select code as code1, id as club1 from public.create_club('Synthetic Lions CC', 'Lahore', 'corporate') \gset
select t.as_user(:'owner2');
select code as code2, id as club2 from public.create_club('Synthetic Kings CC', 'Karachi', 'professional') \gset
reset role;

select t.ok((select count(*) from public.club_members m join public.clubs c on c.id = m.club_id
              where m.user_id = c.owner_id and m.member_role = 'owner' and m.status = 'active') = 2,
            'A1 each new club gets exactly one active owner membership (trigger)');
select t.ok(not exists (select 1 from public.user_roles where role::text not in ('player', 'club_owner')),
            'A2 user_roles holds only trigger-granted roles');

-- ---------------------------------------------------------------------------
-- B. Club-code lookup
-- ---------------------------------------------------------------------------
set role authenticated;
select t.as_user(:'p01');
select t.ok((select count(*) from public.lookup_club_by_code(:'code1')) = 1, 'B1 a valid code finds the club');
select t.ok((select name from public.lookup_club_by_code(lower(:'code1'))) = 'Synthetic Lions CC', 'B2 lower-case code works');
select t.ok((select member_count from public.lookup_club_by_code(:'code1')) = 1
            and not (select is_member from public.lookup_club_by_code(:'code1')),
            'B3 preview: member count, not yet a member');
select t.ok((select count(*) from public.lookup_club_by_code('ZZZZZZ')) = 0, 'B4 an unknown code returns no row');
select t.ok((select count(*) from public.lookup_club_by_code('abc')) = 0, 'B5 a malformed code returns no row');
select t.ok(not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'x'),
            'B6 (lookup output has no owner or code columns — checked in J1)');
reset role;
select t.ok((select count(*) from public.club_code_attempts where user_id = :'p01') = 2,
            'B7 the two failed codes were recorded for that user');
set role anon;
select t.expect_error(format('select * from public.lookup_club_by_code(%L)', :'code1'), '%permission denied%',
                      'B8 anon cannot look up codes');
reset role;

-- ---------------------------------------------------------------------------
-- C. Brute-force throttle: 10 failed codes per person per 15 minutes
-- ---------------------------------------------------------------------------
set role authenticated;
select t.as_user(:'p16');
select t.ok((select count(*) from public.lookup_club_by_code(:'code1')) = 1, 'C1 valid lookups do not count');
select t.ok((select count(*) from (select public.lookup_club_by_code(format('ZZZZ%sA', g)) from generate_series(0, 8) g) s) = 0,
            'C2 nine failed lookups');
select t.ok((public.request_to_join_club('QQQQQQ')).id is null, 'C3 a request with an unknown code returns NULL (10th failure)');
select t.expect_error(format('select * from public.lookup_club_by_code(%L)', :'code1'), '%too many attempts%',
                      'C4 the 11th lookup is refused, even for a valid code');
select t.expect_error(format('select public.request_to_join_club(%L)', :'code1'), '%too many attempts%',
                      'C5 requests are refused too');
reset role;
select t.ok((select count(*) from public.club_code_attempts where user_id = :'p16') = 10, 'C6 exactly 10 attempts recorded');
select t.ok(not exists (select 1 from public.join_requests where user_id = :'p16'), 'C7 no request was created');
update public.club_code_attempts set attempted_at = attempted_at - interval '16 minutes' where user_id = :'p16';
insert into public.club_code_attempts (user_id, attempted_at) values (:'p16', now() - interval '2 days');
set role authenticated;
select t.as_user(:'p16');
select t.ok((select count(*) from public.lookup_club_by_code(:'code1')) = 1, 'C8 after 15 minutes the window has passed');
select t.ok((select count(*) from public.lookup_club_by_code('YYYYYY')) = 0, 'C9 a new failure is recorded');
reset role;
select t.ok(not exists (select 1 from public.club_code_attempts where user_id = :'p16' and attempted_at < now() - interval '1 day'),
            'C10 attempts older than a day are deleted on the next failure');

-- ---------------------------------------------------------------------------
-- D. Join requests
-- ---------------------------------------------------------------------------
set role authenticated;
select t.as_user(:'p01');
select id as req_p01 from public.request_to_join_club(:'code1') \gset
select t.ok((select status from public.join_requests where id = :'req_p01') = 'pending', 'D1 a pending request is created');
select t.expect_error(format('select public.request_to_join_club(%L)', :'code1'), '%already pending%', 'D2 a duplicate pending request is refused');
select t.expect_error(format('select public.request_to_join_club(%L)', :'code2'), '%already pending%',
                      'D3 one pending request per person (another club refused)');
select t.ok((select count(*) from public.join_requests) = 1, 'D4 RLS: the applicant sees only their own request');
select t.as_user(:'owner1');
select t.expect_error(format('select public.request_to_join_club(%L)', :'code1'), '%own club%', 'D5 an owner cannot request their own club');
select t.as_user(:'notdone');
select t.expect_error(format('select public.request_to_join_club(%L)', :'code1'), '%profile incomplete%',
                      'D6 an incomplete profile cannot request');
select t.as_user(:'p02');
select t.expect_error(format('select public.cancel_join_request(%L)', :'req_p01'), '%not found%',
                      'D7 impersonation: someone else cannot cancel the request');
select t.ok((select count(*) from public.join_requests) = 0, 'D8 RLS: another user sees no requests');
select t.as_user(:'outsider');
select t.expect_error(format('select public.decide_join_request(%L, true)', :'req_p01'), '%not allowed%',
                      'D9 a non-owner cannot approve');
select t.expect_error(format('select * from public.club_join_requests(%L)', :'club1'), '%not allowed%',
                      'D10 a non-owner cannot list the club''s requests');
select t.as_user(:'owner2');
select t.expect_error(format('select public.decide_join_request(%L, true)', :'req_p01'), '%not allowed%',
                      'D11 another club''s owner cannot approve');
select t.ok((select count(*) from public.join_requests) = 0, 'D12 RLS: another club''s owner sees none of them');
select t.as_user(:'owner1');
select t.ok((select count(*) from public.join_requests) = 1, 'D13 RLS: the club owner sees the request');
select t.ok((select applicant_age from public.club_join_requests(:'club1') where request_id = :'req_p01') > 20,
            'D14 the owner gets the applicant''s age');
reset role;
select t.ok(pg_get_function_result('public.club_join_requests(uuid)'::regprocedure) not like '%date_of_birth%',
            'D15 club_join_requests never returns a date of birth');

-- ---------------------------------------------------------------------------
-- E. Decisions
-- ---------------------------------------------------------------------------
set role authenticated;
select t.as_user(:'owner1');
select t.expect_error(format('select public.decide_join_request(%L, true, %L)', :'req_p01', 'owner'), '%invalid role%',
                      'E1 approval can never grant owner');
select t.ok((public.decide_join_request(:'req_p01', true, 'player')).status = 'approved', 'E2 the owner approves as player');
select t.ok((public.decide_join_request(:'req_p01', false, 'player', 'late')).status = 'approved',
            'E3 deciding again returns it unchanged');
reset role;
select t.ok((select count(*) from public.club_members where club_id = :'club1' and user_id = :'p01' and status = 'active'
              and member_role = 'player') = 1, 'E4 exactly one active player membership');
select t.ok((select role from public.profiles where id = :'p01') is distinct from 'club_owner'
            and not exists (select 1 from public.user_roles where user_id = :'p01' and role::text = 'club_owner'),
            'E5 no role escalation: profiles.role and user_roles untouched');
set role authenticated;
select t.as_user(:'p01');
select t.ok((select club_code from public.my_club_memberships()) = :'code1', 'E6 the member sees the membership and code');
select t.expect_error(format('select public.request_to_join_club(%L)', :'code1'), '%already member%', 'E7 a member cannot request again');
select t.ok((select count(*) from public.club_members) = 1, 'E8 RLS: a member sees only their own membership row');
select t.as_user(:'p02');
select id as req_p02 from public.request_to_join_club(:'code1') \gset
select t.as_user(:'owner1');
select t.expect_error(format('select public.decide_join_request(%L, false, %L, %L)', :'req_p02', 'player', repeat('x', 121)),
                      '23514', 'E9 an over-long decline reason is refused');
select t.ok((public.decide_join_request(:'req_p02', false, 'player', '  Squad full  ')).decline_reason = 'Squad full',
            'E10 decline keeps a trimmed reason');
select t.as_user(:'p02');
select t.ok((select status from public.my_join_requests() limit 1) = 'rejected', 'E11 the applicant sees the rejection');
select t.as_user(:'p03');
select id as req_p03 from public.request_to_join_club(:'code1') \gset
select t.ok((public.cancel_join_request(:'req_p03')).status = 'cancelled', 'E12 the applicant cancels');
select t.expect_error(format('select public.cancel_join_request(%L)', :'req_p03'), '%not pending%', 'E13 cancelling twice is refused');
select t.as_user(:'owner1');
select t.ok(not exists (select 1 from public.club_join_requests(:'club1') where request_id = :'req_p03'),
            'E14 cancelled requests are hidden from the owner list');
reset role;

-- ---------------------------------------------------------------------------
-- F. Removal and re-joining
-- ---------------------------------------------------------------------------
select id as mem_p01 from public.club_members where club_id = :'club1' and user_id = :'p01' \gset
select id as mem_owner1 from public.club_members where club_id = :'club1' and member_role = 'owner' \gset
set role authenticated;
select t.as_user(:'outsider');
select t.expect_error(format('select public.remove_club_member(%L)', :'mem_p01'), '%not allowed%', 'F1 an outsider cannot remove');
select t.as_user(:'owner2');
select t.expect_error(format('select public.remove_club_member(%L)', :'mem_p01'), '%not allowed%', 'F2 another owner cannot remove');
select t.as_user(:'owner1');
select t.expect_error(format('select public.remove_club_member(%L)', :'mem_owner1'), '%not allowed%', 'F3 the owner row cannot be removed');
select t.ok((public.remove_club_member(:'mem_p01')).status = 'removed', 'F4 the owner removes a member');
select t.ok((public.remove_club_member(:'mem_p01')).status = 'removed', 'F5 removing again is harmless');
select t.as_user(:'p01');
select t.ok((select count(*) from public.my_club_memberships()) = 0, 'F6 the removed person has no membership');
select id as req_p01b from public.request_to_join_club(:'code1') \gset
select t.as_user(:'owner1');
select t.ok((public.decide_join_request(:'req_p01b', true, 'coach')).status = 'approved', 'F7 re-approval');
reset role;
select t.ok((select id from public.club_members where club_id = :'club1' and user_id = :'p01') = :'mem_p01'
            and (select member_role from public.club_members where id = :'mem_p01') = 'coach'
            and (select removed_at from public.club_members where id = :'mem_p01') is null,
            'F8 re-joining re-activates the same row with the new role');

-- ---------------------------------------------------------------------------
-- G. Direct DML, internal helpers, identity
-- ---------------------------------------------------------------------------
set role authenticated;
select t.as_user(:'owner1');
select t.expect_error(format('insert into public.club_members (club_id, user_id, member_role) values (%L, %L, %L)', :'club1', :'outsider', 'player'),
                      '%permission denied%', 'G1 direct INSERT into club_members blocked');
select t.expect_error(format('update public.club_members set member_role = %L where id = %L', 'owner', :'mem_p01'),
                      '%permission denied%', 'G2 direct UPDATE (role escalation) blocked');
select t.expect_error(format('delete from public.join_requests where id = %L', :'req_p02'), '%permission denied%',
                      'G3 direct DELETE from join_requests blocked');
select t.expect_error(format('insert into public.join_requests (club_id, user_id) values (%L, %L)', :'club1', :'p03'),
                      '%permission denied%', 'G4 direct INSERT into join_requests blocked');
select t.expect_error('select * from public.club_code_attempts', '%permission denied%', 'G5 the throttle table is not readable');
select t.expect_error(format('delete from public.club_code_attempts where user_id = %L', :'p16'), '%permission denied%',
                      'G6 the throttle cannot be reset by a user');
select t.expect_error(format('select public.club_code_failed(%L)', :'owner1'), '%permission denied%', 'G7 club_code_failed not callable');
select t.expect_error(format('select public.club_code_throttled(%L)', :'owner1'), '%permission denied%', 'G8 club_code_throttled not callable');
select t.expect_error('select public.clubs_add_owner_member()', '%permission denied%', 'G9 the owner trigger function not callable');
select t.expect_error('select public.club_members_leave_teams()', '%permission denied%', 'G10 the team trigger function not callable');
reset role;
set role anon;
select t.expect_error('select * from public.club_members', '%permission denied%', 'G11 anon cannot read club_members');
select t.expect_error(format('select public.is_club_owner(%L)', :'club1'), '%permission denied%', 'G12 anon cannot call is_club_owner');
select t.expect_error('select * from public.my_join_requests()', '%permission denied%', 'G13 anon cannot call my_join_requests');
reset role;
set role authenticated;
select set_config('request.jwt.claims', '', false);
select t.expect_error(format('select public.request_to_join_club(%L)', :'code1'), '%not authenticated%',
                      'G14 no session (no auth.uid()) → not authenticated');
reset role;
select t.ok(not exists (
  select 1 from pg_proc p, unnest(coalesce(p.proargnames, '{}'::text[])) a
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('lookup_club_by_code', 'request_to_join_club', 'cancel_join_request', 'decide_join_request',
                       'remove_club_member', 'club_join_requests', 'club_member_list', 'my_club_memberships',
                       'my_join_requests', 'create_team', 'save_team', 'archive_team')
     and a in ('p_user_id', 'p_uid', 'p_owner_id', 'p_role_claim')),
  'G15 identity: no callable function accepts a user id (auth.uid() only)');

-- ---------------------------------------------------------------------------
-- H. Teams and squads
-- ---------------------------------------------------------------------------
-- 14 more players join club 1 (requests and approvals through the functions).
select format('set role authenticated; select t.as_user(%L); select public.request_to_join_club(%L); reset role;', u, :'code1')
  from (select format('c0000000-0000-4000-8000-%s', lpad(g::text, 12, '0'))::uuid u from generate_series(4, 15) g) s \gexec
select format('set role authenticated; select t.as_user(%L); select public.request_to_join_club(%L); reset role;', :'p02', :'code1') \gexec
select format('set role authenticated; select t.as_user(%L); select public.request_to_join_club(%L); reset role;', :'p03', :'code1') \gexec
select format('set role authenticated; select t.as_user(%L); select public.decide_join_request(%L, true); reset role;', :'owner1', r.id)
  from public.join_requests r where r.club_id = :'club1' and r.status = 'pending' \gexec
-- One member of club 2, for cross-club checks.
select format('set role authenticated; select t.as_user(%L); select public.request_to_join_club(%L); reset role;',
              'c0000000-0000-4000-8000-000000000017', :'code2') \gexec
select format('set role authenticated; select t.as_user(%L); select public.decide_join_request(%L, true); reset role;', :'owner2', r.id)
  from public.join_requests r where r.club_id = :'club2' and r.status = 'pending' \gexec

select t.ok((select count(*) from public.club_members where club_id = :'club1' and status = 'active') = 16,
            'H0 club 1 has the owner and 15 active members');

-- Squads as JSON: 11 playing + 4 subs from club 1's players (owner excluded).
select jsonb_agg(jsonb_build_object('member_id', id, 'selection', case when rn <= 11 then 'playing' else 'sub' end) order by rn) as squad15,
       jsonb_agg(jsonb_build_object('member_id', id, 'selection', 'playing') order by rn) filter (where rn <= 12) as squad12playing,
       jsonb_agg(jsonb_build_object('member_id', id, 'selection', case when rn <= 10 then 'playing' else 'sub' end) order by rn) filter (where rn <= 15) as squad5subs,
       (array_agg(id order by rn))[1] as m1, (array_agg(id order by rn))[2] as m2, (array_agg(id order by rn))[15] as m15
  from (select m.id, row_number() over (order by m.joined_at, m.id) rn
          from public.club_members m where m.club_id = :'club1' and m.status = 'active' and m.member_role <> 'owner') s \gset
select id as foreign_member from public.club_members where club_id = :'club2' and member_role <> 'owner' \gset

set role authenticated;
select t.as_user(:'owner1');
select id as team1 from public.create_team(:'club1', 'First XI', 't20') \gset
select t.expect_error(format('select public.create_team(%L, %L, %L)', :'club1', '  first   xi ', 'odi'), '%duplicate name%',
                      'H1 duplicate team name (case and spaces ignored)');
select t.expect_error(format('select public.create_team(%L, %L, %L)', :'club1', 'Custom', 'custom'), '%team: invalid%',
                      'H2 custom format needs overs');
select t.expect_error(format('select public.create_team(%L, %L, %L, 60)', :'club1', 'Custom', 'custom'), '%team: invalid%',
                      'H3 overs above 50 refused');
select t.expect_error(format('select public.create_team(%L, %L, %L, 40000)', :'club1', 'Custom', 'custom'), '%team: invalid%',
                      'H4 out-of-range overs refused cleanly');
select t.expect_error(format('select public.create_team(%L, %L, %L)', :'club1', repeat('x', 41), 't20'), '%team: invalid%',
                      'H5 names over 40 characters refused');
select t.ok((public.save_team(:'team1', 'First XI', 't20', null, null, null, :'squad15'::jsonb)).id = :'team1',
            'H6 11 playing + 4 substitutes saved');
select t.expect_error(format('select public.save_team(%L, %L, %L, null, null, null, %L::jsonb)', :'team1', 'First XI', 't20', :'squad12playing'),
                      '%squad full%', 'H7 12 playing refused');
select t.expect_error(format('select public.save_team(%L, %L, %L, null, null, null, %L::jsonb)', :'team1', 'First XI', 't20', :'squad5subs'),
                      '%squad full%', 'H8 5 substitutes refused');
select t.expect_error(format('select public.save_team(%L, %L, %L, null, null, null, %L::jsonb)', :'team1', 'First XI', 't20',
                             jsonb_build_array(jsonb_build_object('member_id', :'m1', 'selection', 'playing'),
                                               jsonb_build_object('member_id', :'m1', 'selection', 'sub'))),
                      '%team: invalid%', 'H9 the same player twice refused');
select t.expect_error(format('select public.save_team(%L, %L, %L, null, null, null, %L::jsonb)', :'team1', 'First XI', 't20',
                             jsonb_build_array(jsonb_build_object('member_id', :'foreign_member', 'selection', 'playing'))),
                      '%player not in club%', 'H10 another club''s member refused');
select t.expect_error(format('select public.save_team(%L, %L, %L, null, null, null, %L::jsonb)', :'team1', 'First XI', 't20',
                             '[{"member_id": "not-a-uuid", "selection": "playing"}]'), '%team: invalid%', 'H11 malformed squad JSON refused');
select t.expect_error(format('select public.save_team(%L, %L, %L, null, %L, %L, %L::jsonb)', :'team1', 'First XI', 't20', :'m1', :'m1', :'squad15'),
                      '%team: invalid%', 'H12 captain and vice-captain must differ');
select t.expect_error(format('select public.save_team(%L, %L, %L, null, %L, null, %L::jsonb)', :'team1', 'First XI', 't20', :'mem_owner1', :'squad15'),
                      '%team: invalid%', 'H13 the captain must be in the squad');
select t.ok((public.save_team(:'team1', 'First XI', 't20', null, :'m1', :'m2', :'squad15'::jsonb)).captain_member_id = :'m1',
            'H14 captain and vice-captain saved');
reset role;
select t.ok((select count(*) from public.team_players where team_id = :'team1') = 15
            and (select count(distinct position) from public.team_players where team_id = :'team1') = 15,
            'H15 15 squad places with unique positions');
select t.expect_error(format('insert into public.team_players (team_id, member_id, selection, position) values (%L, %L, %L, 1)',
                             :'team1', :'mem_owner1', 'sub'), '23505', 'H16 duplicate squad position refused (unique)');
select t.expect_error(format('insert into public.team_players (team_id, member_id, selection, position) values (%L, %L, %L, 15)',
                             :'team1', :'foreign_member', 'sub'), '%player not in club%', 'H17 trigger refuses a foreign member even for direct writes');
set role authenticated;
select t.as_user(:'owner1');
select id as team2 from public.create_team(:'club1', 'Second XI', 'odi') \gset
select t.expect_error(format('select public.save_team(%L, %L, %L, null, null, null, %L::jsonb)', :'team2', 'First XI', 'odi', '[]'),
                      '%duplicate name%', 'H18 renaming onto another team''s name refused');
select t.ok((public.save_team(:'team2', 'Reserves', 'custom', 20, null, null, '[]'::jsonb)).custom_overs = 20,
            'H19 editing name / format / overs');

-- Unauthorized team changes
select t.as_user(:'owner2');
select t.ok((select count(*) from public.teams) = 0, 'H20 RLS: another club''s owner sees no teams');
select t.expect_error(format('select public.save_team(%L, %L, %L, null, null, null, %L::jsonb)', :'team1', 'X', 't20', '[]'),
                      '%not allowed%', 'H21 another owner cannot edit');
select t.expect_error(format('select public.archive_team(%L)', :'team1'), '%not allowed%', 'H22 another owner cannot archive');
select t.expect_error(format('select public.create_team(%L, %L, %L)', :'club1', 'Mine', 't20'), '%not allowed%',
                      'H23 another owner cannot create teams in the club');
select t.as_user(:'p01');
select t.ok((select count(*) from public.teams) = 0 and (select count(*) from public.team_players) = 0,
            'H24 RLS: a member sees no team rows');
select t.expect_error(format('update public.teams set name = %L where id = %L', 'Hacked', :'team1'), '%permission denied%',
                      'H25 direct UPDATE of teams blocked');
select t.expect_error(format('delete from public.team_players where team_id = %L', :'team1'), '%permission denied%',
                      'H26 direct DELETE of team_players blocked');

-- A removed member leaves every squad; captaincy cleared
select t.as_user(:'owner1');
select t.ok((public.remove_club_member(:'m1')).status = 'removed', 'H27 the captain is removed from the club');
reset role;
select t.ok(not exists (select 1 from public.team_players where member_id = :'m1')
            and (select captain_member_id from public.teams where id = :'team1') is null
            and (select vice_captain_member_id from public.teams where id = :'team1') = :'m2',
            'H28 removed from the squad; captain cleared, vice-captain kept');
set role authenticated;
select t.as_user(:'owner1');
select t.expect_error(format('select public.save_team(%L, %L, %L, null, null, null, %L::jsonb)', :'team1', 'First XI', 't20', :'squad15'),
                      '%player not in club%', 'H29 a removed member cannot be re-added');

-- Archive ("delete")
select t.ok((public.archive_team(:'team1')).status = 'archived', 'H30 archive');
select t.ok((public.archive_team(:'team1')).status = 'archived', 'H31 archiving again is harmless');
select t.expect_error(format('select public.save_team(%L, %L, %L, null, null, null, %L::jsonb)', :'team1', 'First XI', 't20', '[]'),
                      '%archived%', 'H32 an archived team cannot be edited');
select t.ok((public.create_team(:'club1', 'First XI', 't20')).id <> :'team1', 'H33 the name is free again');
reset role;
select t.ok((select count(*) from public.teams where id = :'team1') = 1, 'H34 the archived row is kept');

-- ---------------------------------------------------------------------------
-- J. Lookup output shape
-- ---------------------------------------------------------------------------
select t.ok(pg_get_function_result('public.lookup_club_by_code(text)'::regprocedure) not like '%owner%'
            and pg_get_function_result('public.lookup_club_by_code(text)'::regprocedure) not like '%code%',
            'J1 the lookup never returns the owner or the code');

\echo ALL MEMBERSHIP / TEAM CHECKS PASSED
