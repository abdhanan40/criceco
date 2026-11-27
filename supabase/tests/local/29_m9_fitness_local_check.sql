-- CricEco · LOCAL TEST ONLY — migration 34 (M9 fitness) on a DISPOSABLE
-- database after migrations 1–31 (+ the D1 location seed and the Storage
-- stand-in of 26_m5_m6_media_local_check.sh) and migration 34: the
-- "postgres" database of a throwaway container of the real Supabase image,
-- or a plain PostgreSQL database with 00_auth_stub.sql and
-- 02_legacy_profiles_fixture.sql. Migrations 32 / 33 are not needed.
-- Synthetic data only (people ee940000-…, matches ee9400aa-…); everything
-- runs in ONE transaction that is ROLLED BACK at the end.
-- Run with psql:  psql -X -v ON_ERROR_STOP=1 -f 29_m9_fitness_local_check.sql
-- Every check prints "PASS: …"; the first failure stops the run ("FAIL: …").
-- Confirmed results are seeded directly with session_replication_role =
-- replica (the result pipeline itself is covered by local 17–19).
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
  if to_regprocedure('public.log_workout(date, text, integer, text, text)') is null then
    raise exception 'apply migration 34 first';
  end if;
end $$;

create schema t29;
grant usage on schema t29 to anon, authenticated, service_role;

create function t29.ok(p_cond boolean, p_name text) returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_name; end if;
  raise notice 'PASS: %', p_name;
end $$;

-- PASS when p_sql fails with exactly SQLSTATE p_state and a message LIKE p_like.
create function t29.err(p_sql text, p_state text, p_like text, p_name text) returns void language plpgsql as $$
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

create function t29.okq(p_sql text, p_name text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    raise exception 'FAIL: % — error [% %]', p_name, sqlstate, sqlerrm;
  end;
  raise notice 'PASS: %', p_name;
end $$;

-- Rows returned / touched by p_sql.
create function t29.n(p_sql text) returns int language plpgsql as $$
declare
  v int;
begin
  execute 'select count(*) from (' || p_sql || ') s' into v;
  return v;
end $$;
create function t29.affected(p_sql text) returns int language plpgsql as $$
declare
  v int;
begin
  execute p_sql;
  get diagnostics v = row_count;
  return v;
end $$;

-- Both spellings: the image's own auth.uid() reads request.jwt.claim.sub only.
create function t29.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true),
         set_config('request.jwt.claim.sub', p_uid::text, true);
$$;
create function t29.as_nobody() returns void language sql as $$
  select set_config('request.jwt.claims', '', true), set_config('request.jwt.claim.sub', '', true);
