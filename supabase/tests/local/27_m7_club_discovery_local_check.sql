-- CricEco · LOCAL TEST ONLY — migration 32 (M7 club discovery: public club
-- profiles and directory, availability slots, player rankings, applicant
-- statistics) on a DISPOSABLE database after migrations 1–31 (+ the D1
-- location seed and, for 31, the Storage stand-in of
-- 26_m5_m6_media_local_check.sh) and migration 32: the "postgres" database
-- of a throwaway container of the real Supabase image (legacy fixture copy
-- without its auth guard).
-- Synthetic data only (people ee920000-…, matches ee9200aa-…); everything
-- runs in ONE transaction that is ROLLED BACK at the end. Results and
-- scorecards are seeded directly with session_replication_role = replica
-- (their guards and audit triggers are not what is tested here).
-- Run with psql:  psql -X -v ON_ERROR_STOP=1 -f 27_m7_club_discovery_local_check.sql
-- Every check prints "PASS: …"; the first failure stops the run ("FAIL: …").
-- Refuses to run where any auth user has a password (a real project).
\set ON_ERROR_STOP on

begin;

do $$
declare
  v_pw boolean := false;
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password') then
    execute 'select exists (select 1 from auth.users where coalesce(encrypted_password, '''') <> '''')' into v_pw;
  end if;
  if v_pw or exists (select 1 from auth.users where email is null or email not like '%@local.test') then
    raise exception 'LOCAL ONLY: this database has real users — refusing';
  end if;
  if to_regprocedure('public.player_rankings(text, uuid, text, integer)') is null then
    raise exception 'apply migration 32 first';
  end if;
end $$;

create schema t27;
grant usage on schema t27 to anon, authenticated, service_role;

create function t27.ok(p_cond boolean, p_name text) returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_name; end if;
  raise notice 'PASS: %', p_name;
end $$;

