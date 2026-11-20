-- CricEco · LOCAL TEST ONLY — migration 18 (match lineups) on a DISPOSABLE
-- plain PostgreSQL 17 database, after 00_auth_stub.sql,
-- 02_legacy_profiles_fixture.sql, migrations 1–17 (+ the D1 location seed)
-- and migration 18 (migration 19 may or may not be applied: nothing here sets
-- an availability). The injured / unavailable rule (migration 19) is tested
-- in 16_player_availability_local_check.sql. Synthetic accounts only (ids e8…).
-- Run with psql:  psql -X -v ON_ERROR_STOP=1 -f 15_match_lineups_local_check.sql
-- Every check prints "PASS: …"; the first failure stops the run ("FAIL: …").
-- Concurrency (two sessions) is in 15b_match_lineups_concurrency.sh.
-- Refuses to run on a real Supabase project (its auth.users has passwords).
\set ON_ERROR_STOP on

do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password') then
    raise exception 'LOCAL ONLY: this looks like a real Supabase project — refusing';
  end if;
  if to_regclass('public.match_lineups') is null then
    raise exception 'apply migration 18 first';
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
create or replace function t.day(p_offset int) returns date language sql stable as $$
  select (now() at time zone 'Asia/Karachi')::date + p_offset;
$$;
-- Synthetic person n: uuid e8000000-…-<n>.
create or replace function t.uid(p_n int) returns uuid language sql immutable as $$
  select ('e8000000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
$$;
-- The membership id of person n (each synthetic player is in one club).
create or replace function t.mem(p_n int) returns uuid language sql stable security definer set search_path = '' as $$
  select m.id from public.club_members m where m.user_id = t.uid(p_n);
$$;
-- A squad: the club's active non-owner members by user id, skipping p_skip,
-- then p_playing "playing" and p_subs "sub", in that order.
create or replace function t.squad(p_club uuid, p_skip int, p_playing int, p_subs int)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('member_id', x.id,
                                               'selection', case when x.rn <= p_playing then 'playing' else 'sub' end)
                            order by x.rn), '[]'::jsonb)
    from (select s.id, row_number() over (order by s.user_id) as rn
            from (select m.id, m.user_id
                    from public.club_members m
                   where m.club_id = p_club and m.status = 'active' and m.member_role <> 'owner'
                   order by m.user_id offset p_skip limit p_playing + p_subs) s) x;
$$;
-- Replace the member of element p_index (0-based) of a squad.
create or replace function t.swap(p_squad jsonb, p_index int, p_member uuid) returns jsonb language sql immutable as $$
  select jsonb_set(p_squad, array[p_index::text, 'member_id'], to_jsonb(p_member::text));
$$;
create or replace function t.make_person(p_n int) returns uuid language plpgsql as $$
declare
  v uuid := t.uid(p_n);
begin
  insert into auth.users (id, email) values (v, format('lineup%s@local.test', p_n));
  insert into public.current_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
  insert into public.permanent_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
  update public.profiles
     set full_name = format('Lineup Person %s', p_n),
         phone = format('+923%s', lpad((520000000 + p_n)::text, 9, '0')),
         date_of_birth = date '2000-05-01',
         profile_completed = true
   where id = v;
  insert into public.player_profiles (user_id, player_role, batting_style, bowling_style, is_wicketkeeper)
  values (v, 'all_rounder', 'right_handed', 'right_arm_fast', false);
  return v;
end $$;
grant execute on all functions in schema t to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Synthetic data: owners 1 (club A), 2 (club B), 3 (club C); players
-- 101–116 of A, 117 removed from A; 201–215 of B; 300 an outsider.
-- ---------------------------------------------------------------------------
select count(*) from (select t.make_person(n)
                        from (select unnest(array[1, 2, 3, 300]) union all select generate_series(101, 117)
                              union all select generate_series(201, 215)) s(n)) x;
insert into public.clubs (owner_id, name, short_name, city, club_type) values
  (t.uid(1), 'Lineup Lions', 'LL', 'Lahore', 'corporate'),
  (t.uid(2), 'Lineup Kings', 'LK', 'Karachi', 'professional'),
  (t.uid(3), 'Lineup Riders', null, 'Lahore', 'corporate');
