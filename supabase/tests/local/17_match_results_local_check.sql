-- CricEco · LOCAL TEST ONLY — migration 20 (match results and innings
-- totals) on a DISPOSABLE plain PostgreSQL 17 database, after
-- 00_auth_stub.sql, 02_legacy_profiles_fixture.sql, migrations 1–19 (+ the
-- D1 location seed) and migration 20. Synthetic accounts only (ids eb…).
-- Run with psql:  psql -X -v ON_ERROR_STOP=1 -f 17_match_results_local_check.sql
-- Every check prints "PASS: …"; the first failure stops the run ("FAIL: …").
-- Concurrency (two sessions) is in 17b_match_results_concurrency.sh.
-- Refuses to run on a real Supabase project (its auth.users has passwords).
\set ON_ERROR_STOP on

do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password') then
    raise exception 'LOCAL ONLY: this looks like a real Supabase project — refusing';
  end if;
  if to_regclass('public.match_results') is null then
    raise exception 'apply migration 20 first';
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
create or replace function t.uidb(p_n int) returns uuid language sql immutable as $$
  select ('eb000000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
$$;
create or replace function t.make_personb(p_n int) returns uuid language plpgsql as $$
declare
  v uuid := t.uidb(p_n);
begin
  insert into auth.users (id, email) values (v, format('result%s@local.test', p_n));
  insert into public.current_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
  insert into public.permanent_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
  update public.profiles
     set full_name = format('Result Person %s', p_n),
         phone = format('+923%s', lpad((560000000 + p_n)::text, 9, '0')),
         date_of_birth = date '2000-05-01', profile_completed = true
   where id = v;
  insert into public.player_profiles (user_id, player_role, batting_style, bowling_style, is_wicketkeeper)
  values (v, 'all_rounder', 'right_handed', 'right_arm_fast', false);
  return v;
end $$;
-- Innings JSON: (batting club, runs, wickets, balls [, extras…]).
create or replace function t.inn(p_club uuid, p_runs int, p_wkts int, p_balls int,
                                 p_wides int default 0, p_declared boolean default null)
returns jsonb language sql immutable as $$
  select jsonb_build_object('batting_club_id', p_club, 'runs', p_runs, 'wickets', p_wkts, 'balls', p_balls,
                            'wides', p_wides, 'byes', 1, 'leg_byes', 2)
         || case when p_declared is null then '{}'::jsonb else jsonb_build_object('declared', p_declared) end;
$$;
-- A submission that must be refused (as the current user).
create or replace function t.bad(p_match uuid, p_outcome text, p_innings jsonb, p_like text, p_name text)
returns void language sql as $$
  select t.expect_error(format('select public.submit_match_result(%L, %L, %L)', p_match, p_outcome, p_innings), p_like, p_name);
$$;
grant execute on all functions in schema t to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Synthetic data: owners 1 (club A "Result Lions"), 2 (club B "Result
-- Kings"), 3 (club C); members 11–12 of A, 21 of B (12 later removed); 30 an
-- outsider. Matches A vs B (club_a = A):
--   m1 T20 played · m2 T20 played · m3 T20 played · m4 T20 played ·
--   m5 T20 tomorrow · m6 pending · m7 cancelled · m8 Test played ·
--   m9 Test played · m10 custom (10 overs) played
-- ---------------------------------------------------------------------------
select count(*) from (select t.make_personb(n) from unnest(array[1, 2, 3, 11, 12, 21, 30]) n) s;
insert into public.clubs (owner_id, name, city, club_type) values
  (t.uidb(1), 'Result Lions', 'Lahore', 'corporate'),
  (t.uidb(2), 'Result Kings', 'Karachi', 'corporate'),
  (t.uidb(3), 'Result Riders', 'Lahore', 'corporate');
select id as club_a from public.clubs where owner_id = t.uidb(1) \gset
select id as club_b from public.clubs where owner_id = t.uidb(2) \gset
select id as club_c from public.clubs where owner_id = t.uidb(3) \gset
insert into public.club_members (club_id, user_id, member_role, status) values
  (:'club_a', t.uidb(11), 'player', 'active'), (:'club_a', t.uidb(12), 'player', 'active'),
  (:'club_b', t.uidb(21), 'player', 'active');
select id as mem11 from public.club_members where user_id = t.uidb(11) \gset
select id as mem12 from public.club_members where user_id = t.uidb(12) \gset
select id as mem21 from public.club_members where user_id = t.uidb(21) \gset
select id as memc from public.club_members where club_id = :'club_c' \gset
\set a 'eb000000-0000-4000-8000-000000000001'
\set b 'eb000000-0000-4000-8000-000000000002'
\set c 'eb000000-0000-4000-8000-000000000003'
\set p11 'eb000000-0000-4000-8000-000000000011'
\set p12 'eb000000-0000-4000-8000-000000000012'
\set p21 'eb000000-0000-4000-8000-000000000021'
\set u 'eb000000-0000-4000-8000-000000000030'

create or replace function t.add_match(p_n int, p_status text, p_starts timestamptz, p_format text,
                                       p_overs int default null) returns uuid language plpgsql as $$
declare v uuid := ('eb0000aa-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
begin
  insert into public.matches (id, club_a_id, club_b_id, format, custom_overs, status, starts_at, venue_name,
                              cancelled_at, cancelled_by_club_id, cancel_reason)
  select v, a.id, b.id, p_format, p_overs, p_status, p_starts, case when p_starts is null then null else 'Gaddafi Stadium' end,
         case when p_status = 'cancelled' then now() end, case when p_status = 'cancelled' then a.id end,
         case when p_status = 'cancelled' then 'Rain' end
    from public.clubs a, public.clubs b
   where a.name = 'Result Lions' and b.name = 'Result Kings';
  return v;
end $$;
select t.add_match(1, 'confirmed', now() - interval '1 day', 't20') as m1 \gset
select t.add_match(2, 'confirmed', now() - interval '2 days', 't20') as m2 \gset
select t.add_match(3, 'confirmed', now() - interval '3 days', 't20') as m3 \gset
select t.add_match(4, 'confirmed', now() - interval '4 days', 't20') as m4 \gset
select t.add_match(5, 'confirmed', now() + interval '1 day', 't20') as m5 \gset
select t.add_match(6, 'pending', null, 't20') as m6 \gset
select t.add_match(7, 'cancelled', null, 't20') as m7 \gset
select t.add_match(8, 'confirmed', now() - interval '5 days', 'test') as m8 \gset
select t.add_match(9, 'confirmed', now() - interval '6 days', 'test') as m9 \gset
select t.add_match(10, 'confirmed', now() - interval '7 days', 'custom', 10) as m10 \gset

-- A's usual result for m1: A 186/6 (120 balls), B 162/8 → A won by 24 runs.
select jsonb_build_array(t.inn(:'club_a', 186, 6, 120, 7), t.inn(:'club_b', 162, 8, 120)) as inn_m1 \gset

-- ---------------------------------------------------------------------------
-- A. Who may submit, and when
-- ---------------------------------------------------------------------------
set role anon;
select t.expect_error(format('select public.submit_match_result(%L, %L, %L)', :'m1', 'club_a_won', :'inn_m1'),
                      '%permission denied%', 'A1 anon cannot submit');
select t.expect_error(format('select public.confirm_match_result(%L, 1)', :'m1'), '%permission denied%', 'A1b anon cannot confirm');
select t.expect_error(format('select public.dispute_match_result(%L, 1, %L)', :'m1', 'x'), '%permission denied%', 'A1c anon cannot dispute');
select t.expect_error(format('select * from public.match_result(%L)', :'m1'), '%permission denied%', 'A1d anon cannot read a result');
select t.expect_error(format('select * from public.club_results(%L)', :'club_a'), '%permission denied%', 'A1e anon cannot read club results');
select t.expect_error(format('select * from public.club_record(%L)', :'club_a'), '%permission denied%', 'A1f anon cannot read a club record');
select t.expect_error('select count(*) from public.match_results', '%permission denied%', 'A1g anon cannot read match_results');
reset role;
set role authenticated;
select t.no_session();
select t.expect_error(format('select public.submit_match_result(%L, %L, %L)', :'m1', 'club_a_won', :'inn_m1'),
                      '%not authenticated%', 'A2 no session: not authenticated');
select t.as_user(:'p11');
select t.expect_error(format('select public.submit_match_result(%L, %L, %L)', :'m1', 'club_a_won', :'inn_m1'),
                      '%result: not allowed%', 'A3 a member (not the owner) cannot submit');
select t.as_user(:'c');
select t.expect_error(format('select public.submit_match_result(%L, %L, %L)', :'m1', 'club_a_won', :'inn_m1'),
                      '%result: not allowed%', 'A4 another club''s owner cannot submit');
select t.as_user(:'a');
select t.expect_error(format('select public.submit_match_result(%L, %L, %L)', gen_random_uuid(), 'club_a_won', :'inn_m1'),
                      '%result: not found%', 'A5 unknown match: not found');
select t.expect_error(format('select public.submit_match_result(%L, %L, %L)', :'m5', 'club_a_won', :'inn_m1'),
                      '%match not played%', 'A6 a confirmed match that hasn''t started: match not played');
select t.expect_error(format('select public.submit_match_result(%L, %L, %L)', :'m6', 'club_a_won', :'inn_m1'),
                      '%match not played%', 'A7 a pending match: match not played');
select t.expect_error(format('select public.submit_match_result(%L, %L, %L)', :'m7', 'club_a_won', :'inn_m1'),
                      '%match not played%', 'A8 a cancelled match: match not played');

-- ---------------------------------------------------------------------------
-- B. Validation (nothing is stored by any refusal)
-- ---------------------------------------------------------------------------
select t.bad(:'m1', 'a_won', :'inn_m1', '%result: invalid%', 'B1 unknown outcome: invalid');
select t.bad(:'m1', 'club_a_won', '{"x": 1}', '%invalid innings%', 'B2 innings not an array: invalid innings');
select t.bad(:'m1', 'club_a_won', '[1, 2]', '%invalid innings%', 'B3 an innings that isn''t an object: invalid innings');
select t.bad(:'m1', 'club_a_won', jsonb_build_array(t.inn(:'club_c', 186, 6, 120), t.inn(:'club_b', 162, 8, 120)),
             '%invalid innings%', 'B4 a club not in the match batting: invalid innings');
select t.bad(:'m1', 'club_a_won', jsonb_build_array(jsonb_set(t.inn(:'club_a', 186, 6, 120), '{runs}', '"lots"'),
             t.inn(:'club_b', 162, 8, 120)), '%invalid innings%', 'B5 non-numeric runs: invalid innings');
select t.bad(:'m1', 'club_a_won', jsonb_build_array(jsonb_set(t.inn(:'club_a', 186, 6, 120), '{runs}', '186.5'),
             t.inn(:'club_b', 162, 8, 120)), '%invalid innings%', 'B6 fractional runs: invalid innings');
select t.bad(:'m1', 'club_a_won', jsonb_build_array(t.inn(:'club_a', 186, 11, 120), t.inn(:'club_b', 162, 8, 120)),
             '%invalid innings%', 'B7 11 wickets: invalid innings');
select t.bad(:'m1', 'club_a_won', jsonb_build_array(t.inn(:'club_a', 186, 6, 121), t.inn(:'club_b', 162, 8, 120)),
             '%invalid innings%', 'B8 121 balls in a T20 innings: invalid innings');
select t.bad(:'m10', 'club_a_won', jsonb_build_array(t.inn(:'club_a', 86, 6, 61), t.inn(:'club_b', 62, 8, 60)),
             '%invalid innings%', 'B9 61 balls in a 10-over custom innings: invalid innings');
select t.bad(:'m1', 'club_a_won', jsonb_build_array(t.inn(:'club_a', 5, 6, 120, 10), t.inn(:'club_b', 3, 8, 120)),
             '%invalid innings%', 'B10 extras above the runs: invalid innings');
select t.bad(:'m1', 'club_a_won', jsonb_build_array(t.inn(:'club_a', 186, 6, 120, 0, true), t.inn(:'club_b', 162, 8, 120)),
             '%invalid innings%', 'B11 a declaration in a T20: invalid innings');
select t.bad(:'m1', 'club_a_won', jsonb_build_array(t.inn(:'club_a', 186, 6, 120), t.inn(:'club_b', 162, 8, 120),
             t.inn(:'club_a', 10, 0, 6)), '%invalid innings%', 'B12 three innings in a T20: invalid innings');
select t.bad(:'m1', 'club_a_won', jsonb_build_array(t.inn(:'club_a', 186, 6, 120), t.inn(:'club_a', 162, 8, 120)),
             '%invalid innings%', 'B13 one club batting twice in a T20: invalid innings');
select t.bad(:'m1', 'club_a_won', jsonb_build_array(t.inn(:'club_a', 150, 6, 120), t.inn(:'club_b', 162, 8, 120)),
             '%inconsistent result%', 'B14 a win for the side with fewer runs: inconsistent result');
select t.bad(:'m1', 'tie', :'inn_m1', '%inconsistent result%', 'B15 a tie with different totals: inconsistent result');
select t.bad(:'m1', 'club_a_won', jsonb_build_array(t.inn(:'club_a', 186, 6, 120)),
             '%inconsistent result%', 'B16 a win after one innings: inconsistent result');
select t.bad(:'m1', 'abandoned', :'inn_m1', '%inconsistent result%', 'B17 abandoned with innings: inconsistent result');
select t.expect_error(format('select public.submit_match_result(%L, %L, %L, %L)', :'m1', 'club_a_won', :'inn_m1', :'memc'),
                      '%invalid player%', 'B18 a Player of the Match from another club: invalid player');
select t.expect_error(format('select public.submit_match_result(%L, %L, %L, %L)', :'m1', 'club_a_won', :'inn_m1', gen_random_uuid()),
                      '%invalid player%', 'B19 an unknown Player of the Match: invalid player');
reset role;
select t.ok(not exists (select 1 from public.match_results) and not exists (select 1 from public.match_innings),
            'B20 nothing was stored by the refusals');

-- ---------------------------------------------------------------------------
-- C. Submit and confirm
-- ---------------------------------------------------------------------------
set role authenticated;
select t.as_user(:'a');
select (public.submit_match_result(:'m1', ' CLUB_A_WON ', :'inn_m1', :'mem11')).version as v_m1 \gset
reset role;
select t.ok(:v_m1 = 1 and (select status = 'submitted' and outcome = 'club_a_won' and margin_runs = 24 and margin_wickets is null
                                  and not innings_victory and player_of_match_name = 'Result Person 11'
                                  and submitted_by_club_id = :'club_a' and submitted_by = :'a' and decided_at is null
                             from public.match_results where match_id = :'m1'),
            'C1 A submits: version 1, waiting; margin computed: 24 runs; Player of the Match named');
select t.ok((select count(*) = 2 and bool_and(bowling_club_id <> batting_club_id)
                    and max(wides) filter (where innings_no = 1) = 7 and max(byes) = 1 and max(leg_byes) = 2
               from public.match_innings where match_id = :'m1')
            and (select bowling_club_id from public.match_innings where match_id = :'m1' and innings_no = 1) = :'club_b',
            'C2 both innings stored in batting order, the other club bowling, extras kept');
select t.ok((select status from public.matches where id = :'m1') = 'confirmed', 'C3 the match stays confirmed until the result is');
set role authenticated;
select t.as_user(:'a');
select t.expect_error(format('select public.confirm_match_result(%L, 1)', :'m1'), '%result: not allowed%',
                      'C4 the submitting club can''t confirm its own result');
select t.as_user(:'p21');
select t.expect_error(format('select public.confirm_match_result(%L, 1)', :'m1'), '%result: not allowed%',
                      'C5 a member (not the owner) can''t confirm');
select t.as_user(:'c');
select t.expect_error(format('select public.confirm_match_result(%L, 1)', :'m1'), '%result: not allowed%',
                      'C6 another club''s owner can''t confirm');
select t.as_user(:'b');
select t.ok((select summary from public.match_result(:'m1')) = 'Result Lions won by 24 runs'
            and (select not submitted_by_me and status = 'submitted' from public.match_result(:'m1')),
            'C7 B reads the waiting result: summary from the computed margin and the current club name');
select t.expect_error(format('select public.confirm_match_result(%L, 2)', :'m1'), '%version changed%',
                      'C8 confirming another version: version changed');
select (public.confirm_match_result(:'m1', 1)).status as c_status \gset
reset role;
select t.ok(:'c_status' = 'confirmed'
            and (select decided_by_club_id = :'club_b' and decided_by = :'b' and decided_at is not null
                   from public.match_results where match_id = :'m1' and version = 1)
            and (select status from public.matches where id = :'m1') = 'completed',
            'C9 B confirms: the result is confirmed, by B; the match is completed');
set role authenticated;
select t.as_user(:'b');
select t.expect_error(format('select public.confirm_match_result(%L, 1)', :'m1'), '%not pending%',
                      'C10 confirming again: not pending');
select t.expect_error(format('select public.dispute_match_result(%L, 1, %L)', :'m1', 'x'), '%not pending%',
                      'C11 disputing a confirmed result: not pending');
-- A chase: B 150/9, A 151/4 in 110 balls → A won by 6 wickets.
select t.as_user(:'a');
select (public.submit_match_result(:'m2', 'club_a_won',
          jsonb_build_array(t.inn(:'club_b', 150, 9, 120), t.inn(:'club_a', 151, 4, 110)))).margin_wickets as w_m2 \gset
reset role;
select t.ok(:w_m2 = 6 and (select margin_runs is null from public.match_results where match_id = :'m2'),
            'C12 a successful chase: the margin is in wickets (10 − 4 = 6)');
set role authenticated;
select t.as_user(:'b');
select t.ok((select summary from public.match_result(:'m2')) = 'Result Lions won by 6 wickets', 'C13 "won by 6 wickets"');
select public.confirm_match_result(:'m2', 1);
reset role;

-- ---------------------------------------------------------------------------
-- D. Dispute, revise, replace
-- ---------------------------------------------------------------------------
set role authenticated;
select t.as_user(:'a');
select public.submit_match_result(:'m3', 'club_b_won', jsonb_build_array(t.inn(:'club_a', 120, 10, 98), t.inn(:'club_b', 121, 2, 80)));
select t.as_user(:'b');
select t.expect_error(format('select public.dispute_match_result(%L, 1, %L)', :'m3', '  '), '%invalid reason%',
                      'D1 a dispute without a reason: invalid reason');
select t.expect_error(format('select public.dispute_match_result(%L, 1, %L)', :'m3', repeat('r', 301)), '%invalid reason%',
                      'D2 a 301-character reason: invalid reason');
select t.as_user(:'a');
select t.expect_error(format('select public.dispute_match_result(%L, 1, %L)', :'m3', 'Mine'), '%result: not allowed%',
                      'D3 the submitter can''t dispute its own result');
select t.as_user(:'b');
select (public.dispute_match_result(:'m3', 1, ' We scored   121 for 1 ')).status as d_status \gset
reset role;
select t.ok(:'d_status' = 'disputed'
            and (select dispute_reason = 'We scored 121 for 1' and decided_by_club_id = :'club_b'
                   from public.match_results where match_id = :'m3' and version = 1)
            and (select status from public.matches where id = :'m3') = 'confirmed',
            'D4 B disputes with a reason: disputed; the match stays unplayed-in-results (confirmed)');
set role authenticated;
select t.as_user(:'b');
select (public.submit_match_result(:'m3', 'club_b_won', jsonb_build_array(t.inn(:'club_a', 120, 10, 98), t.inn(:'club_b', 121, 1, 80)))).version as v_m3 \gset
select t.as_user(:'a');
select public.confirm_match_result(:'m3', :v_m3);
reset role;
select t.ok(:v_m3 = 2 and (select string_agg(version || ':' || status, ',' order by version) from public.match_results where match_id = :'m3') = '1:disputed,2:confirmed'
            and (select margin_wickets from public.match_results where match_id = :'m3' and version = 2) = 9,
            'D5 B submits the corrected version 2; A confirms it: the history keeps both');
-- Replacing a version still waiting for an answer.
set role authenticated;
select t.as_user(:'a');
select public.submit_match_result(:'m4', 'club_a_won', :'inn_m1');
select (public.submit_match_result(:'m4', 'club_a_won', jsonb_build_array(t.inn(:'club_a', 190, 6, 120), t.inn(:'club_b', 162, 8, 120)))).version as v_m4 \gset
select t.as_user(:'b');
select t.expect_error(format('select public.confirm_match_result(%L, 1)', :'m4'), '%version changed%',
                      'D6 confirming the replaced version 1: version changed');
reset role;
select t.ok(:v_m4 = 2 and (select status = 'superseded' and decided_by_club_id = :'club_a' from public.match_results where match_id = :'m4' and version = 1)
            and (select count(*) from public.match_results where match_id = :'m4' and status = 'submitted') = 1,
            'D7 a new submission replaces the waiting one (superseded, by A): one waiting version');

-- ---------------------------------------------------------------------------
-- E. Corrections after confirmation
-- ---------------------------------------------------------------------------
set role authenticated;
select t.as_user(:'b');
select (public.submit_match_result(:'m1', 'club_a_won', jsonb_build_array(t.inn(:'club_a', 180, 6, 120), t.inn(:'club_b', 162, 8, 120)))).version as v_corr \gset
select t.as_user(:'a');
select t.ok((select summary from public.club_results(:'club_a') where match_id = :'m1') = 'Result Lions won by 24 runs',
            'E1 a correction waiting for an answer: the confirmed result still stands');
select public.confirm_match_result(:'m1', :v_corr);
select t.ok((select summary || ' v' || version from public.club_results(:'club_a') where match_id = :'m1') = 'Result Lions won by 18 runs v2',
            'E2 A confirms the correction: it becomes the result');
reset role;
select t.ok((select status = 'superseded' and decided_by_club_id = :'club_b' and decided_by = :'b'
               from public.match_results where match_id = :'m1' and version = 1)
            and (select count(*) from public.match_results where match_id = :'m1' and status = 'confirmed') = 1,
            'E3 the old confirmed version is superseded and keeps who confirmed it (audit)');

-- ---------------------------------------------------------------------------
-- F. Tie, no result, abandoned; Test format
-- ---------------------------------------------------------------------------
reset role;
select t.add_match(11, 'confirmed', now() - interval '8 days', 't20') as m11 \gset
select t.add_match(12, 'confirmed', now() - interval '9 days', 't20') as m12 \gset
select t.add_match(13, 'confirmed', now() - interval '10 days', 't20') as m13 \gset
set role authenticated;
select t.as_user(:'a');
select public.submit_match_result(:'m11', 'tie', jsonb_build_array(t.inn(:'club_a', 150, 7, 120), t.inn(:'club_b', 150, 9, 120)));
select public.submit_match_result(:'m12', 'no_result', jsonb_build_array(t.inn(:'club_a', 80, 2, 50)));
select public.submit_match_result(:'m13', 'abandoned', '[]');
select t.as_user(:'b');
select t.ok((select summary from public.match_result(:'m11')) = 'Match tied'
            and (select summary from public.match_result(:'m12')) = 'No result'
            and (select summary from public.match_result(:'m13')) = 'Match abandoned',
            'F1 tie (equal totals), no result (one innings), abandoned (no innings)');
select public.confirm_match_result(:'m11', 1);
select public.confirm_match_result(:'m12', 1);
select public.confirm_match_result(:'m13', 1);
-- Test: A 300/10, B 150/10 and (follow-on) 120/10 → A won by an innings and 30 runs.
select t.as_user(:'a');
select public.submit_match_result(:'m8', 'club_a_won', jsonb_build_array(
         t.inn(:'club_a', 300, 10, 540), t.inn(:'club_b', 150, 10, 300), t.inn(:'club_b', 120, 10, 280)));
select t.ok((select summary from public.match_result(:'m8') where status = 'submitted') = 'Result Lions won by an innings and 30 runs',
            'F2 Test: an innings victory (the winner batted once)');
-- Test: A 200 (dec 9), B 250, A 180, B 131/3 → B won by 7 wickets.
select public.submit_match_result(:'m9', 'club_b_won', jsonb_build_array(
         t.inn(:'club_a', 200, 9, 400, 0, true), t.inn(:'club_b', 250, 10, 500), t.inn(:'club_a', 180, 10, 360),
         t.inn(:'club_b', 131, 3, 200)));
select t.ok((select summary from public.match_result(:'m9') where status = 'submitted') = 'Result Kings won by 7 wickets',
            'F3 Test: a fourth-innings chase, a declaration allowed');
select t.bad(:'m9', 'club_b_won', jsonb_build_array(t.inn(:'club_a', 200, 10, 400, 0, true), t.inn(:'club_b', 250, 10, 500)),
             '%invalid innings%', 'F4 Test: declared with 10 wickets down: invalid innings');
select t.bad(:'m9', 'club_a_won', jsonb_build_array(t.inn(:'club_a', 200, 10, 400), t.inn(:'club_b', 100, 10, 500),
             t.inn(:'club_a', 180, 10, 360), t.inn(:'club_a', 1, 0, 6)), '%invalid innings%',
             'F5 Test: a club batting three times: invalid innings');
reset role;

-- ---------------------------------------------------------------------------
-- G. Who sees what (function and RLS); no direct writes
-- ---------------------------------------------------------------------------
set role authenticated;
select t.as_user(:'b');
select t.ok((select count(*) from public.match_result(:'m3')) = 2 and (select count(*) from public.match_result(:'m4')) = 2,
            'G1 an owner sees every version (disputed, superseded, waiting)');
select t.as_user(:'p11');
select t.ok((select count(*) from public.match_result(:'m3')) = 1
            and (select status from public.match_result(:'m3')) = 'confirmed'
            and (select count(*) from public.match_result(:'m4')) = 0,
            'G2 a member sees only the confirmed result (nothing while one waits)');
select t.ok((select count(*) from public.match_results where status <> 'confirmed') = 0
            and (select count(*) from public.match_results) > 0
            and (select count(*) from public.match_innings i where not exists (
                   select 1 from public.match_results r where r.match_id = i.match_id and r.version = i.version
                     and r.status = 'confirmed')) = 0,
            'G3 RLS: a member reads confirmed versions and their innings only');
select t.as_user(:'c');
select t.expect_error(format('select * from public.match_result(%L)', :'m1'), '%result: not allowed%',
                      'G4 another club''s owner can''t read the result');
select t.ok((select count(*) from public.match_results) = 0 and (select count(*) from public.match_innings) = 0,
            'G5 RLS: another club''s owner reads nothing');
select t.as_user(:'u');
select t.expect_error(format('select * from public.match_result(%L)', :'m1'), '%result: not allowed%', 'G6 an outsider can''t read it');
select t.as_user(:'a');
select t.expect_error(format('insert into public.match_results (match_id, version, outcome, submitted_by_club_id) values (%L, 9, %L, %L)',
                             :'m5', 'tie', :'club_a'), '%permission denied%', 'G7 direct INSERT: denied');
select t.expect_error(format('update public.match_results set outcome = %L where match_id = %L', 'tie', :'m1'),
                      '%permission denied%', 'G8 direct UPDATE: denied');
select t.expect_error(format('delete from public.match_innings where match_id = %L', :'m1'), '%permission denied%',
                      'G9 direct DELETE: denied');
reset role;

-- ---------------------------------------------------------------------------
-- H. Versions are immutable (even for the database owner)
-- ---------------------------------------------------------------------------
select t.expect_error(format('update public.match_results set outcome = %L where match_id = %L and version = 2', 'tie', :'m1'),
                      '%invalid transition%', 'H1 a confirmed result''s outcome never changes');
select t.expect_error(format('update public.match_results set status = %L, decided_at = null, decided_by_club_id = null where match_id = %L and version = 2',
                             'submitted', :'m1'), '%invalid transition%', 'H2 confirmed → submitted: refused');
select t.expect_error(format('update public.match_results set status = %L, dispute_reason = null where match_id = %L and version = 1',
                             'confirmed', :'m3'), '%invalid transition%', 'H3 disputed → confirmed: refused');
select t.expect_error(format('update public.match_innings set runs = 999 where match_id = %L', :'m1'),
                      '%invalid transition%', 'H4 innings totals never change');
select t.expect_error(format('insert into public.match_innings (match_id, version, innings_no, batting_club_id, bowling_club_id, runs, wickets, balls) values (%L, 2, 3, %L, %L, 1, 0, 1)',
                             :'m1', :'club_c', :'club_a'), '%invalid innings%', 'H5 an innings for a club not in the match: refused');
select t.expect_error(format('insert into public.match_results (match_id, version, outcome, submitted_by_club_id) values (%L, 3, %L, %L)',
                             :'m4', 'tie', :'club_a'), '23505', 'H6 a second waiting version: refused (unique)');
select t.expect_error(format('insert into public.match_results (match_id, version, outcome, margin_runs, submitted_by_club_id) values (%L, 5, %L, 3, %L)',
                             :'m10', 'tie', :'club_a'), '23514', 'H7 a margin on a tie: refused (check)');

-- ---------------------------------------------------------------------------
-- I. Club results and record; completed matches are closed
-- ---------------------------------------------------------------------------
set role authenticated;
select t.as_user(:'p21');
select t.ok((select string_agg(result, ',' order by starts_at desc) from public.club_results(:'club_b'))
              = 'lost,lost,won,tied,no_result,abandoned',
            'I1 club_results from B''s side (m1, m2 lost; m3 won; m11 tied; m12 no result; m13 abandoned)');
select t.ok((select played = 6 and won = 1 and lost = 2 and tied = 1 and no_result = 1 and abandoned = 1
               from public.club_record(:'club_b')),
            'I2 club_record (a member reads it): 6 played, 1 won, 2 lost, 1 tied, 1 no result, 1 abandoned');
select t.as_user(:'c');
select t.expect_error(format('select * from public.club_record(%L)', :'club_b'), '%result: not allowed%',
                      'I3 another club''s owner can''t read B''s record');
select t.as_user(:'a');
select t.expect_error(format('select public.cancel_match(%L, %L)', :'m1', 'Late'), '%not open%',
                      'I4 a completed match can''t be cancelled');
select t.expect_error(format('select public.propose_match_schedule(%L, %L, %L)', :'m1', now() + interval '2 days', 'X'),
                      '%not open%', 'I5 a completed match can''t be rescheduled');
reset role;

-- ---------------------------------------------------------------------------
-- J. Account deletion: "Deleted player", the result stays (decision 8)
-- ---------------------------------------------------------------------------
-- m2's confirmed result names member 12 as Player of the Match: a correction
-- (B submits, A confirms) sets that, then 12 deletes their account.
set role authenticated;
select t.as_user(:'b');
select public.submit_match_result(:'m2', 'club_a_won',
         jsonb_build_array(t.inn(:'club_b', 150, 9, 120), t.inn(:'club_a', 151, 4, 110)), :'mem12');
select t.as_user(:'a');
select public.confirm_match_result(:'m2', 2);
reset role;
delete from auth.users where id = :'p12';
select t.ok((select player_of_match_name is null and player_of_match_member_id is null and player_of_match_deleted
                    and status = 'confirmed'
               from public.match_results where match_id = :'m2' and version = 2),
            'J1 the deleted player''s name and link are gone; the confirmed result stays');
set role authenticated;
select t.as_user(:'a');
select t.ok((select player_of_match_deleted and player_of_match_name is null from public.match_result(:'m2') where status = 'confirmed'),
            'J2 match_result reports "deleted" (the app shows "Deleted player")');
reset role;
select t.ok((select count(*) from public.match_results where player_of_match_name = 'Result Person 11') >= 1,
            'J3 other players'' names are untouched');

-- Clean up (this database only).
delete from public.clubs where owner_id::text like 'eb000000%';
delete from auth.users where id::text like 'eb000000%';
select t.ok(not exists (select 1 from public.profiles where id::text like 'eb000000%')
            and not exists (select 1 from public.match_results) and not exists (select 1 from public.matches),
            'Z cleanup done');
