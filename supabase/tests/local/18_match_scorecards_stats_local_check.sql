-- CricEco · LOCAL TEST ONLY — migrations 21 (scorecards), 22 (player
-- statistics) and 23 (my_matches) on a DISPOSABLE plain PostgreSQL 17
-- database, after 00_auth_stub.sql, 02_legacy_profiles_fixture.sql,
-- migrations 1–20 (+ the D1 location seed) and migrations 21–23. Synthetic
-- accounts only (ids ed…).
-- Run with psql:  psql -X -v ON_ERROR_STOP=1 -f 18_match_scorecards_stats_local_check.sql
-- Every check prints "PASS: …"; the first failure stops the run ("FAIL: …").
-- Concurrency (two sessions) is in 18b_match_scorecards_concurrency.sh.
-- Refuses to run on a real Supabase project (its auth.users has passwords).
\set ON_ERROR_STOP on

do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password') then
    raise exception 'LOCAL ONLY: this looks like a real Supabase project — refusing';
  end if;
  if to_regclass('public.match_batting') is null or to_regprocedure('public.player_stats(uuid)') is null
     or to_regprocedure('public.my_matches()') is null then
    raise exception 'apply migrations 21–23 first';
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
create or replace function t.no_session() returns void language sql as $$
  select set_config('request.jwt.claims', '', false);