select id as club_a from public.clubs where owner_id = t.uid(1) \gset
select id as club_b from public.clubs where owner_id = t.uid(2) \gset
select id as club_c from public.clubs where owner_id = t.uid(3) \gset
insert into public.club_members (club_id, user_id, member_role, status)
select :'club_a', t.uid(n), 'player', 'active' from generate_series(101, 117) n;
insert into public.club_members (club_id, user_id, member_role, status)
select :'club_b', t.uid(n), 'player', 'active' from generate_series(201, 215) n;
\set a 'e8000000-0000-4000-8000-000000000001'
\set b 'e8000000-0000-4000-8000-000000000002'
\set c 'e8000000-0000-4000-8000-000000000003'
\set u 'e8000000-0000-4000-8000-000000000300'
\set pa1 'e8000000-0000-4000-8000-000000000101'
\set pb1 'e8000000-0000-4000-8000-000000000201'
\set ra 'e8000000-0000-4000-8000-000000000117'

-- Teams, matches (through the functions).
set role authenticated;
select t.as_user(:'a');
select id as team_a from public.create_team(:'club_a', 'Lions XI', 't20') \gset
select id as team_a_old from public.create_team(:'club_a', 'Lions Old', 't20') \gset
select public.archive_team(:'team_a_old');
-- 117 is in team_a's squad, then removed from the club (later).
select public.save_team(:'team_a', 'Lions XI', 't20', null, null, null,
                        jsonb_build_array(jsonb_build_object('member_id', t.mem(117), 'selection', 'playing'),
                                          jsonb_build_object('member_id', t.mem(110), 'selection', 'playing')));
select (public.send_challenge(:'club_a', :'club_b', 't20', null, t.day(2), 'Lineup Ground')).id as ch_m \gset
select t.as_user(:'b');
select id as team_b from public.create_team(:'club_b', 'Kings XI', 't20') \gset
select (public.respond_to_challenge(:'ch_m', true)).match_id as m \gset
select public.respond_to_match_schedule(:'m', 1, true);
select t.as_user(:'a');
select (public.send_challenge(:'club_a', :'club_c', 'odi', null, t.day(4), 'Lineup Ground')).id as ch_p \gset
select t.as_user(:'c');
select (public.respond_to_challenge(:'ch_p', true)).match_id as p \gset
select (public.send_challenge(:'club_c', :'club_a', 't10', null, t.day(6), 'Riders Ground')).id as ch_q \gset
select t.as_user(:'a');
select (public.respond_to_challenge(:'ch_q', true)).match_id as q \gset
select public.respond_to_match_schedule(:'q', 1, true);
select (public.send_challenge(:'club_a', :'club_b', 't20', null, t.day(8), 'Lineup Ground')).id as ch_h \gset
select t.as_user(:'b');
select (public.respond_to_challenge(:'ch_h', true)).match_id as h \gset
select public.respond_to_match_schedule(:'h', 1, true);
reset role;
select t.ok((select string_agg(status, ',' order by starts_at) from public.matches where id in (:'m', :'q', :'h')) = 'confirmed,confirmed,confirmed'
            and (select status from public.matches where id = :'p') = 'pending', 'S0 setup: M, Q, H confirmed; P pending');
-- Q has started (its time moved back for the fixture).
set session_replication_role = replica;
update public.matches set starts_at = now() - interval '1 hour' where id = :'q';
set session_replication_role = origin;
select t.squad(:'club_a', 0, 11, 4)::text as sq_a \gset
select t.squad(:'club_b', 0, 11, 4)::text as sq_b \gset
select t.mem(101) as cap_a \gset
select t.mem(102) as vice_a \gset
select t.mem(112) as sub_a \gset

-- ---------------------------------------------------------------------------
-- A. Who may save, and when
-- ---------------------------------------------------------------------------
set role anon;
select t.expect_error(format('select public.save_match_lineup(%L, %L, null, %L, null, null)', :'m', 'XI', :'sq_a'),
                      '%permission denied%', 'A1 anon cannot call save_match_lineup');
reset role;
set role authenticated;
select t.no_session();
select t.expect_error(format('select public.save_match_lineup(%L, %L, null, %L, null, null)', :'m', 'XI', :'sq_a'),
                      '%not authenticated%', 'A2 no session: not authenticated');
