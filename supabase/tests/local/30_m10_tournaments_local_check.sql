-- CricEco · LOCAL TEST ONLY — migration 35 (M10 Tournaments) on a DISPOSABLE
-- database after migrations 1–34 (+ the D1 location seed and the Storage
-- stand-in of 26_m5_m6_media_local_check.sh) and migration 35: the
-- "postgres" database of a throwaway container of the real Supabase image
-- (fixture copy without its auth guard), or a plain PostgreSQL database with
-- 00_auth_stub.sql and 02_legacy_profiles_fixture.sql.
-- Synthetic data only (people e10a0000-…, matches e10a00aa-…, scorer clients
-- ec10…); everything runs in ONE transaction that is ROLLED BACK at the end,
-- so nothing is left behind.
-- Run with psql:  psql -X -v ON_ERROR_STOP=1 -f 30_m10_tournaments_local_check.sql
-- Every check prints "PASS: …"; the first failure stops the run ("FAIL: …").
-- Inside one transaction now() does not move, so where the draw's seeding
-- (approval order) matters the test spaces decided_at out directly.
-- Two-session races (the last slot) are run separately (docs/M10_TOURNAMENTS.md).
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
  if to_regclass('public.tournaments') is null then
    raise exception 'apply migration 35 first';
  end if;
end $$;

create schema t30;
grant usage on schema t30 to anon, authenticated, service_role;

create function t30.ok(p_cond boolean, p_name text) returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_name; end if;
  raise notice 'PASS: %', p_name;
end $$;

-- PASS when p_sql fails with exactly SQLSTATE p_state and a message LIKE p_like.
create function t30.err(p_sql text, p_state text, p_like text, p_name text) returns void language plpgsql as $$
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

-- Both spellings: the image's own auth.uid() reads request.jwt.claim.sub only.
create function t30.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true),
         set_config('request.jwt.claim.sub', p_uid::text, true);
$$;
create function t30.as_nobody() returns void language sql as $$
  select set_config('request.jwt.claims', '', true), set_config('request.jwt.claim.sub', '', true);
