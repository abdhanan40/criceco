-- CricEco · LOCAL TEST ONLY — migration 17 (match challenges and matches) on
-- a DISPOSABLE plain PostgreSQL 17 database, after 00_auth_stub.sql,
-- 02_legacy_profiles_fixture.sql, migrations 1–16 (+ the D1 location seed)
-- and migration 17. Synthetic accounts only (ids e7…).
-- Run with psql:  psql -X -v ON_ERROR_STOP=1 -f 14_matches_local_check.sql
-- Every check prints "PASS: …"; the first failure stops the run ("FAIL: …").
-- Concurrency (two sessions) is in 14b_matches_concurrency.sh.
-- Refuses to run on a real Supabase project (its auth.users has passwords).
\set ON_ERROR_STOP on

do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password') then
    raise exception 'LOCAL ONLY: this looks like a real Supabase project — refusing';
  end if;
  if to_regclass('public.matches') is null or to_regclass('public.match_challenges') is null then
    raise exception 'apply migration 17 first';
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
-- Dates and times relative to "now" in Asia/Karachi.
create or replace function t.day(p_offset int) returns date language sql stable as $$
  select (now() at time zone 'Asia/Karachi')::date + p_offset;
$$;
grant execute on all functions in schema t to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Synthetic accounts and clubs (created directly; the club functions are
-- tested elsewhere): owners A, B, C, D of clubs A (Lahore), B (Karachi),
-- C (Lahore), D (Islamabad); M an active player of club A; R a removed member
-- of club A; U an outsider; owners of clubs E01–E20 (for the pending cap).
-- ---------------------------------------------------------------------------
\set a 'e7000000-0000-4000-8000-000000000001'
\set b 'e7000000-0000-4000-8000-000000000002'
\set c 'e7000000-0000-4000-8000-000000000003'
\set d 'e7000000-0000-4000-8000-000000000004'
\set m 'e7000000-0000-4000-8000-000000000005'
\set r 'e7000000-0000-4000-8000-000000000006'
\set u 'e7000000-0000-4000-8000-000000000007'