select t.as_user(:'pa1');
select t.expect_error(format('select public.save_match_lineup(%L, %L, null, %L, null, null)', :'m', 'XI', :'sq_a'),
                      '%lineup: not allowed%', 'A3 a member (not the owner) cannot save');
select t.as_user(:'c');
select t.expect_error(format('select public.save_match_lineup(%L, %L, null, %L, null, null)', :'m', 'XI', :'sq_a'),
                      '%lineup: not allowed%', 'A4 the owner of a club not in the match cannot save');
select t.as_user(:'a');
select t.expect_error(format('select public.save_match_lineup(%L, %L, null, %L, null, null)', gen_random_uuid(), 'XI', :'sq_a'),
                      '%lineup: not found%', 'A5 unknown match: not found');
select t.expect_error(format('select public.save_match_lineup(%L, %L, null, %L, null, null)', :'p', 'XI', :'sq_a'),
                      '%match not confirmed%', 'A6 a pending (unconfirmed) match: match not confirmed');
select t.expect_error(format('select public.save_match_lineup(%L, %L, null, %L, null, null)', :'q', 'XI', :'sq_a'),
                      '%match started%', 'A7 a match that has started: match started');

-- ---------------------------------------------------------------------------
-- B. Validation (nothing is stored by any refused save)
-- ---------------------------------------------------------------------------
select t.expect_error(format('select public.save_match_lineup(%L, %L, null, %L, null, null)', :'m', '   ', :'sq_a'),
                      '%invalid name%', 'B1 blank name: invalid name');
select t.expect_error(format('select public.save_match_lineup(%L, %L, null, %L, null, null)', :'m', repeat('n', 41), :'sq_a'),
                      '%invalid name%', 'B2 name of 41 characters: invalid name');
select t.expect_error(format('select public.save_match_lineup(%L, %L, null, %L, null, null)', :'m', 'XI', '{"a": 1}'),
                      '%lineup: invalid%', 'B3 players not an array: invalid');
select t.expect_error(format('select public.save_match_lineup(%L, %L, null, null, null, null)', :'m', 'XI'),
                      '%lineup: invalid%', 'B3b no players: invalid');
select t.expect_error(format('select public.save_match_lineup(%L, %L, null, %L, null, null)', :'m', 'XI',
                             jsonb_set((:'sq_a')::jsonb, '{0,selection}', '"bench"')),
                      '%lineup: invalid%', 'B4 unknown selection: invalid');
select t.expect_error(format('select public.save_match_lineup(%L, %L, null, %L, null, null)', :'m', 'XI',
                             jsonb_set((:'sq_a')::jsonb, '{0,member_id}', '"not-a-uuid"')),
                      '%lineup: invalid%', 'B5 a malformed member id: invalid');
select t.expect_error(format('select public.save_match_lineup(%L, %L, null, %L, null, null)', :'m', 'XI',
                             t.squad(:'club_a', 0, 10, 4)), '%invalid squad%', 'B6 10 + 4: invalid squad');
select t.expect_error(format('select public.save_match_lineup(%L, %L, null, %L, null, null)', :'m', 'XI',
                             t.squad(:'club_a', 0, 11, 3)), '%invalid squad%', 'B7 11 + 3: invalid squad');
select t.expect_error(format('select public.save_match_lineup(%L, %L, null, %L, null, null)', :'m', 'XI',
                             t.squad(:'club_a', 0, 12, 4)), '%invalid squad%', 'B8 12 + 4: invalid squad');
select t.expect_error(format('select public.save_match_lineup(%L, %L, null, %L, null, null)', :'m', 'XI',
                             t.squad(:'club_a', 0, 11, 5)), '%invalid squad%', 'B9 11 + 5: invalid squad');
select t.expect_error(format('select public.save_match_lineup(%L, %L, null, %L, null, null)', :'m', 'XI', '[]'),
                      '%invalid squad%', 'B10 empty squad: invalid squad');
select t.expect_error(format('select public.save_match_lineup(%L, %L, null, %L, null, null)', :'m', 'XI',
                             t.swap((:'sq_a')::jsonb, 14, t.mem(101))), '%lineup: invalid%', 'B11 a player listed twice: invalid');
select t.expect_error(format('select public.save_match_lineup(%L, %L, null, %L, %L, %L)', :'m', 'XI', :'sq_a', :'cap_a', :'cap_a'),
                      '%invalid captain%', 'B12 captain = vice-captain: invalid captain');