$$;
create function t30.p(p_n int) returns uuid language sql immutable as $$
  select ('e10a0000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
$$;
create function t30.m(p_n int) returns uuid language sql immutable as $$
  select ('e10a00aa-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
$$;
create function t30.cl(p_n int) returns uuid language sql immutable as $$
  select ('ec100000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
$$;
create function t30.today() returns date language sql stable as $$
  select (now() at time zone 'Asia/Karachi')::date;
$$;
-- Named ids kept across role switches.
create table t30.ids (k text primary key, v uuid not null);
create function t30.put(p_k text, p_v uuid) returns uuid language sql security definer set search_path = '' as $$
  insert into t30.ids (k, v) values (p_k, p_v) on conflict (k) do update set v = excluded.v returning v;
$$;
create function t30.id(p_k text) returns uuid language sql stable security definer set search_path = '' as $$
  select v from t30.ids where k = p_k;
$$;
create function t30.club(p_name text) returns uuid language sql stable security definer set search_path = '' as $$
  select c.id from public.clubs c where c.name = p_name;
$$;
-- Person n's membership in a club.
create function t30.mem(p_n int, p_club text) returns uuid language sql stable security definer set search_path = '' as $$
  select m.id from public.club_members m join public.clubs c on c.id = m.club_id
   where c.name = p_club and m.user_id = ('e10a0000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
$$;
-- A squad: the first 11 people play, the next 4 are substitutes.
create function t30.squad(p_club text, p_people int[]) returns jsonb language sql stable as $$
  select jsonb_agg(jsonb_build_object('member_id', t30.mem(u.n, p_club),
                                      'selection', case when u.o <= 11 then 'playing' else 'sub' end) order by u.o)
    from unnest(p_people) with ordinality u(n, o);
$$;
create function t30.range(p_from int, p_to int) returns int[] language sql immutable as $$
  select array(select generate_series(p_from, p_to));
$$;
create function t30.notes(p_recipient uuid, p_type text) returns int language sql stable security definer set search_path = '' as $$
  select count(*)::int from public.notifications n where n.recipient_id = p_recipient and n.type = p_type;
$$;
create function t30.note(p_recipient uuid, p_type text) returns public.notifications
language sql stable security definer set search_path = '' as $$
  select n.* from public.notifications n where n.recipient_id = p_recipient and n.type = p_type
   order by n.created_at desc, n.id desc limit 1;
$$;
create function t30.reg(p_id uuid) returns public.tournament_registrations
language sql stable security definer set search_path = '' as $$
  select r.* from public.tournament_registrations r where r.id = p_id;
$$;
create function t30.tour(p_id uuid) returns public.tournaments
language sql stable security definer set search_path = '' as $$
  select t.* from public.tournaments t where t.id = p_id;
$$;
create function t30.fx(p_tid uuid, p_round int, p_match int) returns public.tournament_fixtures
language sql stable security definer set search_path = '' as $$
  select f.* from public.tournament_fixtures f where f.tournament_id = p_tid and f.round_no = p_round and f.match_no = p_match;
$$;
-- notification_category (closed to the API roles), under any role.
create function t30.cat(p_type text) returns text language sql stable security definer set search_path = '' as $$
  select public.notification_category(p_type);
$$;
-- Expected values read past the closed tables (definer), under any role.
create function t30.hosted(p_club uuid) returns uuid[] language sql stable security definer set search_path = '' as $$
  select array_agg(t.id order by t.created_at desc, t.id) from public.tournaments t where t.organizer_club_id = p_club;
$$;
create function t30.all_tours() returns int language sql stable security definer set search_path = '' as $$
  select count(*)::int from public.tournaments;
$$;
create function t30.regs_of_tournament(p_tid uuid) returns uuid[] language sql stable security definer set search_path = '' as $$
  select array_agg(r.id order by r.submitted_at, r.id) from public.tournament_registrations r where r.tournament_id = p_tid;
$$;
create function t30.regs_of_club(p_club uuid) returns uuid[] language sql stable security definer set search_path = '' as $$
  select array_agg(r.id order by r.submitted_at desc, r.id) from public.tournament_registrations r where r.club_id = p_club;
$$;
create function t30.count_sql(p_sql text) returns int language plpgsql as $$
declare
  n int;
begin
  execute 'select count(*) from (' || p_sql || ') s' into n;
  return n;
end $$;
create function t30.make_person(p_n int, p_city text default 'Lahore') returns uuid language plpgsql as $$
declare
  v uuid := t30.p(p_n);
begin
  insert into auth.users (id, email) values (v, format('m10p%s@local.test', p_n));
  insert into public.profiles (id) values (v) on conflict (id) do nothing; -- the sign-up trigger made it already
  insert into public.current_addresses (user_id, city, area, address) values (v, p_city, 'Gulberg', 'Street 1');
  insert into public.permanent_addresses (user_id, city, area, address) values (v, p_city, 'Gulberg', 'Street 1');
  update public.profiles
     set full_name = format('M10 Person %s', lpad(p_n::text, 3, '0')),
         phone = format('+923%s', lpad((740000000 + p_n)::text, 9, '0')),
         date_of_birth = date '2000-05-01', profile_completed = true
   where id = v;
  return v;
end $$;
-- An owner, the club, and members first..last (active players).
create function t30.make_club(p_owner int, p_name text, p_city text, p_first int, p_last int) returns uuid
language plpgsql as $$
declare
  v_club uuid;
  n      int;
begin
  perform t30.make_person(p_owner, p_city);
  insert into public.clubs (owner_id, name, city, club_type) values (t30.p(p_owner), p_name, p_city, 'corporate')
  returning id into v_club;
  if p_first is not null then
    for n in p_first .. p_last loop
      perform t30.make_person(n, p_city);
      insert into public.club_members (club_id, user_id, member_role, status) values (v_club, t30.p(n), 'player', 'active');
    end loop;
  end if;
  return v_club;
end $$;
-- A tournament straight into the table (the draw tests), with n approved
-- entries of clubs "M10 C01" … in approval order.
create function t30.seeded(p_type text, p_n int) returns uuid language plpgsql as $$
declare
  v_tid uuid;
  k     int;
begin
  insert into public.tournaments (organizer_club_id, name, city, ground, format, tournament_type,
                                  start_date, end_date, registration_deadline, max_teams)
  values (t30.club('M10 Hosts'), format('Draw %s %s', p_type, p_n), 'Lahore', 'Draw Ground', 't20', p_type,
          t30.today() + 10, t30.today() + 12, t30.today() + 5, 32)
  returning id into v_tid;
  for k in 1 .. p_n loop
    insert into public.tournament_registrations (tournament_id, club_id, team_name, status, decided_at)
    values (v_tid, t30.club(format('M10 C%s', lpad(k::text, 2, '0'))), format('C%s XI', k), 'approved',
            now() + make_interval(secs => k));
  end loop;
  return v_tid;
end $$;
-- The FixtureEngine knockout invariants for n entries: 'ok' or what differs.
create function t30.check_knockout(p_n int) returns text language plpgsql as $$
declare
  v_tid    uuid := t30.seeded('knockout', p_n);
  v_size   int := 2;
  v_rounds int := 1;
  v_seed   uuid[];
  v_out    record;
  v_names  text[] := array['Final', 'Semifinal', 'Quarterfinal', 'Round of 16', 'Round of 32'];
  v_bad    int;
  m        int;
  f        public.tournament_fixtures;
begin
  while v_size < p_n loop v_size := v_size * 2; v_rounds := v_rounds + 1; end loop;
  v_seed := array(select r.id from public.tournament_registrations r where r.tournament_id = v_tid order by r.decided_at);
  perform t30.as_user(t30.p(1));
  select * into v_out from public.generate_tournament_fixtures(v_tid);
  if v_out.outcome <> 'generated' or v_out.fixture_count <> v_size - 1 then
    return format('n=%s: outcome %s count %s (want %s)', p_n, v_out.outcome, v_out.fixture_count, v_size - 1);
  end if;
  if (select count(distinct round_no) from public.tournament_fixtures where tournament_id = v_tid) <> v_rounds
     or exists (select 1 from public.tournament_fixtures x where x.tournament_id = v_tid
                 and x.round_name <> v_names[v_rounds - x.round_no + 1]) then
    return format('n=%s: rounds / names', p_n);
  end if;
  for m in 1 .. v_size / 2 loop
    f := t30.fx(v_tid, 1, m);
    if f.home_registration_id is distinct from (case when 2 * m - 1 <= p_n then v_seed[2 * m - 1] end)
       or f.home_bye <> (2 * m - 1 > p_n)
       or f.away_registration_id is distinct from (case when 2 * m <= p_n then v_seed[2 * m] end)
       or f.away_bye <> (2 * m > p_n) then
      return format('n=%s: first-round fixture %s', p_n, m);
    end if;
  end loop;
  -- n - 1 real matches; size - n BYE walkovers, all resolved; the Final open.
  select count(*) into v_bad from public.tournament_fixtures x
   where x.tournament_id = v_tid and not x.home_bye and not x.away_bye;
  if v_bad <> p_n - 1 then
    return format('n=%s: %s real matches (want %s)', p_n, v_bad, p_n - 1);
  end if;
  if exists (select 1 from public.tournament_fixtures x where x.tournament_id = v_tid and x.decided_at is null
              and (x.home_bye or x.away_bye)
              and (x.home_bye or x.home_registration_id is not null) and (x.away_bye or x.away_registration_id is not null))
     or exists (select 1 from public.tournament_fixtures x where x.tournament_id = v_tid and x.decided_at is not null
                 and not (x.home_bye or x.away_bye)) then
    return format('n=%s: BYE walkovers', p_n);
  end if;
  -- Every walkover's winner sits in its next fixture's slot.
  if exists (select 1 from public.tournament_fixtures x
               join public.tournament_fixtures nx on nx.id = x.next_fixture_id
              where x.tournament_id = v_tid and x.decided_at is not null
                and not (case x.next_slot when 'home' then nx.home_registration_id is not distinct from x.winner_registration_id
                                                         and nx.home_bye = x.winner_bye
                                          else nx.away_registration_id is not distinct from x.winner_registration_id
                                               and nx.away_bye = x.winner_bye end)) then
    return format('n=%s: walkover winners not moved on', p_n);
  end if;
  if (select x.decided_at from public.tournament_fixtures x where x.tournament_id = v_tid and x.round_no = v_rounds) is not null
     or (select count(*) from public.tournament_fixtures x where x.tournament_id = v_tid and x.round_no = v_rounds) <> 1 then
    return format('n=%s: the Final', p_n);
  end if;
  if (select count(*) from public.tournament_fixtures x, lateral (values (x.home_registration_id), (x.away_registration_id)) s(r)
       where x.tournament_id = v_tid and x.round_no = 1 and s.r is not null) <> p_n
     or (select count(distinct s.r) from public.tournament_fixtures x, lateral (values (x.home_registration_id), (x.away_registration_id)) s(r)
          where x.tournament_id = v_tid and x.round_no = 1 and s.r is not null) <> p_n then
    return format('n=%s: every entry once in the first round', p_n);
  end if;
  if (select status from public.tournaments where id = v_tid) <> 'registration_closed' then
    return format('n=%s: status', p_n);
  end if;
  return 'ok';
end $$;
create function t30.check_league(p_n int) returns text language plpgsql as $$
declare
  v_tid uuid := t30.seeded('league', p_n);
  v_out record;
begin
  perform t30.as_user(t30.p(1));
  select * into v_out from public.generate_tournament_fixtures(v_tid);
  if v_out.outcome <> 'generated' or v_out.fixture_count <> p_n * (p_n - 1) / 2 then
    return format('n=%s: outcome %s count %s', p_n, v_out.outcome, v_out.fixture_count);
  end if;
  if exists (select 1 from public.tournament_fixtures x where x.tournament_id = v_tid
              and (x.round_no <> 1 or x.round_name <> 'League Stage' or x.home_bye or x.away_bye
                   or x.home_registration_id is null or x.away_registration_id is null or x.decided_at is not null
                   or x.next_fixture_id is not null))
     or (select count(distinct least(x.home_registration_id::text, x.away_registration_id::text) || greatest(x.home_registration_id::text, x.away_registration_id::text))
           from public.tournament_fixtures x where x.tournament_id = v_tid) <> p_n * (p_n - 1) / 2
     or (select array_agg(x.match_no order by x.match_no) from public.tournament_fixtures x where x.tournament_id = v_tid)
        <> array(select generate_series(1, p_n * (p_n - 1) / 2))::smallint[] then
    return format('n=%s: pairs', p_n);
  end if;
  if (select count(*) from public.tournament_fixtures(v_tid) x where x.state = 'ready') <> p_n * (p_n - 1) / 2 then
    return format('n=%s: states', p_n);
  end if;
  return 'ok';
end $$;
grant select on t30.ids to anon, authenticated, service_role;
grant execute on all functions in schema t30 to anon, authenticated, service_role;

-- People / clubs:
--   1 owns "M10 Hosts" (Lahore; the organizer), members 11, 12 (12 removed later)
--   2 owns "M10 Lions" (Karachi), members 101–118
--   3 owns "M10 Kings" (Lahore), members 201–216 (+ 117, also a Lions member); mutes "matches"
--   4 owns "M10 Riders" (Lahore), members 301–315; mutes "join_requests" and "challenges"
--   8 owns "M10 Eagles" (Lahore), members 501–515
--   5 owns "M10 Bulk" (Multan), no members (the create limits)
--   6 a player in no club; 9 a Lions-less owner of "M10 Other" (Quetta)
--   401–432 own "M10 C01" … "M10 C32" (the draw tests)
select t30.make_club(1, 'M10 Hosts', 'Lahore', 11, 12);
select t30.make_club(2, 'M10 Lions', 'Karachi', 101, 118);
select t30.make_club(3, 'M10 Kings', 'Lahore', 201, 216);
select t30.make_club(4, 'M10 Riders', 'Lahore', 301, 315);
select t30.make_club(8, 'M10 Eagles', 'Lahore', 501, 515);
select t30.make_club(5, 'M10 Bulk', 'Multan', null, null);
select t30.make_club(9, 'M10 Other', 'Quetta', null, null);
select t30.make_person(6);
select count(*) from (select t30.make_club(400 + k, format('M10 C%s', lpad(k::text, 2, '0')), 'Lahore', null, null)
                        from generate_series(1, 32) k) s;
insert into public.club_members (club_id, user_id, member_role, status)
values (t30.club('M10 Kings'), t30.p(117), 'player', 'active');
insert into public.notification_preferences (user_id, join_requests, challenges, matches, results, announcements)
values (t30.p(3), true, true, false, true, true), (t30.p(4), false, false, true, true, true);
-- 118 is injured (no end date); 116 was injured until yesterday.
insert into public.player_availability (user_id, status, reason, until_date)
values (t30.p(118), 'injured', 'injury', null), (t30.p(116), 'injured', 'injury', t30.today() - 1);
insert into public.teams (club_id, name, format) values (t30.club('M10 Lions'), 'Lions First XI', 't20');
insert into public.teams (club_id, name, format, status, archived_at)
values (t30.club('M10 Lions'), 'Lions Old XI', 't20', 'archived', now());
insert into public.teams (club_id, name, format) values (t30.club('M10 Kings'), 'Kings XI', 't20');
select t30.put('lionsteam', (select id from public.teams where name = 'Lions First XI'));
select t30.put('lionsold', (select id from public.teams where name = 'Lions Old XI'));
select t30.put('kingsteam', (select id from public.teams where name = 'Kings XI'));

-- ---------------------------------------------------------------------------
-- A. Access
-- ---------------------------------------------------------------------------
create table t30.api (sig text primary key, call text not null);
insert into t30.api (sig, call) values
  ('public.create_tournament(uuid, text, text, text, text, integer, text, date, date, date, integer, integer, integer, text, text[])',
   'select * from public.create_tournament(gen_random_uuid(), ''x'', ''Lahore'', ''G'', ''t20'', null, ''league'', current_date + 5, current_date + 6, current_date + 1, 4)'),
  ('public.my_hosted_tournaments(uuid)', 'select * from public.my_hosted_tournaments(gen_random_uuid())'),
  ('public.browse_tournaments(text)', 'select * from public.browse_tournaments()'),
  ('public.tournament_detail(uuid)', 'select * from public.tournament_detail(gen_random_uuid())'),
  ('public.tournament_hub_stats(uuid)', 'select * from public.tournament_hub_stats(gen_random_uuid())'),
  ('public.tournament_teams(uuid)', 'select * from public.tournament_teams(gen_random_uuid())'),
  ('public.tournament_registration_squad(uuid)', 'select * from public.tournament_registration_squad(gen_random_uuid())'),
  ('public.submit_tournament_registration(uuid, uuid, text, uuid, jsonb, uuid, uuid, uuid, boolean)',
   'select * from public.submit_tournament_registration(gen_random_uuid(), gen_random_uuid(), ''X'', null, ''[]'', null, null, null, true)'),
  ('public.decide_tournament_registration(uuid, boolean)', 'select * from public.decide_tournament_registration(gen_random_uuid(), true)'),
  ('public.remove_tournament_team(uuid)', 'select * from public.remove_tournament_team(gen_random_uuid())'),
  ('public.my_tournament_registrations(uuid, text)', 'select * from public.my_tournament_registrations(gen_random_uuid())'),
  ('public.generate_tournament_fixtures(uuid)', 'select * from public.generate_tournament_fixtures(gen_random_uuid())'),
  ('public.tournament_fixtures(uuid)', 'select * from public.tournament_fixtures(gen_random_uuid())'),
  ('public.tournament_points_table(uuid)', 'select * from public.tournament_points_table(gen_random_uuid())'),
  ('public.tournament_awards(uuid)', 'select * from public.tournament_awards(gen_random_uuid())');
grant select on t30.api to anon, authenticated, service_role;

select t30.ok((select bool_and(has_function_privilege('authenticated', sig::regprocedure, 'execute')
                               and not has_function_privilege('anon', sig::regprocedure, 'execute'))
                 from t30.api) and (select count(*) from t30.api) = 15,
              'A1 the 15 app functions: authenticated may execute, anon may not');
select t30.ok(has_function_privilege('service_role', 'public.record_tournament_fixture_result(uuid, uuid, uuid)', 'execute')
              and not has_function_privilege('authenticated', 'public.record_tournament_fixture_result(uuid, uuid, uuid)', 'execute')
              and not has_function_privilege('anon', 'public.record_tournament_fixture_result(uuid, uuid, uuid)', 'execute'),
              'A2 record_tournament_fixture_result: service_role only');
select t30.ok(not (select bool_or(has_function_privilege(r, f::regprocedure, 'execute'))
                     from unnest(array['public.tournament_status_now(text, date)',
                                       'public.tournament_list(uuid, uuid, uuid, boolean, text)',
                                       'public.tournament_registration_rows(uuid, uuid, uuid)',
                                       'public.tournament_fixture_decide(uuid, uuid, boolean)',
                                       'public.tournament_advance_byes(uuid)', 'public.tournament_standings(uuid)',
                                       'public.tournament_registrations_validate()',
                                       'public.tournament_registration_players_validate()']) f,
                          unnest(array['anon', 'authenticated', 'service_role']) r),
              'A3 the 8 helpers: no API role may execute');
select t30.ok(not (select bool_or(has_table_privilege(r, t::regclass, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'))
                     from unnest(array['public.tournaments', 'public.tournament_registrations',
                                       'public.tournament_registration_players', 'public.tournament_fixtures']) t,
                          unnest(array['anon', 'authenticated', 'service_role']) r)
              and (select bool_and(c.relrowsecurity) from pg_class c
                    where c.oid in ('public.tournaments'::regclass, 'public.tournament_registrations'::regclass,
                                    'public.tournament_registration_players'::regclass, 'public.tournament_fixtures'::regclass))
              and not exists (select 1 from pg_policy p where p.polrelid in ('public.tournaments'::regclass,
                                    'public.tournament_registrations'::regclass, 'public.tournament_registration_players'::regclass,
                                    'public.tournament_fixtures'::regclass)),
              'A4 the 4 tables: RLS on, no policy, no table privilege for anon / authenticated / service_role');

set local role anon;
select t30.err(a.call, '42501', '%permission denied%', 'A5 anon: ' || split_part(a.sig, '(', 1)) from t30.api a;
reset role;
set local role authenticated;
select t30.as_nobody();
select t30.err(a.call, '42501', 'tournament: not authenticated', 'A6 no signed-in user: ' || split_part(a.sig, '(', 1))
  from t30.api a;
select t30.as_user(t30.p(2));
select t30.err('select * from public.tournaments', '42501', '%permission denied%', 'A7 a signed-in user cannot read tournaments directly');
select t30.err('select * from public.tournament_fixtures', '42501', '%permission denied%', 'A8 … nor the fixtures');
select t30.err('update public.tournament_fixtures set winner_registration_id = null', '42501', '%permission denied%',
               'A9 … nor write a fixture result directly');
select t30.err(format('insert into public.tournament_registrations (tournament_id, club_id, team_name) values (%L, %L, ''X'')',
                      gen_random_uuid(), t30.club('M10 Lions')), '42501', '%permission denied%',
               'A10 … nor insert an entry directly');
select t30.err('select * from public.record_tournament_fixture_result(gen_random_uuid(), gen_random_uuid())',
               '42501', '%permission denied%', 'A11 … nor call the scorer''s result function');
reset role;
set local role service_role;
select t30.err('select * from public.tournament_fixtures', '42501', '%permission denied%',
               'A12 service_role cannot read the fixtures table directly either');
select t30.err('update public.tournament_fixtures set decided_at = now()', '42501', '%permission denied%',
               'A13 … nor write it (only through record_tournament_fixture_result)');
reset role;

-- ---------------------------------------------------------------------------
-- B. Create Tournament
-- ---------------------------------------------------------------------------
set local role authenticated;
select t30.as_user(t30.p(1));
select t30.put('t1', (select tournament_id from public.create_tournament(
  t30.club('M10 Hosts'), '  Spring   Cup ', ' Lahore ', 'Pindi   Ground', 't20', 12, 'knockout',
  t30.today() + 10, t30.today() + 12, t30.today() + 5, 4, 15000, 100000, '  Bring whites.  ',
  array['  Max 4 overs  per bowler ', '', null, 'No   beamers'])));
select t30.ok((select d.name = 'Spring Cup' and d.city = 'Lahore' and d.ground = 'Pindi Ground' and d.format = 't20'
                      and d.custom_overs is null and d.tournament_type = 'knockout' and d.max_teams = 4
                      and d.entry_fee = 15000 and d.prize = 100000 and d.description = 'Bring whites.'
                      and d.rules = array['Max 4 overs per bowler', 'No beamers'] and d.status = 'registration_open'
                      and d.accepts_registrations and d.approved_count = 0 and d.pending_count = 0
                      and d.available_slots = 4 and d.is_organizer and not d.fixtures_generated
                      and d.organizer_name = 'M10 Hosts' and d.my_registration_id is null
                 from public.tournament_detail(t30.id('t1')) d),
              'B1 the owner publishes: trimmed text, overs ignored for T20, blank rules dropped, open, organizer view');
select t30.ok((select created_by from t30.tour(t30.id('t1'))) = t30.p(1), 'B2 created_by is the owner');
select t30.put('t2', (select tournament_id from public.create_tournament(
  t30.club('M10 Hosts'), 'Final Shootout', 'Lahore', 'Model Town', 'custom', 15, 'knockout',
  t30.today(), t30.today(), t30.today(), 2)));
select t30.ok((select d.format = 'custom' and d.custom_overs = 15 and d.entry_fee is null and d.prize is null
                      and d.description = '' and d.rules = '{}' and d.registration_deadline = t30.today()
                 from public.tournament_detail(t30.id('t2')) d),
              'B3 boundaries: start = end = deadline = today, 2 teams, custom 15 overs, no fee / prize');
select t30.put('t3', (select tournament_id from public.create_tournament(
  t30.club('M10 Hosts'), 'League Cup', 'Lahore', 'Bagh-e-Jinnah', 'odi', null, 'league',
  t30.today() + 20, t30.today() + 30, t30.today() + 10, 4, 0, 0)));
select t30.put('t4', (select tournament_id from public.create_tournament(
  t30.club('M10 Hosts'), 'Late Cup', 'Lahore', 'Gaddafi', 't10', null, 'league',
  t30.today() + 3, t30.today() + 4, t30.today(), 32)));
select t30.put('t5', (select tournament_id from public.create_tournament(
  t30.club('M10 Hosts'), 'Deadline Cup', 'Lahore', 'Gaddafi', 'test', null, 'knockout',
  t30.today() + 3, t30.today() + 7, t30.today(), 8)));
select t30.ok((select max_teams = 32 and entry_fee is null from t30.tour(t30.id('t4')))
              and (select entry_fee = 0 and prize = 0 from t30.tour(t30.id('t3'))),
              'B4 32 teams and a fee of 0 are accepted');

select t30.err(format('select * from public.create_tournament(%L, %L, ''Lahore'', ''G'', ''t20'', null, ''league'', %L, %L, %L, 4)',
                      t30.club('M10 Hosts'), v.name, t30.today() + 5, t30.today() + 6, t30.today() + 1),
               '22023', 'tournament: invalid name', 'B5 invalid name: ' || v.label)
  from (values ('blank', '   '), ('61 characters', repeat('n', 61))) v(label, name);
select t30.err(format('select * from public.create_tournament(%L, ''Cup'', %L, %L, %L, %L, %L, %L, %L, %L, %L)',
                      t30.club('M10 Hosts'), v.city, v.ground, v.format, v.overs, v.ttype, v.s, v.e, v.d, v.mx),
               '22023', v.msg, 'B6 ' || v.msg)
  from (values
    ('', 'G', 't20', null::int, 'league', t30.today() + 5, t30.today() + 6, t30.today() + 1, 4, 'tournament: invalid city'),
    ('Lahore', ' ', 't20', null, 'league', t30.today() + 5, t30.today() + 6, t30.today() + 1, 4, 'tournament: invalid ground'),
    ('Lahore', 'G', 'T20', null, 'league', t30.today() + 5, t30.today() + 6, t30.today() + 1, 4, 'tournament: invalid format'),
    ('Lahore', 'G', 'custom', null, 'league', t30.today() + 5, t30.today() + 6, t30.today() + 1, 4, 'tournament: invalid overs'),
    ('Lahore', 'G', 'custom', 51, 'league', t30.today() + 5, t30.today() + 6, t30.today() + 1, 4, 'tournament: invalid overs'),
    ('Lahore', 'G', 't20', null, 'round_robin', t30.today() + 5, t30.today() + 6, t30.today() + 1, 4, 'tournament: invalid type'),
    ('Lahore', 'G', 't20', null, 'league', null, t30.today() + 6, t30.today() + 1, 4, 'tournament: invalid start date'),
    ('Lahore', 'G', 't20', null, 'league', t30.today() - 1, t30.today() + 6, t30.today() - 1, 4, 'tournament: start date in the past'),
    ('Lahore', 'G', 't20', null, 'league', t30.today() + 366, t30.today() + 367, t30.today() + 1, 4, 'tournament: start date too far ahead'),
    ('Lahore', 'G', 't20', null, 'league', t30.today() + 5, null, t30.today() + 1, 4, 'tournament: invalid end date'),
    ('Lahore', 'G', 't20', null, 'league', t30.today() + 5, t30.today() + 4, t30.today() + 1, 4, 'tournament: end date before start date'),
    ('Lahore', 'G', 't20', null, 'league', t30.today() + 5, t30.today() + 186, t30.today() + 1, 4, 'tournament: tournament too long'),
    ('Lahore', 'G', 't20', null, 'league', t30.today() + 5, t30.today() + 6, null, 4, 'tournament: invalid deadline'),
    ('Lahore', 'G', 't20', null, 'league', t30.today() + 5, t30.today() + 6, t30.today() - 1, 4, 'tournament: deadline in the past'),
    ('Lahore', 'G', 't20', null, 'league', t30.today() + 5, t30.today() + 6, t30.today() + 6, 4, 'tournament: deadline after start date'),
    ('Lahore', 'G', 't20', null, 'league', t30.today() + 5, t30.today() + 6, t30.today() + 1, 1, 'tournament: invalid max teams'),
    ('Lahore', 'G', 't20', null, 'league', t30.today() + 5, t30.today() + 6, t30.today() + 1, 33, 'tournament: invalid max teams'),
    ('Lahore', 'G', 't20', null, 'league', t30.today() + 5, t30.today() + 6, t30.today() + 1, null, 'tournament: invalid max teams')
  ) v(city, ground, format, overs, ttype, s, e, d, mx, msg);
select t30.err(format('select * from public.create_tournament(%L, ''Cup'', ''Lahore'', ''G'', ''t20'', null, ''league'', %L, %L, %L, 4, %s, %s, %L, %L)',
                      t30.club('M10 Hosts'), t30.today() + 5, t30.today() + 6, t30.today() + 1,
                      coalesce(v.fee::text, 'null'), coalesce(v.prize::text, 'null'), v.descr, v.rules),
               '22023', v.msg, 'B7 ' || v.msg || ' (' || v.label || ')')
  from (values
    ('fee -1', -1, null::int, null::text, null::text, 'tournament: invalid entry fee'),
    ('fee 10,000,000', 10000000, null, null, null, 'tournament: invalid entry fee'),
    ('prize 100,000,000', null, 100000000, null, null, 'tournament: invalid prize'),
    ('501 characters', null, null, repeat('d', 501), null, 'tournament: invalid description'),
    ('21 rules', null, null, null, (select array_agg('rule ' || g)::text from generate_series(1, 21) g), 'tournament: invalid rules'),
    ('a 201-character rule', null, null, null, array[repeat('r', 201)]::text, 'tournament: invalid rules')
  ) v(label, fee, prize, descr, rules, msg);
select t30.err(format('select * from public.create_tournament(%L, ''Cup'', ''Lahore'', ''G'', ''t20'', null, ''league'', %L, %L, %L, 4)',
                      v.club, t30.today() + 5, t30.today() + 6, t30.today() + 1),
               '42501', 'tournament: not allowed', 'B8 not allowed: ' || v.label)
  from (values ('another owner''s club', t30.club('M10 Lions')), ('an unknown club', gen_random_uuid())) v(label, club);
select t30.as_user(t30.p(11));
select t30.err(format('select * from public.create_tournament(%L, ''Cup'', ''Lahore'', ''G'', ''t20'', null, ''league'', %L, %L, %L, 4)',
                      t30.club('M10 Hosts'), t30.today() + 5, t30.today() + 6, t30.today() + 1),
               '42501', 'tournament: not allowed', 'B9 a member of the club (not its owner) cannot host');
-- Limits: 5 new per 24 hours, 20 not completed.
select t30.as_user(t30.p(5));
select count(*) from (select public.create_tournament(t30.club('M10 Bulk'), 'Bulk ' || g, 'Multan', 'G', 't20', null, 'league',
                                                      t30.today() + 5, t30.today() + 6, t30.today() + 1, 4)
                        from generate_series(1, 5) g) s;
select t30.err(format('select * from public.create_tournament(%L, ''Bulk 6'', ''Multan'', ''G'', ''t20'', null, ''league'', %L, %L, %L, 4)',
                      t30.club('M10 Bulk'), t30.today() + 5, t30.today() + 6, t30.today() + 1),
               'P0001', 'tournament: too many tournaments, try later', 'B10 a 6th tournament within 24 hours is refused');
reset role;
insert into public.tournaments (organizer_club_id, name, city, ground, format, tournament_type, start_date, end_date,
                                registration_deadline, max_teams, created_at)
select t30.club('M10 Bulk'), 'Old ' || g, 'Multan', 'G', 't20', 'league', t30.today() + 5, t30.today() + 6, t30.today(), 4,
       now() - interval '2 days'
  from generate_series(1, 15) g;
set local role authenticated;
select t30.as_user(t30.p(5));
select t30.err(format('select * from public.create_tournament(%L, ''Bulk 21'', ''Multan'', ''G'', ''t20'', null, ''league'', %L, %L, %L, 4)',
                      t30.club('M10 Bulk'), t30.today() + 5, t30.today() + 6, t30.today() + 1),
               'P0001', 'tournament: too many tournaments', 'B11 a 21st tournament not yet completed is refused');
reset role;
select t30.err(format('insert into public.tournaments (organizer_club_id, name, city, ground, format, tournament_type, start_date, end_date, registration_deadline, max_teams) values (%L, ''X'', ''Lahore'', ''G'', ''t20'', ''league'', %L, %L, %L, 4)',
                      t30.club('M10 Hosts'), t30.today() + 5, t30.today() + 6, t30.today() - 1),
               '23514', '%tournaments_deadline_not_past%', 'B12 the table refuses a deadline before its creation day');
select t30.err(format('insert into public.tournaments (organizer_club_id, name, city, ground, format, custom_overs, tournament_type, start_date, end_date, registration_deadline, max_teams) values (%L, ''X'', ''Lahore'', ''G'', ''t20'', 10, ''league'', %L, %L, %L, 4)',
                      t30.club('M10 Hosts'), t30.today() + 5, t30.today() + 6, t30.today() + 1),
               '23514', '%tournaments_overs_follow_format%', 'B13 … and overs without the custom format');

-- ---------------------------------------------------------------------------
-- C. My Tournaments, Browse, Details
-- ---------------------------------------------------------------------------
set local role authenticated;
select t30.as_user(t30.p(2));
select t30.put('t7', (select tournament_id from public.create_tournament(
  t30.club('M10 Lions'), 'Lions Invitational', 'Karachi', 'National Stadium', 't20', null, 'league',
  t30.today() + 8, t30.today() + 9, t30.today() + 4, 4)));
select t30.as_user(t30.p(4));
select t30.put('t6', (select tournament_id from public.create_tournament(
  t30.club('M10 Riders'), 'Riders Cup', 'Lahore', 'Race Course', 't20', null, 'knockout',
  t30.today() + 8, t30.today() + 9, t30.today() + 4, 4)));
select t30.as_user(t30.p(1));
select t30.ok((select array_agg(h.tournament_id order by h.created_at desc, h.tournament_id)
                 from public.my_hosted_tournaments(t30.club('M10 Hosts')) h)
              = t30.hosted(t30.club('M10 Hosts'))
              and t30.count_sql(format('select * from public.my_hosted_tournaments(%L)', t30.club('M10 Hosts'))) = 5,
              'C1 My Tournaments: the club''s 5 tournaments, newest first');
select t30.err(format('select * from public.my_hosted_tournaments(%L)', t30.club('M10 Lions')),
               '42501', 'tournament: not allowed', 'C2 … not another club''s');
select t30.as_user(t30.p(2));
select t30.ok(not exists (select 1 from public.browse_tournaments() b where b.organizer_club_id = t30.club('M10 Lions'))
              and exists (select 1 from public.browse_tournaments() b where b.tournament_id = t30.id('t1'))
              and exists (select 1 from public.browse_tournaments() b where b.tournament_id = t30.id('t6')),
              'C3 Browse: other clubs'' tournaments, never the caller''s own');
select t30.as_user(t30.p(3));
select t30.ok(exists (select 1 from public.browse_tournaments() b where b.tournament_id = t30.id('t7'))
              and (select bool_and(b.pending_count is null and not b.is_organizer) from public.browse_tournaments() b),
              'C4 … the Lions'' tournament is listed for the Kings; no pending count for non-organizers');
select t30.ok((select count(*) from public.browse_tournaments(' karachi ') b) = 1
              and (select bool_and(b.city = 'Lahore') from public.browse_tournaments('LAHORE') b)
              and t30.count_sql('select * from public.browse_tournaments(''Quetta'')') = 0,
              'C5 Browse by city: case and outer spaces ignored');
select t30.err(format('select * from public.browse_tournaments(%L)', repeat('c', 61)), '22023', 'tournament: invalid city',
               'C6 a 61-character city is refused');
select t30.ok((select array_agg(b.start_date order by b.start_date) = array_agg(b.start_date)
                 from public.browse_tournaments() b), 'C7 Browse: soonest start first');
select t30.as_user(t30.p(6));
select t30.ok(t30.count_sql('select * from public.browse_tournaments()')
              = t30.all_tours() and
              (select count(*) from public.browse_tournaments()) <= 200,
              'C8 a player in no club browses every tournament');
select t30.ok((select d.tournament_id = t30.id('t1') and not d.is_organizer and d.pending_count is null
                 from public.tournament_detail(t30.id('t1')) d), 'C9 Details: any signed-in user, without the pending count');
select t30.err(format('select * from public.tournament_detail(%L)', gen_random_uuid()), 'P0002', 'tournament: not found',
               'C10 Details of an unknown tournament: not found');
reset role;

-- ---------------------------------------------------------------------------
-- D. Registration (Select Team → squad → summary → agree → submit)
-- ---------------------------------------------------------------------------
-- Lions' squad for T1: 101–115, captain 101, vice 102, keeper 103, from the Lions First XI.
set local role authenticated;
select t30.as_user(t30.p(2));
select t30.put('r1lions', (select registration_id from public.submit_tournament_registration(
  t30.id('t1'), t30.club('M10 Lions'), null, t30.id('lionsteam'), t30.squad('M10 Lions', t30.range(101, 115)),
  t30.mem(101, 'M10 Lions'), t30.mem(102, 'M10 Lions'), t30.mem(103, 'M10 Lions'), true)));
select t30.ok((select r.status = 'pending' and r.team_name = 'Lions First XI' and r.team_id = t30.id('lionsteam')
                      and r.player_count = 15 and r.is_my_club and r.club_name = 'M10 Lions' and r.decided_at is null
                 from public.tournament_teams(t30.id('t1')) r where r.registration_id = t30.id('r1lions')),
              'D1 the Lions enter T1: pending, the team''s name, 15 players');
select t30.ok((select array_agg(s.selection || ':' || s.is_captain || s.is_vice_captain || s.is_wicket_keeper order by s.position)
                 from public.tournament_registration_squad(t30.id('r1lions')) s)
              = array['playing:truefalsefalse', 'playing:falsetruefalse', 'playing:falsefalsetrue']
                || array_fill('playing:falsefalsefalse'::text, array[8]) || array_fill('sub:falsefalsefalse'::text, array[4])
              and (select bool_and(s.member_active and s.full_name like 'M10 Person %')
                     from public.tournament_registration_squad(t30.id('r1lions')) s),
              'D2 the squad in pick order with captain, vice-captain and wicket-keeper');
select t30.ok((select d.my_registration_id = t30.id('r1lions') and d.my_registration_status = 'pending'
                 from public.tournament_detail(t30.id('t1')) d), 'D3 Details shows the Lions'' live entry ("View Registration")');
select t30.ok((select n.inbox = 'club_owner' and n.club_id = t30.club('M10 Hosts') and n.subject_id = t30.id('r1lions')
                      and n.dedupe_key = 'tournament:registration:' || t30.id('r1lions')
                      and n.params ->> 'tournament_name' = 'Spring Cup' and n.params ->> 'applicant_name' = 'M10 Lions'
                      and n.params ->> 'team_name' = 'Lions First XI' and n.params ->> 'tournament_id' = t30.id('t1')::text
                 from t30.note(t30.p(1), 'tournament_registration_received') n)
              and t30.notes(t30.p(1), 'tournament_registration_received') = 1
              and t30.cat('tournament_registration_received') = 'join_requests',
              'D4 the organizer''s owner is told (tournament_registration_received, club_owner inbox, join requests)');
select t30.err(format('select * from public.submit_tournament_registration(%L, %L, ''Again'', null, %L, null, null, null, true)',
                      t30.id('t1'), t30.club('M10 Lions'), t30.squad('M10 Lions', t30.range(101, 115))),
               'P0001', 'tournament: already registered', 'D5 one live entry per club');
-- Input rules (the Kings).
select t30.as_user(t30.p(3));
select t30.err(format('select * from public.submit_tournament_registration(%L, %L, ''K'', null, %L, null, null, null, %s)',
                      t30.id('t1'), t30.club('M10 Kings'), t30.squad('M10 Kings', t30.range(201, 215)), v.agree),
               '22023', 'tournament: rules not agreed', 'D6 the rules must be agreed: ' || v.agree)
  from (values ('false'), ('null')) v(agree);
select t30.err(format('select * from public.submit_tournament_registration(%L, %L, ''K'', null, %L, %L, %L, %L, true)',
                      t30.id('t1'), t30.club('M10 Kings'), v.squad, v.cap, v.vice, v.keeper),
               v.state, v.msg, 'D7 ' || v.label)
  from (values
    ('10 + 3', t30.squad('M10 Kings', t30.range(201, 214)) - 10, null::uuid, null::uuid, null::uuid, '23514', 'tournament: squad must be 11 + 4'),
    ('11 + 3', t30.squad('M10 Kings', t30.range(201, 214)), null, null, null, '23514', 'tournament: squad must be 11 + 4'),
    ('12 + 4', t30.squad('M10 Kings', t30.range(201, 215)) || jsonb_build_array(jsonb_build_object('member_id', t30.mem(216, 'M10 Kings'), 'selection', 'playing')), null, null, null, '23514', 'tournament: squad must be 11 + 4'),
    ('a player twice', t30.squad('M10 Kings', array[201, 201, 203, 204, 205, 206, 207, 208, 209, 210, 211, 212, 213, 214, 215]), null, null, null, '22023', 'tournament: invalid squad'),
    ('not an array', '{"member_id": "x"}'::jsonb, null, null, null, '22023', 'tournament: invalid squad'),
    ('a bad selection', jsonb_set(t30.squad('M10 Kings', t30.range(201, 215)), '{0,selection}', '"bench"'), null, null, null, '22023', 'tournament: invalid squad'),
    ('a bad member id', jsonb_set(t30.squad('M10 Kings', t30.range(201, 215)), '{0,member_id}', '"nope"'), null, null, null, '22023', 'tournament: invalid squad'),
    ('captain = vice-captain', t30.squad('M10 Kings', t30.range(201, 215)), t30.mem(201, 'M10 Kings'), t30.mem(201, 'M10 Kings'), null, '22023', 'tournament: invalid captain'),
    ('captain on the bench', t30.squad('M10 Kings', t30.range(201, 215)), t30.mem(215, 'M10 Kings'), null, null, '22023', 'tournament: invalid captain'),
    ('vice-captain on the bench', t30.squad('M10 Kings', t30.range(201, 215)), null, t30.mem(214, 'M10 Kings'), null, '22023', 'tournament: invalid vice-captain'),
    ('keeper not in the squad', t30.squad('M10 Kings', t30.range(201, 215)), null, null, t30.mem(216, 'M10 Kings'), '22023', 'tournament: invalid wicket-keeper'),
    ('another club''s member', t30.squad('M10 Kings', t30.range(201, 214)) || jsonb_build_array(jsonb_build_object('member_id', t30.mem(301, 'M10 Riders'), 'selection', 'sub')), null, null, null, '23514', 'tournament: player not in club')
  ) v(label, squad, cap, vice, keeper, state, msg);
select t30.err(format('select * from public.submit_tournament_registration(%L, %L, %L, %L, %L, null, null, null, true)',
                      t30.id('t1'), t30.club('M10 Kings'), v.name, v.team, t30.squad('M10 Kings', t30.range(201, 215))),
               v.state, v.msg, 'D8 ' || v.label)
  from (values
    ('another club''s team', 'K', t30.id('lionsteam'), '22023', 'tournament: invalid team'),
    ('no name and no team', '   ', null::uuid, '22023', 'tournament: invalid team name'),
    ('a 41-character name', repeat('k', 41), null, '22023', 'tournament: invalid team name')
  ) v(label, name, team, state, msg);
select t30.err(format('select * from public.submit_tournament_registration(%L, %L, ''K'', null, %L, null, null, null, true)',
                      t30.id('t1'), t30.club('M10 Lions'), t30.squad('M10 Kings', t30.range(201, 215))),
               '42501', 'tournament: not allowed', 'D9 entering for another owner''s club: not allowed');
select t30.err(format('select * from public.submit_tournament_registration(%L, %L, ''K'', null, %L, null, null, null, true)',
                      gen_random_uuid(), t30.club('M10 Kings'), t30.squad('M10 Kings', t30.range(201, 215))),
               'P0002', 'tournament: not found', 'D10 an unknown tournament: not found');
select t30.as_user(t30.p(201));
select t30.err(format('select * from public.submit_tournament_registration(%L, %L, ''K'', null, %L, null, null, null, true)',
                      t30.id('t1'), t30.club('M10 Kings'), t30.squad('M10 Kings', t30.range(201, 215))),
               '42501', 'tournament: not allowed', 'D11 a club member (not the owner) cannot enter');
select t30.as_user(t30.p(1));
select t30.err(format('select * from public.submit_tournament_registration(%L, %L, ''H'', null, ''[]'', null, null, null, true)',
                      t30.id('t1'), t30.club('M10 Hosts')),
               'P0001', 'tournament: own tournament', 'D12 the organizer cannot enter its own tournament');
select t30.as_user(t30.p(2));
select t30.err(format('select * from public.submit_tournament_registration(%L, %L, ''L'', %L, %L, null, null, null, true)',
                      t30.id('t2'), t30.club('M10 Lions'), t30.id('lionsold'), t30.squad('M10 Lions', t30.range(101, 115))),
               'P0001', 'tournament: team archived', 'D13 an archived team is refused');
select t30.err(format('select * from public.submit_tournament_registration(%L, %L, ''L'', null, %L, null, null, null, true)',
                      t30.id('t2'), t30.club('M10 Lions'), t30.squad('M10 Lions', t30.range(104, 118))),
               'P0001', 'tournament: player unavailable', 'D14 an injured player (no end date) is refused');
-- Kings enter T1 with 201–215, keeper 201.
select t30.as_user(t30.p(3));
select t30.put('r1kings', (select registration_id from public.submit_tournament_registration(
  t30.id('t1'), t30.club('M10 Kings'), 'Kings XI', t30.id('kingsteam'), t30.squad('M10 Kings', t30.range(201, 215)),
  null, null, t30.mem(201, 'M10 Kings'), true)));
-- The Riders enter T1 (their owner mutes nothing the organizer gets).
select t30.as_user(t30.p(4));
select t30.put('r1riders', (select registration_id from public.submit_tournament_registration(
  t30.id('t1'), t30.club('M10 Riders'), 'Riders', null, t30.squad('M10 Riders', t30.range(301, 315)), null, null, null, true)));
select t30.as_user(t30.p(8));
select t30.put('r1eagles', (select registration_id from public.submit_tournament_registration(
  t30.id('t1'), t30.club('M10 Eagles'), 'Eagles', null, t30.squad('M10 Eagles', t30.range(501, 515)), null, null, null, true)));
select t30.ok(t30.notes(t30.p(1), 'tournament_registration_received') = 4, 'D15 four entries, four requests for the organizer');
-- A person in two clubs plays for one entry per tournament (117: Lions and Kings).
select t30.as_user(t30.p(2));
select t30.put('r3lions', (select registration_id from public.submit_tournament_registration(
  t30.id('t3'), t30.club('M10 Lions'), 'Lions League', null, t30.squad('M10 Lions', array[117] || t30.range(101, 114)),
  null, null, null, true)));
select t30.ok((select status from t30.reg(t30.id('r3lions'))) = 'pending',
              'D16 117 (also a Kings member) plays for the Lions in T3');
select t30.as_user(t30.p(3));
select t30.err(format('select * from public.submit_tournament_registration(%L, %L, ''K'', null, %L, null, null, null, true)',
                      t30.id('t3'), t30.club('M10 Kings'), t30.squad('M10 Kings', array[117] || t30.range(201, 214))),
               'P0001', 'tournament: player already registered', 'D17 … 117 cannot also play for the Kings in T3');
select t30.put('r3kings', (select registration_id from public.submit_tournament_registration(
  t30.id('t3'), t30.club('M10 Kings'), 'Kings League', null, t30.squad('M10 Kings', t30.range(201, 215)), null, null, null, true)));
select t30.as_user(t30.p(4));
select t30.put('r3riders', (select registration_id from public.submit_tournament_registration(
  t30.id('t3'), t30.club('M10 Riders'), 'Riders League', null, t30.squad('M10 Riders', t30.range(301, 315)), null, null, null, true)));
-- Muted: the Riders' owner turned join requests off.
select t30.as_user(t30.p(2));
select t30.put('r6lions', (select registration_id from public.submit_tournament_registration(
  t30.id('t6'), t30.club('M10 Lions'), 'Lions', null, t30.squad('M10 Lions', t30.range(101, 115)), null, null, null, true)));
select t30.ok((select status from t30.reg(t30.id('r6lions'))) = 'pending'
              and t30.notes(t30.p(4), 'tournament_registration_received') = 0,
              'D18 muted join requests: the entry is made, the Riders'' owner gets no notification');
-- The deadline (Asia/Karachi day): T5 closes today, T4 closed yesterday.
select t30.put('r5lions', (select registration_id from public.submit_tournament_registration(
  t30.id('t5'), t30.club('M10 Lions'), 'Lions', null, t30.squad('M10 Lions', t30.range(102, 116)), null, null, null, true)));
select t30.ok((select status from t30.reg(t30.id('r5lions'))) = 'pending',
              'D19 entering on the deadline day itself is accepted (with 116, injured only until yesterday)');
reset role;
update public.tournaments set created_at = now() - interval '3 days', registration_deadline = t30.today() - 1
 where id = t30.id('t4');
set local role authenticated;
select t30.as_user(t30.p(2));
select t30.err(format('select * from public.submit_tournament_registration(%L, %L, ''L'', null, %L, null, null, null, true)',
                      t30.id('t4'), t30.club('M10 Lions'), t30.squad('M10 Lions', t30.range(101, 115))),
               'P0001', 'tournament: registration closed', 'D20 after the deadline day: registration closed');
select t30.ok((select d.status = 'registration_closed' and not d.accepts_registrations
                 from public.tournament_detail(t30.id('t4')) d)
              and (select status from t30.tour(t30.id('t4'))) = 'registration_open',
              'D21 … shown as registration_closed (the stored row is not rewritten)');
-- Visibility of entries.
select t30.as_user(t30.p(9));
select t30.ok(t30.count_sql(format('select * from public.tournament_teams(%L)', t30.id('t1'))) = 0,
              'D22 another club sees no pending entries');
select t30.err(format('select * from public.tournament_registration_squad(%L)', t30.id('r1lions')),
               '42501', 'tournament: not allowed', 'D23 … nor a squad');
select t30.as_user(t30.p(3));
select t30.ok((select array_agg(r.registration_id) from public.tournament_teams(t30.id('t1')) r) = array[t30.id('r1kings')],
              'D24 an entering club sees its own pending entry only');
select t30.as_user(t30.p(1));
select t30.ok((select array_agg(r.registration_id order by r.submitted_at, r.registration_id)
                 from public.tournament_teams(t30.id('t1')) r where r.status = 'pending')
              = t30.regs_of_tournament(t30.id('t1'))
              and t30.count_sql(format('select * from public.tournament_registration_squad(%L)', t30.id('r1kings'))) = 15
              and (select pending_count from public.tournament_detail(t30.id('t1'))) = 4,
              'D25 the organizer sees every request (oldest first), their squads and the pending count');
select t30.err(format('select * from public.tournament_teams(%L)', gen_random_uuid()), 'P0002', 'tournament: not found',
               'D26 entries of an unknown tournament: not found');
-- My Registrations.
select t30.as_user(t30.p(2));
select t30.ok((select array_agg(r.registration_id order by r.submitted_at desc, r.registration_id)
                 from public.my_tournament_registrations(t30.club('M10 Lions')) r)
              = t30.regs_of_club(t30.club('M10 Lions'))
              and t30.count_sql(format('select * from public.my_tournament_registrations(%L, ''pending'')', t30.club('M10 Lions'))) = 4
              and t30.count_sql(format('select * from public.my_tournament_registrations(%L, ''approved'')', t30.club('M10 Lions'))) = 0
              and (select r.tournament_name = 'Spring Cup' and r.organizer_name = 'M10 Hosts' and r.player_count = 15
                          and r.tournament_status = 'registration_open'
                     from public.my_tournament_registrations(t30.club('M10 Lions')) r where r.registration_id = t30.id('r1lions')),
              'D27 My Registrations: the club''s 4 entries, by status');
select t30.err(format('select * from public.my_tournament_registrations(%L, ''Pending'')', t30.club('M10 Lions')),
               '22023', 'tournament: invalid status', 'D28 an unknown status filter is refused');
select t30.err(format('select * from public.my_tournament_registrations(%L)', t30.club('M10 Kings')),
               '42501', 'tournament: not allowed', 'D29 … and another club''s registrations');
select t30.ok((select h.hosted = 1 and h.registered = 4 and h.approved = 0 and h.pending = 4
                      and h.open = (select count(*) from public.browse_tournaments() b where b.accepts_registrations)
                 from public.tournament_hub_stats(t30.club('M10 Lions')) h),
              'D30 Tournament Center stats for the Lions');
select t30.err(format('select * from public.tournament_hub_stats(%L)', t30.club('M10 Kings')),
               '42501', 'tournament: not allowed', 'D31 … not for another club');
reset role;
select t30.err(format('insert into public.tournament_registrations (tournament_id, club_id, team_name) values (%L, %L, ''Self'')',
                      t30.id('t1'), t30.club('M10 Hosts')), '23514', 'tournament: own tournament',
               'D32 the table refuses the organizer''s own entry');
select t30.err(format('insert into public.tournament_registration_players (registration_id, member_id, selection, position) values (%L, %L, ''sub'', 15)',
                      t30.id('r6lions'), t30.mem(201, 'M10 Kings')), '23514', 'tournament: player not in club',
               'D33 … and another club''s member in a squad');
select t30.err(format('update public.tournament_registration_players set is_captain = true where registration_id = %L and position = 4',
                      t30.id('r1lions')), '23505', '%one_captain%', 'D34 … and two captains');

-- ---------------------------------------------------------------------------
-- E. Decisions (Team Requests: approve / reject; remove a team)
-- ---------------------------------------------------------------------------
set local role authenticated;
select t30.as_user(t30.p(2));
select t30.err(format('select * from public.decide_tournament_registration(%L, true)', t30.id('r1kings')),
               '42501', 'tournament: not allowed', 'E1 only the organizer''s owner decides');
select t30.as_user(t30.p(1));
select t30.err(format('select * from public.decide_tournament_registration(%L, true)', gen_random_uuid()),
               'P0002', 'tournament: registration not found', 'E2 an unknown entry: not found');
select t30.err(format('select * from public.decide_tournament_registration(%L, null)', t30.id('r1kings')),
               '22023', 'tournament: invalid decision', 'E3 a decision is required');
select t30.ok((select r.status = 'approved' and r.decided_at is not null
                 from public.decide_tournament_registration(t30.id('r1lions'), true) r),
              'E4 the organizer approves the Lions');
select t30.ok((select decided_by from t30.reg(t30.id('r1lions'))) = t30.p(1), 'E4b … decided_by is the organizer''s owner');
select t30.ok((select n.inbox = 'club_owner' and n.club_id = t30.club('M10 Lions') and n.subject_id = t30.id('r1lions')
                      and n.params ->> 'organizer_name' = 'M10 Hosts' and n.params ->> 'tournament_name' = 'Spring Cup'
                 from t30.note(t30.p(2), 'tournament_registration_approved') n)
              and t30.cat('tournament_registration_approved') = 'challenges',
              'E5 … their owner is told (tournament_registration_approved, challenges)');
select t30.err(format('select * from public.decide_tournament_registration(%L, false)', t30.id('r1lions')),
               'P0001', 'tournament: not pending', 'E6 a decided entry cannot be decided again');
select public.decide_tournament_registration(t30.id('r1kings'), true);
select public.decide_tournament_registration(t30.id('r1riders'), true);
select t30.ok(t30.notes(t30.p(4), 'tournament_registration_approved') = 0 and t30.notes(t30.p(3), 'tournament_registration_approved') = 1,
              'E7 muted challenges: the Riders'' owner is not told; the Kings'' owner is');
-- T3: reject → enter again; remove → enter again; the last slot.
select t30.ok((select r.status from public.decide_tournament_registration(t30.id('r3lions'), false) r) = 'rejected',
              'E8a the organizer rejects the Lions'' T3 entry');
select t30.ok(t30.notes(t30.p(2), 'tournament_registration_rejected') = 1
              and t30.cat('tournament_registration_rejected') = 'challenges',
              'E8 a rejection: the Lions'' owner is told (tournament_registration_rejected)');
select t30.as_user(t30.p(2));
select t30.put('r3lions2', (select registration_id from public.submit_tournament_registration(
  t30.id('t3'), t30.club('M10 Lions'), 'Lions League', null, t30.squad('M10 Lions', t30.range(101, 115)), null, null, null, true)));
select t30.ok((select d.my_registration_id = t30.id('r3lions2') and d.my_registration_status = 'pending'
                 from public.tournament_detail(t30.id('t3')) d), 'E9 a rejected club may enter again');
select t30.as_user(t30.p(1));
select public.decide_tournament_registration(t30.id('r3lions2'), true);
select public.decide_tournament_registration(t30.id('r3kings'), true);
select public.decide_tournament_registration(t30.id('r3riders'), true);
select t30.err(format('select * from public.remove_tournament_team(%L)', t30.id('r1eagles')),
               'P0001', 'tournament: not approved', 'E10 only a confirmed team can be removed');
select t30.as_user(t30.p(2));
select t30.err(format('select * from public.remove_tournament_team(%L)', t30.id('r3kings')),
               '42501', 'tournament: not allowed', 'E11 only the organizer''s owner removes a team');
select t30.as_user(t30.p(1));
select t30.ok((select r.status = 'removed' from public.remove_tournament_team(t30.id('r3kings')) r),
              'E12a the organizer removes the Kings from T3');
select t30.ok(t30.notes(t30.p(3), 'tournament_team_removed') = 1
              and (select n.params ->> 'team_name' from t30.note(t30.p(3), 'tournament_team_removed') n) = 'Kings League'
              and t30.cat('tournament_team_removed') = 'challenges',
              'E12 the organizer removes the Kings; their owner is told (tournament_team_removed)');
select t30.err(format('select * from public.remove_tournament_team(%L)', gen_random_uuid()),
               'P0002', 'tournament: registration not found', 'E13 removing an unknown entry: not found');
select t30.as_user(t30.p(3));
select t30.put('r3kings2', (select registration_id from public.submit_tournament_registration(
  t30.id('t3'), t30.club('M10 Kings'), 'Kings League', null, t30.squad('M10 Kings', t30.range(201, 215)), null, null, null, true)));
select t30.as_user(t30.p(8));
select t30.put('r3eagles', (select registration_id from public.submit_tournament_registration(
  t30.id('t3'), t30.club('M10 Eagles'), 'Eagles League', null, t30.squad('M10 Eagles', t30.range(501, 515)), null, null, null, true)));
select t30.as_user(t30.p(1));
select public.decide_tournament_registration(t30.id('r3kings2'), true);
select t30.ok((select status from t30.tour(t30.id('t3'))) = 'registration_open', 'E14a 3 of 4 confirmed: still open');
select t30.ok((select r.status from public.decide_tournament_registration(t30.id('r3eagles'), true) r) = 'approved',
              'E14b the 4th approval');
select t30.ok((select d.status = 'registration_full' and not d.accepts_registrations and d.available_slots = 0
                          and d.approved_count = 4
                     from public.tournament_detail(t30.id('t3')) d),
              'E14 the 4th of 4 approvals fills T3 (registration_full)');
select t30.ok((select r.status from public.remove_tournament_team(t30.id('r3eagles')) r) = 'removed', 'E15a remove the Eagles');
select t30.ok((select status from t30.tour(t30.id('t3'))) = 'registration_open',
              'E15 removing a team re-opens a full tournament');
select t30.as_user(t30.p(8));
select t30.put('r3eagles2', (select registration_id from public.submit_tournament_registration(
  t30.id('t3'), t30.club('M10 Eagles'), 'Eagles League', null, t30.squad('M10 Eagles', t30.range(501, 515)), null, null, null, true)));
select t30.as_user(t30.p(1));
select public.decide_tournament_registration(t30.id('r3eagles2'), true);
-- T2 (2 teams): full after 2; a 3rd entry is refused; a 3rd approval too.
select t30.as_user(t30.p(2));
select t30.put('r2lions', (select registration_id from public.submit_tournament_registration(
  t30.id('t2'), t30.club('M10 Lions'), 'Lions', t30.id('lionsteam'), t30.squad('M10 Lions', t30.range(101, 115)),
  null, null, t30.mem(101, 'M10 Lions'), true)));
select t30.as_user(t30.p(3));
select t30.put('r2kings', (select registration_id from public.submit_tournament_registration(
  t30.id('t2'), t30.club('M10 Kings'), 'Kings', null, t30.squad('M10 Kings', t30.range(201, 215)),
  null, null, t30.mem(201, 'M10 Kings'), true)));
select t30.as_user(t30.p(4));
select t30.put('r2riders', (select registration_id from public.submit_tournament_registration(
  t30.id('t2'), t30.club('M10 Riders'), 'Riders', null, t30.squad('M10 Riders', t30.range(301, 315)), null, null, null, true)));
select t30.as_user(t30.p(1));
select public.decide_tournament_registration(t30.id('r2lions'), true);
select public.decide_tournament_registration(t30.id('r2kings'), true);
select t30.err(format('select * from public.decide_tournament_registration(%L, true)', t30.id('r2riders')),
               'P0001', 'tournament: registration full', 'E16 no approval beyond max_teams');
select t30.ok((select r.status from public.decide_tournament_registration(t30.id('r2riders'), false) r) = 'rejected',
              'E17 … the request can still be rejected');
select t30.as_user(t30.p(8));
select t30.err(format('select * from public.submit_tournament_registration(%L, %L, ''E'', null, %L, null, null, null, true)',
                      t30.id('t2'), t30.club('M10 Eagles'), t30.squad('M10 Eagles', t30.range(501, 515))),
               'P0001', 'tournament: registration full', 'E18 a full tournament takes no new entries');
reset role;

-- ---------------------------------------------------------------------------
-- F. The draw (generate fixtures)
-- ---------------------------------------------------------------------------
-- Approval order = seeding: Lions, Kings, Riders (T1), Lions, Kings, Riders, Eagles (T3).
update public.tournament_registrations set decided_at = now() + make_interval(secs => v.k)
  from (values ('r1lions', 1), ('r1kings', 2), ('r1riders', 3), ('r3lions2', 1), ('r3kings2', 2), ('r3riders', 3),
               ('r3eagles2', 4), ('r2lions', 1), ('r2kings', 2)) v(name, k)
 where id = t30.id(v.name);
set local role authenticated;
select t30.as_user(t30.p(2));
select t30.err(format('select * from public.generate_tournament_fixtures(%L)', t30.id('t1')),
               '42501', 'tournament: not allowed', 'F1 only the organizer''s owner generates fixtures');
select t30.as_user(t30.p(1));
select t30.err(format('select * from public.generate_tournament_fixtures(%L)', gen_random_uuid()),
               'P0002', 'tournament: not found', 'F2 an unknown tournament: not found');
select t30.err(format('select * from public.generate_tournament_fixtures(%L)', t30.id('t5')),
               'P0001', 'tournament: not enough teams', 'F3 fewer than 2 confirmed teams: not enough teams');
select t30.ok((select f.outcome = 'generated' and f.fixture_count = 3 from public.generate_tournament_fixtures(t30.id('t1')) f),
              'F4 T1 (3 teams, knockout): 3 fixtures');
select t30.ok((select array_agg(x.round_name || '#' || x.match_no || ':' || coalesce(x.home_name, case when x.home_bye then 'BYE' else 'TBD' end)
                                || '-' || coalesce(x.away_name, case when x.away_bye then 'BYE' else 'TBD' end) || ':' || x.state
                                order by x.round_no, x.match_no)
                 from public.tournament_fixtures(t30.id('t1')) x)
              = array['Semifinal#1:M10 Lions-M10 Kings:ready', 'Semifinal#2:M10 Riders-BYE:walkover', 'Final#1:TBD-M10 Riders:tbd'],
              'F5 the bracket: Lions v Kings, Riders get a BYE straight into the Final''s away slot');
select t30.ok((select x.winner_registration_id = t30.id('r1riders') and x.next_slot = 'away'
                 from public.tournament_fixtures(t30.id('t1')) x where x.round_no = 1 and x.match_no = 2),
              'F6 … the BYE is resolved at once (winner Riders, no points)');
select t30.ok((select d.status = 'registration_closed' and d.fixtures_generated and not d.accepts_registrations
                 from public.tournament_detail(t30.id('t1')) d)
              and (select status from t30.reg(t30.id('r1eagles'))) = 'rejected'
              and t30.notes(t30.p(8), 'tournament_registration_rejected') = 1,
              'F7 registration closes; the still-pending Eagles are rejected and told');
select t30.ok(t30.notes(t30.p(2), 'tournament_fixtures_published') = 1 and t30.notes(t30.p(4), 'tournament_fixtures_published') = 1
              and t30.notes(t30.p(3), 'tournament_fixtures_published') = 0 and t30.notes(t30.p(8), 'tournament_fixtures_published') = 0
              and (select n.subject_id = t30.id('t1') and n.club_id = t30.club('M10 Lions') and n.params ->> 'round_name' = 'Semifinal'
                     from t30.note(t30.p(2), 'tournament_fixtures_published') n)
              and t30.cat('tournament_fixtures_published') = 'matches',
              'F8 the confirmed clubs'' owners are told (fixtures_published, matches); the Kings muted matches');
select t30.ok((select f.outcome = 'already_generated' and f.fixture_count = 3 from public.generate_tournament_fixtures(t30.id('t1')) f)
              and t30.count_sql(format('select * from public.tournament_fixtures(%L)', t30.id('t1'))) = 3
              and t30.notes(t30.p(2), 'tournament_fixtures_published') = 1,
              'F9 generating again changes nothing (idempotent)');
select t30.err(format('select * from public.remove_tournament_team(%L)', t30.id('r1lions')),
               'P0001', 'tournament: fixtures generated', 'F10 no team can be removed once fixtures exist');
reset role;
update public.tournament_registrations set status = 'pending', decided_at = null, decided_by = null where id = t30.id('r1eagles');
set local role authenticated;
select t30.as_user(t30.p(1));
select t30.err(format('select * from public.decide_tournament_registration(%L, true)', t30.id('r1eagles')),
               'P0001', 'tournament: fixtures generated', 'F11 … nor approved');
select t30.as_user(t30.p(8));
select t30.err(format('select * from public.submit_tournament_registration(%L, %L, ''E'', null, %L, null, null, null, true)',
                      t30.id('t1'), t30.club('M10 Eagles'), t30.squad('M10 Eagles', t30.range(501, 515))),
               'P0001', 'tournament: registration closed', 'F14 a new entry after the draw: registration closed');
select t30.as_user(t30.p(6));
select t30.ok(t30.count_sql(format('select * from public.tournament_fixtures(%L)', t30.id('t1'))) = 3
              and t30.count_sql(format('select * from public.tournament_points_table(%L)', t30.id('t1'))) = 3,
              'F15 any signed-in user reads the fixtures and the points table');
select t30.err(format('select * from public.tournament_fixtures(%L)', gen_random_uuid()), 'P0002', 'tournament: not found',
               'F16 fixtures of an unknown tournament: not found');
select t30.ok((select bool_and(p.played = 0 and p.points = 0) from public.tournament_points_table(t30.id('t1')) p)
              and (select array_agg(p.club_name order by p.position) from public.tournament_points_table(t30.id('t1')) p)
                  = array['M10 Kings', 'M10 Lions', 'M10 Riders'],
              'F17 before any result: zeros, ordered by club name (the BYE gives no points)');
reset role;
-- The engine for many sizes (knockout with BYEs; league pairs).
select t30.ok(t30.check_knockout(n) = 'ok', 'F18 knockout draw for ' || n || ' teams')
  from unnest(array[2, 3, 4, 5, 6, 7, 8, 9, 12, 16, 17, 31, 32]) n;
select t30.ok(t30.check_league(n) = 'ok', 'F19 league draw for ' || n || ' teams')
  from unnest(array[2, 3, 4, 5, 8, 32]) n;
-- Exact layouts (FixtureEngine): 5 and 6 teams.
select t30.put('t5draw', t30.seeded('knockout', 5));
select t30.put('t6draw', t30.seeded('knockout', 6));
set local role authenticated;
select t30.as_user(t30.p(1));
select count(*) from public.generate_tournament_fixtures(t30.id('t5draw'));
select count(*) from public.generate_tournament_fixtures(t30.id('t6draw'));
select t30.ok((select array_agg(x.round_name || ':' || coalesce(x.home_name, case when x.home_bye then 'BYE' else 'TBD' end)
                                || '-' || coalesce(x.away_name, case when x.away_bye then 'BYE' else 'TBD' end) || ':' || x.state
                                || ':' || case when x.winner_bye then 'BYE' when x.winner_registration_id = x.home_registration_id then x.home_name else '-' end
                                order by x.round_no, x.match_no)
                 from public.tournament_fixtures(t30.id('t5draw')) x)
              = array['Quarterfinal:M10 C01-M10 C02:ready:-', 'Quarterfinal:M10 C03-M10 C04:ready:-',
                      'Quarterfinal:M10 C05-BYE:walkover:M10 C05', 'Quarterfinal:BYE-BYE:walkover:BYE',
                      'Semifinal:TBD-TBD:tbd:-', 'Semifinal:M10 C05-BYE:walkover:M10 C05', 'Final:TBD-M10 C05:tbd:-'],
              'F20 5 teams: C05 walks over twice into the Final (BYE v BYE gives a BYE)');
select t30.ok((select array_agg(x.round_name || ':' || coalesce(x.home_name, case when x.home_bye then 'BYE' else 'TBD' end)
                                || '-' || coalesce(x.away_name, case when x.away_bye then 'BYE' else 'TBD' end) || ':' || x.state
                                order by x.round_no, x.match_no)
                 from public.tournament_fixtures(t30.id('t6draw')) x)
              = array['Quarterfinal:M10 C01-M10 C02:ready', 'Quarterfinal:M10 C03-M10 C04:ready',
                      'Quarterfinal:M10 C05-M10 C06:ready', 'Quarterfinal:BYE-BYE:walkover',
                      'Semifinal:TBD-TBD:tbd', 'Semifinal:TBD-BYE:tbd', 'Final:TBD-TBD:tbd'],
              'F21 6 teams: the C05 v C06 winner will meet a BYE in the Semifinal');
reset role;

-- ---------------------------------------------------------------------------
-- G. Results: only the trusted scorer (service_role), then standings / champion
-- ---------------------------------------------------------------------------
select t30.put('t1sf1', (t30.fx(t30.id('t1'), 1, 1)).id);
select t30.put('t1sf2', (t30.fx(t30.id('t1'), 1, 2)).id);
select t30.put('t1final', (t30.fx(t30.id('t1'), 2, 1)).id);
set local role service_role;
select t30.as_nobody();
select t30.err(format('select * from public.record_tournament_fixture_result(%L, %L)', gen_random_uuid(), t30.id('r1lions')),
               'P0002', 'tournament: fixture not found', 'G1 an unknown fixture: not found');
select t30.err(format('select * from public.record_tournament_fixture_result(%L, %L)', t30.id('t1final'), t30.id('r1riders')),
               'P0001', 'tournament: fixture not ready', 'G2 the Final is not ready (one side TBD)');
select t30.err(format('select * from public.record_tournament_fixture_result(%L, %L)', t30.id('t1sf2'), t30.id('r1lions')),
               'P0001', 'tournament: fixture already decided', 'G3 a BYE walkover cannot be given another winner');
select t30.err(format('select * from public.record_tournament_fixture_result(%L, %L)', t30.id('t1sf1'), t30.id('r1riders')),
               '22023', 'tournament: invalid winner', 'G4 the winner must be one of the two teams');
select t30.err(format('select * from public.record_tournament_fixture_result(%L, null)', t30.id('t1sf1')),
               '22023', 'tournament: invalid winner', 'G5 … and given');
select t30.ok((select r.tournament_status = 'registration_closed' and r.champion_registration_id is null
                 from public.record_tournament_fixture_result(t30.id('t1sf1'), t30.id('r1kings')) r),
              'G6a the scorer records the Kings'' Semifinal win');
select t30.ok((t30.fx(t30.id('t1'), 2, 1)).home_registration_id = t30.id('r1kings'),
              'G6 the Kings win the Semifinal and move into the Final''s home slot');
select t30.ok((select r.fixture_id = t30.id('t1sf1') from public.record_tournament_fixture_result(t30.id('t1sf1'), t30.id('r1kings')) r),
              'G7 the same result again changes nothing');
select t30.err(format('select * from public.record_tournament_fixture_result(%L, %L)', t30.id('t1sf1'), t30.id('r1lions')),
               'P0001', 'tournament: fixture already decided', 'G8 a different winner for a decided fixture is refused');
select t30.ok((select r.tournament_status = 'completed' and r.champion_registration_id = t30.id('r1riders')
                 from public.record_tournament_fixture_result(t30.id('t1final'), t30.id('r1riders')) r),
              'G9 the Riders win the Final: the tournament is completed with its champion');
reset role;
set local role authenticated;
select t30.as_user(t30.p(3));
select t30.ok((select d.status = 'completed' and d.winner_registration_id = t30.id('r1riders') and d.winner_name = 'M10 Riders'
                 from public.tournament_detail(t30.id('t1')) d), 'G10 Details: completed, winner M10 Riders');
select t30.ok((select array_agg(p.club_name || ':' || p.played || p.won || p.lost || ':' || p.points order by p.position)
                 from public.tournament_points_table(t30.id('t1')) p)
              = array['M10 Kings:211:2', 'M10 Riders:110:2', 'M10 Lions:101:0'],
              'G11 the points table: 2 a win, played fixtures only, ties by club name');
select t30.ok((select array_agg(x.state order by x.round_no, x.match_no) from public.tournament_fixtures(t30.id('t1')) x)
              = array['completed', 'walkover', 'completed'], 'G12 fixture states after the results');
reset role;
-- T3 league (Lions, Kings, Riders, Eagles): every pair once; the champion when all 6 are decided.
set local role authenticated;
select t30.as_user(t30.p(1));
select t30.ok((select f.fixture_count = 6 from public.generate_tournament_fixtures(t30.id('t3')) f), 'G13 T3 league: 6 fixtures');
reset role;
set local role service_role;
-- Seeds 1 Lions, 2 Kings, 3 Riders, 4 Eagles. Results: 1 beats 2 and 3; 4 beats 1; 2 beats 3 and 4; 3 beats 4.
select count(*) from (
  select public.record_tournament_fixture_result((t30.fx(t30.id('t3'), 1, g)).id,
           case g when 1 then t30.id('r3lions2') when 2 then t30.id('r3lions2') when 3 then t30.id('r3eagles2')
                  when 4 then t30.id('r3kings2') when 5 then t30.id('r3kings2') end)
    from generate_series(1, 5) g) s;
select t30.ok((select status from t30.tour(t30.id('t3'))) = 'registration_closed', 'G14 5 of 6 decided: not completed yet');
select t30.ok((select r.tournament_status = 'completed' and r.champion_registration_id = t30.id('r3kings2')
                 from public.record_tournament_fixture_result((t30.fx(t30.id('t3'), 1, 6)).id, t30.id('r3riders')) r),
              'G15 the last result completes the league: Kings and Lions on 4, Kings first by name');
reset role;
set local role authenticated;
select t30.as_user(t30.p(2));
select t30.ok((select array_agg(p.club_name || ':' || p.played || p.won || p.lost || ':' || p.points order by p.position)
                 from public.tournament_points_table(t30.id('t3')) p)
              = array['M10 Kings:321:4', 'M10 Lions:321:4', 'M10 Eagles:312:2', 'M10 Riders:312:2'],
              'G16 the league table');
reset role;

-- ---------------------------------------------------------------------------
-- H. Awards from official results only (T2 Final: Lions v Kings)
-- ---------------------------------------------------------------------------
set local role authenticated;
select t30.as_user(t30.p(1));
select count(*) from public.generate_tournament_fixtures(t30.id('t2'));
select t30.as_user(t30.p(2));
select t30.ok(t30.count_sql(format('select * from public.tournament_awards(%L)', t30.id('t2'))) = 0
              and t30.count_sql(format('select * from public.tournament_awards(%L)', t30.id('t1'))) = 0,
              'H1 no official result linked: no awards (never invented figures)');
select t30.as_user(t30.p(6));
select t30.err(format('select * from public.tournament_awards(%L)', t30.id('t2')), '42501', 'tournament: not allowed',
               'H2 awards: not for a player of no club in the tournament');
select t30.as_user(t30.p(4));
select t30.err(format('select * from public.tournament_awards(%L)', t30.id('t2')), '42501', 'tournament: not allowed',
               'H3 … nor for a club whose entry was rejected');
select t30.err(format('select * from public.tournament_awards(%L)', gen_random_uuid()), 'P0002', 'tournament: not found',
               'H4 awards of an unknown tournament: not found');
reset role;
-- Three past matches: m1 Lions v Kings (official result below), m2 Lions v Riders, m3 Lions v Kings (no result).
insert into public.matches (id, club_a_id, club_b_id, format, status, starts_at, venue_name)
values (t30.m(1), t30.club('M10 Lions'), t30.club('M10 Kings'), 't20', 'confirmed', now() - interval '1 day', 'Award Ground'),
       (t30.m(2), t30.club('M10 Lions'), t30.club('M10 Riders'), 't20', 'confirmed', now() - interval '1 day', 'Award Ground'),
       (t30.m(3), t30.club('M10 Lions'), t30.club('M10 Kings'), 't20', 'confirmed', now() - interval '2 days', 'Award Ground');
insert into public.scorer_clients (id, name, key_id, single_step_trusted, status)
values (t30.cl(1), 'M10 Trusted Scorer', 'm10.trusted.k1', true, 'active');
-- Lions 40/1 (24 balls): 104 30 st 201 b 202, 105 10*; 202 bowls 4-0-40.
-- Kings 25/1 (18 balls): 203 20 c 106 b 107, 204 5*; 107 bowls 3-0-25. Lions won.
select jsonb_build_object('outcome', 'club_a_won', 'innings', jsonb_build_array(
  jsonb_build_object('batting_club_id', t30.club('M10 Lions'), 'runs', 40, 'wickets', 1, 'balls', 24,
    'batting', jsonb_build_array(
      jsonb_build_object('member_id', t30.mem(104, 'M10 Lions'), 'runs', 30, 'balls', 16, 'dismissal', 'stumped',
                         'bowler_member_id', t30.mem(202, 'M10 Kings'), 'fielder_member_id', t30.mem(201, 'M10 Kings')),
      jsonb_build_object('member_id', t30.mem(105, 'M10 Lions'), 'runs', 10, 'balls', 8, 'dismissal', 'not_out')),
    'bowling', jsonb_build_array(jsonb_build_object('member_id', t30.mem(202, 'M10 Kings'), 'balls', 24, 'runs', 40))),
  jsonb_build_object('batting_club_id', t30.club('M10 Kings'), 'runs', 25, 'wickets', 1, 'balls', 18,
    'batting', jsonb_build_array(
      jsonb_build_object('member_id', t30.mem(203, 'M10 Kings'), 'runs', 20, 'balls', 12, 'dismissal', 'caught',
                         'bowler_member_id', t30.mem(107, 'M10 Lions'), 'fielder_member_id', t30.mem(106, 'M10 Lions')),
      jsonb_build_object('member_id', t30.mem(204, 'M10 Kings'), 'runs', 5, 'balls', 6, 'dismissal', 'not_out')),
    'bowling', jsonb_build_array(jsonb_build_object('member_id', t30.mem(107, 'M10 Lions'), 'balls', 18, 'runs', 25))))) as card \gset
set local role service_role;
select public.assign_match_official(t30.m(1), t30.cl(1), 'scorer');
select t30.ok((select r.outcome = 'accepted' from public.ingest_official_result(t30.cl(1), 'm10-1', t30.m(1), :'card', 'req-m10-1') r),
              'H5 (setup) the trusted scorer submits m1''s official result');
reset role;
select t30.ok((select status from public.match_results where match_id = t30.m(1)) = 'confirmed', 'H6 (setup) m1 is official');
set local role service_role;
select t30.put('t2final', (t30.fx(t30.id('t2'), 1, 1)).id);
select t30.err(format('select * from public.record_tournament_fixture_result(%L, %L, %L)', t30.id('t2final'), t30.id('r2lions'), t30.m(2)),
               '22023', 'tournament: invalid match', 'H7 a match between other clubs cannot be linked');
select t30.err(format('select * from public.record_tournament_fixture_result(%L, %L, %L)', t30.id('t2final'), t30.id('r2lions'), gen_random_uuid()),
               '22023', 'tournament: invalid match', 'H8 … nor an unknown match');
select t30.err(format('select * from public.record_tournament_fixture_result(%L, %L, %L)', t30.id('t2final'), t30.id('r2lions'), t30.m(3)),
               'P0001', 'tournament: no official result', 'H9 … nor one without an official result');
select t30.err(format('select * from public.record_tournament_fixture_result(%L, %L, %L)', t30.id('t2final'), t30.id('r2kings'), t30.m(1)),
               'P0001', 'tournament: winner differs from the official result', 'H10 the winner must match the official result');
select t30.ok((select r.tournament_status = 'completed' and r.champion_registration_id = t30.id('r2lions')
                 from public.record_tournament_fixture_result(t30.id('t2final'), t30.id('r2lions'), t30.m(1)) r),
              'H11a the scorer records the Final with m1');
select t30.ok((t30.fx(t30.id('t2'), 1, 1)).match_id = t30.m(1),
              'H11 the Final is linked to m1 and the Lions are champions');
reset role;
set local role authenticated;
select t30.as_user(t30.p(2));
select t30.ok((select array_agg(a.award || ':' || a.player_name || ':' || a.club_name || ':' || a.value || ':' || a.matches_counted
                                order by a.award)
                 from public.tournament_awards(t30.id('t2')) a)
              = array['best_fielder:M10 Person 106:M10 Lions:1:1', 'best_keeper:M10 Person 201:M10 Kings:1:1',
                      'top_run_scorer:M10 Person 104:M10 Lions:30:1', 'top_wicket_taker:M10 Person 107:M10 Lions:1:1'],
              'H12 awards from the official scorecard: runs, wickets (tie by name), keeper dismissals, catches');
select t30.ok((select bool_and(a.registration_id = case a.club_name when 'M10 Lions' then t30.id('r2lions') else t30.id('r2kings') end)
                 from public.tournament_awards(t30.id('t2')) a), 'H13 … each with the player''s entry');
select t30.as_user(t30.p(204));
select t30.ok(t30.count_sql(format('select * from public.tournament_awards(%L)', t30.id('t2'))) = 4,
              'H14 an active member of a confirmed club sees the awards');
select t30.as_user(t30.p(11));
select t30.ok(t30.count_sql(format('select * from public.tournament_awards(%L)', t30.id('t2'))) = 4,
              'H15 … and so does the organizer''s member');
reset role;
update public.profiles set show_stats = false where id = t30.p(104);
set local role authenticated;
select t30.as_user(t30.p(2));
select t30.ok((select a.player_name || ':' || a.value from public.tournament_awards(t30.id('t2')) a where a.award = 'top_run_scorer')
              = 'M10 Person 203:20', 'H16 a player who hides their statistics is left out of the awards');
reset role;
set local role service_role;
select t30.err(format('select * from public.record_tournament_fixture_result(%L, %L, %L)', (t30.fx(t30.id('t3'), 1, 1)).id,
                      t30.id('r3lions2'), t30.m(1)),
               'P0001', 'tournament: fixture already decided', 'H17 a decided fixture cannot be re-linked');
reset role;

-- ---------------------------------------------------------------------------
-- I. Account and club deletion
-- ---------------------------------------------------------------------------
select t30.ok((select (public.delete_account_data(t30.p(110)) ->> 'profile')::int = 1), 'I1 player 110 deletes their account');
select t30.ok((select count(*) from public.tournament_registration_players where registration_id = t30.id('r1lions')) = 14
              and (select status from t30.reg(t30.id('r1lions'))) = 'approved',
              'I2 … their squad places are gone; the entries stay');
select t30.put('ridersclub', t30.club('M10 Riders'));
delete from public.clubs where id = t30.id('ridersclub');
select t30.ok(not exists (select 1 from public.tournament_registrations where club_id = t30.id('ridersclub'))
              and not exists (select 1 from public.tournaments where organizer_club_id = t30.id('ridersclub'))
              and (t30.fx(t30.id('t1'), 1, 2)).home_registration_id is null
              and (t30.fx(t30.id('t1'), 2, 1)).winner_registration_id is null
              and (select winner_registration_id from t30.tour(t30.id('t1'))) is null
              and (select count(*) from public.tournament_fixtures where tournament_id = t30.id('t1')) = 3,
              'I3 deleting a club deletes its tournaments and entries; others'' fixtures keep their places (empty)');
select t30.put('hostsclub', t30.club('M10 Hosts'));
delete from public.clubs where id = t30.id('hostsclub');
select t30.ok(not exists (select 1 from public.tournaments where organizer_club_id = t30.id('hostsclub'))
              and not exists (select 1 from public.tournament_fixtures where tournament_id in (t30.id('t1'), t30.id('t2'), t30.id('t3')))
              and not exists (select 1 from public.tournament_registrations where tournament_id = t30.id('t1'))
              and not exists (select 1 from public.tournament_registration_players where registration_id = t30.id('r1lions'))
              and (select count(*) from public.notifications n
                    where n.dedupe_key = 'tournament:registration:' || t30.id('r1lions') and n.club_id is null) = 1,
              'I4 deleting the organizer club deletes its tournaments, entries, squads and fixtures; notifications keep no club');
select t30.ok(exists (select 1 from public.matches where id = t30.m(1))
              and (select status from public.match_results where match_id = t30.m(1)) = 'confirmed',
              'I5 the official match and its result are untouched');

-- ---------------------------------------------------------------------------
-- J. Notification types and categories
-- ---------------------------------------------------------------------------
select t30.ok(t30.cat('tournament_registration_received') = 'join_requests'
              and t30.cat('tournament_registration_approved') = 'challenges'
              and t30.cat('tournament_registration_rejected') = 'challenges'
              and t30.cat('tournament_team_removed') = 'challenges'
              and t30.cat('tournament_fixtures_published') = 'matches'
              and t30.cat('hunt_interest_received') = 'join_requests'
              and t30.cat('hunt_invite_received') = 'membership'
              and t30.cat('join_request_received') = 'join_requests'
              and t30.cat('match_reminder') = 'matches'
              and t30.cat('challenge_expiring') = 'challenges'
              and t30.cat('result_published') = 'results'
              and t30.cat('announcement') = 'announcements'
              and t30.cat('ownership_expiring') = 'membership',
              'J1 categories: the five tournament types mapped; every earlier mapping unchanged');
select t30.err(format('insert into public.notifications (recipient_id, inbox, type, dedupe_key) values (%L, ''club_owner'', ''tournament_bogus'', ''t30:x'')',
                      t30.p(2)),
               '23514', '%notifications_type_check%', 'J2 an unknown type is still refused');
select t30.ok((select array_length(regexp_split_to_array(pg_get_constraintdef(k.oid), '::text'), 1) - 1
                 from pg_constraint k where k.conname = 'notifications_type_check') = 34,
              'J3 the type list has 34 types (29 + 5)');
select t30.ok((select bool_and(n.inbox = 'club_owner') from public.notifications n where n.type like 'tournament_%')
              and (select count(*) from public.notifications n where n.type like 'tournament_%') > 0,
              'J4 every tournament notification is in the club_owner inbox');

rollback;
\echo 'local check 30: all checks passed; everything rolled back'