-- A synthetic person with a completed profile (a club needs one).
create or replace function t.make_person(p_n int) returns uuid language plpgsql as $$
declare
  v uuid := ('e7000000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
begin
  insert into auth.users (id, email) values (v, format('match%s@local.test', p_n));
  insert into public.current_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
  insert into public.permanent_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
  update public.profiles
     set full_name = format('Match Person %s', p_n),
         phone = format('+923%s', lpad((500000000 + p_n)::text, 9, '0')),
         date_of_birth = date '2000-05-01',
         profile_completed = true
   where id = v;
  insert into public.player_profiles (user_id, player_role, batting_style, bowling_style, is_wicketkeeper)
  values (v, 'all_rounder', 'right_handed', 'right_arm_fast', false);
  return v;
end $$;

select count(*) from (select t.make_person(i) from generate_series(1, 27) i) s;

insert into public.clubs (owner_id, name, short_name, city, club_type) values
  (:'a', 'Lahore Lions Match', 'LLM', 'Lahore', 'corporate'),
  (:'b', 'Karachi Kings Match', 'KKM', 'Karachi', 'professional'),
  (:'c', 'Ravi Riders Match', null, 'Lahore', 'college_university'),
  (:'d', 'Capital Falcons Match', 'CFM', 'Islamabad', 'corporate');
insert into public.clubs (owner_id, name, city, club_type)
select ('e7000000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid, format('Eagles Match %s', lpad((i - 7)::text, 2, '0')),
       'Multan', 'corporate'
  from generate_series(8, 27) i;
select id as club_a from public.clubs where owner_id = :'a' \gset
select id as club_b from public.clubs where owner_id = :'b' \gset
select id as club_c from public.clubs where owner_id = :'c' \gset
select id as club_d from public.clubs where owner_id = :'d' \gset
insert into public.club_members (club_id, user_id, member_role, status) values (:'club_a', :'m', 'player', 'active');
insert into public.club_members (club_id, user_id, member_role, status, removed_at)
values (:'club_a', :'r', 'player', 'removed', now());

select count(*) as other_clubs_before from public.clubs where owner_id::text not like 'e7000000%' \gset
select count(*) as members_before from public.club_members \gset
select count(*) as teams_before from public.teams \gset

-- ---------------------------------------------------------------------------
-- A. Club directory (public fields only, owners only)
-- ---------------------------------------------------------------------------
set role anon;
select t.expect_error('select * from public.match_club_directory()', '%permission denied%', 'A1 anon cannot call match_club_directory');
reset role;
set role authenticated;
select t.no_session();
select t.expect_error('select * from public.match_club_directory()', '%not authenticated%', 'A2 no session: not authenticated');
select t.as_user(:'m');
select t.expect_error('select * from public.match_club_directory()', '%not allowed%', 'A3 a member who owns no club: not allowed');
select t.as_user(:'u');
select t.expect_error('select * from public.match_club_directory()', '%not allowed%', 'A3b an outsider: not allowed');
select t.as_user(:'a');
select t.ok((select count(*) from public.match_club_directory()) = 23 + :other_clubs_before
            and not exists (select 1 from public.match_club_directory() where club_id = :'club_a'),
            'A4 owner A sees every other club, never their own');
select t.ok((select count(*) from public.match_club_directory('kings')) = 1
            and (select club_id from public.match_club_directory('  KINGS  ')) = :'club_b',
            'A5 search by name (case and outer spaces ignored)');
select t.ok((select club_id from public.match_club_directory('cfm')) = :'club_d', 'A6 search by short name');
select t.ok((select count(*) from public.match_club_directory(null, ' lahore ')) = 1
            and (select club_id from public.match_club_directory(null, 'LAHORE')) = :'club_c',
            'A7 city filter (exact, case-insensitive; own club excluded)');
select t.ok((select count(*) from public.match_club_directory('%')) = 0
            and (select count(*) from public.match_club_directory('_')) = 0, 'A8 wildcards are literal');
select t.ok((select count(*) from public.match_club_directory('eagles')) = 20, 'A9 20 matching clubs listed');
select t.expect_error(format('select * from public.match_club_directory(%L)', repeat('x', 101)), '%invalid%',
                      'A10 search longer than 100: invalid');
reset role;
select t.ok(pg_get_function_result('public.match_club_directory(text, text)'::regprocedure)
              = 'TABLE(club_id uuid, name text, short_name text, city text, club_type text)',
            'A11 the directory returns exactly id, name, short name, city, type (no owner, phone, email, address, code)');
-- More than 50 clubs: the directory stops at 50.
do $$
declare i int;
begin
  for i in 100..140 loop
    insert into public.clubs (owner_id, name, city, club_type)
    values (t.make_person(i), format('Extra Match %s', i), 'Multan', 'corporate');
  end loop;
end $$;
set role authenticated;
select t.as_user(:'a');
select t.ok((select count(*) from public.match_club_directory()) = 50, 'A12 at most 50 rows');
reset role;
delete from public.clubs where owner_id::text like 'e7000000-0000-4000-8000-0000000001%';
delete from auth.users where id::text like 'e7000000-0000-4000-8000-0000000001%';

-- ---------------------------------------------------------------------------
-- B. send_challenge
-- ---------------------------------------------------------------------------
set role anon;
select t.expect_error(format('select public.send_challenge(%L, %L, %L, null, %L, %L)', :'club_a', :'club_b', 't20',
                             t.day(3), 'Venue'), '%permission denied%', 'B1 anon cannot send');
reset role;
set role authenticated;
select t.no_session();
select t.expect_error(format('select public.send_challenge(%L, %L, %L, null, %L, %L)', :'club_a', :'club_b', 't20',
                             t.day(3), 'Venue'), '%not authenticated%', 'B2 no session: not authenticated');
select t.as_user(:'m');
select t.expect_error(format('select public.send_challenge(%L, %L, %L, null, %L, %L)', :'club_a', :'club_b', 't20',
                             t.day(3), 'Venue'), '%not allowed%', 'B3 a member (not the owner) cannot send for the club');
select t.as_user(:'b');
select t.expect_error(format('select public.send_challenge(%L, %L, %L, null, %L, %L)', :'club_a', :'club_c', 't20',
                             t.day(3), 'Venue'), '%not allowed%', 'B4 another club''s owner cannot send for club A');
select t.as_user(:'a');
select t.expect_error(format('select public.send_challenge(%L, %L, %L, null, %L, %L)', :'club_a', :'club_a', 't20',
                             t.day(3), 'Venue'), '%own club%', 'B5 self-challenge: own club');
select t.expect_error(format('select public.send_challenge(%L, %L, %L, null, %L, %L)', :'club_a', gen_random_uuid(), 't20',
                             t.day(3), 'Venue'), '%club not found%', 'B6 unknown opponent: club not found');
select t.expect_error(format('select public.send_challenge(%L, %L, %L, null, %L, %L)', gen_random_uuid(), :'club_b', 't20',
                             t.day(3), 'Venue'), '%club not found%', 'B6b unknown sending club: club not found');
select t.expect_error(format('select public.send_challenge(%L, %L, %L, null, %L, %L)', :'club_a', :'club_b', 't30',
                             t.day(3), 'Venue'), '%challenge: invalid%', 'B7 unknown format: invalid');
select t.expect_error(format('select public.send_challenge(%L, %L, %L, null, %L, %L)', :'club_a', :'club_b', 'custom',
                             t.day(3), 'Venue'), '%challenge: invalid%', 'B8 custom without overs: invalid');
select t.expect_error(format('select public.send_challenge(%L, %L, %L, 0, %L, %L)', :'club_a', :'club_b', 'custom',
                             t.day(3), 'Venue'), '%challenge: invalid%', 'B8b custom with 0 overs: invalid');
select t.expect_error(format('select public.send_challenge(%L, %L, %L, 51, %L, %L)', :'club_a', :'club_b', 'custom',
                             t.day(3), 'Venue'), '%challenge: invalid%', 'B8c custom with 51 overs: invalid');
select t.expect_error(format('select public.send_challenge(%L, %L, %L, null, %L, %L)', :'club_a', :'club_b', 't20',
                             t.day(0), 'Venue'), '%invalid date%', 'B9 today (Asia/Karachi): invalid date');
select t.expect_error(format('select public.send_challenge(%L, %L, %L, null, %L, %L)', :'club_a', :'club_b', 't20',
                             t.day(-1), 'Venue'), '%invalid date%', 'B9b yesterday: invalid date');
select t.expect_error(format('select public.send_challenge(%L, %L, %L, null, null, %L)', :'club_a', :'club_b', 't20',
                             'Venue'), '%invalid date%', 'B9c no date: invalid date');
select t.expect_error(format('select public.send_challenge(%L, %L, %L, null, %L, %L)', :'club_a', :'club_b', 't20',
                             t.day(366), 'Venue'), '%invalid date%', 'B9d more than a year ahead: invalid date');
select t.expect_error(format('select public.send_challenge(%L, %L, %L, null, %L, %L)', :'club_a', :'club_b', 't20',
                             t.day(3), '   '), '%invalid venue%', 'B10 blank venue: invalid venue');
select t.expect_error(format('select public.send_challenge(%L, %L, %L, null, %L, %L)', :'club_a', :'club_b', 't20',
                             t.day(3), repeat('v', 101)), '%invalid venue%', 'B10b venue of 101 characters: invalid venue');
select t.expect_error(format('select public.send_challenge(%L, %L, %L, null, %L, %L, %L)', :'club_a', :'club_b', 't20',
                             t.day(3), 'Venue', repeat('m', 281)), '%invalid message%', 'B11 message of 281 characters: invalid message');
select t.ok(not exists (select 1 from public.match_challenges), 'B11b nothing was stored by the refused attempts');

select (public.send_challenge(:'club_a', :'club_b', ' T20 ', null, t.day(2), '  Gaddafi   Stadium ',
                              repeat('m', 280))).id as ch_ab \gset
reset role;
select t.ok((select status = 'pending' and format = 't20' and custom_overs is null and venue_name = 'Gaddafi Stadium'
                    and char_length(message) = 280 and proposed_date = t.day(2) and decided_at is null and match_id is null
               from public.match_challenges where id = :'ch_ab'),
            'B12 challenge sent: pending, format and venue normalised, 280-character message kept');
select t.ok((select expires_at = (t.day(2)::timestamp at time zone 'Asia/Karachi') from public.match_challenges where id = :'ch_ab'),
            'B13 expiry capped at the start of the proposed date (sooner than 7 days)');
set role authenticated;
select t.as_user(:'a');
select (public.send_challenge(:'club_a', :'club_c', 'custom', 15, t.day(20), 'Bagh-e-Jinnah', '   ')).id as ch_ac \gset
select (public.send_challenge(:'club_a', :'club_d', 't10', 12, t.day(30), 'F-9 Park')).id as ch_ad \gset
reset role;
select t.ok((select custom_overs = 15 and message is null
                    and abs(extract(epoch from expires_at - (created_at + interval '7 days'))) < 1
               from public.match_challenges where id = :'ch_ac'),
            'B14 custom 15 overs kept; blank message stored as NULL; expiry 7 days when the date is later');
select t.ok((select custom_overs is null from public.match_challenges where id = :'ch_ad'), 'B15 overs ignored for a non-custom format');
set role authenticated;
select t.expect_error(format('select public.send_challenge(%L, %L, %L, null, %L, %L)', :'club_a', :'club_b', 'odi',
                             t.day(5), 'Venue'), '%already pending%', 'B16 a second pending challenge to the same club: already pending');
select t.as_user(:'b');
select t.expect_error(format('select public.send_challenge(%L, %L, %L, null, %L, %L)', :'club_b', :'club_a', 'odi',
                             t.day(5), 'Venue'), '%already pending%', 'B17 the reverse direction: already pending');
-- Pending cap: club D sends 20, the 21st is refused.
select t.as_user(:'d');
select public.send_challenge(:'club_d', c.club_id, 't20', null, t.day(10), 'F-9 Park')
  from public.match_club_directory('eagles') c;
select t.ok((select count(*) from public.club_challenges(:'club_d') where direction = 'sent' and status = 'pending') = 20,
            'B18 20 pending sent challenges allowed');
select t.expect_error(format('select public.send_challenge(%L, %L, %L, null, %L, %L)', :'club_d', :'club_b', 't20',
                             t.day(10), 'Venue'), '%too many pending%', 'B19 the 21st pending sent challenge: too many pending');
reset role;
-- One of D's challenges runs out (time moved back, guard off for the fixture).
set session_replication_role = replica;
update public.match_challenges set created_at = now() - interval '8 days', expires_at = now() - interval '1 day'
 where id = (select id from public.match_challenges where from_club_id = :'club_d' and to_club_id <> :'club_a'
              order by created_at, id limit 1)
returning id as ch_d_stale \gset
set session_replication_role = origin;
set role authenticated;
select t.as_user(:'d');
select t.ok((select status from public.club_challenges(:'club_d') where challenge_id = :'ch_d_stale') = 'expired',
            'B20 a pending challenge past its expiry reads as expired');
select (public.send_challenge(:'club_d', :'club_b', 't20', null, t.day(10), 'F-9 Park')).id as ch_db \gset
reset role;
select t.ok((select status from public.match_challenges where id = :'ch_d_stale') = 'expired',
            'B21 an expired challenge frees a place under the cap (marked expired when D sends again)');

-- ---------------------------------------------------------------------------
-- C. Challenge visibility (RLS) and no direct writes
-- ---------------------------------------------------------------------------
set role authenticated;
select t.as_user(:'a');
select t.ok((select count(*) from public.match_challenges) = 3, 'C1 owner A reads their 3 challenges');
select t.as_user(:'b');
select t.ok((select count(*) from public.match_challenges) = 2
            and exists (select 1 from public.match_challenges where id = :'ch_ab')
            and not exists (select 1 from public.match_challenges where id = :'ch_ac'),
            'C2 owner B reads only challenges involving club B');
select t.as_user(:'m');
select t.ok((select count(*) from public.match_challenges) = 0, 'C3 a member (not owner) reads no challenges');
select t.as_user(:'u');
select t.ok((select count(*) from public.match_challenges) = 0, 'C4 an outsider reads no challenges');
select t.as_user(:'a');
select t.expect_error(format('insert into public.match_challenges (from_club_id, to_club_id, format, proposed_date, venue_name, expires_at)
                              values (%L, %L, %L, %L, %L, now() + interval ''1 day'')', :'club_a', :'club_c', 't20', t.day(4), 'X'),
                      '%permission denied%', 'C5 direct INSERT into match_challenges: denied');
select t.expect_error(format('update public.match_challenges set status = %L where id = %L', 'accepted', :'ch_ab'),
                      '%permission denied%', 'C6 direct UPDATE of match_challenges: denied');
select t.expect_error(format('delete from public.match_challenges where id = %L', :'ch_ab'),
                      '%permission denied%', 'C7 direct DELETE from match_challenges: denied');
select t.ok((select count(*) from public.club_challenges(:'club_a')) = 3
            and (select direction from public.club_challenges(:'club_a') where challenge_id = :'ch_ab') = 'sent'
            and (select opponent_name from public.club_challenges(:'club_a') where challenge_id = :'ch_ab') = 'Karachi Kings Match',
            'C8 club_challenges: A''s sent challenges with the opponent''s name');
select t.as_user(:'b');
select t.ok((select direction from public.club_challenges(:'club_b') where challenge_id = :'ch_ab') = 'received'
            and (select opponent_short_name from public.club_challenges(:'club_b') where challenge_id = :'ch_ab') = 'LLM',
            'C9 club_challenges: B sees it as received');
select t.expect_error(format('select * from public.club_challenges(%L)', :'club_a'), '%not allowed%',
                      'C10 club_challenges of another club: not allowed');
select t.as_user(:'m');
select t.expect_error(format('select * from public.club_challenges(%L)', :'club_a'), '%not allowed%',
                      'C11 club_challenges for a member (not owner): not allowed');
reset role;
set role anon;
select t.expect_error('select count(*) from public.match_challenges', '%permission denied%', 'C12 anon cannot read match_challenges');
select t.expect_error(format('select * from public.club_challenges(%L)', :'club_a'), '%permission denied%',
                      'C13 anon cannot call club_challenges');
reset role;

-- ---------------------------------------------------------------------------
-- D. respond_to_challenge
-- ---------------------------------------------------------------------------
set role anon;
select t.expect_error(format('select public.respond_to_challenge(%L, true)', :'ch_ab'), '%permission denied%',
                      'D1 anon cannot respond');
reset role;
set role authenticated;
select t.no_session();
select t.expect_error(format('select public.respond_to_challenge(%L, true)', :'ch_ab'), '%not authenticated%',
                      'D2 no session: not authenticated');
select t.as_user(:'a');
select t.expect_error(format('select public.respond_to_challenge(%L, true)', :'ch_ab'), '%not allowed%',
                      'D3 the sender cannot accept their own challenge');
select t.as_user(:'c');
select t.expect_error(format('select public.respond_to_challenge(%L, true)', :'ch_ab'), '%not allowed%',
                      'D4 another club''s owner cannot accept');
select t.as_user(:'m');
select t.expect_error(format('select public.respond_to_challenge(%L, true)', :'ch_ab'), '%not allowed%',
                      'D5 a member (not the owner) cannot accept');
select t.as_user(:'b');
select t.expect_error(format('select public.respond_to_challenge(%L, null)', :'ch_ab'), '%challenge: invalid%',
                      'D6 no answer: invalid');
select t.expect_error(format('select public.respond_to_challenge(%L, true)', gen_random_uuid()), '%not found%',
                      'D7 unknown challenge: not found');
select t.as_user(:'c');
select (public.respond_to_challenge(:'ch_ac', false)).status as declined_status \gset
reset role;
select t.ok(:'declined_status' = 'declined'
            and (select decided_by = :'c' and decided_at is not null and match_id is null
                   from public.match_challenges where id = :'ch_ac')
            and not exists (select 1 from public.matches where challenge_id = :'ch_ac'),
            'D8 decline: declined, decided by C, no match');
set role authenticated;
select t.as_user(:'c');
select t.expect_error(format('select public.respond_to_challenge(%L, true)', :'ch_ac'), '%not pending%',
                      'D9 answering a declined challenge: not pending');
select t.as_user(:'b');
select (public.respond_to_challenge(:'ch_ab', true)).match_id as match_ab \gset
reset role;
select t.ok((select status = 'accepted' and match_id = :'match_ab' and decided_by = :'b'
               from public.match_challenges where id = :'ch_ab'),
            'D10 accept: accepted, linked to its match');
select t.ok((select count(*) from public.matches where challenge_id = :'ch_ab') = 1
            and (select club_a_id = :'club_a' and club_b_id = :'club_b' and status = 'pending' and format = 't20'
                        and starts_at is null and proposed_by_club_id = :'club_a' and proposal_version = 1
                        and proposed_venue_name = 'Gaddafi Stadium' and proposed_city is null
                        and proposed_starts_at = ((t.day(2) + time '10:00') at time zone 'Asia/Karachi')
                   from public.matches where id = :'match_ab'),
            'D11 exactly one pending match: A (challenger) vs B; the challenge''s date (10:00 PKT) and venue are A''s proposal v1');
set role authenticated;
select t.as_user(:'b');
select t.expect_error(format('select public.respond_to_challenge(%L, true)', :'ch_ab'), '%not pending%',
                      'D12 accepting twice: not pending');
reset role;
select t.ok((select count(*) from public.matches where challenge_id = :'ch_ab') = 1, 'D13 still exactly one match');
-- A→D runs out before D answers.
set session_replication_role = replica;
update public.match_challenges set created_at = now() - interval '8 days', expires_at = now() - interval '1 day'
 where id = :'ch_ad';
set session_replication_role = origin;
set role authenticated;
select t.as_user(:'d');
select (public.respond_to_challenge(:'ch_ad', true)).status as expired_status \gset
reset role;
select t.ok(:'expired_status' = 'expired'
            and (select status = 'expired' and match_id is null and decided_by is null from public.match_challenges where id = :'ch_ad')
            and not exists (select 1 from public.matches where challenge_id = :'ch_ad'),
            'D14 accepting an expired challenge: returns expired, no match');
set role authenticated;
select t.as_user(:'d');
select t.expect_error(format('select public.respond_to_challenge(%L, true)', :'ch_ad'), '%not pending%',
                      'D15 answering it again: not pending');
reset role;

-- ---------------------------------------------------------------------------
-- E. Schedule: propose and respond
-- ---------------------------------------------------------------------------
set role authenticated;
select t.as_user(:'a');
select t.expect_error(format('select public.respond_to_match_schedule(%L, 1, true)', :'match_ab'), '%not allowed%',
                      'E1 the proposer cannot accept their own proposal');
select t.as_user(:'c');
select t.expect_error(format('select public.respond_to_match_schedule(%L, 1, true)', :'match_ab'), '%not allowed%',
                      'E2 another club''s owner cannot respond');
select t.expect_error(format('select public.propose_match_schedule(%L, %L, %L)', :'match_ab', now() + interval '3 days', 'X'),
                      '%not allowed%', 'E3 another club''s owner cannot propose');
select t.as_user(:'m');
select t.expect_error(format('select public.respond_to_match_schedule(%L, 1, true)', :'match_ab'), '%not allowed%',
                      'E4 a member (not the owner) cannot respond');
select t.expect_error(format('select public.propose_match_schedule(%L, %L, %L)', :'match_ab', now() + interval '3 days', 'X'),
                      '%not allowed%', 'E5 a member (not the owner) cannot propose');
select t.as_user(:'b');
select t.expect_error(format('select public.respond_to_match_schedule(%L, 0, true)', :'match_ab'), '%proposal changed%',
                      'E6 a stale proposal version: proposal changed');
select t.expect_error(format('select public.respond_to_match_schedule(%L, 1, null)', :'match_ab'), '%match: invalid%',
                      'E7 no answer: invalid');
select t.expect_error(format('select public.propose_match_schedule(%L, %L, %L)', :'match_ab', now() - interval '1 minute', 'X'),
                      '%invalid time%', 'E8 a past time: invalid time');
select t.expect_error(format('select public.propose_match_schedule(%L, null, %L)', :'match_ab', 'X'),
                      '%invalid time%', 'E8b no time: invalid time');
select t.expect_error(format('select public.propose_match_schedule(%L, %L, %L)', :'match_ab', now() + interval '366 days', 'X'),
                      '%invalid time%', 'E8c more than a year ahead: invalid time');
select t.expect_error(format('select public.propose_match_schedule(%L, %L, %L)', :'match_ab', now() + interval '3 days', ' '),
                      '%invalid venue%', 'E9 blank venue: invalid venue');
select t.expect_error(format('select public.propose_match_schedule(%L, %L, %L, %L)', :'match_ab', now() + interval '3 days', 'X',
                             repeat('c', 61)), '%invalid city%', 'E10 city of 61 characters: invalid city');
select t.expect_error(format('select public.propose_match_schedule(%L, %L, %L)', gen_random_uuid(), now() + interval '3 days', 'X'),
                      '%not found%', 'E11 unknown match: not found');
-- B counter-proposes (replaces A's proposal).
select date_trunc('minute', now()) + interval '3 days' as t3 \gset
select (public.propose_match_schedule(:'match_ab', (:'t3')::timestamptz, ' National  Stadium ',
                                      ' Karachi ')).proposal_version as v_b \gset
reset role;
select t.ok(:v_b = 2 and (select proposed_by_club_id = :'club_b' and proposed_venue_name = 'National Stadium'
                                 and proposed_city = 'Karachi' and status = 'pending'
                            from public.matches where id = :'match_ab'),
            'E12 B''s counter-proposal replaces A''s: version 2, by B, venue and city normalised');
set role authenticated;
select t.as_user(:'b');
select t.expect_error(format('select public.respond_to_match_schedule(%L, 2, true)', :'match_ab'), '%not allowed%',
                      'E13 B cannot accept B''s own proposal');
select t.as_user(:'a');
select t.expect_error(format('select public.respond_to_match_schedule(%L, 1, true)', :'match_ab'), '%proposal changed%',
                      'E14 A answering the replaced proposal v1: proposal changed');
select public.respond_to_match_schedule(:'match_ab', 2, false);
reset role;
select t.ok((select status = 'pending' and proposed_starts_at is null and proposed_venue_name is null
                    and proposed_city is null and proposed_by_club_id is null and proposal_version = 2 and starts_at is null
               from public.matches where id = :'match_ab'),
            'E15 decline: the proposal is cleared, the match stays pending');
set role authenticated;
select t.as_user(:'a');
select t.expect_error(format('select public.respond_to_match_schedule(%L, 2, true)', :'match_ab'), '%no proposal%',
                      'E16 responding with no open proposal: no proposal');
select (public.propose_match_schedule(:'match_ab', (:'t3')::timestamptz, 'Gaddafi Stadium',
                                      'Lahore')).proposal_version as v_a \gset
select t.as_user(:'b');
select (public.respond_to_match_schedule(:'match_ab', :v_a, true)).status as confirmed_status \gset
reset role;
select t.ok(:'confirmed_status' = 'confirmed'
            and (select starts_at = (:'t3')::timestamptz and venue_name = 'Gaddafi Stadium'
                        and city = 'Lahore' and proposed_starts_at is null and proposal_version = 3
                   from public.matches where id = :'match_ab'),
            'E17 B accepts A''s proposal v3: confirmed at that time and venue, proposal cleared');
select starts_at as ab_start from public.matches where id = :'match_ab' \gset
set role authenticated;
select t.as_user(:'a');
select t.ok((select count(*) from public.club_matches(:'club_a')) = 1
            and (select challenged_by_me and opponent_club_id = :'club_b' and opponent_name = 'Karachi Kings Match'
                        and status = 'confirmed' and proposed_by_me is null
                   from public.club_matches(:'club_a')),
            'E18 club_matches(A): one row, A challenged, opponent B, confirmed');
select t.as_user(:'b');
select t.ok((select not challenged_by_me and opponent_club_id = :'club_a' from public.club_matches(:'club_b')),
            'E19 club_matches(B): the same match seen from B');
select t.expect_error(format('select * from public.club_matches(%L)', :'club_a'), '%not allowed%',
                      'E20 club_matches of another club: not allowed');
-- Clash: C challenges A; A accepts; C proposes a time overlapping A–B (T20 = 4 h).
select t.as_user(:'c');
select (public.send_challenge(:'club_c', :'club_a', 't20', null, t.day(4), 'Minto Park')).id as ch_ca \gset
select t.as_user(:'a');
select (public.respond_to_challenge(:'ch_ca', true)).match_id as match_ca \gset
select t.as_user(:'c');
select (public.propose_match_schedule(:'match_ca', (:'ab_start')::timestamptz + interval '3 hours 59 minutes', 'Minto Park'))
         .proposal_version as v_ca \gset
select t.as_user(:'a');
select t.expect_error(format('select public.respond_to_match_schedule(%L, %s, true)', :'match_ca', :v_ca), '%schedule clash%',
                      'E21 confirming a time that overlaps another confirmed match of A: schedule clash');
reset role;
select t.ok((select status = 'pending' and proposed_starts_at is not null from public.matches where id = :'match_ca'),
            'E22 after the clash nothing changed (still pending, proposal kept)');
set role authenticated;
select t.as_user(:'c');
select (public.propose_match_schedule(:'match_ca', (:'ab_start')::timestamptz - interval '4 hours', 'Minto Park'))
         .proposal_version as v_ca2 \gset
select t.as_user(:'a');
select t.ok((public.respond_to_match_schedule(:'match_ca', :v_ca2, true)).status = 'confirmed',
            'E23 a time ending exactly when A–B starts: confirmed (no clash)');
-- Reschedule a confirmed match: it stays confirmed at the old time until accepted.
select (public.propose_match_schedule(:'match_ab', (:'ab_start')::timestamptz + interval '1 day', 'Gaddafi Stadium'))
         .proposal_version as v_res \gset
reset role;
select t.ok((select status = 'confirmed' and starts_at = (:'ab_start')::timestamptz and proposed_by_club_id = :'club_a'
               from public.matches where id = :'match_ab'),
            'E24 a reschedule proposal keeps the confirmed match at its agreed time');
set role authenticated;
select t.as_user(:'b');
select public.respond_to_match_schedule(:'match_ab', :v_res, false);
reset role;
select t.ok((select status = 'confirmed' and starts_at = (:'ab_start')::timestamptz and proposed_starts_at is null
               from public.matches where id = :'match_ab'),
            'E25 declining the reschedule keeps the agreed time');
-- A proposal whose time has passed can't be accepted.
set role authenticated;
select t.as_user(:'b');
select (public.send_challenge(:'club_b', :'club_c', 'odi', null, t.day(6), 'Arbab Niaz')).id as ch_bc \gset
select t.as_user(:'c');
select (public.respond_to_challenge(:'ch_bc', true)).match_id as match_bc \gset
reset role;
set session_replication_role = replica;
update public.matches set proposed_starts_at = now() - interval '1 hour' where id = :'match_bc';
set session_replication_role = origin;
set role authenticated;
select t.as_user(:'c');
select t.expect_error(format('select public.respond_to_match_schedule(%L, 1, true)', :'match_bc'), '%invalid time%',
                      'E26 accepting a proposal whose time has passed: invalid time');
reset role;

-- ---------------------------------------------------------------------------
-- F. Cancel
-- ---------------------------------------------------------------------------
set role anon;
select t.expect_error(format('select public.cancel_match(%L, %L)', :'match_ab', 'Rain'), '%permission denied%',
                      'F1 anon cannot cancel');
reset role;
set role authenticated;
select t.as_user(:'d');
select t.expect_error(format('select public.cancel_match(%L, %L)', :'match_ab', 'Rain'), '%not allowed%',
                      'F2 another club''s owner cannot cancel');
select t.as_user(:'m');
select t.expect_error(format('select public.cancel_match(%L, %L)', :'match_ab', 'Rain'), '%not allowed%',
                      'F3 a member (not the owner) cannot cancel');
select t.as_user(:'b');
select t.expect_error(format('select public.cancel_match(%L, %L)', :'match_ab', '  '), '%invalid reason%',
                      'F4 blank reason: invalid reason');
select t.expect_error(format('select public.cancel_match(%L, %L)', :'match_ab', repeat('r', 201)), '%invalid reason%',
                      'F5 reason of 201 characters: invalid reason');
select (public.cancel_match(:'match_ab', ' Ground   unavailable ')).status as cancelled_status \gset
reset role;
select t.ok(:'cancelled_status' = 'cancelled'
            and (select cancelled_by_club_id = :'club_b' and cancel_reason = 'Ground unavailable' and cancelled_at is not null
                        and starts_at = (:'ab_start')::timestamptz
                   from public.matches where id = :'match_ab'),
            'F6 B cancels the confirmed match: cancelled by B, reason and time recorded');
set role authenticated;
select t.as_user(:'a');
select t.expect_error(format('select public.cancel_match(%L, %L)', :'match_ab', 'Again'), '%not open%',
                      'F7 cancelling twice: not open');
select t.expect_error(format('select public.propose_match_schedule(%L, %L, %L)', :'match_ab', now() + interval '5 days', 'X'),
                      '%not open%', 'F8 proposing on a cancelled match: not open');
select t.expect_error(format('select public.respond_to_match_schedule(%L, 3, true)', :'match_ab'), '%not open%',
                      'F9 responding on a cancelled match: not open');
select t.ok((select cancelled_by_me is false and status = 'cancelled' from public.club_matches(:'club_a') where match_id = :'match_ab'),
            'F10 club_matches(A): cancelled, not by A');
reset role;
-- A confirmed match that has started can't be cancelled or rescheduled.
set session_replication_role = replica;
update public.matches set starts_at = now() - interval '1 hour' where id = :'match_ca';
set session_replication_role = origin;
set role authenticated;
select t.as_user(:'c');
select t.expect_error(format('select public.cancel_match(%L, %L)', :'match_ca', 'Late'), '%already started%',
                      'F11 cancelling a started match: already started');
select t.expect_error(format('select public.propose_match_schedule(%L, %L, %L)', :'match_ca', now() + interval '5 days', 'X'),
                      '%already started%', 'F12 rescheduling a started match: already started');
-- A pending match can be cancelled at any time.
select t.ok((public.cancel_match(:'match_bc', 'Not enough players')).status = 'cancelled', 'F13 a pending match can be cancelled');
reset role;

-- ---------------------------------------------------------------------------
-- G. Status transitions and constraints (enforced even for the database owner)
-- ---------------------------------------------------------------------------
select t.expect_error(format('update public.matches set status = %L where id = %L', 'pending', :'match_ca'),
                      '%invalid transition%', 'G1 confirmed → pending: invalid transition');
select t.expect_error(format('update public.matches set status = %L, cancelled_at = null, cancelled_by_club_id = null, cancel_reason = null where id = %L',
                             'confirmed', :'match_ab'), '%not open%', 'G2 cancelled → confirmed: not open');
select t.expect_error(format('update public.matches set club_a_id = %L where id = %L', :'club_d', :'match_ca'),
                      '%invalid transition%', 'G3 a match''s clubs never change');
select t.expect_error(format('update public.matches set format = %L where id = %L', 'odi', :'match_ca'),
                      '%invalid transition%', 'G4 a match''s format never changes');
select t.expect_error(format('update public.match_challenges set status = %L, decided_at = null where id = %L', 'pending', :'ch_ac'),
                      '%not pending%', 'G5 declined → pending: refused');
select t.expect_error(format('update public.match_challenges set venue_name = %L where id = %L', 'Elsewhere', :'ch_db'),
                      '%invalid transition%', 'G6 a pending challenge''s terms never change');
select t.expect_error(format('update public.match_challenges set status = %L where id = %L', 'pending', :'ch_db'),
                      '%invalid transition%', 'G7 pending → pending: refused');
select t.expect_error(format('insert into public.matches (club_a_id, club_b_id, format, status) values (%L, %L, %L, %L)',
                             :'club_a', :'club_d', 't20', 'confirmed'), '23514', 'G8 confirmed without a time: refused (check)');
select t.expect_error(format('insert into public.matches (club_a_id, club_b_id, format, proposed_starts_at) values (%L, %L, %L, now())',
                             :'club_a', :'club_d', 't20'), '23514', 'G9 an incomplete proposal: refused (check)');
select t.expect_error(format('insert into public.matches (club_a_id, club_b_id, format, proposed_starts_at, proposed_venue_name, proposed_by_club_id)
                              values (%L, %L, %L, now(), %L, %L)', :'club_a', :'club_d', 't20', 'X', :'club_c'),
                      '23514', 'G10 a proposal by a club that is not playing: refused (check)');
select t.expect_error(format('insert into public.matches (club_a_id, club_b_id, format) values (%L, %L, %L)',
                             :'club_a', :'club_a', 't20'), '23514', 'G11 a club against itself: refused (check)');
select t.expect_error(format('insert into public.match_challenges (from_club_id, to_club_id, format, proposed_date, venue_name, expires_at)
                              values (%L, %L, %L, %L, %L, now() + interval ''1 day'')', :'club_a', :'club_a', 't20', t.day(3), 'X'),
                      '23514', 'G12 a self-challenge: refused (check)');
select t.expect_error(format('insert into public.match_challenges (from_club_id, to_club_id, format, proposed_date, venue_name, expires_at)
                              values (%L, %L, %L, %L, %L, now() + interval ''1 day'')', :'club_b', :'club_d', 't20', t.day(3), 'X'),
                      '23505', 'G13 a second pending challenge for a pair (direct insert): refused (unique index)');
select t.expect_error(format('insert into public.matches (challenge_id, club_a_id, club_b_id, format) values (%L, %L, %L, %L)',
                             :'ch_ab', :'club_a', :'club_b', 't20'), '23505', 'G14 a second match for one challenge: refused (unique)');

-- ---------------------------------------------------------------------------
-- H. Match visibility (RLS) and no direct writes
-- ---------------------------------------------------------------------------
set role authenticated;
select t.as_user(:'a');
select t.ok((select count(*) from public.matches) = 2, 'H1 owner A reads A''s 2 matches');
select t.as_user(:'m');
select t.ok((select count(*) from public.matches) = 2
            and (select count(*) from public.matches where :'club_a' in (club_a_id, club_b_id)) = 2,
            'H2 an active member of A reads A''s matches');
select t.expect_error(format('select * from public.club_matches(%L)', :'club_a'), '%not allowed%',
                      'H3 club_matches for a member (not owner): not allowed');
select t.ok(public.is_active_club_member(:'club_a') and not public.is_active_club_member(:'club_b'),
            'H4 is_active_club_member: true for own club only');
select t.as_user(:'r');
select t.ok((select count(*) from public.matches) = 0 and not public.is_active_club_member(:'club_a'),
            'H5 a removed member reads no matches');
select t.as_user(:'d');
select t.ok((select count(*) from public.matches) = 0, 'H6 another club''s owner reads none of these matches');
select t.as_user(:'u');
select t.ok((select count(*) from public.matches) = 0, 'H7 an outsider reads no matches');
select t.as_user(:'a');
select t.expect_error(format('insert into public.matches (club_a_id, club_b_id, format) values (%L, %L, %L)', :'club_a', :'club_d', 't20'),
                      '%permission denied%', 'H8 direct INSERT into matches: denied');
select t.expect_error(format('update public.matches set status = %L where id = %L', 'cancelled', :'match_ca'),
                      '%permission denied%', 'H9 direct UPDATE of matches: denied');
select t.expect_error(format('delete from public.matches where id = %L', :'match_ca'),
                      '%permission denied%', 'H10 direct DELETE from matches: denied');
select t.no_session();
select t.ok((select count(*) from public.matches) = 0 and (select count(*) from public.match_challenges) = 0,
            'H11 authenticated role without a session reads nothing');
reset role;
set role anon;
select t.expect_error('select count(*) from public.matches', '%permission denied%', 'H12 anon cannot read matches');
select t.expect_error(format('select * from public.club_matches(%L)', :'club_a'), '%permission denied%', 'H13 anon cannot call club_matches');
select t.expect_error(format('select public.propose_match_schedule(%L, now(), %L)', :'match_ca', 'X'), '%permission denied%',
                      'H14 anon cannot propose');
select t.expect_error(format('select public.respond_to_match_schedule(%L, 1, true)', :'match_ca'), '%permission denied%',
                      'H15 anon cannot respond to a schedule');
reset role;

-- ---------------------------------------------------------------------------
-- I. Internal helpers
-- ---------------------------------------------------------------------------
set role authenticated;
select t.as_user(:'a');
select t.expect_error(format('select public.match_lock_clubs(%L, %L)', :'club_a', :'club_b'), '%permission denied%',
                      'I1 match_lock_clubs is not callable by app roles');
select t.expect_error('select public.match_duration(''t20'', null)', '%permission denied%',
                      'I2 match_duration is not callable by app roles');
reset role;
select t.ok(public.match_duration('t10', null) = interval '3 hours' and public.match_duration('t20', null) = interval '4 hours'
            and public.match_duration('odi', null) = interval '8 hours' and public.match_duration('test', null) = interval '5 days'
            and public.match_duration('custom', 20) = interval '160 minutes' and public.match_duration('custom', 5) = interval '1 hour',
            'I3 durations: T10 3 h, T20 4 h, ODI 8 h, Test 5 days, custom overs × 8 min (at least 1 h)');

-- ---------------------------------------------------------------------------
-- J. Existing data untouched; deleting a club removes only its own match data
-- ---------------------------------------------------------------------------
select t.ok((select count(*) from public.clubs where owner_id::text not like 'e7000000%') = :other_clubs_before
            and (select count(*) from public.club_members) = :members_before
            and (select count(*) from public.teams) = :teams_before,
            'J1 clubs, memberships and teams unchanged by the match functions');
delete from public.clubs where id = :'club_c';
select t.ok(not exists (select 1 from public.matches where :'club_c' in (club_a_id, club_b_id))
            and not exists (select 1 from public.match_challenges where :'club_c' in (from_club_id, to_club_id))
            and exists (select 1 from public.matches where id = :'match_ab')
            and exists (select 1 from public.match_challenges where id = :'ch_ab' and match_id = :'match_ab'),
            'J2 deleting club C removes C''s challenges and matches only');

-- Clean up (this database only).
delete from public.clubs where owner_id::text like 'e7000000%';
delete from auth.users where id::text like 'e7000000%';
select t.ok(not exists (select 1 from public.profiles where id::text like 'e7000000%')
            and not exists (select 1 from public.matches) and not exists (select 1 from public.match_challenges),
            'Z cleanup done');