select t.expect_error(format('select public.save_match_lineup(%L, %L, null, %L, %L, null)', :'m', 'XI', :'sq_a', t.mem(116)),
                      '%invalid captain%', 'B13 a captain not in the lineup: invalid captain');
select t.expect_error(format('select public.save_match_lineup(%L, %L, null, %L, %L, null)', :'m', 'XI', :'sq_a', :'sub_a'),
                      '%invalid captain%', 'B14 a substitute as captain: invalid captain');
select t.expect_error(format('select public.save_match_lineup(%L, %L, null, %L, null, %L)', :'m', 'XI', :'sq_a', t.mem(116)),
                      '%invalid vice-captain%', 'B15 a vice-captain not in the lineup: invalid vice-captain');
select t.expect_error(format('select public.save_match_lineup(%L, %L, null, %L, %L, %L)', :'m', 'XI', :'sq_a', :'cap_a', :'sub_a'),
                      '%invalid vice-captain%', 'B16 a substitute as vice-captain: invalid vice-captain');
select t.expect_error(format('select public.save_match_lineup(%L, %L, null, %L, null, null)', :'m', 'XI',
                             t.swap((:'sq_a')::jsonb, 3, t.mem(201))), '%player not in club%',
                      'B17 another club''s player: player not in club');
select t.expect_error(format('select public.save_match_lineup(%L, %L, null, %L, null, null)', :'m', 'XI',
                             t.swap((:'sq_a')::jsonb, 3, gen_random_uuid())), '%player not in club%',
                      'B18 an unknown member id: player not in club');
select t.expect_error(format('select public.save_match_lineup(%L, %L, %L, %L, null, null)', :'m', 'XI', :'team_a_old', :'sq_a'),
                      '%team archived%', 'B19 an archived source team: team archived');
select t.expect_error(format('select public.save_match_lineup(%L, %L, %L, %L, null, null)', :'m', 'XI', :'team_b', :'sq_a'),
                      '%invalid team%', 'B20 another club''s team: invalid team');
select t.expect_error(format('select public.save_match_lineup(%L, %L, %L, %L, null, null)', :'m', 'XI', gen_random_uuid(), :'sq_a'),
                      '%invalid team%', 'B21 an unknown team: invalid team');
reset role;
-- Member 117 leaves club A (removed by the owner): removed from team_a too.
set role authenticated;
select t.as_user(:'a');
select public.remove_club_member(t.mem(117));
select t.expect_error(format('select public.save_match_lineup(%L, %L, null, %L, null, null)', :'m', 'XI',
                             t.swap((:'sq_a')::jsonb, 3, t.mem(117))), '%player not in club%',
                      'B22 a removed (inactive) member: player not in club');
reset role;
select t.ok(not exists (select 1 from public.match_lineups) and not exists (select 1 from public.match_lineup_players),
            'B23 nothing was stored by the refused saves');
select t.ok(not exists (select 1 from public.team_players where member_id = t.mem(117))
            and exists (select 1 from public.team_players where member_id = t.mem(110)),
            'B24 existing behaviour kept: the removed member also left team_a''s squad');

-- ---------------------------------------------------------------------------
-- C. Saving
-- ---------------------------------------------------------------------------
set role authenticated;
select t.as_user(:'a');
select (public.save_match_lineup(:'m', '  Lions   Match XI ', :'team_a', :'sq_a', :'cap_a', :'vice_a')).saved_by as saved_by_a \gset
reset role;
select t.ok(:'saved_by_a' = :'a'
            and (select name = 'Lions Match XI' and source_team_id = :'team_a' and captain_member_id = :'cap_a'
                        and vice_captain_member_id = :'vice_a'
                   from public.match_lineups where match_id = :'m' and club_id = :'club_a'),
            'C1 A''s lineup saved: name normalised, source team, captain, vice-captain, saved by the owner');
select t.ok((select count(*) filter (where selection = 'playing') = 11 and count(*) filter (where selection = 'sub') = 4
                    and min(position) = 1 and max(position) = 15 and count(distinct position) = 15
               from public.match_lineup_players where match_id = :'m' and club_id = :'club_a')
            and (select position from public.match_lineup_players where match_id = :'m' and member_id = :'cap_a') = 1
            and (select selection from public.match_lineup_players where match_id = :'m' and member_id = :'sub_a') = 'sub',
            'C2 exactly 11 + 4, positions 1–15 in pick order');