-- PASS when p_sql fails with exactly SQLSTATE p_state and a message LIKE p_like.
create function t27.err(p_sql text, p_state text, p_like text, p_name text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlstate = p_state and sqlerrm like p_like then
      raise notice 'PASS: % [% %]', p_name, sqlstate, sqlerrm;
      return;
    end if;
    raise exception 'FAIL: % — unexpected error [% %]', p_name, sqlstate, sqlerrm;
  end;
  raise exception 'FAIL: % — no error', p_name;
end $$;

create function t27.okq(p_sql text, p_name text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    raise exception 'FAIL: % — error [% %]', p_name, sqlstate, sqlerrm;
  end;
  raise notice 'PASS: %', p_name;
end $$;

create function t27.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true),
         set_config('request.jwt.claim.sub', p_uid::text, true);
$$;
create function t27.as_nobody() returns void language sql as $$
  select set_config('request.jwt.claims', '', true), set_config('request.jwt.claim.sub', '', true);
$$;
create function t27.p(p_n int) returns uuid language sql immutable as $$
  select ('ee920000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
$$;
create function t27.m(p_n int) returns uuid language sql immutable as $$
  select ('ee9200aa-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
$$;
-- Asia/Karachi today + n.
create function t27.d(p_n int) returns date language sql stable as $$
  select (now() at time zone 'Asia/Karachi')::date + p_n;
$$;
create function t27.club(p_name text) returns uuid language sql stable security definer set search_path = '' as $$
  select c.id from public.clubs c where c.name = p_name;
$$;
create function t27.mem(p_user int, p_club text) returns uuid language sql stable security definer set search_path = '' as $$
  select m.id from public.club_members m join public.clubs c on c.id = m.club_id
   where m.user_id = ('ee920000-0000-4000-8000-' || lpad(p_user::text, 12, '0'))::uuid and c.name = p_club;
$$;
create function t27.open_count(p_club uuid) returns int language sql stable security definer set search_path = '' as $$
  select count(*)::int from public.club_match_slots s where s.club_id = p_club and s.status = 'open';
$$;
create function t27.slot(p_id uuid) returns public.club_match_slots language sql stable security definer set search_path = '' as $$
  select * from public.club_match_slots s where s.id = p_id;
$$;
-- A post as the current role; returns the new slot id.
create function t27.post(p_club uuid, p_days int, p_start text, p_end text, p_format text default 't20',
                         p_overs int default null, p_city text default 'Lahore', p_notes text default null)
returns uuid language sql as $$
  select s.slot_id from public.post_match_slot(p_club, p_format, p_overs, p_city, t27.d(p_days), p_start::time,
                                               p_end::time, null, null, p_notes) s;
$$;
-- SQL text of a post (for t27.err).
create function t27.post_sql(p_club uuid, p_format text, p_overs int, p_city text, p_date date, p_start text, p_end text,
                             p_ground text default null, p_venue text default null, p_notes text default null)
returns text language sql immutable as $$
  select format('select * from public.post_match_slot(%L, %L, %s, %L, %L, %L, %L, %L, %L, %L)',
                p_club, p_format, coalesce(p_overs::text, 'null'), p_city, p_date, p_start, p_end, p_ground, p_venue, p_notes);
$$;
create function t27.make_person(p_n int, p_role text default null) returns uuid language plpgsql as $$
declare
  v uuid := t27.p(p_n);
begin
  insert into auth.users (id, email) values (v, format('m7p%s@local.test', p_n));
  insert into public.profiles (id) values (v) on conflict (id) do nothing; -- the sign-up trigger made it already
  insert into public.current_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
  insert into public.permanent_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
  update public.profiles
     set full_name = format('M7 Person %s', p_n),
         phone = format('+923%s', lpad((740000000 + p_n)::text, 9, '0')),
         date_of_birth = date '2000-05-01', profile_completed = true
   where id = v;
  if p_role is not null then
    insert into public.player_profiles (user_id, player_role, batting_style, bowling_style)
    values (v, p_role, case when p_role <> 'bowler' then 'right_handed' end,
            case when p_role <> 'batsman' then 'left_arm_orthodox' end);
  end if;
  return v;
end $$;
grant execute on all functions in schema t27 to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
-- People: 1 / 2 / 3 own "M7 Lions" (Lahore) / "M7 Kings" (Karachi) /
-- "M7 Riders" (Lahore). Lions: 4 (batsman), 5 (batsman, show_stats off).
-- Kings: 6 (all-rounder, public_profile off), 7 (bowler), 9 (batsman,
-- REMOVED). Riders: 13 (coach, no player profile), 4 (joined later).
-- No club: 8 (batsman), 10 (bowler, show_stats off), 11, 12 (batsman).
-- Requests to Lions: 9 and 10 pending, 11 rejected.
select count(*) from (select t27.make_person(n, r)
                        from (values (1, null), (2, null), (3, null), (4, 'batsman'), (5, 'batsman'), (6, 'all_rounder'),
                                     (7, 'bowler'), (8, 'batsman'), (9, 'batsman'), (10, 'bowler'), (11, null),
                                     (12, 'batsman'), (13, null)) v(n, r)) s;
update public.profiles set show_stats = false where id in (t27.p(5), t27.p(10));
update public.profiles set public_profile = false where id = t27.p(6);
insert into public.clubs (owner_id, name, short_name, city, club_type, established_year, home_ground_id)
values (t27.p(1), 'M7 Lions', 'LNS', 'Lahore', 'corporate', 1999, 'ground_7'),
       (t27.p(2), 'M7 Kings', null, 'Karachi', 'professional', null, null),
       (t27.p(3), 'M7 Riders', 'RDR', 'Lahore', 'college_university', 2010, null);
update public.clubs set logo_path = id::text || '/aa920000-0000-4000-8000-000000000001.png' where name = 'M7 Lions';
insert into public.club_members (club_id, user_id, member_role, status, joined_at, removed_at)
values (t27.club('M7 Lions'), t27.p(4), 'player', 'active', now() - interval '60 days', null),
       (t27.club('M7 Lions'), t27.p(5), 'player', 'active', now() - interval '50 days', null),
       (t27.club('M7 Kings'), t27.p(6), 'player', 'active', now() - interval '60 days', null),
       (t27.club('M7 Kings'), t27.p(7), 'player', 'active', now() - interval '60 days', null),
       (t27.club('M7 Kings'), t27.p(9), 'player', 'removed', now() - interval '100 days', now() - interval '3 days'),
       (t27.club('M7 Riders'), t27.p(13), 'coach', 'active', now() - interval '60 days', null),
       (t27.club('M7 Riders'), t27.p(4), 'player', 'active', now() - interval '10 days', null);
insert into public.join_requests (club_id, user_id, status, created_at)
values (t27.club('M7 Lions'), t27.p(9), 'pending', now() - interval '1 day'),
       (t27.club('M7 Lions'), t27.p(10), 'pending', now() - interval '1 day');
insert into public.join_requests (club_id, user_id, status, decline_reason, decided_at, decided_by, created_at)
values (t27.club('M7 Lions'), t27.p(11), 'rejected', 'Squad full', now() - interval '2 days', t27.p(1), now() - interval '5 days');

-- Matches and confirmed results (m8: a result still waiting = not counted).
--   m1 Lions v Kings  Lions won      −10 d     m6 Lions v Kings  abandoned −1 d
--   m2 Kings v Lions  Kings won      −8 d      m7 Lions v Kings  Lions won −20 d (ODI)
--   m3 Lions v Kings  tie            −6 d      m8 Lions v Kings  submitted −3 d
--   m4 Lions v Riders Riders won     −4 d      m9 Kings v Riders Riders won −5 d
--   m5 Lions v Kings  no result      −2 d
set session_replication_role = replica;
insert into public.matches (id, club_a_id, club_b_id, format, status, starts_at, venue_name)
select t27.m(k), t27.club(a), t27.club(b), f, 'confirmed', now() - (dd || ' days')::interval, 'M7 Ground'
  from (values (1, 'M7 Lions', 'M7 Kings', 't20', 10), (2, 'M7 Kings', 'M7 Lions', 't20', 8),
               (3, 'M7 Lions', 'M7 Kings', 't20', 6), (4, 'M7 Lions', 'M7 Riders', 't20', 4),
               (5, 'M7 Lions', 'M7 Kings', 't20', 2), (6, 'M7 Lions', 'M7 Kings', 't20', 1),
               (7, 'M7 Lions', 'M7 Kings', 'odi', 20), (8, 'M7 Lions', 'M7 Kings', 't20', 3),
               (9, 'M7 Kings', 'M7 Riders', 't20', 5)) v(k, a, b, f, dd);
-- Results come from an official scorer (migration 24).
insert into public.scorer_clients (id, name, key_id) values ('ee9200cc-0000-4000-8000-000000000001', 'M7 Scorer', 'm7-scorer-key');
insert into public.result_submission_log (client_id, action, match_id, idempotency_key, payload, payload_sha256, outcome)
select 'ee9200cc-0000-4000-8000-000000000001'::uuid, 'ingest', t27.m(k), 'm7-fixture-' || k, '{}'::jsonb, repeat('0', 64), 'accepted'
  from generate_series(1, 9) k;
insert into public.match_results (match_id, version, status, outcome, scorer_client_id, submission_id,
                                  decided_by_client_id, decided_at)
select t27.m(k), 1, case when k = 8 then 'submitted' else 'confirmed' end, o,
       'ee9200cc-0000-4000-8000-000000000001',
       (select l.id from public.result_submission_log l where l.idempotency_key = 'm7-fixture-' || k),
       case when k <> 8 then 'ee9200cc-0000-4000-8000-000000000001'::uuid end,
       case when k <> 8 then now() end
  from (values (1, 'club_a_won'), (2, 'club_a_won'), (3, 'tie'), (4, 'club_b_won'), (5, 'no_result'),
               (6, 'abandoned'), (7, 'club_a_won'), (8, 'club_a_won'), (9, 'club_b_won')) v(k, o);
-- Innings 1: club A bats; innings 2: club B bats.
insert into public.match_innings (match_id, version, innings_no, batting_club_id, bowling_club_id, runs, wickets, balls)
select m.id, 1, i, case when i = 1 then m.club_a_id else m.club_b_id end, case when i = 1 then m.club_b_id else m.club_a_id end,
       150, 5, 120
  from public.matches m cross join (values (1), (2)) v(i)
 where m.id in (select t27.m(k) from generate_series(1, 9) k);
-- Batting (match, innings, position, person, club, runs, balls, dismissal).
insert into public.match_batting (match_id, version, innings_no, position, member_id, player_name, runs, balls, dismissal)
select t27.m(k), 1, inn, pos, t27.mem(n, c), format('M7 Person %s', n), r, b, d
  from (values (1, 1, 1, 4, 'M7 Lions', 50, 40, 'not_out'), (2, 2, 1, 4, 'M7 Lions', 30, 25, 'run_out'),
               (3, 1, 1, 4, 'M7 Lions', 20, 15, 'run_out'), (4, 1, 1, 4, 'M7 Lions', 10, 12, 'run_out'),
               (7, 1, 1, 4, 'M7 Lions', 5, 10, 'run_out'), (8, 1, 1, 4, 'M7 Lions', 100, 60, 'not_out'),
               (1, 1, 2, 5, 'M7 Lions', 12, 10, 'run_out'),
               (1, 2, 1, 9, 'M7 Kings', 40, 30, 'not_out'), (9, 1, 1, 9, 'M7 Kings', 25, 20, 'run_out'),
               (2, 1, 1, 6, 'M7 Kings', 33, 20, 'run_out')) v(k, inn, pos, n, c, r, b, d);
-- Bowling (match, innings, bowler no, person, club, balls, runs, wickets).
insert into public.match_bowling (match_id, version, innings_no, bowler_no, member_id, player_name, balls, runs, wickets)
select t27.m(k), 1, inn, 1, t27.mem(n, c), format('M7 Person %s', n), bl, r, w
  from (values (1, 1, 7, 'M7 Kings', 24, 30, 2), (2, 2, 7, 'M7 Kings', 24, 20, 1),
               (3, 1, 7, 'M7 Kings', 18, 25, 0)) v(k, inn, n, c, bl, r, w);
set session_replication_role = default;

-- ---------------------------------------------------------------------------
-- C. Public club profile and directory
-- ---------------------------------------------------------------------------
set local role authenticated;
select t27.as_user(t27.p(12));
select t27.ok((select row(p.club_id, p.name, p.short_name, p.city, p.club_type, p.established_year, p.home_ground_id,
                          p.logo_path, p.member_count, p.is_own)::text
                 from public.club_public_profile(t27.club('M7 Lions')) p)
              = row(t27.club('M7 Lions'), 'M7 Lions', 'LNS', 'Lahore', 'corporate', 1999, 'ground_7',
                    t27.club('M7 Lions')::text || '/aa920000-0000-4000-8000-000000000001.png', 3, false)::text,
              'C1 any signed-in user reads a club''s public profile (3 active members: owner, 4, 5)');
select t27.ok((select row(p.played, p.won, p.lost, p.tied, p.no_result, p.abandoned)::text
                 from public.club_public_profile(t27.club('M7 Lions')) p) = '(7,2,2,1,1,1)',
              'C2 the official record counts confirmed results only (m8 waiting is left out)');
select t27.ok((select p.recent_form = array['abandoned', 'no_result', 'lost', 'tied', 'lost']
                      and p.played_formats = array['t20', 'odi']
                 from public.club_public_profile(t27.club('M7 Lions')) p),
              'C3 recent form: the last 5, newest first; played formats, most played first');
select t27.ok((select row(p.played, p.won, p.lost, p.tied)::text from public.club_public_profile(t27.club('M7 Kings')) p) = '(7,1,3,1)'
              and (select row(p.played, p.won, p.member_count)::text from public.club_public_profile(t27.club('M7 Riders')) p) = '(2,2,3)',
              'C4 the record from each club''s side (Kings 7: W1 L3 T1; Riders 2: W2; removed members not counted)');
select t27.ok((select p.recent_form = array['abandoned', 'no_result', 'lost', 'tied', 'won']
                 from public.club_public_profile(t27.club('M7 Kings')) p)
              and (select p.recent_form = array['won', 'won'] and p.played_formats = array['t20']
                     from public.club_public_profile(t27.club('M7 Riders')) p),
              'C5 recent form from each club''s side (Kings: m9 lost, m2 won; Riders: 2 results)');
select t27.as_user(t27.p(1));
select t27.ok((select p.is_own from public.club_public_profile(t27.club('M7 Lions')) p)
              and not (select p.is_own from public.club_public_profile(t27.club('M7 Kings')) p),
              'C6 is_own is true for the caller''s own club only');
select t27.err(format('select * from public.club_public_profile(%L)', 'ee920000-0000-4000-8000-00000000ffff'),
               'P0002', 'club: not found', 'C7 an unknown club: not found');
select t27.as_nobody();
select t27.err(format('select * from public.club_public_profile(%L)', t27.club('M7 Lions')),
               '42501', 'club: not authenticated', 'C8 no session: not authenticated');
select t27.err('select * from public.club_directory()', '42501', 'club: not authenticated', 'C9 directory without a session: not authenticated');

select t27.as_user(t27.p(1));
select t27.ok((select array_agg(d.name order by d.name) from public.club_directory('M7') d) = array['M7 Kings', 'M7 Riders'],
              'C10 the directory never lists a club the caller owns');
select t27.as_user(t27.p(12));
select t27.ok((select array_agg(d.name order by d.name) from public.club_directory('M7') d) = array['M7 Kings', 'M7 Lions', 'M7 Riders'],
              'C11 a player (no club) sees every club');
select t27.ok((select array_agg(d.name) from public.club_directory('rdr') d) = array['M7 Riders']
              and (select array_agg(d.name order by d.name) from public.club_directory('m7', '  LAHORE ') d) = array['M7 Lions', 'M7 Riders']
              and (select count(*) from public.club_directory('m7', 'Quetta') d) = 0,
              'C12 search by short name (case-insensitive); city exactly, case and outer spaces ignored');
select t27.ok((select array_agg(d.name) from public.club_directory('M7', null, 1, 1) d) = array['M7 Lions']
              and (select count(*) from public.club_directory('M7', null, 0, 0) d) = 1
              and (select count(*) from public.club_directory('M7', null, 500, -5) d) = 3,
              'C13 limit / offset (by name; limit clamped to 1–100, offset to ≥ 0)');
select t27.ok((select row(d.played, d.won, d.lost, d.member_count, d.logo_path is not null)::text
                 from public.club_directory('M7 Lions') d) = '(7,2,2,3,t)',
              'C14 directory rows carry the same public figures');
select t27.err(format('select * from public.club_directory(%L)', repeat('x', 101)), '22023', 'club: invalid',
               'C15 a search over 100 characters: invalid');
select t27.err(format('select * from public.club_directory(null, %L)', repeat('x', 61)), '22023', 'club: invalid',
               'C16 a city over 60 characters: invalid');
reset role;
select t27.ok(pg_get_function_result('public.club_directory(text, text, integer, integer)'::regprocedure)
                = 'TABLE(club_id uuid, name text, short_name text, city text, club_type text, established_year integer, '
                  'home_ground_id text, logo_path text, member_count integer, played integer, won integer, lost integer, '
                  'tied integer, no_result integer, abandoned integer, recent_form text[], played_formats text[])',
              'C17 directory columns: public fields only (no owner, phone, e-mail, address or join code)');

-- ---------------------------------------------------------------------------
-- S. Availability slots
-- ---------------------------------------------------------------------------
set local role authenticated;
select t27.as_user(t27.p(1));
select t27.post(t27.club('M7 Lions'), 1, '14:00', '16:00', 't20', 9, ' Lahore ', '  Friendly  ') as s1 \gset
select t27.ok((select row(s.club_id, s.format, s.custom_overs, s.city, s.slot_date, s.start_time, s.end_time, s.notes,
                          s.status, s.closed_at)::text
                 from public.my_club_slots(t27.club('M7 Lions')) s where s.slot_id = :'s1')
              = row(t27.club('M7 Lions'), 't20', null::smallint, 'Lahore', t27.d(1), time '14:00', time '16:00', 'Friendly',
                    'open', null::timestamptz)::text,
              'S1 the owner posts a slot from tomorrow (overs ignored for T20; city and notes trimmed)');
select t27.ok((select s.starts_at = (t27.d(1) + time '14:00') at time zone 'Asia/Karachi'
                      and s.ends_at = (t27.d(1) + time '16:00') at time zone 'Asia/Karachi'
                      and s.created_by = t27.p(1)
                 from t27.slot(:'s1') s),
              'S2 the time range is stored in Asia/Karachi; created_by is the owner');
select t27.ok((select row(s.format, s.custom_overs, s.ground_id, s.venue_name)::text
                 from public.post_match_slot(t27.club('M7 Lions'), 'CUSTOM', 15, 'Lahore', t27.d(2), '06:00', '08:00',
                                             ' ground_7 ', '  Model   Town  Ground ', '   ') s)
              = '(custom,15,ground_7,"Model Town Ground")',
              'S3 custom overs kept; ground id trimmed; venue spaces collapsed; blank notes = none');
select t27.err(t27.post_sql(t27.club('M7 Lions'), 'custom', null, 'Lahore', t27.d(3), '08:00', '10:00'), '22023', 'slot: invalid',
               'S4 custom without overs: invalid');
select t27.err(t27.post_sql(t27.club('M7 Lions'), 'custom', 51, 'Lahore', t27.d(3), '08:00', '10:00'), '22023', 'slot: invalid',
               'S5 custom with 51 overs: invalid');
select t27.err(t27.post_sql(t27.club('M7 Lions'), 't30', null, 'Lahore', t27.d(3), '08:00', '10:00'), '22023', 'slot: invalid',
               'S6 an unknown format: invalid');
select t27.err(t27.post_sql(t27.club('M7 Lions'), 't20', null, 'Lahore', t27.d(0), '22:00', '23:00'), '22023', 'slot: invalid date',
               'S7 today (Asia/Karachi): invalid date');
select t27.err(t27.post_sql(t27.club('M7 Lions'), 't20', null, 'Lahore', t27.d(-1), '08:00', '10:00'), '22023', 'slot: invalid date',
               'S8 yesterday: invalid date');
select t27.err(t27.post_sql(t27.club('M7 Lions'), 't20', null, 'Lahore', t27.d(366), '08:00', '10:00'), '22023', 'slot: invalid date',
               'S9 more than 365 days ahead: invalid date');
select t27.err(t27.post_sql(t27.club('M7 Lions'), 't20', null, 'Lahore', null, '08:00', '10:00'), '22023', 'slot: invalid date',
               'S10 no date: invalid date');
select t27.ok(t27.post(t27.club('M7 Lions'), 365, '08:00', '10:00') is not null, 'S11 365 days ahead is allowed');
select t27.err(t27.post_sql(t27.club('M7 Lions'), 't20', null, 'Lahore', t27.d(3), '10:00', '10:00'), '22023', 'slot: invalid time',
               'S12 an empty range: invalid time');
select t27.err(t27.post_sql(t27.club('M7 Lions'), 't20', null, 'Lahore', t27.d(3), '10:00', '08:00'), '22023', 'slot: invalid time',
               'S13 ending before it starts: invalid time');
select t27.err(t27.post_sql(t27.club('M7 Lions'), 't20', null, 'Lahore', t27.d(3), '08:00:30', '10:00'), '22023', 'slot: invalid time',
               'S14 seconds: invalid time');
select t27.err(t27.post_sql(t27.club('M7 Lions'), 't20', null, 'Lahore', t27.d(3), '22:00', '24:00'), '22023', 'slot: invalid time',
               'S15 ending at 24:00 (past the day): invalid time');
select t27.err(t27.post_sql(t27.club('M7 Lions'), 't20', null, 'Lahore', t27.d(3), null, '10:00'), '22023', 'slot: invalid time',
               'S16 no start: invalid time');
select t27.err(t27.post_sql(t27.club('M7 Lions'), 't20', null, '   ', t27.d(3), '08:00', '10:00'), '22023', 'slot: invalid city',
               'S17 a blank city: invalid city');
select t27.err(t27.post_sql(t27.club('M7 Lions'), 't20', null, repeat('c', 61), t27.d(3), '08:00', '10:00'), '22023',
               'slot: invalid city', 'S18 a city over 60 characters: invalid city');
select t27.err(t27.post_sql(t27.club('M7 Lions'), 't20', null, 'Lahore', t27.d(3), '08:00', '10:00', repeat('g', 65)), '22023',
               'slot: invalid ground', 'S19 a ground id over 64 characters: invalid ground');
select t27.err(t27.post_sql(t27.club('M7 Lions'), 't20', null, 'Lahore', t27.d(3), '08:00', '10:00', null, repeat('v', 101)), '22023',
               'slot: invalid venue', 'S20 a venue over 100 characters: invalid venue');
select t27.err(t27.post_sql(t27.club('M7 Lions'), 't20', null, 'Lahore', t27.d(3), '08:00', '10:00', null, null, repeat('n', 201)),
               '22023', 'slot: invalid notes', 'S21 notes over 200 characters: invalid notes');
select t27.ok(t27.post(t27.club('M7 Lions'), 3, '08:00', '10:00', p_notes => repeat('n', 200)) is not null,
              'S22 notes of exactly 200 characters are allowed');
-- Overlap with the club's own open slots (s1: tomorrow 14:00–16:00).
select t27.err(t27.post_sql(t27.club('M7 Lions'), 't20', null, 'Lahore', t27.d(1), '15:00', '17:00'), '23P01', 'slot: overlaps',
               'S23 overlapping the club''s own open slot: overlaps');
select t27.err(t27.post_sql(t27.club('M7 Lions'), 'odi', null, 'Karachi', t27.d(1), '13:00', '20:00'), '23P01', 'slot: overlaps',
               'S24 a range that contains it: overlaps (format and city do not matter)');
select t27.ok(t27.post(t27.club('M7 Lions'), 1, '16:00', '18:00') is not null
              and t27.post(t27.club('M7 Lions'), 1, '12:00', '14:00') is not null,
              'S25 back-to-back slots (16:00–18:00, 12:00–14:00) do not overlap');
reset role;
select t27.ok(t27.open_count(t27.club('M7 Lions')) = 6, 'S26 (fixture) Lions has 6 open slots');
set local role authenticated;
select t27.as_user(t27.p(2));
select t27.ok(t27.post(t27.club('M7 Kings'), 1, '14:00', '16:00', p_city => 'Karachi') is not null,
              'S27 another club may post the same time (overlap is per club)');
-- Who may post.
select t27.err(t27.post_sql(t27.club('M7 Lions'), 't20', null, 'Lahore', t27.d(5), '08:00', '10:00'), '42501', 'slot: not allowed',
               'S28 another club''s owner cannot post for Lions');
select t27.as_user(t27.p(4));
select t27.err(t27.post_sql(t27.club('M7 Lions'), 't20', null, 'Lahore', t27.d(5), '08:00', '10:00'), '42501', 'slot: not allowed',
               'S29 a member (not the owner) cannot post');
select t27.err(t27.post_sql('ee920000-0000-4000-8000-00000000ffff', 't20', null, 'Lahore', t27.d(5), '08:00', '10:00'), 'P0002',
               'slot: club not found', 'S30 an unknown club: club not found');
select t27.as_nobody();
select t27.err(t27.post_sql(t27.club('M7 Lions'), 't20', null, 'Lahore', t27.d(5), '08:00', '10:00'), '42501',
               'slot: not authenticated', 'S31 no session: not authenticated');
-- The cap: 10 open slots per club.
select t27.as_user(t27.p(1));
select count(t27.post(t27.club('M7 Lions'), 10 + k, '08:00', '10:00')) from generate_series(1, 4) k;
select t27.ok(t27.open_count(t27.club('M7 Lions')) = 10, 'S32 the owner fills Lions up to 10 open slots');
select t27.err(t27.post_sql(t27.club('M7 Lions'), 't20', null, 'Lahore', t27.d(30), '08:00', '10:00'), 'P0001', 'slot: too many open',
               'S33 the 11th open slot: too many open');
-- Withdraw.
select t27.as_user(t27.p(2));
select t27.err(format('select * from public.withdraw_match_slot(%L)', :'s1'), '42501', 'slot: not allowed',
               'S34 another club''s owner cannot withdraw it');
select t27.as_user(t27.p(4));
select t27.err(format('select * from public.withdraw_match_slot(%L)', :'s1'), '42501', 'slot: not allowed',
               'S35 a member of the club cannot withdraw it');
select t27.err(format('select * from public.withdraw_match_slot(%L)', 'ee920000-0000-4000-8000-00000000ffff'), 'P0002',
               'slot: not found', 'S36 an unknown slot: not found');
select t27.as_nobody();
select t27.err(format('select * from public.withdraw_match_slot(%L)', :'s1'), '42501', 'slot: not authenticated',
               'S37 withdraw without a session: not authenticated');
select t27.as_user(t27.p(1));
select t27.ok((select s.status = 'withdrawn' and s.closed_at = now() from public.withdraw_match_slot(:'s1') s),
              'S38 the owner withdraws the slot');
select t27.ok((select s.status = 'withdrawn' and s.closed_at = now() from public.withdraw_match_slot(:'s1') s)
              and (select count(*) from public.my_club_slots(t27.club('M7 Lions')) s where s.slot_id = :'s1') = 0
              and (select s.status from public.my_club_slots(t27.club('M7 Lions'), true) s where s.slot_id = :'s1') = 'withdrawn',
              'S39 withdrawing again returns it unchanged; it leaves my_club_slots (listed with p_include_closed)');
select t27.ok(t27.post(t27.club('M7 Lions'), 1, '14:00', '15:00') is not null,
              'S40 the freed place can be used again, and the withdrawn slot no longer blocks its time');
select t27.ok(t27.open_count(t27.club('M7 Lions')) = 10, 'S41 … Lions is at 10 open slots again');
-- Expiry by time (the start moved into the past, as time passing would).
reset role;
select s.id as s_exp from public.club_match_slots s
 where s.club_id = t27.club('M7 Lions') and s.status = 'open' and s.starts_at > now() + interval '300 days' \gset
update public.club_match_slots set starts_at = now() - interval '2 hours', ends_at = now() - interval '1 hour' where id = :'s_exp';
set local role authenticated;
select t27.as_user(t27.p(1));
select t27.ok((select count(*) from public.my_club_slots(t27.club('M7 Lions')) s where s.slot_id = :'s_exp') = 0
              and (select s.status from public.my_club_slots(t27.club('M7 Lions'), true) s where s.slot_id = :'s_exp') = 'expired',
              'S42 a started open slot is expired at once by time (listed only with p_include_closed)');
select t27.err(format('select * from public.withdraw_match_slot(%L)', :'s_exp'), 'P0001', 'slot: not open',
               'S43 an expired slot cannot be withdrawn: not open');
select t27.as_user(t27.p(2));
select t27.ok((select count(*) from public.open_match_slots() s where s.slot_id = :'s_exp') = 0,
              'S44 an expired slot is not offered to other clubs');
select t27.as_user(t27.p(1));
select t27.ok(t27.post(t27.club('M7 Lions'), 31, '08:00', '10:00') is not null,
              'S45 an expired slot frees its place under the cap');
reset role;
select t27.ok((select s.status = 'expired' and s.closed_at = now() from t27.slot(:'s_exp') s)
              and t27.open_count(t27.club('M7 Lions')) = 10,
              'S46 the next post marked it expired (closed_at set); Lions is at 10 open again');
set local role authenticated;
-- my_club_slots access and order.
select t27.ok((select bool_and(s.starts_at > now() and s.status = 'open') and count(*) = 10
                      and array_agg(s.starts_at order by s.starts_at) = array_agg(s.starts_at)
                 from public.my_club_slots(t27.club('M7 Lions')) s),
              'S47 my_club_slots: the 10 open slots, by start');
select t27.as_user(t27.p(2));
select t27.err(format('select * from public.my_club_slots(%L)', t27.club('M7 Lions')), '42501', 'slot: not allowed',
               'S48 another owner cannot list Lions'' slots');
select t27.as_user(t27.p(4));
select t27.err(format('select * from public.my_club_slots(%L)', t27.club('M7 Lions')), '42501', 'slot: not allowed',
               'S49 a member cannot list them either');
select t27.as_nobody();
select t27.err(format('select * from public.my_club_slots(%L)', t27.club('M7 Lions')), '42501', 'slot: not authenticated',
               'S50 my_club_slots without a session: not authenticated');
-- open_match_slots (Find Opponent).
select t27.as_user(t27.p(2));
select t27.ok((select count(*) = 10 and bool_and(s.club_id = t27.club('M7 Lions'))
                 from public.open_match_slots(p_limit => 100) s),
              'S51 Kings'' owner sees Lions'' 10 open slots and never Kings'' own');
select t27.ok((select row(s.club_name, s.club_short_name, s.club_city, s.club_type, s.club_logo_path is not null,
                          s.club_played, s.club_won, s.club_lost)::text
                 from public.open_match_slots(p_limit => 1) s) = '("M7 Lions",LNS,Lahore,corporate,t,7,2,2)',
              'S52 each row carries the club''s public name, logo and record');
select t27.ok((select array_agg(s.starts_at order by s.starts_at, s.slot_id) = array_agg(s.starts_at)
                 from public.open_match_slots(p_limit => 100) s)
              and (select min(s.starts_at) from public.open_match_slots(p_limit => 100) s) > now(),
              'S53 soonest first, all in the future');
select t27.ok((select count(*) from public.open_match_slots(' LAHORE ') s) = 10
              and (select count(*) from public.open_match_slots('Karachi') s) = 0
              and (select count(*) from public.open_match_slots(p_format => 'CUSTOM') s) = 1
              and (select count(*) from public.open_match_slots(p_from_date => t27.d(1), p_to_date => t27.d(1)) s) = 3
              and (select count(*) from public.open_match_slots(p_from_date => t27.d(20)) s) = 1,
              'S54 filters: city (case / spaces ignored), format, date range (inclusive, Asia/Karachi)');
select t27.ok((select count(*) from public.open_match_slots(p_limit => 2, p_offset => 9) s) = 1
              and (select count(*) from public.open_match_slots(p_limit => 0) s) = 1,
              'S55 limit / offset (limit clamped to ≥ 1)');
select t27.err('select * from public.open_match_slots(p_format => ''t30'')', '22023', 'slot: invalid', 'S56 an unknown format filter: invalid');
select t27.err(format('select * from public.open_match_slots(p_from_date => %L, p_to_date => %L)', t27.d(5), t27.d(4)), '22023',
               'slot: invalid', 'S57 a date range that ends before it starts: invalid');
select t27.err(format('select * from public.open_match_slots(%L)', repeat('c', 61)), '22023', 'slot: invalid',
               'S58 a city over 60 characters: invalid');
select t27.as_user(t27.p(1));
select t27.ok((select count(*) = 1 and bool_and(s.club_id = t27.club('M7 Kings'))
                 from public.open_match_slots() s),
              'S59 Lions'' owner sees only other clubs'' slots (Kings: 1)');
select t27.as_user(t27.p(12));
select t27.err('select * from public.open_match_slots()', '42501', 'slot: not allowed', 'S60 a signed-in user without a club: not allowed');
select t27.as_nobody();
select t27.err('select * from public.open_match_slots()', '42501', 'slot: not authenticated', 'S61 no session: not authenticated');
-- The table itself is closed.
select t27.as_user(t27.p(1));
select t27.err('select count(*) from public.club_match_slots', '42501', '%permission denied%',
               'S62 authenticated cannot read club_match_slots directly');
select t27.err(format('insert into public.club_match_slots (club_id, format, city, starts_at, ends_at) values (%L, %L, %L, now() + interval ''2 days'', now() + interval ''50 hours'')',
                      t27.club('M7 Lions'), 't20', 'Lahore'), '42501', '%permission denied%',
               'S63 … nor write it');
reset role;
set local role anon;
select t27.err('select count(*) from public.club_match_slots', '42501', '%permission denied%', 'S64 anon cannot read it');
reset role;

-- ---------------------------------------------------------------------------
-- R. Player rankings
-- ---------------------------------------------------------------------------
set local role authenticated;
select t27.as_user(t27.p(12));
select t27.ok((select array_agg(r.full_name order by r.full_name) from public.player_rankings() r)
              = array['M7 Person 4', 'M7 Person 7'],
              'R1 only allowed, ranked players: show_stats off (5), public_profile off (6), removed (9), no club (8, 12), no player profile (13) left out');
select t27.ok((select array_agg(r.full_name) from public.player_rankings() r) = array['M7 Person 4', 'M7 Person 7'],
              'R2 order: matches, runs, wickets descending');
select t27.ok((select row(r.club_name, r.club_short_name, r.player_role, r.matches, r.bat_innings, r.not_outs, r.runs,
                          r.balls_faced, r.batting_average, r.strike_rate, r.highest, r.wickets, r.rating, r.is_me)::text
                 from public.player_rankings() r where r.user_id = t27.p(4))
              = '("M7 Lions",LNS,batsman,5,5,1,115,102,28.75,112.75,50,0,,f)',
              'R3 career figures from confirmed results only (m8 left out); club = earliest active membership; rating NULL');
select t27.ok((select row(r.recent_played, r.recent_wins)::text from public.player_rankings() r where r.user_id = t27.p(4)) = '(5,2)'
              and (select row(r.recent_played, r.recent_wins, r.wickets, r.balls_bowled, r.runs_conceded, r.bowling_average,
                              r.economy, r.best_wickets, r.best_runs)::text
                     from public.player_rankings() r where r.user_id = t27.p(7)) = '(3,1,3,66,75,25.00,6.82,2,30)',
              'R4 recent form (last 5: played / club wins) and bowling figures');
reset role;
select t27.ok((select row(r.matches, r.runs, r.wickets, r.batting_average)::text
                 from (select 1) x, lateral (select * from public.member_stats(array(select m.id from public.club_members m
                                                                                     where m.user_id = t27.p(4)))) r)
              = '(5,115,0,28.75)', 'R5 the figures are member_stats'' (migration 22)');
set local role authenticated;
select t27.as_user(t27.p(5));
select t27.ok((select array_agg(r.full_name || ':' || r.is_me order by r.full_name) from public.player_rankings() r)
              = array['M7 Person 4:false', 'M7 Person 5:true', 'M7 Person 7:false'],
              'R6 a player who hides their stats still sees their own row (is_me)');
select t27.as_user(t27.p(6));
select t27.ok((select count(*) from public.player_rankings() r where r.user_id = t27.p(6) and r.is_me) = 1
              and (select count(*) from public.player_rankings() r where r.user_id = t27.p(5)) = 0,
              'R7 … and never another hidden player');
select t27.as_user(t27.p(12));
select t27.ok((select array_agg(r.full_name) from public.player_rankings('BOWLER') r) = array['M7 Person 7']
              and (select count(*) from public.player_rankings('all_rounder') r) = 0
              and (select array_agg(r.full_name) from public.player_rankings(p_search => ' person   4 ') r) = array['M7 Person 4'],
              'R8 role filter (case-insensitive) and name search');
select t27.ok((select array_agg(r.club_name) from public.player_rankings(p_club_id => t27.club('M7 Riders')) r) = array['M7 Riders']
              and (select array_agg(r.full_name) from public.player_rankings(p_club_id => t27.club('M7 Kings')) r) = array['M7 Person 7']
              and (select count(*) from public.player_rankings(p_club_id => 'ee920000-0000-4000-8000-00000000ffff') r) = 0,
              'R9 club filter: members of that club, shown with that club');
select t27.ok((select count(*) from public.player_rankings(p_limit => 1) r) = 1
              and (select count(*) from public.player_rankings(p_limit => -3) r) = 1,
              'R10 limit (clamped to 1–200)');
select t27.err('select * from public.player_rankings(''keeper'')', '22023', 'ranking: invalid', 'R11 an unknown role: invalid');
select t27.err(format('select * from public.player_rankings(p_search => %L)', repeat('x', 101)), '22023', 'ranking: invalid',
               'R12 a search over 100 characters: invalid');
select t27.as_nobody();
select t27.err('select * from public.player_rankings()', '42501', 'ranking: not authenticated', 'R13 no session: not authenticated');
reset role;

-- ---------------------------------------------------------------------------
-- A. Join-request applicant statistics
-- ---------------------------------------------------------------------------
select r.id as rq9 from public.join_requests r where r.user_id = t27.p(9) and r.status = 'pending' \gset
select r.id as rq10 from public.join_requests r where r.user_id = t27.p(10) and r.status = 'pending' \gset
select r.id as rq11 from public.join_requests r where r.user_id = t27.p(11) \gset
set local role authenticated;
select t27.as_user(t27.p(1));
select t27.ok((select row(a.request_id, a.stats_visible, a.matches, a.bat_innings, a.not_outs, a.runs, a.batting_average,
                          a.highest, a.wickets)::text from public.club_applicant_stats(:'rq9') a)
              = row(:'rq9'::uuid, true, 2, 2, 1, 65, 65.00::numeric, 40, 0)::text,
              'A1 the owner sees a pending applicant''s career figures (an earlier, removed membership included)');
select t27.ok((select a.stats_visible = false and a.request_id = :'rq10'
                      and num_nulls(a.matches, a.bat_innings, a.not_outs, a.runs, a.balls_faced, a.batting_average,
                                    a.strike_rate, a.highest, a.highest_not_out, a.fifties, a.hundreds, a.wickets,
                                    a.balls_bowled, a.runs_conceded, a.bowling_average, a.economy, a.best_wickets,
                                    a.best_runs, a.catches, a.run_outs, a.stumpings, a.player_of_match) = 22
                 from public.club_applicant_stats(:'rq10') a),
              'A2 show_stats off: one row, stats_visible false, every figure NULL');
select t27.ok((select count(*) from public.club_applicant_stats(:'rq10')) = 1, 'A3 … exactly one row');
reset role;
update public.profiles set show_stats = true where id = t27.p(10);
set local role authenticated;
select t27.as_user(t27.p(1));
select t27.ok((select a.stats_visible and a.matches = 0 and a.runs = 0 and a.batting_average is null
                 from public.club_applicant_stats(:'rq10') a),
              'A4 an applicant who never played: zeros (averages NULL)');
select t27.err(format('select * from public.club_applicant_stats(%L)', :'rq11'), 'P0001', 'club_join: not pending',
               'A5 a decided request: not pending');
select t27.err(format('select * from public.club_applicant_stats(%L)', 'ee920000-0000-4000-8000-00000000ffff'), 'P0002',
               'club_join: not found', 'A6 an unknown request: not found');
select t27.as_user(t27.p(2));
select t27.err(format('select * from public.club_applicant_stats(%L)', :'rq9'), '42501', 'club_join: not allowed',
               'A7 another club''s owner: not allowed');
select t27.as_user(t27.p(4));
select t27.err(format('select * from public.club_applicant_stats(%L)', :'rq9'), '42501', 'club_join: not allowed',
               'A8 a member of the club: not allowed');
select t27.as_user(t27.p(9));
select t27.err(format('select * from public.club_applicant_stats(%L)', :'rq9'), '42501', 'club_join: not allowed',
               'A9 the applicant themself: not allowed (they use player_stats)');
select t27.as_nobody();
select t27.err(format('select * from public.club_applicant_stats(%L)', :'rq9'), '42501', 'club_join: not authenticated',
               'A10 no session: not authenticated');
reset role;

-- ---------------------------------------------------------------------------
-- P. Privacy: no phone, owner or contact data anywhere
-- ---------------------------------------------------------------------------
set local role authenticated;
select t27.as_user(t27.p(2));
select t27.ok(coalesce((select jsonb_agg(to_jsonb(x))::text from public.club_directory() x), '') !~ '(\+92374|ee920000-0000-4000-8000-000000000001|m7p)'
              and coalesce((select jsonb_agg(to_jsonb(x))::text from public.club_public_profile(t27.club('M7 Lions')) x), '') !~ '(\+92374|ee920000-0000-4000-8000-000000000001|m7p)'
              and coalesce((select jsonb_agg(to_jsonb(x))::text from public.open_match_slots(p_limit => 100) x), '') !~ '(\+92374|ee920000-0000-4000-8000-000000000001|m7p)'
              and coalesce((select jsonb_agg(to_jsonb(x))::text from public.player_rankings() x), '') !~ '(\+92374|m7p)',
              'P1 no phone, owner id or e-mail in any returned row (directory, profile, open slots, rankings)');
reset role;
select t27.ok(not exists (select 1 from unnest(array['public.club_public_profile(uuid)', 'public.club_directory(text, text, integer, integer)',
                                                    'public.open_match_slots(text, text, date, date, integer, integer)',
                                                    'public.player_rankings(text, uuid, text, integer)',
                                                    'public.club_applicant_stats(uuid)',
                                                    'public.my_club_slots(uuid, boolean)']::regprocedure[]) f
                           where pg_get_function_result(f) ~ '(owner|phone|email|address|code|date_of_birth|created_by)'),
              'P2 no result type has an owner, phone, e-mail, address, code, birth date or created_by column');

-- ---------------------------------------------------------------------------
-- G. Grants
-- ---------------------------------------------------------------------------
select t27.ok((select bool_and(has_function_privilege('authenticated', f, 'execute') and not has_function_privilege('anon', f, 'execute'))
                from unnest(array['public.club_public_profile(uuid)', 'public.club_directory(text, text, integer, integer)',
                                  'public.post_match_slot(uuid, text, integer, text, date, time, time, text, text, text)',
                                  'public.withdraw_match_slot(uuid)', 'public.my_club_slots(uuid, boolean)',
                                  'public.open_match_slots(text, text, date, date, integer, integer)',
                                  'public.player_rankings(text, uuid, text, integer)',
                                  'public.club_applicant_stats(uuid)']::regprocedure[]) f),
              'G1 the eight API functions: authenticated yes, anon no');
select t27.ok(not has_function_privilege('authenticated', 'public.club_public_stats(uuid)', 'execute')
              and not has_function_privilege('authenticated', 'public.player_recent_form(uuid[])', 'execute')
              and not has_function_privilege('anon', 'public.club_public_stats(uuid)', 'execute'),
              'G2 the two internal helpers are closed');
set local role anon;
select t27.err('select * from public.club_directory()', '42501', '%permission denied%', 'G3 anon cannot call club_directory');
select t27.err('select * from public.player_rankings()', '42501', '%permission denied%', 'G4 anon cannot call player_rankings');
select t27.err('select * from public.open_match_slots()', '42501', '%permission denied%', 'G5 anon cannot call open_match_slots');
select t27.err(format('select * from public.club_public_profile(%L)', t27.club('M7 Lions')), '42501', '%permission denied%',
               'G6 anon cannot call club_public_profile');
select t27.err(format('select * from public.club_applicant_stats(%L)', :'rq9'), '42501', '%permission denied%',
               'G7 anon cannot call club_applicant_stats');
select t27.err(t27.post_sql(t27.club('M7 Lions'), 't20', null, 'Lahore', t27.d(5), '08:00', '10:00'), '42501', '%permission denied%',
               'G8 anon cannot call post_match_slot');
select t27.err(format('select * from public.withdraw_match_slot(%L)', :'s1'), '42501', '%permission denied%',
               'G9 anon cannot call withdraw_match_slot');
select t27.err(format('select * from public.my_club_slots(%L)', t27.club('M7 Lions')), '42501', '%permission denied%',
               'G10 anon cannot call my_club_slots');
set local role authenticated;
select t27.as_user(t27.p(1));
select t27.err(format('select * from public.club_public_stats(%L)', t27.club('M7 Lions')), '42501', '%permission denied%',
               'G11 authenticated cannot call the internal club_public_stats');
reset role;

-- ---------------------------------------------------------------------------
-- D. Deletions follow the club and the account
-- ---------------------------------------------------------------------------
select t27.ok((select count(*) from public.club_match_slots s where s.club_id = t27.club('M7 Kings')) = 1,
              'D0 (fixture) Kings has one slot');
delete from auth.users where id = t27.p(4);
select t27.ok(not exists (select 1 from public.profiles where id = t27.p(4))
              and (select count(*) from public.match_batting b where b.player_deleted) >= 5,
              'D1 (fixture) deleting player 4''s account unlinks their scorecard rows');
set local role authenticated;
select t27.as_user(t27.p(12));
select t27.ok((select array_agg(r.full_name) from public.player_rankings() r) = array['M7 Person 7'],
              'D2 a deleted account leaves the rankings');
select t27.ok((select p.member_count from public.club_public_profile(t27.club('M7 Lions')) p) = 2,
              'D3 … and the member count');
reset role;

rollback;
\echo 'local check 27: all checks passed; everything rolled back'