$$;
create function t29.p(p_n int) returns uuid language sql immutable as $$
  select ('ee940000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
$$;
create function t29.m(p_n int) returns uuid language sql immutable as $$
  select ('ee9400aa-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
$$;
create function t29.today() returns date language sql stable as $$
  select (now() at time zone 'Asia/Karachi')::date;
$$;
create function t29.club(p_name text) returns uuid language sql stable security definer set search_path = '' as $$
  select c.id from public.clubs c where c.name = p_name;
$$;
-- Membership id of person n in club c. Reads past RLS.
create function t29.mem(p_n int, p_club text) returns uuid language sql stable security definer set search_path = '' as $$
  select m.id from public.club_members m join public.clubs c on c.id = m.club_id
   where m.user_id = ('ee940000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid and c.name = p_club;
$$;
create function t29.make_person(p_n int) returns uuid language plpgsql as $$
declare
  v uuid := t29.p(p_n);
begin
  insert into auth.users (id, email) values (v, format('m9p%s@local.test', p_n));
  insert into public.profiles (id) values (v) on conflict (id) do nothing; -- the sign-up trigger made it already
  insert into public.current_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
  insert into public.permanent_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
  update public.profiles
     set full_name = format('M9 Person %s', p_n),
         phone = format('+923%s', lpad((740000000 + p_n)::text, 9, '0')),
         date_of_birth = date '2000-05-01', profile_completed = true
   where id = v;
  return v;
end $$;
-- A call of log_workout as SQL text (for t29.err / t29.okq).
create function t29.log_sql(p_date date, p_type text, p_minutes int, p_intensity text, p_notes text default null)
returns text language sql immutable as $$
  select format('select * from public.log_workout(%L::date, %L, %s, %L, %L)',
                p_date, p_type, coalesce(p_minutes::text, 'null'), p_intensity, p_notes);
$$;
grant execute on all functions in schema t29 to anon, authenticated, service_role;

-- People: 1 owns "M9 Lions" (and hides their stats), 2 owns "M9 Kings",
-- 3 a Lions player, 4 a Lions player who hides their stats, 5 removed from
-- Lions, 6 nobody's member, 7 a Kings player, 8 a Lions player whose
-- account is deleted, 10 the limits user, 9 signed in without a profile.
select count(*) from (select t29.make_person(n) from unnest(array[1, 2, 3, 4, 5, 6, 7, 8, 10]) n) s;
insert into auth.users (id, email) values (t29.p(9), 'm9p9@local.test');
delete from public.profiles where id = t29.p(9);
insert into public.clubs (owner_id, name, city, club_type) values (t29.p(1), 'M9 Lions', 'Lahore', 'corporate');
insert into public.clubs (owner_id, name, city, club_type) values (t29.p(2), 'M9 Kings', 'Lahore', 'corporate');
insert into public.club_members (club_id, user_id, member_role, status)
values (t29.club('M9 Lions'), t29.p(3), 'player', 'active'),
       (t29.club('M9 Lions'), t29.p(4), 'player', 'active'),
       (t29.club('M9 Lions'), t29.p(8), 'player', 'active'),
       (t29.club('M9 Kings'), t29.p(7), 'player', 'active');
insert into public.club_members (club_id, user_id, member_role, status, removed_at, removed_by)
values (t29.club('M9 Lions'), t29.p(5), 'player', 'removed', now() - interval '1 day', t29.p(1));
update public.profiles set show_stats = false where id in (t29.p(1), t29.p(4));

-- Matches, Lions (A) v Kings (B): m1 two days ago, confirmed, Lions won;
-- m2 forty days ago, confirmed; m3 yesterday, only submitted; m4 five days
-- ago, v1 superseded and v2 confirmed (a tie). Seeded with triggers off.
set session_replication_role = replica;
insert into public.matches (id, club_a_id, club_b_id, format, status, starts_at, venue_name)
select t29.m(k), t29.club('M9 Lions'), t29.club('M9 Kings'), 't20', 'confirmed', now() - d, 'M9 Ground'
  from (values (1, interval '2 days'), (2, interval '40 days'), (3, interval '1 day'), (4, interval '5 days')) v(k, d);
insert into public.match_results (match_id, version, status, outcome, decided_at, scorer_client_id, submission_id,
                                  decided_by_client_id)
values (t29.m(1), 1, 'confirmed', 'club_a_won', now(), gen_random_uuid(), 940001, gen_random_uuid()),
       (t29.m(2), 1, 'confirmed', 'club_b_won', now(), gen_random_uuid(), 940002, gen_random_uuid()),
       (t29.m(3), 1, 'submitted', 'club_a_won', null, gen_random_uuid(), 940003, null),
       (t29.m(4), 1, 'superseded', 'club_a_won', now(), gen_random_uuid(), 940004, gen_random_uuid()),
       (t29.m(4), 2, 'confirmed', 'tie', now(), gen_random_uuid(), 940005, gen_random_uuid());
insert into public.match_innings (match_id, version, innings_no, batting_club_id, bowling_club_id, runs, wickets, balls)
select x.match_id, x.version, i, case when i = 1 then t29.club('M9 Lions') else t29.club('M9 Kings') end,
       case when i = 1 then t29.club('M9 Kings') else t29.club('M9 Lions') end, 100, 2, 120
  from public.match_results x cross join generate_series(1, 2) i
 where x.match_id::text like 'ee9400aa%';
-- m1: 3 bats 40 (30), 4 bats 10 (8); 3 bowls 18 balls 20 runs 2 wickets;
-- 7 bowls 24 balls 30 runs 1 wicket. m2: 3 bats 70 (50). m3: 3 bats 55 (40).
-- m4 v1: 3 bats 99 (50); v2: 3 bats 12 (10).
insert into public.match_batting (match_id, version, innings_no, position, member_id, player_name, runs, balls, dismissal)
values (t29.m(1), 1, 1, 1, t29.mem(3, 'M9 Lions'), 'M9 Person 3', 40, 30, 'not_out'),
       (t29.m(1), 1, 1, 2, t29.mem(4, 'M9 Lions'), 'M9 Person 4', 10, 8, 'not_out'),
       (t29.m(2), 1, 1, 1, t29.mem(3, 'M9 Lions'), 'M9 Person 3', 70, 50, 'not_out'),
       (t29.m(3), 1, 1, 1, t29.mem(3, 'M9 Lions'), 'M9 Person 3', 55, 40, 'not_out'),
       (t29.m(4), 1, 1, 1, t29.mem(3, 'M9 Lions'), 'M9 Person 3', 99, 50, 'not_out'),
       (t29.m(4), 2, 1, 1, t29.mem(3, 'M9 Lions'), 'M9 Person 3', 12, 10, 'not_out');
insert into public.match_bowling (match_id, version, innings_no, bowler_no, member_id, player_name, balls, runs, wickets)
values (t29.m(1), 1, 2, 1, t29.mem(3, 'M9 Lions'), 'M9 Person 3', 18, 20, 2),
       (t29.m(1), 1, 1, 1, t29.mem(7, 'M9 Kings'), 'M9 Person 7', 24, 30, 1);
set session_replication_role = default;

-- ---------------------------------------------------------------------------
-- A. Access: anon, no session, direct table writes
-- ---------------------------------------------------------------------------
set local role anon;
select t29.err(t29.log_sql(t29.today(), 'training', 60, 'moderate'), '42501', '%permission denied%',
               'A1 anon cannot call log_workout');
select t29.err(format('select * from public.my_workouts(%L, %L)', t29.today() - 6, t29.today()), '42501',
               '%permission denied%', 'A2 anon cannot call my_workouts');
select t29.err(format('select public.delete_workout(%L)', gen_random_uuid()), '42501', '%permission denied%',
               'A3 anon cannot call delete_workout');
select t29.err(format('select * from public.club_member_fitness(%L, %L, %L)', t29.club('M9 Lions'), t29.today() - 6, t29.today()),
               '42501', '%permission denied%', 'A4 anon cannot call club_member_fitness');
select t29.err(format('select * from public.club_member_workouts(%L, %L, %L)', t29.club('M9 Lions'), t29.today() - 6, t29.today()),
               '42501', '%permission denied%', 'A5 anon cannot call club_member_workouts');
select t29.err(format('select * from public.club_member_match_activity(%L, %L, %L)', t29.club('M9 Lions'), t29.today() - 6, t29.today()),
               '42501', '%permission denied%', 'A6 anon cannot call club_member_match_activity');
select t29.err('select * from public.player_workouts', '42501', '%permission denied%', 'A7 anon cannot read player_workouts');
reset role;

set local role authenticated;
select t29.as_nobody();
select t29.err(t29.log_sql(t29.today(), 'training', 60, 'moderate'), '42501', 'fitness: not authenticated',
               'A8 no session: log_workout not authenticated');
select t29.err(format('select * from public.my_workouts(%L, %L)', t29.today() - 6, t29.today()), '42501',
               'fitness: not authenticated', 'A9 no session: my_workouts not authenticated');
select t29.err(format('select public.delete_workout(%L)', gen_random_uuid()), '42501', 'fitness: not authenticated',
               'A10 no session: delete_workout not authenticated');
select t29.err(format('select * from public.club_member_fitness(%L, %L, %L)', t29.club('M9 Lions'), t29.today() - 6, t29.today()),
               '42501', 'fitness: not authenticated', 'A11 no session: club_member_fitness not authenticated');
select t29.err(format('select * from public.club_member_workouts(%L, %L, %L)', t29.club('M9 Lions'), t29.today() - 6, t29.today()),
               '42501', 'fitness: not authenticated', 'A12 no session: club_member_workouts not authenticated');
select t29.err(format('select * from public.club_member_match_activity(%L, %L, %L)', t29.club('M9 Lions'), t29.today() - 6, t29.today()),
               '42501', 'fitness: not authenticated', 'A13 no session: club_member_match_activity not authenticated');

select t29.as_user(t29.p(3));
select t29.err(format('insert into public.player_workouts (user_id, workout_date, workout_type, minutes, intensity) values (%L, %L, ''gym'', 30, ''light'')',
                      t29.p(3), t29.today()), '42501', '%permission denied%', 'A14 no direct INSERT into player_workouts');
select t29.err('update public.player_workouts set minutes = 1', '42501', '%permission denied%', 'A15 no direct UPDATE');
select t29.err('delete from public.player_workouts', '42501', '%permission denied%', 'A16 no direct DELETE');
select t29.err(format('select * from public.fitness_member_matches(%L, %L, %L)', t29.p(3), t29.today() - 6, t29.today()),
               '42501', '%permission denied%', 'A17 the internal fitness_member_matches is closed to authenticated');

-- ---------------------------------------------------------------------------
-- L. log_workout: valid input and bounds
-- ---------------------------------------------------------------------------
select t29.ok((select w.workout_date = t29.today() and w.workout_type = 'training' and w.minutes = 60
                      and w.intensity = 'moderate' and w.notes is null and w.id is not null
                      and w.created_at = now()
                 from public.log_workout(t29.today(), 'training', 60, 'moderate') w),
              'L1 log today: training 60 min moderate, the stored row returned');
select t29.ok((select w.notes = 'Bowling drills' from public.log_workout(t29.today() - 1, 'gym', 90, 'high', '  Bowling drills  ') w),
              'L2 notes are trimmed (gym 90 high yesterday)');
select t29.ok((select w.notes is null from public.log_workout(t29.today() - 3, 'running', 30, 'light', '   ') w),
              'L3 blank notes are stored as NULL (running 30 light)');
select t29.ok((select w.minutes = 45 from public.log_workout(t29.today() - 10, 'nets', 45, 'moderate', repeat('n', 120)) w),
              'L4 notes of exactly 120 characters (nets 45, ten days ago)');
select t29.okq(t29.log_sql(t29.today() - 365, 'other', 1, 'light'), 'L5 365 days back and 1 minute are accepted');
select t29.okq(t29.log_sql(t29.today() - 364, 'other', 600, 'high'), 'L6 600 minutes are accepted');
select t29.err(t29.log_sql(t29.today() + 1, 'training', 60, 'moderate'), '22023', 'fitness: future date',
               'L7 tomorrow (Asia/Karachi) is refused');
select t29.err(t29.log_sql(t29.today() - 366, 'training', 60, 'moderate'), '22023', 'fitness: date too old',
               'L8 366 days back is refused');
select t29.err(t29.log_sql(null, 'training', 60, 'moderate'), '22023', 'fitness: invalid date', 'L9 no date is refused');
select t29.err(t29.log_sql(t29.today(), 'training', 0, 'moderate'), '22023', 'fitness: invalid minutes', 'L10 0 minutes');
select t29.err(t29.log_sql(t29.today(), 'training', 601, 'moderate'), '22023', 'fitness: invalid minutes', 'L11 601 minutes');
select t29.err(t29.log_sql(t29.today(), 'training', -5, 'moderate'), '22023', 'fitness: invalid minutes', 'L12 negative minutes');
select t29.err(t29.log_sql(t29.today(), 'training', null, 'moderate'), '22023', 'fitness: invalid minutes', 'L13 no minutes');
select t29.err(t29.log_sql(t29.today(), 'Training', 60, 'moderate'), '22023', 'fitness: invalid type',
               'L14 a type is a lower-case code (Training refused)');
select t29.err(t29.log_sql(t29.today(), 'yoga', 60, 'moderate'), '22023', 'fitness: invalid type', 'L15 an unknown type');
select t29.err(t29.log_sql(t29.today(), null, 60, 'moderate'), '22023', 'fitness: invalid type', 'L16 no type');
select t29.err(t29.log_sql(t29.today(), 'gym', 60, 'extreme'), '22023', 'fitness: invalid intensity', 'L17 an unknown intensity');
select t29.err(t29.log_sql(t29.today(), 'gym', 60, null), '22023', 'fitness: invalid intensity', 'L18 no intensity');
select t29.err(t29.log_sql(t29.today(), 'gym', 60, 'light', repeat('n', 121)), '22023', 'fitness: notes too long',
               'L19 notes of 121 characters are refused');
select t29.ok(t29.n(format('select * from public.my_workouts(%L, %L)', t29.today() - 365, t29.today())) = 6,
              'L20 the refused calls stored nothing (6 workouts)');
select t29.okq(t29.log_sql(t29.today() - 2, 'gym', 30, 'light', 'Leg day'), 'L21 log one more …');
select t29.okq(format('select public.delete_workout((select w.id from public.player_workouts w where w.notes = %L))', 'Leg day'),
               'L22 … and delete it (the own-row SELECT finds it)');

select t29.as_user(t29.p(9));
select t29.err(t29.log_sql(t29.today(), 'gym', 30, 'light'), 'P0002', 'fitness: profile not found',
               'L23 signed in without a profile row: not found');
select t29.ok(t29.n(format('select * from public.my_workouts(%L, %L)', t29.today() - 6, t29.today())) = 0,
              'L24 … and my_workouts is empty');

-- The table rules hold for any writer (as the table owner here).
reset role;
select t29.err(format('insert into public.player_workouts (user_id, workout_date, workout_type, minutes, intensity) values (%L, %L, ''gym'', 30, ''light'')',
                      t29.p(6), t29.today() + 1), '23514', '%player_workouts_date_window%', 'L25 CHECK: no future date (table)');
select t29.err(format('insert into public.player_workouts (user_id, workout_date, workout_type, minutes, intensity) values (%L, %L, ''gym'', 30, ''light'')',
                      t29.p(6), t29.today() - 366), '23514', '%player_workouts_date_window%', 'L26 CHECK: not older than 365 days (table)');
select t29.err(format('insert into public.player_workouts (user_id, workout_date, workout_type, minutes, intensity, notes) values (%L, %L, ''gym'', 30, ''light'', '' x'')',
                      t29.p(6), t29.today()), '23514', '%player_workouts_notes_check%', 'L27 CHECK: untrimmed notes (table)');
select t29.err(format('insert into public.player_workouts (user_id, workout_date, workout_type, minutes, intensity) values (%L, %L, ''gym'', 601, ''light'')',
                      t29.p(6), t29.today()), '23514', '%player_workouts_minutes_check%', 'L28 CHECK: 601 minutes (table)');
select t29.err(format('insert into public.player_workouts (user_id, workout_date, workout_type, minutes, intensity) values (%L, %L, ''GYM'', 30, ''light'')',
                      t29.p(6), t29.today()), '23514', '%player_workouts_type_check%', 'L29 CHECK: type codes (table)');
select t29.err(format('insert into public.player_workouts (user_id, workout_date, workout_type, minutes, intensity) values (%L, %L, ''gym'', 30, ''max'')',
                      t29.p(6), t29.today()), '23514', '%player_workouts_intensity_check%', 'L30 CHECK: intensity codes (table)');

-- ---------------------------------------------------------------------------
-- R. Limits: 10 on one date, 30 logged in 24 hours
-- ---------------------------------------------------------------------------
set local role authenticated;
select t29.as_user(t29.p(10));
select count(*) from (select public.log_workout(t29.today() - 3, 'training', 10, 'light') from generate_series(1, 10)) s;
select t29.err(t29.log_sql(t29.today() - 3, 'training', 10, 'light'), 'P0001', 'fitness: too many workouts on that day',
               'R1 the 11th workout on one date is refused');
select count(*) from (select public.log_workout(t29.today() - 3 - g, 'training', 10, 'light') from generate_series(1, 20) g) s;
select t29.err(t29.log_sql(t29.today() - 30, 'training', 10, 'light'), 'P0001', 'fitness: too many workouts logged, try later',
               'R2 the 31st workout logged in 24 hours is refused (another date)');
reset role;
update public.player_workouts set created_at = now() - interval '25 hours' where user_id = t29.p(10);
set local role authenticated;
select t29.as_user(t29.p(10));
select t29.okq(t29.log_sql(t29.today() - 30, 'training', 10, 'light'), 'R3 after 24 hours logging is possible again');
select t29.err(t29.log_sql(t29.today() - 3, 'training', 10, 'light'), 'P0001', 'fitness: too many workouts on that day',
               'R4 … but the per-date limit still counts the older rows');

-- ---------------------------------------------------------------------------
-- M. my_workouts and the own-row SELECT; delete_workout
-- ---------------------------------------------------------------------------
-- More rows: 4 (hidden), 1 (the owner, hidden), 5 (removed), 8 (deleted later).
select t29.as_user(t29.p(4));
select count(*) from public.log_workout(t29.today(), 'gym', 50, 'high', 'Private note');
select t29.as_user(t29.p(1));
select count(*) from public.log_workout(t29.today(), 'nets', 20, 'light');
select t29.as_user(t29.p(5));
select count(*) from public.log_workout(t29.today(), 'running', 40, 'moderate');
select t29.as_user(t29.p(8));
select count(*) from public.log_workout(t29.today(), 'running', 40, 'moderate');

select t29.as_user(t29.p(3));
select t29.ok((select string_agg(w.workout_type || ':' || w.minutes || ':' || w.intensity, ',' order by w.workout_date, w.created_at)
                 from public.my_workouts(t29.today() - 6, t29.today()) w)
              = 'running:30:light,gym:90:high,training:60:moderate',
              'M1 my_workouts: the range, oldest first, own rows only');
select t29.ok(t29.n(format('select * from public.my_workouts(%L, %L)', t29.today() - 365, t29.today())) = 6,
              'M2 a 366-day range is allowed');
select t29.err(format('select * from public.my_workouts(%L, %L)', t29.today() - 366, t29.today()), '22023',
               'fitness: invalid range', 'M3 a 367-day range is refused');
select t29.err(format('select * from public.my_workouts(%L, %L)', t29.today(), t29.today() - 1), '22023',
               'fitness: invalid range', 'M4 from after to is refused');
select t29.err(format('select * from public.my_workouts(null, %L)', t29.today()), '22023', 'fitness: invalid range',
               'M5 an open range is refused');
select t29.ok((select count(*) from public.player_workouts) = 6
              and (select count(*) from public.player_workouts w where w.user_id <> t29.p(3)) = 0,
              'M6 the direct SELECT shows only the caller''s rows');
select t29.err(format('select public.delete_workout(%L)', (select w.id from public.player_workouts w limit 0)), 'P0002',
               'fitness: workout not found', 'M7 delete_workout(NULL) is not found');
select t29.err(format('select public.delete_workout(%L)', gen_random_uuid()), 'P0002', 'fitness: workout not found',
               'M8 an unknown id is not found');
reset role;
select id as w4 from public.player_workouts where user_id = t29.p(4) \gset
set local role authenticated;
select t29.as_user(t29.p(3));
select t29.err(format('select public.delete_workout(%L)', :'w4'), 'P0002', 'fitness: workout not found',
               'M9 someone else''s workout cannot be deleted (looks not found)');
select t29.as_user(t29.p(1));
select t29.err(format('select public.delete_workout(%L)', :'w4'), 'P0002', 'fitness: workout not found',
               'M10 … not even by the owner of their club');
reset role;
select t29.ok((select count(*) from public.player_workouts where id = :'w4') = 1, 'M11 that workout is still there');
set local role authenticated;
select t29.as_user(t29.p(4));
select t29.okq(format('select public.delete_workout(%L)', :'w4'), 'M12 its owner deletes it');
select t29.err(format('select public.delete_workout(%L)', :'w4'), 'P0002', 'fitness: workout not found',
               'M13 deleting it twice: not found');
select count(*) from public.log_workout(t29.today(), 'gym', 50, 'high', 'Private note');

-- ---------------------------------------------------------------------------
-- O. The owner's view
-- ---------------------------------------------------------------------------
select t29.as_user(t29.p(1));
select t29.ok((select string_agg(f.member_id::text || '|' || f.fitness_visible || '|' || coalesce(f.workout_sessions::text, '-') || '|'
                                 || coalesce(f.workout_minutes::text, '-') || '|' || coalesce(f.training_load::text, '-') || '|'
                                 || coalesce((t29.today() - f.last_workout_date)::text, '-') || '|'
                                 || coalesce(f.matches::text, '-') || '|' || coalesce((t29.today() - f.last_match_date)::text, '-'),
                                 ',' order by f.member_role = 'owner' desc, f.member_id)
                 from public.club_member_fitness(t29.club('M9 Lions'), t29.today() - 6, t29.today()) f
                where f.user_id in (t29.p(1), t29.p(3), t29.p(4)))
              = t29.mem(1, 'M9 Lions') || '|true|1|20|0.17|0|0|-,'
                || (select string_agg(x, ',' order by x) from unnest(array[
                      t29.mem(3, 'M9 Lions') || '|true|3|180|3.50|0|2|2',
                      t29.mem(4, 'M9 Lions') || '|false|-|-|-|-|-|-']) x),
              'O1 club_member_fitness: owner''s own row visible though hidden; 3 = 3 sessions, 180 min, load 3.50, 2 matches; 4 hidden (all NULL)');
select t29.ok((select array_agg(f.user_id order by f.user_id)
                 from public.club_member_fitness(t29.club('M9 Lions'), t29.today() - 6, t29.today()) f)
              = array[t29.p(1), t29.p(3), t29.p(4), t29.p(8)],
              'O2 active members only (removed 5 and non-members absent)');
select t29.ok((select f.member_role = 'owner' from public.club_member_fitness(t29.club('M9 Lions'), t29.today() - 6, t29.today()) f limit 1),
              'O3 the owner''s row comes first');
select t29.ok((select f.workout_sessions = 4 and f.workout_minutes = 225 and f.training_load = 4.25
                 from public.club_member_fitness(t29.club('M9 Lions'), t29.today() - 10, t29.today()) f
                where f.user_id = t29.p(3)),
              'O4 a wider range (11 days) adds the older workout');
select t29.ok((select f.workout_sessions = 0 and f.workout_minutes = 0 and f.training_load = 0 and f.last_workout_date is null
                      and f.matches = 0 and f.last_match_date is null
                 from public.club_member_fitness(t29.club('M9 Lions'), t29.today() - 30, t29.today() - 29) f
                where f.user_id = t29.p(3)),
              'O5 nothing in the range: zeros and NULL dates (not hidden)');
select t29.ok((select string_agg(w.workout_type || ':' || w.minutes || ':' || w.intensity, ',' order by w.workout_date, w.workout_type)
                 from public.club_member_workouts(t29.club('M9 Lions'), t29.today() - 6, t29.today()) w
                where w.member_id = t29.mem(3, 'M9 Lions'))
              = 'running:30:light,gym:90:high,training:60:moderate',
              'O6 club_member_workouts: the member''s workouts in the range');
select t29.ok((select array_agg(distinct w.member_id order by w.member_id)
                 from public.club_member_workouts(t29.club('M9 Lions'), t29.today() - 6, t29.today()) w)
              = (select array_agg(x order by x) from unnest(array[t29.mem(1, 'M9 Lions'), t29.mem(3, 'M9 Lions'), t29.mem(8, 'M9 Lions')]) x),
              'O7 … none of the hidden member 4 or the removed member 5');
select t29.ok(pg_get_function_result('public.club_member_workouts(uuid, date, date)'::regprocedure) not like '%notes%',
              'O8 club_member_workouts has no notes column');
select t29.ok((select string_agg(a.result || ':' || a.opponent_name || ':' || a.club_name || ':' || a.bat_runs || '/' || a.bat_balls
                                 || ':' || a.bowl_balls || '-' || a.bowl_runs || '-' || a.bowl_wickets, ',' order by a.starts_at desc)
                 from public.club_member_match_activity(t29.club('M9 Lions'), t29.today() - 6, t29.today()) a
                where a.member_id = t29.mem(3, 'M9 Lions'))
              = 'won:M9 Kings:M9 Lions:40/30:18-20-2,tied:M9 Kings:M9 Lions:12/10:0-0-0',
              'O9 club_member_match_activity: confirmed only (not m3), the confirmed version (m4 v2), own figures, newest first');
select t29.ok(t29.n(format('select * from public.club_member_match_activity(%L, %L, %L) where member_id = %L',
                           t29.club('M9 Lions'), t29.today() - 6, t29.today(), t29.mem(4, 'M9 Lions'))) = 0,
              'O10 … nothing for the hidden member 4 (who batted in m1)');
select t29.ok(t29.n(format('select * from public.club_member_match_activity(%L, %L, %L)',
                           t29.club('M9 Lions'), t29.today() - 1, t29.today())) = 0,
              'O11 a range without confirmed matches (m3 only submitted): no rows');
select t29.ok(t29.n(format('select * from public.club_member_match_activity(%L, %L, %L)',
                           t29.club('M9 Lions'), t29.today() - 45, t29.today() - 35)) = 1,
              'O12 an older range finds m2 only');
select t29.okq(format('select * from public.club_member_fitness(%L, %L, %L)', t29.club('M9 Lions'), t29.today() - 30, t29.today()),
               'O13 a 31-day range is allowed');
select t29.err(format('select * from public.club_member_fitness(%L, %L, %L)', t29.club('M9 Lions'), t29.today() - 31, t29.today()),
               '22023', 'fitness: invalid range', 'O14 a 32-day range is refused (fitness)');
select t29.err(format('select * from public.club_member_workouts(%L, %L, %L)', t29.club('M9 Lions'), t29.today() - 31, t29.today()),
               '22023', 'fitness: invalid range', 'O15 … (workouts)');
select t29.err(format('select * from public.club_member_match_activity(%L, %L, %L)', t29.club('M9 Lions'), t29.today() - 31, t29.today()),
               '22023', 'fitness: invalid range', 'O16 … (match activity)');
select t29.err(format('select * from public.club_member_fitness(%L, null, %L)', t29.club('M9 Lions'), t29.today()),
               '22023', 'fitness: invalid range', 'O17 an open range is refused');
select t29.err(format('select * from public.club_member_workouts(%L, %L, %L)', t29.club('M9 Lions'), t29.today(), t29.today() - 1),
               '22023', 'fitness: invalid range', 'O18 from after to is refused');

-- Kings' owner sees their own player 7 (lost m1, bowled 24-30-1), not Lions.
select t29.as_user(t29.p(2));
select t29.ok((select string_agg(a.result || ':' || a.opponent_name || ':' || a.bat_runs || '/' || a.bat_balls || ':'
                                 || a.bowl_balls || '-' || a.bowl_runs || '-' || a.bowl_wickets, ',')
                 from public.club_member_match_activity(t29.club('M9 Kings'), t29.today() - 6, t29.today()) a
                where a.member_id = t29.mem(7, 'M9 Kings'))
              = 'lost:M9 Lions:0/0:24-30-1',
              'O19 the other side''s view: lost, opponent Lions, their own bowling');
select t29.err(format('select * from public.club_member_fitness(%L, %L, %L)', t29.club('M9 Lions'), t29.today() - 6, t29.today()),
               '42501', 'fitness: not allowed', 'O20 another club''s owner: not allowed (fitness)');
select t29.err(format('select * from public.club_member_workouts(%L, %L, %L)', t29.club('M9 Lions'), t29.today() - 6, t29.today()),
               '42501', 'fitness: not allowed', 'O21 … (workouts)');
select t29.err(format('select * from public.club_member_match_activity(%L, %L, %L)', t29.club('M9 Lions'), t29.today() - 6, t29.today()),
               '42501', 'fitness: not allowed', 'O22 … (match activity)');
select t29.as_user(t29.p(3));
select t29.err(format('select * from public.club_member_fitness(%L, %L, %L)', t29.club('M9 Lions'), t29.today() - 6, t29.today()),
               '42501', 'fitness: not allowed', 'O23 a member (not the owner): not allowed');
select t29.err(format('select * from public.club_member_workouts(%L, %L, %L)', t29.club('M9 Lions'), t29.today() - 6, t29.today()),
               '42501', 'fitness: not allowed', 'O24 … (workouts)');
select t29.err(format('select * from public.club_member_match_activity(%L, %L, %L)', t29.club('M9 Lions'), t29.today() - 6, t29.today()),
               '42501', 'fitness: not allowed', 'O25 … (match activity)');
select t29.as_user(t29.p(6));
select t29.err(format('select * from public.club_member_fitness(%L, %L, %L)', t29.club('M9 Lions'), t29.today() - 6, t29.today()),
               '42501', 'fitness: not allowed', 'O26 a non-member: not allowed');
select t29.as_user(t29.p(1));
select t29.err(format('select * from public.club_member_fitness(%L, %L, %L)', gen_random_uuid(), t29.today() - 6, t29.today()),
               '42501', 'fitness: not allowed', 'O27 an unknown club: not allowed');
select t29.err(format('select * from public.club_member_fitness(null, %L, %L)', t29.today() - 6, t29.today()),
               '42501', 'fitness: not allowed', 'O28 a NULL club: not allowed');

-- Member 4 shows their statistics again: visible at once.
select t29.as_user(t29.p(4));
select public.set_profile_visibility(null, true);
select t29.as_user(t29.p(1));
select t29.ok((select f.fitness_visible and f.workout_sessions = 1 and f.training_load = 1.25 and f.matches = 1
                 from public.club_member_fitness(t29.club('M9 Lions'), t29.today() - 6, t29.today()) f
                where f.user_id = t29.p(4))
              and t29.n(format('select * from public.club_member_match_activity(%L, %L, %L) where member_id = %L',
                               t29.club('M9 Lions'), t29.today() - 6, t29.today(), t29.mem(4, 'M9 Lions'))) = 1,
              'O29 show_stats back on: member 4''s figures and match show');

-- A member removed from the club drops out of the view.
select t29.as_user(t29.p(1));
select status from public.remove_club_member(t29.mem(4, 'M9 Lions'));
select t29.ok(t29.n(format('select * from public.club_member_fitness(%L, %L, %L) where user_id = %L',
                           t29.club('M9 Lions'), t29.today() - 6, t29.today(), t29.p(4))) = 0
              and t29.n(format('select * from public.club_member_workouts(%L, %L, %L) where member_id = %L',
                               t29.club('M9 Lions'), t29.today() - 6, t29.today(), t29.mem(4, 'M9 Lions'))) = 0,
              'O30 after removal the member is no longer in the owner''s view');

-- ---------------------------------------------------------------------------
-- D. Account deletion
-- ---------------------------------------------------------------------------
reset role;
set local role service_role;
select (public.delete_account_data(t29.p(8)))->>'profile' as deleted;
reset role;
select t29.ok((select count(*) from public.player_workouts where user_id = t29.p(8)) = 0,
              'D1 delete_account_data removes the person''s workouts (cascade)');
delete from auth.users where id = t29.p(10);
select t29.ok((select count(*) from public.player_workouts where user_id = t29.p(10)) = 0,
              'D2 deleting the auth user removes their workouts (cascade)');
select t29.ok((select count(*) from public.player_workouts where user_id = t29.p(3)) = 6,
              'D3 the other players'' workouts stay');
set local role authenticated;
select t29.as_user(t29.p(1));
select t29.ok(t29.n(format('select * from public.club_member_fitness(%L, %L, %L) where user_id = %L',
                           t29.club('M9 Lions'), t29.today() - 6, t29.today(), t29.p(8))) = 0,
              'D4 the deleted member is gone from the owner''s view');
reset role;

do $$ begin raise notice 'ALL M9 FITNESS CHECKS PASSED'; end $$;
rollback;
