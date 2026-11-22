-- CricEco · LOCAL TEST ONLY — migration 26 (notification preferences, M3
-- P4) on a DISPOSABLE plain PostgreSQL 17 database, after 00_auth_stub.sql,
-- 02_legacy_profiles_fixture.sql, migrations 1–25 (+ the D1 location seed)
-- and migration 26. Synthetic data only (people ee3…, matches ee3…aa,
-- clients ec3e…). Every event is driven through the REAL functions.
-- Run with psql:  psql -X -v ON_ERROR_STOP=1 -f 21_notification_preferences_local_check.sql
-- Every check prints "PASS: …"; the first failure stops the run ("FAIL: …").
-- Concurrency (two sessions) is in 21b_notification_preferences_concurrency.sh.
-- Refuses to run on a real Supabase project (its auth.users has passwords).
\set ON_ERROR_STOP on

do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password') then
    raise exception 'LOCAL ONLY: this looks like a real Supabase project — refusing';
  end if;
  if to_regclass('public.notification_preferences') is null then
    raise exception 'apply migration 26 first';
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
create or replace function t.nobody() returns void language sql as $$
  select set_config('request.jwt.claims', '', false);
$$;
create or replace function t.p(p_n int) returns uuid language sql immutable as $$
  select ('ee300000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
$$;
create or replace function t.m(p_n int) returns uuid language sql immutable as $$
  select ('ee3000aa-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
$$;
create or replace function t.cl(p_n int) returns uuid language sql immutable as $$
  select ('ec3e0000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
$$;
create or replace function t.mem(p_n int) returns uuid language sql stable security definer set search_path = '' as $$
  select m.id from public.club_members m where m.user_id = ('ee300000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
$$;
create or replace function t.club(p_n int) returns uuid language sql stable security definer set search_path = '' as $$
  select c.id from public.clubs c where c.name = (array['Pref Lions', 'Pref Kings'])[p_n];
$$;
create or replace function t.code(p_n int) returns text language sql stable security definer set search_path = '' as $$
  select c.code from public.clubs c where c.name = (array['Pref Lions', 'Pref Kings'])[p_n];
$$;
create or replace function t.req(p_n int) returns uuid language sql stable security definer set search_path = '' as $$
  select r.id from public.join_requests r
   where r.user_id = ('ee300000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid
   order by r.created_at desc, r.id desc limit 1;
$$;
create or replace function t.cnt(p_n int, p_type text) returns int language sql stable security definer set search_path = '' as $$
  select count(*)::int from public.notifications n
   where n.recipient_id = ('ee300000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid and n.type = p_type;
$$;
create or replace function t.typed(p_type text) returns int language sql stable security definer set search_path = '' as $$
  select count(*)::int from public.notifications n where n.recipient_id::text like 'ee300000%' and n.type = p_type;
$$;
create or replace function t.prefs_rows() returns int language sql stable security definer set search_path = '' as $$
  select count(*)::int from public.notification_preferences p where p.user_id::text like 'ee300000%';
$$;
-- Sets [p_n]'s preferences as that person, through the API.
create or replace function t.set_prefs(p_n int, p_jr boolean, p_ch boolean, p_ma boolean, p_re boolean, p_an boolean)
returns void language plpgsql as $$
begin
  perform t.as_user(t.p(p_n));
  perform * from public.set_notification_preferences(p_jr, p_ch, p_ma, p_re, p_an);
end $$;
create or replace function t.squad(p_playing int[], p_subs int[]) returns jsonb language sql stable as $$
  select jsonb_agg(x.j order by x.o)
    from (select jsonb_build_object('member_id', t.mem(n), 'selection', 'playing') j, o
            from unnest(p_playing) with ordinality u(n, o)
          union all
          select jsonb_build_object('member_id', t.mem(n), 'selection', 'sub'), 100 + o
            from unnest(p_subs) with ordinality u(n, o)) x;
$$;
create or replace function t.res(p_pom int) returns jsonb language sql stable as $$
  select jsonb_build_object('outcome', 'club_a_won', 'player_of_match_member_id', t.mem(p_pom),
           'innings', jsonb_build_array(
             jsonb_build_object('batting_club_id', t.club(1), 'runs', 150, 'wickets', 3, 'balls', 120),
             jsonb_build_object('batting_club_id', t.club(2), 'runs', 120, 'wickets', 10, 'balls', 110)));
$$;
create or replace function t.make_person(p_n int, p_player boolean default true) returns uuid language plpgsql as $$
declare
  v uuid := t.p(p_n);
begin
  insert into auth.users (id, email) values (v, format('pref%s@local.test', p_n));
  insert into public.current_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
  insert into public.permanent_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
  update public.profiles
     set full_name = format('Pref Person %s', p_n),
         phone = format('+923%s', lpad((630000000 + p_n)::text, 9, '0')),
         date_of_birth = date '2000-05-01', profile_completed = true
   where id = v;
  if p_player then
    insert into public.player_profiles (user_id, player_role, batting_style, bowling_style, is_wicketkeeper)
    values (v, 'all_rounder', 'right_handed', 'right_arm_fast', false);
  end if;
  return v;
end $$;
grant execute on all functions in schema t to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Synthetic data: owners 1 (Pref Lions, A) and 2 (Pref Kings, B); A players
-- 101–115; B players 201–215; 300 and 301 in no club. Match m1: A v B,
-- confirmed, in 3 days; m2: A v B, played yesterday (for results).
-- ---------------------------------------------------------------------------
select t.nobody();
select count(*) from (select t.make_person(n) from unnest(array[1, 2, 300, 301]
                        || array(select generate_series(101, 115)) || array(select generate_series(201, 215))) n) s;
insert into public.clubs (owner_id, name, city, club_type) values
  (t.p(1), 'Pref Lions', 'Lahore', 'corporate'), (t.p(2), 'Pref Kings', 'Karachi', 'corporate');
insert into public.club_members (club_id, user_id, member_role, status)
select case when n < 200 then t.club(1) else t.club(2) end, t.p(n), 'player', 'active'
  from unnest(array(select generate_series(101, 115)) || array(select generate_series(201, 215))) n;
insert into public.matches (id, club_a_id, club_b_id, format, status, starts_at, venue_name) values
  (t.m(1), t.club(1), t.club(2), 't20', 'confirmed', now() + interval '3 days', 'Pref Ground'),
  (t.m(2), t.club(1), t.club(2), 't20', 'confirmed', now() - interval '1 day', 'Pref Ground');

-- ---------------------------------------------------------------------------
-- S. Access
-- ---------------------------------------------------------------------------
set role anon;
select t.expect_error('select * from public.my_notification_preferences()', '%permission denied%',
                      'S1 anon cannot read preferences');
select t.expect_error('select * from public.set_notification_preferences(true, true, true, true, true)',
                      '%permission denied%', 'S1b anon cannot save them');
reset role;
set role authenticated;
select t.as_user(t.p(101));
select t.expect_error('select count(*) from public.notification_preferences', '%permission denied%',
                      'S2 a user cannot read the table directly');
select t.expect_error(format('insert into public.notification_preferences (user_id, matches) values (%L, false)', t.p(102)),
                      '%permission denied%', 'S2b nor write anyone''s row (their own included) directly');
select t.expect_error(format('select public.notification_muted(%L, %L)', t.p(102), 'announcement'), '%permission denied%',
                      'S3 nor ask whether someone muted a category');
select t.expect_error('select public.notification_category(''announcement'')', '%permission denied%',
                      'S3b nor call the internal category helper');
reset role;
set role service_role;
select t.nobody();
select t.expect_error('select count(*) from public.notification_preferences', '%permission denied%',
                      'S4 service_role cannot read the table');
select t.expect_error('select * from public.set_notification_preferences(true, true, true, true, true)',
                      '%permission denied%', 'S4b nor call the API');
reset role;
set role authenticated;
select t.nobody();
select t.expect_error('select * from public.my_notification_preferences()', '%not authenticated%',
                      'S5 without a signed-in user: not authenticated');

-- ---------------------------------------------------------------------------
-- A. The API
-- ---------------------------------------------------------------------------
select t.as_user(t.p(101));
select t.ok((select p.join_requests and p.challenges and p.matches and p.results and p.announcements and p.updated_at is null
               from public.my_notification_preferences() p)
            and (select count(*) = 1 from public.my_notification_preferences()) and t.prefs_rows() = 0,
            'A1 never changed: everything on, no row stored');
select t.ok((select not p.matches and p.join_requests and p.challenges and p.results and p.announcements
                    and p.updated_at is not null
               from public.set_notification_preferences(true, true, false, true, true) p),
            'A2 saving returns the saved row');
select t.ok((select not p.matches and p.results from public.my_notification_preferences() p) and t.prefs_rows() = 1,
            'A3 … and reads back');
select t.expect_error('select * from public.set_notification_preferences(true, null, true, true, true)', '%invalid%',
                      'A4 every category is required (no half-saves)');
select t.as_user(t.p(102));
select t.ok((select p.matches from public.my_notification_preferences() p),
            'A5 one person''s choice is theirs only');
reset role;

-- ---------------------------------------------------------------------------
-- E. Enforced on the server, per category
-- ---------------------------------------------------------------------------
-- join_requests: the owner mutes, a request arrives — no notice; unmutes — notice.
set role authenticated;
select t.set_prefs(1, false, true, true, true, true);
select t.as_user(t.p(300));
select (public.request_to_join_club(t.code(1))).status;
select t.ok(t.cnt(1, 'join_request_received') = 0 and (select r.status = 'pending' from public.join_requests r where r.id = t.req(300)),
            'E1 join requests off: the request is made, the owner is not told');
select t.set_prefs(1, true, true, true, true, true);
select t.as_user(t.p(301));
select (public.request_to_join_club(t.code(1))).status;
select t.ok(t.cnt(1, 'join_request_received') = 1, 'E1b back on: the next request is told');

-- membership: always on, whatever is saved.
select t.set_prefs(300, false, false, false, false, false);
select t.as_user(t.p(1));
select (public.decide_join_request(t.req(300), true, 'player')).status;
select t.ok(t.cnt(300, 'join_request_approved') = 1, 'E2 membership is always on: the approval arrives with everything off');
select public.remove_club_member(t.mem(300)) is not null;
select t.ok(t.cnt(300, 'removed_from_club') = 1, 'E2b … and so does a removal');

-- challenges: owner 2 mutes; owner 1 challenges.
select t.set_prefs(2, true, false, true, true, true);
select t.as_user(t.p(1));
select (public.send_challenge(t.club(1), t.club(2), 't20', null, current_date + 10, 'Pref Ground', null)).status;
select t.ok(t.cnt(2, 'challenge_received') = 0, 'E3 challenges off: the challenged owner is not told');

-- matches: 101 has matches off (A2). A line-up tells the others, not 101.
select (public.save_match_lineup(t.m(1), 'Pref XI', null, t.squad(array(select generate_series(101, 111)), array[112, 113, 114, 115]),
                                 null, null)).name;
select t.ok(t.cnt(101, 'lineup_selected') = 0 and t.typed('lineup_selected') = 14,
            'E4 matches off: a selected player who muted it is not told; the other 14 are');
-- 102 is told, then mutes; their next change is not told, the old notice stays.
select t.set_prefs(102, true, true, false, true, true);
select t.as_user(t.p(1));
select (public.save_match_lineup(t.m(1), 'Pref XI', null, t.squad(array[101] || array(select generate_series(103, 112)), array[102, 113, 114, 115]),
                                 null, null)).name;
select t.ok(t.cnt(102, 'lineup_changed') = 0 and t.cnt(102, 'lineup_selected') = 1 and t.cnt(112, 'lineup_changed') = 1,
            'E5 muting stops new notices only: what is in the inbox stays');

-- results: 103 mutes results (and is Player of the Match); 104 does not.
reset role;
select t.nobody();
insert into public.scorer_clients (id, name, key_id) values
  (t.cl(1), 'Pref Scorer', 'pref.scorer.k1'), (t.cl(2), 'Pref Verifier', 'pref.verifier.k1');
select public.assign_match_official(t.m(2), t.cl(1), 'scorer');
select public.assign_match_official(t.m(2), t.cl(2), 'verifier');
set role authenticated;
select t.set_prefs(103, true, true, true, false, true);
reset role;
set role service_role;
select t.nobody();
select (public.ingest_official_result(t.cl(1), 'pref-1', t.m(2), t.res(103), 'req-1')).outcome;
select (public.verify_official_result(t.cl(2), 'pref-2', t.m(2), 1, true, null)).outcome;
reset role;
select t.ok(t.cnt(103, 'result_published') = 0 and t.cnt(103, 'player_of_match') = 0 and t.cnt(104, 'result_published') = 1
            and t.cnt(1, 'result_published') = 1,
            'E6 results off: no result, no Player of the Match notice; everyone else is told');

-- announcements: 105 mutes; the count is who was told, and 105 cannot open it.
set role authenticated;
select t.set_prefs(105, true, true, true, true, false);
select t.as_user(t.p(1));
select r.recipient_count as told, r.announcement_id as ann
  from public.publish_club_announcement(t.club(1), 'Nets', 'Friday 5 PM.', 'all') r \gset
select t.ok(:told = 14 and t.cnt(105, 'announcement') = 0 and t.cnt(106, 'announcement') = 1,
            'E7 announcements off: not told and not counted (15 members − 1)');
select t.as_user(t.p(105));
select t.expect_error(format('select * from public.club_announcement(%L)', :'ann'), '%not found%',
                      'E7b … and it is not theirs to open');
reset role;

-- ---------------------------------------------------------------------------
-- D. Account deletion removes the preferences
-- ---------------------------------------------------------------------------
select t.nobody();
select t.ok(exists (select 1 from public.notification_preferences p where p.user_id = t.p(105)), 'D0 before: 105 has a row');
delete from auth.users where id = t.p(105);
select t.ok(not exists (select 1 from public.notification_preferences p where p.user_id = t.p(105)),
            'D1 deleting the account deletes its preferences');

-- ---------------------------------------------------------------------------
-- Clean up (this database only): only this check's own records.
-- ---------------------------------------------------------------------------
delete from public.clubs where owner_id::text like 'ee300000%';
delete from public.matches where id::text like 'ee3000aa%';
delete from auth.users where id::text like 'ee300000%';
set session_replication_role = replica;
delete from public.result_submission_log where client_id::text like 'ec3e0000%' or match_id::text like 'ee3000aa%';
delete from public.result_change_log where match_id::text like 'ee3000aa%';
delete from public.scorer_clients where id::text like 'ec3e0000%';
set session_replication_role = default;
select t.ok(not exists (select 1 from public.profiles where id::text like 'ee300000%')
            and t.prefs_rows() = 0
            and not exists (select 1 from public.notifications where recipient_id::text like 'ee300000%')
            and not exists (select 1 from public.scorer_clients where id::text like 'ec3e0000%')
            and not exists (select 1 from public.matches where id::text like 'ee3000aa%'),
            'Z cleanup done');
drop schema t cascade;