set role authenticated;
select t.as_user(:'b');
select public.save_match_lineup(:'m', 'Kings XI', :'team_b', :'sq_b', null, null);
select t.as_user(:'a');
select t.squad(:'club_a', 1, 11, 4)::text as sq_a2 \gset
select public.save_match_lineup(:'m', 'Lions Match XI', null, :'sq_a2', t.mem(102), t.mem(103));
reset role;
select t.ok((select count(*) from public.match_lineup_players where match_id = :'m' and club_id = :'club_a') = 15
            and not exists (select 1 from public.match_lineup_players where match_id = :'m' and member_id = :'cap_a')
            and exists (select 1 from public.match_lineup_players where match_id = :'m' and member_id = t.mem(116))
            and (select captain_member_id = t.mem(102) and vice_captain_member_id = t.mem(103) and source_team_id is null
                   from public.match_lineups where match_id = :'m' and club_id = :'club_a')
            and (select count(*) from public.match_lineups where match_id = :'m') = 2,
            'C3 saving again replaces the whole lineup (players, captain, team); B''s lineup is separate');

-- ---------------------------------------------------------------------------
-- D. Privacy: own club only
-- ---------------------------------------------------------------------------
set role authenticated;
select t.as_user(:'a');
select t.ok((select count(*) from public.match_lineup(:'m')) = 15
            and (select bool_and(club_id = :'club_a') from public.match_lineup(:'m'))
            and (select count(*) from public.match_lineup(:'m') where full_name like 'Lineup Person %') = 15,
            'D1 owner A reads A''s lineup only (15 players with names)');
select t.as_user(:'pa1');
select t.ok((select count(*) from public.match_lineup(:'m')) = 15
            and (select bool_and(club_id = :'club_a') from public.match_lineup(:'m')),
            'D2 an active member of A reads A''s lineup only');
select t.as_user(:'b');
select t.ok((select count(*) from public.match_lineup(:'m')) = 15
            and (select bool_and(club_id = :'club_b') from public.match_lineup(:'m')),
            'D3 owner B reads B''s lineup only (never the opponent''s)');
select t.as_user(:'pb1');
select t.ok((select bool_and(club_id = :'club_b') from public.match_lineup(:'m')), 'D4 a member of B reads B''s lineup only');
select t.ok((select count(*) from public.match_lineups) = 1 and (select count(*) from public.match_lineup_players) = 15
            and not exists (select 1 from public.match_lineup_players where club_id = :'club_a'),
            'D5 RLS: a member of B reads no row of A''s lineup');
select t.as_user(:'a');
select t.ok(not exists (select 1 from public.match_lineups where club_id = :'club_b')
            and not exists (select 1 from public.match_lineup_players where club_id = :'club_b'),
            'D6 RLS: owner A reads no row of B''s lineup');
select t.as_user(:'c');
select t.expect_error(format('select * from public.match_lineup(%L)', :'m'), '%lineup: not allowed%',
                      'D7 another club''s owner: not allowed');
select t.ok((select count(*) from public.match_lineups) = 0, 'D7b RLS: another club''s owner reads no lineup');
select t.as_user(:'u');
select t.expect_error(format('select * from public.match_lineup(%L)', :'m'), '%lineup: not allowed%', 'D8 an outsider: not allowed');
select t.as_user(:'ra');
select t.expect_error(format('select * from public.match_lineup(%L)', :'m'), '%lineup: not allowed%',
                      'D9 a removed member: not allowed');
select t.ok((select count(*) from public.match_lineup_players) = 0, 'D9b RLS: a removed member reads nothing');
select t.as_user(:'a');
select t.expect_error(format('select * from public.match_lineup(%L)', gen_random_uuid()), '%lineup: not found%',
                      'D10 unknown match: not found');
select t.ok((select count(*) from public.match_lineup(:'p')) = 0, 'D11 no lineup saved yet: no rows');
select t.no_session();
select t.ok((select count(*) from public.match_lineups) = 0, 'D12 no session: reads nothing');
reset role;
set role anon;
select t.expect_error('select count(*) from public.match_lineups', '%permission denied%', 'D13 anon cannot read match_lineups');
select t.expect_error('select count(*) from public.match_lineup_players', '%permission denied%',
                      'D14 anon cannot read match_lineup_players');