$$;
-- Person n (1–3 owners of clubs A/B/C, 101–116 club A, 201–215 club B,
-- 301 club C, 400 no club) and match n.
create or replace function t.p(p_n int) returns uuid language sql immutable as $$
  select ('ed000000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
$$;
create or replace function t.m(p_n int) returns uuid language sql immutable as $$
  select ('ed0000aa-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
$$;
-- Membership id of person n (any club, any status). Reads past RLS.
create or replace function t.mem(p_n int) returns uuid language sql stable security definer set search_path = '' as $$
  select m.id from public.club_members m where m.user_id = ('ed000000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
$$;
create or replace function t.club(p_owner int) returns uuid language sql stable security definer set search_path = '' as $$
  select c.id from public.clubs c where c.owner_id = ('ed000000-0000-4000-8000-' || lpad(p_owner::text, 12, '0'))::uuid;
$$;
create or replace function t.make_person(p_n int) returns uuid language plpgsql as $$
declare
  v uuid := t.p(p_n);
begin
  insert into auth.users (id, email) values (v, format('card%s@local.test', p_n));
  insert into public.current_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
  insert into public.permanent_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
  update public.profiles
     set full_name = format('Card Person %s', p_n),
         phone = format('+923%s', lpad((580000000 + p_n)::text, 9, '0')),
         date_of_birth = date '2000-05-01', profile_completed = true
   where id = v;
  insert into public.player_profiles (user_id, player_role, batting_style, bowling_style, is_wicketkeeper)
  values (v, 'all_rounder', 'right_handed', 'right_arm_fast', false);
  return v;
end $$;
-- Card rows by person number.
create or replace function t.bat(p_n int, p_runs int, p_balls int, p_fours int, p_sixes int, p_how text,
                                 p_bowler int default null, p_fielder int default null, p_direct boolean default null)
returns jsonb language sql stable as $$
  select jsonb_strip_nulls(jsonb_build_object(
           'member_id', t.mem(p_n), 'runs', p_runs, 'balls', p_balls, 'fours', p_fours, 'sixes', p_sixes,
           'dismissal', p_how, 'bowler_member_id', t.mem(p_bowler), 'fielder_member_id', t.mem(p_fielder),
           'direct_hit', p_direct));
$$;
create or replace function t.bowl(p_n int, p_balls int, p_maidens int, p_runs int, p_wides int default 0, p_nb int default 0)
returns jsonb language sql stable as $$
  select jsonb_build_object('member_id', t.mem(p_n), 'balls', p_balls, 'maidens', p_maidens, 'runs', p_runs,
                            'wides', p_wides, 'no_balls', p_nb);
$$;
-- A refused scorecard for match 1 (as the current user).
create or replace function t.badc(p_innings jsonb, p_name text) returns void language sql as $$
  select t.expect_error(format('select public.submit_match_result_with_scorecard(%L, %L, %L)', t.m(1), 'club_a_won', p_innings),
                        '%invalid scorecard%', p_name);
$$;
create or replace function t.stat(p_user int) returns jsonb language sql as $$
  select to_jsonb(s) from public.player_stats(t.p(p_user)) s;
$$;
grant execute on all functions in schema t to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Synthetic data. Club A "Card Lions" (owner 1; players 101–116), club B
-- "Card Kings" (owner 2; players 201–215, 215 then removed), club C "Card
-- Riders" (owner 3; player 301), 400 in no club. Matches A vs B:
--   m1 T20 played — A saved its line-up before the start (XI 101–111,
--      subs 112–115, captain 101, vice 102; 116 not picked); B saved none
--   m2 T20 tomorrow · m3 cancelled after scheduling · m4 pending ·
--   m5 / m6 T20 played (totals-only checks)
-- ---------------------------------------------------------------------------
select count(*) from (select t.make_person(n) from unnest(array[1, 2, 3, 301, 400]
                        || array(select generate_series(101, 116)) || array(select generate_series(201, 215))) n) s;
insert into public.clubs (owner_id, name, city, club_type) values
  (t.p(1), 'Card Lions', 'Lahore', 'corporate'),
  (t.p(2), 'Card Kings', 'Karachi', 'corporate'),
  (t.p(3), 'Card Riders', 'Lahore', 'corporate');
insert into public.club_members (club_id, user_id, member_role, status)
select t.club(case when n < 200 then 1 when n < 300 then 2 else 3 end), t.p(n), 'player', 'active'
  from unnest(array[301] || array(select generate_series(101, 116)) || array(select generate_series(201, 215))) n;
insert into public.matches (id, club_a_id, club_b_id, format, status, starts_at, venue_name, cancelled_at,
                            cancelled_by_club_id, cancel_reason)
select t.m(k), t.club(1), t.club(2), 't20', s, st, case when st is null then null else 'Card Ground' end,
       case when s = 'cancelled' then now() end, case when s = 'cancelled' then t.club(1) end,
       case when s = 'cancelled' then 'Rain' end
  from (values (1, 'confirmed', now() + interval '1 hour'), (2, 'confirmed', now() + interval '1 day'),
               (3, 'cancelled', now() - interval '3 days'), (4, 'pending', null::timestamptz),
               (5, 'confirmed', now() - interval '5 days'), (6, 'confirmed', now() - interval '6 days')) v(k, s, st);
set role authenticated;
select t.as_user(t.p(1));
select name from public.save_match_lineup(t.m(1), 'Card XI', null,
  (select jsonb_agg(jsonb_build_object('member_id', t.mem(n), 'selection', case when n <= 111 then 'playing' else 'sub' end) order by n)
     from generate_series(101, 115) n), t.mem(101), t.mem(102));
select t.as_user(t.p(2));
select status from public.remove_club_member(t.mem(215));
reset role;
-- The match is played: its start moves into the past (the guard would refuse).
set session_replication_role = replica;
update public.matches set starts_at = now() - interval '1 day' where id = t.m(1);
set session_replication_role = default;

-- The scorecard of m1 (club_a_won by 30 runs):
-- A 150/3 (120 balls; b 1, lb 2, w 3, nb 1): 101 60 c 205 b 201, 102 45 b 202,
--   103 20 run out (203, direct hit), 104 15*, 105 3*, 106–111 did not bat;
--   B bowls 201 24-0-35 (w 2, nb 1), 202 24-0-30 (w 1), 203 24-0-27,
--   204 24-0-25, 205 24-0-30.
-- B 120 all out (110 balls; lb 1, w 2): 201 40 c sub (112) b 101, 202 0 lbw
--   b 102, 203 25 st 104 b 103, 204 12 b 101, 205 10 c & b 102, 206 8 run
--   out (105), 207 7 hit wicket b 103, 208 6 c 106 b 104, 209 5 b 104,
--   210 4 c 107 b 105, 211 0*; A bowls 101 24-0-30 (w 2), 102 24-0-25,
--   103 24-1-22, 104 24-0-20, 105 14-0-22.
select jsonb_build_array(
  jsonb_build_object('batting_club_id', t.club(1), 'runs', 150, 'wickets', 3, 'balls', 120,
                     'byes', 1, 'leg_byes', 2, 'wides', 3, 'no_balls', 1,
    'batting', jsonb_build_array(
       t.bat(101, 60, 40, 6, 2, 'caught', 201, 205), t.bat(102, 45, 35, 4, 1, 'bowled', 202),
       t.bat(103, 20, 20, 2, 0, 'run_out', null, 203, true), t.bat(104, 15, 15, 1, 0, 'not_out'),
       t.bat(105, 3, 10, 0, 0, 'not_out'), t.bat(106, 0, 0, 0, 0, 'did_not_bat'), t.bat(107, 0, 0, 0, 0, 'did_not_bat'),
       t.bat(108, 0, 0, 0, 0, 'did_not_bat'), t.bat(109, 0, 0, 0, 0, 'did_not_bat'), t.bat(110, 0, 0, 0, 0, 'did_not_bat'),
       t.bat(111, 0, 0, 0, 0, 'did_not_bat')),
    'bowling', jsonb_build_array(t.bowl(201, 24, 0, 35, 2, 1), t.bowl(202, 24, 0, 30, 1), t.bowl(203, 24, 0, 27),
                                 t.bowl(204, 24, 0, 25), t.bowl(205, 24, 0, 30))),
  jsonb_build_object('batting_club_id', t.club(2), 'runs', 120, 'wickets', 10, 'balls', 110, 'leg_byes', 1, 'wides', 2,
    'batting', jsonb_build_array(
       t.bat(201, 40, 30, 4, 1, 'caught', 101, 112), t.bat(202, 0, 2, 0, 0, 'lbw', 102),
       t.bat(203, 25, 20, 2, 0, 'stumped', 103, 104), t.bat(204, 12, 15, 1, 0, 'bowled', 101),
       t.bat(205, 10, 10, 1, 0, 'caught', 102, 102), t.bat(206, 8, 8, 0, 0, 'run_out', null, 105),
       t.bat(207, 7, 7, 0, 0, 'hit_wicket', 103), t.bat(208, 6, 6, 0, 0, 'caught', 104, 106),
       t.bat(209, 5, 5, 0, 0, 'bowled', 104), t.bat(210, 4, 5, 0, 0, 'caught', 105, 107),
       t.bat(211, 0, 2, 0, 0, 'not_out')),
    'bowling', jsonb_build_array(t.bowl(101, 24, 0, 30, 2), t.bowl(102, 24, 0, 25), t.bowl(103, 24, 1, 22),
                                 t.bowl(104, 24, 0, 20), t.bowl(105, 14, 0, 22)))) as card \gset
select :'card'::jsonb #- '{0,batting}' #- '{0,bowling}' #- '{1,batting}' #- '{1,bowling}' as totals \gset

-- ---------------------------------------------------------------------------
-- P. The player pools (match_player_pool)
-- ---------------------------------------------------------------------------
set role anon;
select t.expect_error(format('select * from public.match_player_pool(%L)', t.m(1)), '%permission denied%', 'P1 anon cannot read a pool');
select t.expect_error(format('select public.submit_match_result_with_scorecard(%L, %L, %L)', t.m(1), 'club_a_won', :'card'),
                      '%permission denied%', 'P1b anon cannot submit a scorecard');
select t.expect_error(format('select * from public.match_scorecard(%L)', t.m(1)), '%permission denied%', 'P1c anon cannot read a scorecard');
select t.expect_error(format('select * from public.player_stats(%L)', t.p(101)), '%permission denied%', 'P1d anon cannot read stats');
select t.expect_error('select * from public.my_matches()', '%permission denied%', 'P1e anon cannot call my_matches');
reset role;
set role authenticated;
select t.no_session();
select t.expect_error(format('select * from public.match_player_pool(%L)', t.m(1)), '%not authenticated%', 'P2 no session: not authenticated');
select t.as_user(t.p(101));
select t.expect_error(format('select * from public.match_player_pool(%L)', t.m(1)), '%result: not allowed%',
                      'P3 a member (not an owner) can''t read the pools');
select t.as_user(t.p(3));
select t.expect_error(format('select * from public.match_player_pool(%L)', t.m(1)), '%result: not allowed%',
                      'P4 another club''s owner can''t read the pools');
select t.as_user(t.p(1));
select t.ok((select count(*) = 17 and bool_and(club_id = t.club(1) and selection = 'member')
               from public.match_player_pool(t.m(2))),
            'P5 before the start: the own club only (m2: no line-up → its 17 active members)');
select t.ok((select count(*) filter (where club_id = t.club(1)) = 15
                    and count(*) filter (where club_id = t.club(1) and selection = 'playing') = 11
                    and count(*) filter (where club_id = t.club(1) and selection = 'sub') = 4
                    and count(*) filter (where club_id = t.club(2)) = 15
                    and bool_and(selection = 'member') filter (where club_id = t.club(2))
                    and not bool_or(member_id = t.mem(215)) and not bool_or(member_id = t.mem(116))
               from public.match_player_pool(t.m(1))),
            'P6 after the start: A''s line-up (11 + 4) and B''s active members (owner + 14; removed 215 left out)');
select t.ok((select string_agg(full_name, ',' order by pick_order) from public.match_player_pool(t.m(1))
              where club_id = t.club(1) and pick_order <= 2) = 'Card Person 101,Card Person 102',
            'P7 the line-up comes in pick order, with names');
select t.as_user(t.p(2));
select t.ok((select count(*) from public.match_player_pool(t.m(1))) = 30, 'P8 the other owner sees both pools too');

-- ---------------------------------------------------------------------------
-- I. Invalid scorecards: refused, nothing stored
-- ---------------------------------------------------------------------------
select t.as_user(t.p(1));
select t.badc(:'card'::jsonb #- '{1,batting}' #- '{1,bowling}', 'I1 cards on one innings only (all-or-nothing)');
select t.badc(:'card'::jsonb #- '{1,bowling}', 'I2 a batting card without its bowling card');
select t.badc(jsonb_set(:'card', '{0,batting}', '"x"'), 'I3 batting not an array');
select t.badc(jsonb_set(:'card', '{0,bowling}', '[]'), 'I4 an empty bowling card');
select t.badc(jsonb_set(:'card', '{0,batting,5,member_id}', to_jsonb(t.mem(112))), 'I5 a substitute batting');
select t.badc(jsonb_set(jsonb_set(:'card', '{1,bowling,4,member_id}', to_jsonb(t.mem(112))),
                        '{1,batting,9,bowler_member_id}', to_jsonb(t.mem(112))), 'I6 a substitute bowling');
select t.badc(jsonb_set(:'card', '{0,batting,5,member_id}', to_jsonb(t.mem(116))),
              'I7 a member left out of the saved line-up batting');
select t.badc(jsonb_set(:'card', '{0,batting,5,member_id}', to_jsonb(t.mem(201))), 'I8 the other club''s player batting');
select t.badc(jsonb_set(:'card', '{1,batting,10,member_id}', to_jsonb(t.mem(215))),
              'I9 a removed member batting (no line-up: active members only)');
select t.badc(jsonb_set(:'card', '{0,batting,0,fielder_member_id}', to_jsonb(t.mem(301))), 'I10 a third club''s player fielding');
select t.badc(jsonb_set(:'card', '{0,batting,5,member_id}', to_jsonb(t.mem(101))), 'I11 the same batter twice');
select t.badc(jsonb_set(:'card', '{0,bowling,1,member_id}', to_jsonb(t.mem(201))), 'I12 the same bowler twice');
select t.badc(jsonb_set(:'card', '{0,batting,0,runs}', '61'), 'I13 batters'' runs + extras ≠ the innings runs');
select t.badc(jsonb_set(:'card', '{0,batting,4,dismissal}', '"retired_out"'), 'I14 dismissals ≠ the innings wickets');
select t.badc(jsonb_set(:'card', '{0,batting,5,dismissal}', '"not_out"'), 'I15 three not out');
select t.badc(jsonb_set(:'card', '{0,batting,0,fielder_member_id}', 'null'), 'I16 caught without a fielder');
select t.badc(jsonb_set(:'card', '{0,batting,1,bowler_member_id}', 'null'), 'I17 bowled without a bowler');
select t.badc(jsonb_set(:'card', '{0,batting,2,bowler_member_id}', to_jsonb(t.mem(201))), 'I18 a run out credited to a bowler');
select t.badc(jsonb_set(:'card', '{0,batting,1,bowler_member_id}', to_jsonb(t.mem(206))), 'I19 a bowler not on the bowling card');
select t.badc(jsonb_set(:'card', '{0,batting,3,fielder_member_id}', to_jsonb(t.mem(206))), 'I20 a fielder on a not out');
select t.badc(jsonb_set(:'card', '{0,batting,0,direct_hit}', 'true'), 'I21 a direct hit on a catch');
select t.badc(jsonb_set(:'card', '{0,batting,5,balls}', '1'), 'I22 did not bat, but faced a ball');
select t.badc(jsonb_set(:'card', '{0,batting,4,fours}', '1'), 'I23 boundaries above the runs');
select t.badc(jsonb_set(:'card', '{0,batting,0,dismissal}', '"caught_behind"'), 'I24 an unknown dismissal');
select t.badc(jsonb_set(:'card', '{0,batting,0,member_id}', '"abc"'), 'I25 a malformed member id');
select t.badc(jsonb_set(:'card', '{0,batting,0,runs}', '"lots"'), 'I26 non-numeric runs');
select t.badc(jsonb_set(jsonb_set(:'card', '{0,bowling,0,balls}', '30'), '{0,bowling,1,balls}', '18'),
              'I27 a bowler beyond 4 overs in a T20');
select t.badc(jsonb_set(:'card', '{0,bowling,4,balls}', '23'), 'I28 bowlers'' balls ≠ the innings balls');
select t.badc(jsonb_set(:'card', '{0,bowling,4,runs}', '31'), 'I29 bowlers'' runs ≠ runs − byes − leg byes − penalty');
select t.badc(jsonb_set(:'card', '{0,bowling,1,wides}', '0'), 'I30 bowlers'' wides ≠ the innings wides');
select t.badc(jsonb_set(:'card', '{0,bowling,0,wickets}', '2'), 'I31 a bowler''s wickets ≠ the dismissals credited');
select t.badc(jsonb_set(:'card', '{0,bowling,2,maidens}', '5'), 'I32 more maidens than overs');
select t.badc(jsonb_set(:'card', '{0,bowling,4,member_id}', to_jsonb(t.mem(301))), 'I33 a third club''s player bowling');
reset role;
select t.ok(not exists (select 1 from public.match_results where match_id = t.m(1))
            and not exists (select 1 from public.match_batting) and not exists (select 1 from public.match_bowling),
            'I34 nothing was stored by the refusals (not even the result)');

-- ---------------------------------------------------------------------------
-- S. A valid scorecard
-- ---------------------------------------------------------------------------
set role authenticated;
select t.as_user(t.p(1));
select (public.submit_match_result_with_scorecard(t.m(1), 'club_a_won', jsonb_set(:'card', '{0,bowling,0,wickets}', '1'),
                                                  t.mem(101))).version as v1 \gset
reset role;
select t.ok(:v1 = 1 and (select margin_runs = 30 and status = 'submitted' from public.match_results where match_id = t.m(1)),
            'S1 the result with its cards is stored (A won by 30 runs; a correct "wickets" accepted)');
select t.ok((select count(*) from public.match_batting where match_id = t.m(1)) = 22
            and (select count(*) from public.match_bowling where match_id = t.m(1)) = 10,
            'S2 22 batting rows and 10 bowling rows');
select t.ok((select string_agg(w.wickets::text, ',' order by w.bowler_no) from public.match_bowling w
              where w.match_id = t.m(1) and w.innings_no = 2) = '2,2,2,2,1'
            and (select string_agg(w.wickets::text, ',' order by w.bowler_no) from public.match_bowling w
                  where w.match_id = t.m(1) and w.innings_no = 1) = '1,1,0,0,0',
            'S3 bowlers'' wickets computed from the dismissals (run outs credit nobody)');
select t.ok((select fielder_substitute and player_name = 'Card Person 201' and fielder_name = 'Card Person 112'
               from public.match_batting where match_id = t.m(1) and innings_no = 2 and position = 1)
            and (select bool_and(not fielder_substitute) from public.match_batting
                  where match_id = t.m(1) and not (innings_no = 2 and position = 1)),
            'S4 the substitute''s catch is marked "substitute"');
set role authenticated;
select t.as_user(t.p(2));
select t.ok((select string_agg(b ->> 'dismissal_text', ' | ' order by (b ->> 'position')::int)
               from public.match_scorecard(t.m(1), 1) s, jsonb_array_elements(s.batting) b where s.innings_no = 1)
            = 'c Card Person 205 b Card Person 201 | b Card Person 202 | run out (Card Person 203) | not out | not out'
              || ' | did not bat | did not bat | did not bat | did not bat | did not bat | did not bat',
            'S5 dismissal texts, innings 1');
select t.ok((select string_agg(b ->> 'dismissal_text', ' | ' order by (b ->> 'position')::int)
               from public.match_scorecard(t.m(1), 1) s, jsonb_array_elements(s.batting) b
              where s.innings_no = 2 and (b ->> 'position')::int <= 7)
            = 'c sub (Card Person 112) b Card Person 101 | lbw b Card Person 102 | st Card Person 104 b Card Person 103'
              || ' | b Card Person 101 | c & b Card Person 102 | run out (Card Person 105) | hit wicket b Card Person 103',
            'S6 dismissal texts, innings 2: c sub, lbw, st, b, c & b, run out, hit wicket');
select t.ok((select count(*) from public.match_scorecard(t.m(1), 1)) = 2
            and (select jsonb_array_length(bowling) from public.match_scorecard(t.m(1), 1) where innings_no = 2) = 5,
            'S7 the other owner reads the waiting scorecard (2 innings)');
select t.as_user(t.p(201));
select t.ok((select count(*) from public.match_scorecard(t.m(1))) = 0 and (select count(*) from public.match_scorecard(t.m(1), 1)) = 0
            and (select count(*) from public.match_batting) = 0,
            'S8 a member sees no scorecard while the result waits (function and RLS)');
select t.as_user(t.p(2));
select public.confirm_match_result(t.m(1), 1);
select t.as_user(t.p(201));
select t.ok((select count(*) from public.match_scorecard(t.m(1))) = 2 and (select count(*) from public.match_batting) = 22
            and (select count(*) from public.match_bowling) = 10,
            'S9 once confirmed, members of both clubs read the scorecard');
select t.as_user(t.p(400));
select t.expect_error(format('select * from public.match_scorecard(%L)', t.m(1)), '%result: not allowed%',
                      'S10 an outsider can''t read the scorecard');
select t.ok((select count(*) from public.match_batting) = 0 and (select count(*) from public.match_bowling) = 0,
            'S11 RLS: an outsider reads no card rows');
select t.as_user(t.p(3));
select t.ok((select count(*) from public.match_batting) = 0, 'S12 RLS: another club''s owner reads no card rows');
select t.as_user(t.p(1));
select t.expect_error(format('insert into public.match_bowling (match_id, version, innings_no, bowler_no, member_id, player_name, balls, runs) values (%L, 1, 1, 6, %L, %L, 0, 0)',
                             t.m(1), t.mem(206), 'X'), '%permission denied%', 'S13 direct INSERT: denied');
select t.expect_error(format('update public.match_batting set runs = 99 where match_id = %L', t.m(1)), '%permission denied%',
                      'S14 direct UPDATE: denied');
reset role;
select t.expect_error(format('update public.match_batting set runs = 99 where match_id = %L and position = 1', t.m(1)),
                      '%invalid transition%', 'S15 card rows never change (even for the database owner)');
select t.expect_error(format('update public.match_bowling set player_name = %L where match_id = %L and bowler_no = 1', 'X', t.m(1)),
                      '%invalid transition%', 'S16 a stored name never changes');
select t.expect_error(format('insert into public.match_bowling (match_id, version, innings_no, bowler_no, member_id, player_name, balls, runs) values (%L, 1, 1, 6, %L, %L, 0, 0)',
                             t.m(1), t.mem(206), 'X'), '%invalid scorecard%', 'S17 no card rows added to a confirmed result');

-- ---------------------------------------------------------------------------
-- T. Totals-only results stay possible
-- ---------------------------------------------------------------------------
set role authenticated;
select t.as_user(t.p(1));
select (public.submit_match_result_with_scorecard(t.m(5), 'club_a_won', :'totals')).version as v5 \gset
select public.submit_match_result(t.m(6), 'club_a_won', :'card');
reset role;
select t.ok(:v5 = 1 and not exists (select 1 from public.match_batting where match_id in (t.m(5), t.m(6)))
            and (select count(*) from public.match_innings where match_id in (t.m(5), t.m(6))) = 4,
            'T1 without cards the result is totals-only (migration 20''s submit stores no cards)');
set role authenticated;
select t.as_user(t.p(2));
select t.ok((select count(*) from public.match_scorecard(t.m(5), 1)) = 0, 'T2 a totals-only result has no scorecard rows');
select public.confirm_match_result(t.m(5), 1);
reset role;

-- ---------------------------------------------------------------------------
-- C. Statistics (confirmed results only)
-- ---------------------------------------------------------------------------
set role authenticated;
select t.as_user(t.p(101));
select t.ok((select s ->> 'matches' = '1' and s ->> 'bat_innings' = '1' and s ->> 'runs' = '60' and s ->> 'balls_faced' = '40'
                    and s ->> 'batting_average' = '60.00' and s ->> 'strike_rate' = '150.00' and s ->> 'highest' = '60'
                    and s ->> 'highest_not_out' = 'false' and s ->> 'fifties' = '1' and s ->> 'hundreds' = '0'
                    and s ->> 'fours' = '6' and s ->> 'sixes' = '2'
                    and s ->> 'bowl_innings' = '1' and s ->> 'balls_bowled' = '24' and s ->> 'runs_conceded' = '30'
                    and s ->> 'wickets' = '2' and s ->> 'bowling_average' = '15.00' and s ->> 'economy' = '7.50'
                    and s ->> 'bowling_strike_rate' = '12.00' and s ->> 'best_wickets' = '2' and s ->> 'best_runs' = '30'
                    and s ->> 'player_of_match' = '1' and s ->> 'catches' = '0'
               from t.stat(101) s),
            'C1 player 101 (own stats): 60 (40), avg 60.00, SR 150.00, a fifty; 2/30 in 4 overs, econ 7.50; Player of the Match');
select t.ok((select s ->> 'not_outs' = '1' and s ->> 'batting_average' is null and s ->> 'highest' = '15'
                    and s ->> 'highest_not_out' = 'true' and s ->> 'stumpings' = '1' and s ->> 'wickets' = '2'
               from t.stat(104) s),
            'C2 player 104 (a clubmate): 15*, no average while unbeaten; a stumping');
select t.ok((select s ->> 'matches' = '1' and s ->> 'catches' = '1' and s ->> 'bat_innings' = '0' and s ->> 'runs' = '0'
                    and s ->> 'highest' is null and s ->> 'bowl_innings' = '0' and s ->> 'economy' is null
               from t.stat(112) s),
            'C3 the substitute 112: one match, one catch, no batting or bowling');
select t.ok((select s ->> 'catches' = '1' from t.stat(102) s), 'C4 a caught & bowled counts as the bowler''s catch');
select t.expect_error(format('select * from public.player_stats(%L)', t.p(202)), '%stats: not allowed%',
                      'C5 a player of club A can''t read a club B player''s stats');
select t.as_user(t.p(201));
select t.ok((select s ->> 'ducks' = '1' and s ->> 'bat_innings' = '1' and s ->> 'wickets' = '1' and s ->> 'catches' = '0'
               from t.stat(202) s)
            and (select s ->> 'run_outs' = '1' and s ->> 'direct_hits' = '1' and s ->> 'wickets' = '0'
                        and s ->> 'bowling_average' is null and s ->> 'best_wickets' = '0' and s ->> 'best_runs' = '27'
                   from t.stat(203) s)
            and (select s ->> 'catches' = '1' from t.stat(205) s),
            'C6 club B''s players: a duck; a direct-hit run out; 0/27 with no average; a catch');
select t.as_user(t.p(2));
select t.ok((select s ->> 'runs' = '40' from t.stat(201) s), 'C7 the owner of a player''s club reads their stats');
select t.expect_error(format('select * from public.player_stats(%L)', t.p(215)), '%stats: not allowed%',
                      'C8 a removed member''s stats are no longer the club''s to read');
select t.as_user(t.p(400));
select t.expect_error(format('select * from public.player_stats(%L)', t.p(101)), '%stats: not allowed%', 'C9 an outsider can''t read stats');
select t.ok((select (s).matches = 0 and (s).runs = 0 and (s).batting_average is null from public.player_stats() s),
            'C10 a player with no cards: zeros and nulls (own stats, no argument)');
select t.as_user(t.p(103));
select t.ok((select count(*) = 17 and count(*) filter (where matches = 1) = 12
                    and max(runs) filter (where member_id = t.mem(101)) = 60
                    and max(catches) filter (where member_id = t.mem(112)) = 1
                    and max(matches) filter (where member_id = t.mem(116)) = 0
               from public.club_member_stats(t.club(1))),
            'C11 club_member_stats: 17 active members of A (owner + 16 players), 12 of them on the card (101–112)');
select t.as_user(t.p(201));
select t.expect_error(format('select * from public.club_member_stats(%L)', t.club(1)), '%stats: not allowed%',
                      'C12 another club''s member can''t read A''s squad stats');
select t.as_user(t.p(101));
select t.ok((select count(*) = 1 and max(result) = 'won' and max(opponent_name) = 'Card Kings' and max(bat_runs) = 60
                    and max(bat_outs) = 1 and max(bowl_wickets) = 2 and bool_and(player_of_match)
                    and max(summary) = 'Card Lions won by 30 runs'
               from public.player_match_log()),
            'C13 player_match_log: won, 60 and 2 wickets, Player of the Match');
select t.as_user(t.p(201));
select t.ok((select max(result) = 'lost' and max(bat_runs) = 40 and max(bowl_wickets) = 1 and not bool_or(player_of_match)
               from public.player_match_log(t.p(201))),
            'C14 player_match_log from the losing side');

-- A correction (B submits version 2: 101 scored 64, 102 41) counts only once confirmed.
select t.as_user(t.p(2));
select (public.submit_match_result_with_scorecard(t.m(1), 'club_a_won',
          jsonb_set(jsonb_set(:'card', '{0,batting,0,runs}', '64'), '{0,batting,1,runs}', '41'), t.mem(101))).version as v2 \gset
select t.as_user(t.p(101));
select t.ok((select s ->> 'runs' from t.stat(101) s) = '60', 'C15 a waiting correction doesn''t count');
select t.as_user(t.p(1));
select public.confirm_match_result(t.m(1), :v2);
select t.as_user(t.p(101));
select t.ok((select s ->> 'runs' = '64' and s ->> 'matches' = '1' and s ->> 'highest' = '64' from t.stat(101) s)
            and (select s ->> 'runs' from t.stat(102) s) = '41',
            'C16 the confirmed correction replaces the figures (superseded version ignored)');
reset role;
select t.ok((select count(*) from public.match_batting where match_id = t.m(1) and version = 1) = 22
            and (select count(*) from public.match_batting where match_id = t.m(1) and version = 2) = 22,
            'C17 both versions'' cards are kept (audit)');

-- ---------------------------------------------------------------------------
-- M. my_matches
-- ---------------------------------------------------------------------------
set role authenticated;
select t.no_session();
select t.expect_error('select * from public.my_matches()', '%not authenticated%', 'M1 no session: not authenticated');
select t.as_user(t.p(101));
select t.ok((select string_agg(status, ',' order by starts_at desc) from public.my_matches()) = 'confirmed,completed,cancelled,completed,confirmed',
            'M2 player 101: m2 upcoming, m1 completed, m3 cancelled, m5, m6 — never the pending m4');
select t.ok((select lineup_saved and selection = 'playing' and is_captain and not is_vice_captain and result = 'won'
                    and summary = 'Card Lions won by 30 runs' and result_version = 2 and opponent_name = 'Card Kings'
               from public.my_matches() where match_id = t.m(1))
            and (select not lineup_saved and selection is null and result is null from public.my_matches() where match_id = t.m(2))
            and (select cancel_reason = 'Rain' from public.my_matches() where match_id = t.m(3))
            and (select result is null from public.my_matches() where match_id = t.m(6)),
            'M3 own selection and captaincy, the result from the club''s side; nothing for an unconfirmed result');
select t.as_user(t.p(112));
select t.ok((select selection = 'sub' from public.my_matches() where match_id = t.m(1)), 'M4 a substitute sees "sub"');
select t.as_user(t.p(116));
select t.ok((select selection is null and lineup_saved from public.my_matches() where match_id = t.m(1)),
            'M5 a member not picked: a line-up exists, no selection');
select t.as_user(t.p(201));
select t.ok((select result = 'lost' and not lineup_saved and club_name = 'Card Kings' from public.my_matches() where match_id = t.m(1)),
            'M6 the other club''s member: their side of the result, never A''s line-up');
select t.as_user(t.p(215));
select t.ok((select count(*) from public.my_matches()) = 0, 'M7 a removed member: no matches');
select t.as_user(t.p(400));
select t.ok((select count(*) from public.my_matches()) = 0, 'M8 a player in no club: no matches');
reset role;

-- ---------------------------------------------------------------------------
-- D. Account deletion: "Deleted player", the rows and others' figures stay
-- ---------------------------------------------------------------------------
delete from auth.users where id in (t.p(101), t.p(205));
select t.ok((select count(*) from public.match_batting where match_id = t.m(1)) = 44
            and (select count(*) from public.match_bowling where match_id = t.m(1)) = 20
            and (select bool_and(player_deleted and player_name is null and member_id is null)
                   from public.match_batting where match_id = t.m(1) and innings_no = 1 and position = 1)
            and (select bool_and(player_deleted and wickets = 2) from public.match_bowling
                  where match_id = t.m(1) and innings_no = 2 and bowler_no = 1)
            and (select bool_and(fielder_deleted and fielder_name is null)
                   from public.match_batting where match_id = t.m(1) and innings_no = 1 and position = 1),
            'D1 deleted batter, bowler and fielder: names and links gone, rows and figures kept');
set role authenticated;
select t.as_user(t.p(2));
select t.ok((select b ->> 'dismissal_text' from public.match_scorecard(t.m(1)) s, jsonb_array_elements(s.batting) b
              where s.innings_no = 1 and (b ->> 'position')::int = 1) = 'c Deleted player b Card Person 201'
            and (select b ->> 'dismissal_text' from public.match_scorecard(t.m(1)) s, jsonb_array_elements(s.batting) b
                  where s.innings_no = 2 and (b ->> 'position')::int = 1) = 'c sub (Card Person 112) b Deleted player'
            and (select (b ->> 'deleted')::boolean and b ->> 'name' is null and b ->> 'dismissal_text' = 'c & b Card Person 102'
                   from public.match_scorecard(t.m(1)) s, jsonb_array_elements(s.batting) b
                  where s.innings_no = 2 and (b ->> 'position')::int = 5),
            'D2 dismissal texts say "Deleted player"; the deleted batter''s row is flagged');
select t.ok((select s ->> 'wickets' = '1' and s ->> 'runs' = '40' from t.stat(201) s),
            'D3 other players'' figures are unchanged (201 still has the wicket of the deleted batter)');
select t.ok((select player_of_match_deleted from public.match_result(t.m(1)) where status = 'confirmed'),
            'D4 the Player of the Match is "deleted" too (migration 20)');
select t.as_user(t.p(103));
select t.ok((select count(*) from public.club_member_stats(t.club(1))) = 16
            and (select s ->> 'stumpings' from t.stat(104) s) = '1',
            'D5 the squad list no longer has the deleted player; clubmates unchanged');
reset role;

-- Clean up (this database only).
delete from public.clubs where owner_id::text like 'ed000000%';
delete from auth.users where id::text like 'ed000000%';
select t.ok(not exists (select 1 from public.profiles where id::text like 'ed000000%')
            and not exists (select 1 from public.match_results) and not exists (select 1 from public.match_batting)
            and not exists (select 1 from public.match_bowling) and not exists (select 1 from public.matches),
            'Z cleanup done');
