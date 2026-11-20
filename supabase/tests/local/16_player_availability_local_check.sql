-- CricEco · LOCAL TEST ONLY — migration 19 (player availability) on a
-- DISPOSABLE plain PostgreSQL 17 database, after 00_auth_stub.sql,
-- 02_legacy_profiles_fixture.sql, migrations 1–18 (+ the D1 location seed)
-- and migration 19. Also tests migration 18's "no injured / unavailable
-- player in a lineup" rule, which migration 19 enforces.
-- Synthetic accounts only (ids e9…).
-- Run with psql:  psql -X -v ON_ERROR_STOP=1 -f 16_player_availability_local_check.sql
-- Every check prints "PASS: …"; the first failure stops the run ("FAIL: …").
-- Refuses to run on a real Supabase project (its auth.users has passwords).
\set ON_ERROR_STOP on

do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password') then
    raise exception 'LOCAL ONLY: this looks like a real Supabase project — refusing';
  end if;
  if to_regclass('public.player_availability') is null then
    raise exception 'apply migration 19 first';
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
create or replace function t.uid9(p_n int) returns uuid language sql immutable as $$
  select ('e9000000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
$$;
create or replace function t.mem9(p_n int, p_club uuid) returns uuid language sql stable security definer set search_path = '' as $$
  select m.id from public.club_members m where m.user_id = t.uid9(p_n) and m.club_id = p_club;
$$;
-- Squad of club p_club: members p_first .. p_first + 14 (11 playing, 4 sub).
create or replace function t.squad9(p_club uuid, p_first int) returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_agg(jsonb_build_object('member_id', t.mem9(n, p_club),
                                      'selection', case when n < p_first + 11 then 'playing' else 'sub' end) order by n)
    from generate_series(p_first, p_first + 14) n;
$$;
create or replace function t.make_person9(p_n int) returns uuid language plpgsql as $$
declare
  v uuid := t.uid9(p_n);
begin
  insert into auth.users (id, email) values (v, format('avail%s@local.test', p_n));
  insert into public.current_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
  insert into public.permanent_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
  update public.profiles
     set full_name = format('Avail Person %s', p_n),
         phone = format('+923%s', lpad((530000000 + p_n)::text, 9, '0')),
         date_of_birth = date '2000-05-01',
         profile_completed = true
   where id = v;
  insert into public.player_profiles (user_id, player_role, batting_style, bowling_style, is_wicketkeeper)
  values (v, 'all_rounder', 'right_handed', 'right_arm_fast', false);
  return v;
end $$;
grant execute on all functions in schema t to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Synthetic data: owners 1 (club A), 2 (club B); players 101–116 of A,
-- 117 removed from A; 201–215 of B; 300 an outsider. Match M: A vs B,
-- confirmed for day+3 10:00 (Asia/Karachi).
-- ---------------------------------------------------------------------------
select count(*) from (select t.make_person9(n)
                        from (select unnest(array[1, 2, 300]) union all select generate_series(101, 117)
                              union all select generate_series(201, 215)) s(n)) x;
insert into public.clubs (owner_id, name, city, club_type) values
  (t.uid9(1), 'Avail Lions', 'Lahore', 'corporate'),
  (t.uid9(2), 'Avail Kings', 'Karachi', 'professional');
select id as club_a from public.clubs where owner_id = t.uid9(1) \gset
select id as club_b from public.clubs where owner_id = t.uid9(2) \gset
insert into public.club_members (club_id, user_id, member_role, status)
select :'club_a', t.uid9(n), 'player', 'active' from generate_series(101, 117) n;
insert into public.club_members (club_id, user_id, member_role, status)
select :'club_b', t.uid9(n), 'player', 'active' from generate_series(201, 215) n;
\set a 'e9000000-0000-4000-8000-000000000001'
\set b 'e9000000-0000-4000-8000-000000000002'
\set u 'e9000000-0000-4000-8000-000000000300'
\set p1 'e9000000-0000-4000-8000-000000000101'
\set p2 'e9000000-0000-4000-8000-000000000102'
\set p3 'e9000000-0000-4000-8000-000000000103'
\set r 'e9000000-0000-4000-8000-000000000117'
\set q1 'e9000000-0000-4000-8000-000000000201'
set role authenticated;
select t.as_user(:'a');
select (public.send_challenge(:'club_a', :'club_b', 't20', null, t.day(3), 'Avail Ground')).id as ch \gset
select t.as_user(:'b');
select (public.respond_to_challenge(:'ch', true)).match_id as m \gset
select public.respond_to_match_schedule(:'m', 1, true);
-- 117 sets a record while still a member, then is removed from A.
select t.as_user(:'r');
select public.set_my_availability('injured', 'injury', null, 'Hamstring');
select t.as_user(:'a');
select public.remove_club_member(t.mem9(117, :'club_a'));
reset role;

-- ---------------------------------------------------------------------------
-- A. Anonymous and signed-out access
-- ---------------------------------------------------------------------------
set role anon;
select t.expect_error('select public.set_my_availability(''available'')', '%permission denied%', 'A1 anon cannot set availability');
select t.expect_error('select * from public.my_availability()', '%permission denied%', 'A2 anon cannot read my_availability');
select t.expect_error(format('select * from public.club_player_availability(%L)', :'club_a'), '%permission denied%',
                      'A3 anon cannot call club_player_availability');
select t.expect_error('select count(*) from public.player_availability', '%permission denied%', 'A4 anon cannot read the table');
reset role;
set role authenticated;
select t.no_session();
select t.expect_error('select public.set_my_availability(''available'')', '%not authenticated%', 'A5 no session: set refused');
select t.expect_error('select * from public.my_availability()', '%not authenticated%', 'A6 no session: my_availability refused');
select t.expect_error(format('select * from public.club_player_availability(%L)', :'club_a'), '%not authenticated%',
                      'A7 no session: club_player_availability refused');
select t.ok((select count(*) from public.player_availability) = 0, 'A8 no session: the table reads empty');

-- ---------------------------------------------------------------------------
-- B. Setting one's own availability: every status, validation
-- ---------------------------------------------------------------------------
select t.as_user(:'p1');
select (public.set_my_availability('available')).status as s1 \gset
select (public.set_my_availability('limited', 'work')).status as s2 \gset
select (public.set_my_availability('unavailable', 'travel', t.day(5))).status as s3 \gset
select (public.set_my_availability('other', 'other', null, 'Exams')).status as s4 \gset
select (public.set_my_availability('injured', 'injury', t.day(10), 'Hamstring')).status as s5 \gset
select t.ok(:'s1' = 'available' and :'s2' = 'limited' and :'s3' = 'unavailable' and :'s4' = 'other' and :'s5' = 'injured',
            'B1 every status can be set: available, limited, unavailable, other, injured');
select t.ok((select count(*) from public.player_availability where user_id = :'p1') = 1
            and (select reason = 'injury' and until_date = t.day(10) and notes = 'Hamstring'
                   from public.player_availability where user_id = :'p1'),
            'B2 one record per person, replaced each time');
select t.expect_error('select public.set_my_availability(''busy'')', '%invalid status%', 'B3 unknown status: invalid status');
select t.expect_error('select public.set_my_availability(null)', '%invalid status%', 'B4 no status: invalid status');
select t.expect_error('select public.set_my_availability(''injured'', ''holiday'')', '%invalid reason%',
                      'B5 unknown reason: invalid reason');
select t.expect_error(format('select public.set_my_availability(%L, %L, %L)', 'injured', 'injury', t.day(-1)), '%invalid date%',
                      'B6 an until date in the past: invalid date');
select t.expect_error(format('select public.set_my_availability(%L, %L, %L)', 'injured', 'injury', t.day(366)), '%invalid date%',
                      'B7 an until date more than a year ahead: invalid date');
select t.expect_error(format('select public.set_my_availability(%L, null, null, %L)', 'limited', repeat('n', 201)),
                      '%invalid notes%', 'B8 notes of 201 characters: invalid notes');
select t.ok((select reason = 'injury' and until_date = t.day(10) and notes = 'Hamstring'
               from public.player_availability where user_id = :'p1'),
            'B9 refused updates changed nothing');
select t.ok((select until_date = t.day(0) and char_length(notes) = 200
               from public.set_my_availability('limited', null, t.day(0), repeat('n', 200))),
            'B10 until today and 200-character notes are accepted');
select t.ok((select status = 'injured' and reason = 'rest_day' and notes is null
               from public.set_my_availability('  INJURED ', ' Rest_Day ', null, '   ')),
            'B11 status and reason normalised (case, spaces); blank notes stored as NULL');
select t.ok((select status = 'available' and reason is null and until_date is null and notes = 'Back'
               from public.set_my_availability('available', 'injury', t.day(4), 'Back')),
            'B12 "available" clears reason and until date');
select t.ok((select count(*) from public.my_availability()) = 1
            and (select user_id = :'p1' and status = 'available' from public.my_availability()),
            'B13 my_availability returns the caller''s own record');
select t.as_user(:'p2');
select t.ok((select count(*) from public.my_availability()) = 0, 'B14 no record yet: my_availability returns nothing');
select public.set_my_availability('unavailable', 'personal', null, 'Away');
select t.as_user(:'p3');
select public.set_my_availability('limited');
select t.as_user(:'q1');
select public.set_my_availability('injured', 'injury');
reset role;
select t.ok((select status from public.player_availability where user_id = :'p1') = 'available'
            and (select status from public.player_availability where user_id = :'p2') = 'unavailable',
            'B15 each person changed only their own record');

-- ---------------------------------------------------------------------------
-- C. Nobody writes directly; each person reads only their own record
-- ---------------------------------------------------------------------------
set role authenticated;
select t.as_user(:'p1');
select t.expect_error(format('insert into public.player_availability (user_id, status) values (%L, %L)', :'u', 'injured'),
                      '%permission denied%', 'C1 direct INSERT: denied');
select t.expect_error(format('update public.player_availability set status = %L where user_id = %L', 'available', :'p2'),
                      '%permission denied%', 'C2 direct UPDATE (of another person''s record): denied');
select t.expect_error(format('update public.player_availability set status = %L where user_id = %L', 'injured', :'p1'),
                      '%permission denied%', 'C3 direct UPDATE (of one''s own record): denied');
select t.expect_error(format('delete from public.player_availability where user_id = %L', :'p1'),
                      '%permission denied%', 'C4 direct DELETE: denied');
select t.ok((select count(*) from public.player_availability) = 1
            and (select user_id from public.player_availability) = :'p1',
            'C5 a player reads only their own record (RLS)');
select t.expect_error(format('select * from public.club_player_availability(%L)', :'club_a'), '%availability: not allowed%',
                      'C6 a member (not the owner) cannot list the club''s availability');
select t.as_user(:'u');
select t.ok((select count(*) from public.player_availability) = 0, 'C7 an outsider reads nothing');
select t.expect_error(format('select * from public.club_player_availability(%L)', :'club_a'), '%availability: not allowed%',
                      'C8 an outsider cannot list a club''s availability');

-- ---------------------------------------------------------------------------
-- D. Club owners: their ACTIVE members only
-- ---------------------------------------------------------------------------
select t.as_user(:'a');
select t.ok((select count(*) from public.club_player_availability(:'club_a')) = 17
            and (select status from public.club_player_availability(:'club_a') where user_id = :'p2') = 'unavailable'
            and (select locks_selection from public.club_player_availability(:'club_a') where user_id = :'p2')
            and (select status = 'limited' and not locks_selection from public.club_player_availability(:'club_a') where user_id = :'p3')
            and (select status = 'available' and reason is null and updated_at is null
                   from public.club_player_availability(:'club_a') where user_id = t.uid9(110)),
            'D1 owner A lists A''s 17 active members (owner included); no record = available; locks for unavailable only');
select t.ok(not exists (select 1 from public.club_player_availability(:'club_a') where user_id = :'r')
            and not exists (select 1 from public.player_availability where user_id = :'r'),
            'D2 a removed member''s availability is no longer visible to the club owner');
select t.ok((select count(*) from public.player_availability) = 3
            and not exists (select 1 from public.player_availability where user_id = :'q1'),
            'D3 RLS: owner A reads A''s members'' records only (not B''s players)');
select t.expect_error(format('select * from public.club_player_availability(%L)', :'club_b'), '%availability: not allowed%',
                      'D4 owner A cannot list club B (the opponent)');
select t.as_user(:'b');
select t.ok(not exists (select 1 from public.player_availability where user_id in (:'p1', :'p2', :'p3'))
            and exists (select 1 from public.player_availability where user_id = :'q1'),
            'D5 owner B (the opponent) reads none of A''s players'' records');
select t.ok((select locks_selection from public.club_player_availability(:'club_b') where user_id = :'q1'),
            'D6 owner B sees their own injured player as locked');
reset role;
-- A person in two clubs: each club's owner sees them (they are a member of both).
insert into public.club_members (club_id, user_id, member_role, status) values (:'club_b', :'p2', 'player', 'active');
set role authenticated;
select t.as_user(:'b');
select t.ok((select status from public.club_player_availability(:'club_b') where user_id = :'p2') = 'unavailable',
            'D7 a member of both clubs is visible to each club''s owner');
reset role;
delete from public.club_members where club_id = :'club_b' and user_id = :'p2';

-- ---------------------------------------------------------------------------
-- E. Lineups: no injured / unavailable player on the match day
-- ---------------------------------------------------------------------------
set role authenticated;
select t.as_user(:'p2');
select public.set_my_availability('available');
select t.as_user(:'a');
select public.save_match_lineup(:'m', 'Avail XI', null, t.squad9(:'club_a', 101), null, null);
reset role;
select string_agg(member_id::text || position, ',' order by position) as saved_players
  from public.match_lineup_players where match_id = :'m' and club_id = :'club_a' \gset
set role authenticated;
select t.as_user(:'p2');
select public.set_my_availability('injured', 'injury');
select t.as_user(:'a');
select t.expect_error(format('select public.save_match_lineup(%L, %L, null, %L, null, null)', :'m', 'Avail XI 2',
                             t.squad9(:'club_a', 101)), '%lineup: player unavailable%',
                      'E1 an injured player (no end date) can''t be picked');
reset role;
select t.ok((select string_agg(member_id::text || position, ',' order by position)
               from public.match_lineup_players where match_id = :'m' and club_id = :'club_a') = :'saved_players'
            and (select name from public.match_lineups where match_id = :'m' and club_id = :'club_a') = 'Avail XI',
            'E2 the refused save left the saved lineup intact (atomic)');
select t.ok(exists (select 1 from public.match_lineup_players where match_id = :'m' and member_id = t.mem9(102, :'club_a')),
            'E3 a status change after saving does not change the saved lineup');
set role authenticated;
select t.as_user(:'p2');
select public.set_my_availability('unavailable', 'travel', t.day(3));
select t.as_user(:'a');
select t.expect_error(format('select public.save_match_lineup(%L, %L, null, %L, null, null)', :'m', 'XI', t.squad9(:'club_a', 101)),
                      '%lineup: player unavailable%', 'E4 unavailable until the match day: can''t be picked');
select t.as_user(:'p2');
select public.set_my_availability('unavailable', 'travel', t.day(2));
select t.as_user(:'a');
select t.ok((public.save_match_lineup(:'m', 'XI', null, t.squad9(:'club_a', 101), null, null)).name = 'XI',
            'E5 unavailable only until the day before the match: can be picked');
select t.as_user(:'p2');
select public.set_my_availability('injured', 'injury', t.day(2));
select t.as_user(:'a');
select t.ok((public.save_match_lineup(:'m', 'XI', null, t.squad9(:'club_a', 101), null, null)).name = 'XI',
            'E6 injured until the day before the match: can be picked');
select t.as_user(:'p2');
select public.set_my_availability('limited');
select t.as_user(:'p3');
select public.set_my_availability('other', 'other', null, 'Exams');
select t.as_user(:'a');
select t.ok((public.save_match_lineup(:'m', 'XI', null, t.squad9(:'club_a', 101), null, null)).name = 'XI',
            'E7 limited and other players can be picked');
select t.as_user(:'b');
select t.expect_error(format('select public.save_match_lineup(%L, %L, null, %L, null, null)', :'m', 'Kings', t.squad9(:'club_b', 201)),
                      '%lineup: player unavailable%', 'E8 the rule applies to the other club too (B''s injured player)');
reset role;

-- ---------------------------------------------------------------------------
-- F. Account deletion removes the record
-- ---------------------------------------------------------------------------
delete from auth.users where id = :'r';
select t.ok(not exists (select 1 from public.player_availability where user_id = :'r'),
            'F1 deleting an account deletes its availability record (cascade)');

-- Clean up (this database only).
delete from public.clubs where owner_id::text like 'e9000000%';
delete from auth.users where id::text like 'e9000000%';
select t.ok(not exists (select 1 from public.profiles where id::text like 'e9000000%')
            and not exists (select 1 from public.player_availability),
            'Z cleanup done');