select t.expect_error(format('select * from public.match_lineup(%L)', :'m'), '%permission denied%', 'D15 anon cannot call match_lineup');
reset role;

-- ---------------------------------------------------------------------------
-- E. No direct writes; table-level integrity
-- ---------------------------------------------------------------------------
set role authenticated;
select t.as_user(:'a');
select t.expect_error(format('insert into public.match_lineups (match_id, club_id, name) values (%L, %L, %L)', :'p', :'club_a', 'X'),
                      '%permission denied%', 'E1 direct INSERT into match_lineups: denied');
select t.expect_error(format('update public.match_lineups set name = %L where match_id = %L', 'X', :'m'),
                      '%permission denied%', 'E2 direct UPDATE of match_lineups: denied');
select t.expect_error(format('delete from public.match_lineup_players where match_id = %L', :'m'),
                      '%permission denied%', 'E3 direct DELETE from match_lineup_players: denied');
select t.expect_error(format('insert into public.match_lineup_players (match_id, club_id, member_id, selection, position)
                              values (%L, %L, %L, %L, 16)', :'m', :'club_a', t.mem(101), 'sub'),
                      '%permission denied%', 'E4 direct INSERT into match_lineup_players: denied');
reset role;
select t.expect_error(format('update public.match_lineup_players set position = 2 where match_id = %L and member_id = %L',
                             :'m', t.mem(116)), '23505', 'E5 duplicate position in a lineup: refused (unique)');
select t.expect_error(format('update public.match_lineup_players set position = 16 where match_id = %L and member_id = %L',
                             :'m', t.mem(116)), '23514', 'E6 position 16: refused (check)');
select t.expect_error(format('insert into public.match_lineups (match_id, club_id, name) values (%L, %L, %L)', :'m', :'club_c', 'X'),
                      '%club not in match%', 'E7 a lineup for a club not in the match: refused (trigger)');
select t.expect_error(format('update public.match_lineup_players set member_id = %L where match_id = %L and member_id = %L',
                             t.mem(201), :'m', t.mem(116)), '%player not in club%',
                      'E8 another club''s member in a lineup: refused (trigger)');
select t.expect_error(format('update public.match_lineups set vice_captain_member_id = captain_member_id where match_id = %L and club_id = %L',
                             :'m', :'club_a'), '23514', 'E9 captain = vice-captain: refused (check)');
select t.expect_error(format('delete from public.teams where id = %L', :'team_b'), '23503',
                      'E10 a team used by a lineup can''t be deleted (ON DELETE RESTRICT)');

-- ---------------------------------------------------------------------------
-- F. Atomicity: a failure late in a save leaves the previous lineup intact
-- ---------------------------------------------------------------------------
select string_agg(member_id::text || selection || position, ',' order by position) as before_players
  from public.match_lineup_players where match_id = :'m' and club_id = :'club_a' \gset
select saved_at as before_saved from public.match_lineups where match_id = :'m' and club_id = :'club_a' \gset
create or replace function t.fail_on_101() returns trigger language plpgsql as $$
begin
  if new.member_id = t.mem(101) then raise exception 'test: injected failure'; end if;
  return new;
end $$;
create trigger t_fail_on_101 before insert on public.match_lineup_players for each row execute function t.fail_on_101();
set role authenticated;
select t.as_user(:'a');
select t.expect_error(format('select public.save_match_lineup(%L, %L, null, %L, %L, %L)', :'m', 'New XI', :'sq_a', :'cap_a', :'vice_a'),
                      '%injected failure%', 'F1 a save failing after its first writes (injected) …');
reset role;
drop trigger t_fail_on_101 on public.match_lineup_players;
select t.ok((select string_agg(member_id::text || selection || position, ',' order by position)
               from public.match_lineup_players where match_id = :'m' and club_id = :'club_a') = :'before_players'
            and (select name = 'Lions Match XI' and saved_at = (:'before_saved')::timestamptz and captain_member_id = t.mem(102)
                   from public.match_lineups where match_id = :'m' and club_id = :'club_a'),
            'F2 … leaves the previous lineup exactly as it was (no partial write)');

-- ---------------------------------------------------------------------------
-- G. Member removal: out of lineups of matches not completed; history kept
-- ---------------------------------------------------------------------------
set role authenticated;
select t.as_user(:'a');
select public.save_match_lineup(:'m', 'Lions Match XI', null, :'sq_a', :'cap_a', :'vice_a');
select public.save_match_lineup(:'h', 'Lions Final XI', :'team_a', :'sq_a', :'cap_a', :'vice_a');
reset role;
-- H is played (results arrive in M2; set here directly — the status guard allows confirmed → completed).
update public.matches set status = 'completed' where id = :'h';
set role authenticated;
select t.as_user(:'a');
select public.remove_club_member(:'cap_a');
reset role;
select t.ok((select count(*) from public.match_lineup_players where match_id = :'m' and club_id = :'club_a') = 14
            and not exists (select 1 from public.match_lineup_players where match_id = :'m' and member_id = :'cap_a')
            and (select captain_member_id is null and vice_captain_member_id = :'vice_a'
                   from public.match_lineups where match_id = :'m' and club_id = :'club_a'),
            'G1 removed member leaves the upcoming match''s lineup; captain cleared, vice-captain kept');
select t.ok((select count(*) from public.match_lineup_players where match_id = :'h' and club_id = :'club_a') = 15
            and exists (select 1 from public.match_lineup_players where match_id = :'h' and member_id = :'cap_a')
            and (select captain_member_id = :'cap_a' from public.match_lineups where match_id = :'h' and club_id = :'club_a'),
            'G2 the completed match keeps its lineup and captain (history)');
select t.ok((select count(*) from public.match_lineup_players where match_id = :'m' and club_id = :'club_b') = 15,
            'G3 the other club''s lineup is untouched');
set role authenticated;
select t.as_user(:'a');
select t.expect_error(format('select public.save_match_lineup(%L, %L, null, %L, null, null)', :'h', 'XI', :'sq_a'),
                      '%match not confirmed%', 'G4 a completed match''s lineup can''t be changed');
reset role;
-- Account deletion removes that person's memberships, and with them their lineup rows.
delete from auth.users where id = t.uid(103);
select t.ok(not exists (select 1 from public.match_lineup_players lp
                         where lp.match_id in (:'m', :'h') and lp.club_id = :'club_a'
                           and not exists (select 1 from public.club_members cm where cm.id = lp.member_id))
            and (select count(*) from public.match_lineup_players where match_id = :'h' and club_id = :'club_a') = 14,
            'G5 a deleted account''s lineup rows go with their membership (cascade)');

-- ---------------------------------------------------------------------------
-- H. Cancel waits for nothing here; a cancelled match is closed for lineups
-- ---------------------------------------------------------------------------
set role authenticated;
select t.as_user(:'b');
select public.cancel_match(:'m', 'Ground flooded');
select t.expect_error(format('select public.save_match_lineup(%L, %L, null, %L, null, null)', :'m', 'XI', :'sq_b'),
                      '%match not confirmed%', 'H1 a cancelled match: match not confirmed');
select t.ok((select count(*) from public.match_lineup(:'m')) = 15, 'H2 a cancelled match''s lineup stays readable');
reset role;

-- ---------------------------------------------------------------------------
-- I. Deleting a club removes its lineups (team RESTRICT doesn't block it)
-- ---------------------------------------------------------------------------
delete from public.clubs where id = :'club_b';
select t.ok(not exists (select 1 from public.match_lineups where club_id = :'club_b')
            and not exists (select 1 from public.teams where id = :'team_b')
            and not exists (select 1 from public.matches where id = :'m'),
            'I1 deleting club B removes its teams, its matches and both clubs'' lineups for them');
select t.ok(exists (select 1 from public.match_lineups where match_id = :'h') is false
            and exists (select 1 from public.teams where id = :'team_a'),
            'I2 club A''s own team stays');

-- Clean up (this database only).
delete from public.clubs where owner_id::text like 'e8000000%';
delete from auth.users where id::text like 'e8000000%';
drop function if exists t.fail_on_101();
select t.ok(not exists (select 1 from public.profiles where id::text like 'e8000000%')
            and not exists (select 1 from public.match_lineups) and not exists (select 1 from public.matches),
            'Z cleanup done');
