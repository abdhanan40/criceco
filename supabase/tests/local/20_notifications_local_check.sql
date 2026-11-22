-- CricEco · LOCAL TEST ONLY — migration 25 (notifications: the server inbox,
-- M3 P1) on a DISPOSABLE plain PostgreSQL 17 database, after 00_auth_stub.sql
-- (which grants like Supabase: new tables and functions to anon /
-- authenticated / service_role), 02_legacy_profiles_fixture.sql, migrations
-- 1–24 (+ the D1 location seed) and migration 25. Synthetic data only
-- (people ee2…, matches ee2…aa, clients ec2e…).
-- Every event is driven through the REAL functions of migrations 11–24 (as
-- the signed-in owner / player, or service_role for the scorer path).
-- Run with psql:  psql -X -v ON_ERROR_STOP=1 -f 20_notifications_local_check.sql
-- Every check prints "PASS: …"; the first failure stops the run ("FAIL: …").
-- Concurrency (two sessions) is in 20b_notifications_concurrency.sh.
-- Refuses to run on a real Supabase project (its auth.users has passwords).
\set ON_ERROR_STOP on

do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password') then
    raise exception 'LOCAL ONLY: this looks like a real Supabase project — refusing';
  end if;
  if to_regclass('public.notifications') is null then
    raise exception 'apply migration 25 first';
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

-- Who is "signed in" (auth.uid()); t.nobody() for postgres / service_role steps.
create or replace function t.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, false);
$$;
create or replace function t.nobody() returns void language sql as $$
  select set_config('request.jwt.claims', '', false);
$$;
create or replace function t.p(p_n int) returns uuid language sql immutable as $$
  select ('ee200000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
$$;
create or replace function t.m(p_n int) returns uuid language sql immutable as $$
  select ('ee2000aa-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
$$;
create or replace function t.cl(p_n int) returns uuid language sql immutable as $$
  select ('ec2e0000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
$$;
-- The helpers below read past RLS (definer), so checks work under any role.
create or replace function t.mem(p_n int) returns uuid language sql stable security definer set search_path = '' as $$
  select m.id from public.club_members m where m.user_id = ('ee200000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
$$;
create or replace function t.club(p_n int) returns uuid language sql stable security definer set search_path = '' as $$
  select c.id from public.clubs c where c.name = (array['Note Lions', 'Note Kings', 'Note Riders'])[p_n];
$$;
create or replace function t.code(p_n int) returns text language sql stable security definer set search_path = '' as $$
  select c.code from public.clubs c where c.name = (array['Note Lions', 'Note Kings', 'Note Riders'])[p_n];
$$;
create or replace function t.req(p_n int) returns uuid language sql stable security definer set search_path = '' as $$
  select r.id from public.join_requests r
   where r.user_id = ('ee200000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid
   order by r.created_at desc, r.id desc limit 1;
$$;
create or replace function t.xfer() returns uuid language sql stable security definer set search_path = '' as $$
  select x.id from public.club_ownership_transfers x
   where x.club_id = (select c.id from public.clubs c where c.name = 'Note Riders')
   order by x.created_at desc, x.id desc limit 1;
$$;
create or replace function t.chal() returns uuid language sql stable security definer set search_path = '' as $$
  select x.id from public.match_challenges x
   where x.from_club_id = (select c.id from public.clubs c where c.name = 'Note Lions')
   order by x.created_at desc, x.id desc limit 1;
$$;
create or replace function t.mx() returns uuid language sql stable security definer set search_path = '' as $$
  select x.match_id from public.match_challenges x
   where x.from_club_id = (select c.id from public.clubs c where c.name = 'Note Lions') and x.match_id is not null
   order by x.created_at desc limit 1;
$$;
create or replace function t.ver() returns int language sql stable security definer set search_path = '' as $$
  select m.proposal_version from public.matches m where m.id = t.mx();
$$;
create or replace function t.cnt(p_n int, p_type text) returns int language sql stable security definer set search_path = '' as $$
  select count(*)::int from public.notifications n
   where n.recipient_id = ('ee200000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid and n.type = p_type;
$$;
create or replace function t.total(p_n int) returns int language sql stable security definer set search_path = '' as $$
  select count(*)::int from public.notifications n
   where n.recipient_id = ('ee200000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
$$;
create or replace function t.typed(p_type text) returns int language sql stable security definer set search_path = '' as $$
  select count(*)::int from public.notifications n where n.recipient_id::text like 'ee200000%' and n.type = p_type;
$$;
create or replace function t.ours() returns int language sql stable security definer set search_path = '' as $$
  select count(*)::int from public.notifications n where n.recipient_id::text like 'ee200000%';
$$;
create or replace function t.one(p_n int, p_type text) returns public.notifications
language sql stable security definer set search_path = '' as $$
  select n.* from public.notifications n
   where n.recipient_id = ('ee200000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid and n.type = p_type
   order by n.created_at desc, n.id desc limit 1;
$$;
-- The line-up state of the challenge match (all, or one person).
create or replace function t.states() returns int language sql stable security definer set search_path = '' as $$
  select count(*)::int from public.notification_lineup_state s where s.match_id = t.mx();
$$;
create or replace function t.state_of(p_n int) returns text language sql stable security definer set search_path = '' as $$
  select s.selection from public.notification_lineup_state s where s.match_id = t.mx() and s.member_id = t.mem(p_n);
$$;
-- A squad: [p_playing] then [p_subs] (person numbers).
create or replace function t.squad(p_playing int[], p_subs int[]) returns jsonb language sql stable as $$
  select jsonb_agg(x.j order by x.o)
    from (select jsonb_build_object('member_id', t.mem(n), 'selection', 'playing') j, o
            from unnest(p_playing) with ordinality u(n, o)
          union all
          select jsonb_build_object('member_id', t.mem(n), 'selection', 'sub'), 100 + o
            from unnest(p_subs) with ordinality u(n, o)) x;
$$;
-- A T20 result between Note Lions (A) and Note Kings (B), optional Player of the Match.
create or replace function t.res(p_a int, p_a_w int, p_b int, p_b_w int, p_pom int) returns jsonb language sql stable as $$
  select jsonb_build_object('outcome', case when p_a > p_b then 'club_a_won' when p_b > p_a then 'club_b_won' else 'tie' end,
           'innings', jsonb_build_array(
             jsonb_build_object('batting_club_id', t.club(1), 'runs', p_a, 'wickets', p_a_w, 'balls', 120),
             jsonb_build_object('batting_club_id', t.club(2), 'runs', p_b, 'wickets', p_b_w, 'balls', 110)))
         || case when p_pom is null then '{}'::jsonb else jsonb_build_object('player_of_match_member_id', t.mem(p_pom)) end;
$$;
create or replace function t.make_person(p_n int, p_player boolean default true) returns uuid language plpgsql as $$
declare
  v uuid := t.p(p_n);
begin
  insert into auth.users (id, email) values (v, format('note%s@local.test', p_n));
  insert into public.current_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
  insert into public.permanent_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
  update public.profiles
     set full_name = format('Note Person %s', p_n),
         phone = format('+923%s', lpad((610000000 + p_n)::text, 9, '0')),
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
-- Synthetic data: owners 1 (Note Lions, A), 2 (Note Kings, B), 3 (Note
-- Riders, C); A members 101–116 and 118 (players), 117 (staff: no cricket
-- profile); B members 201–215; C member 401; 300–302 in no club yet.
-- ---------------------------------------------------------------------------
select t.nobody();
select count(*) from (select t.make_person(n) from unnest(array[1, 2, 3, 300, 301, 302, 401, 118]
                        || array(select generate_series(101, 116)) || array(select generate_series(201, 215))) n) s;
select t.make_person(117, false);
insert into public.clubs (owner_id, name, city, club_type) values
  (t.p(1), 'Note Lions', 'Lahore', 'corporate'),
  (t.p(2), 'Note Kings', 'Karachi', 'corporate'),
  (t.p(3), 'Note Riders', 'Lahore', 'corporate');
insert into public.club_members (club_id, user_id, member_role, status)
select case when n < 200 then t.club(1) when n < 400 then t.club(2) else t.club(3) end, t.p(n), 'player', 'active'
  from unnest(array(select generate_series(101, 118)) || array(select generate_series(201, 215)) || array[401]) n;
select t.ok(t.ours() = 0, 'B0 setting up clubs and members notifies nobody');

-- ---------------------------------------------------------------------------
-- S. Access: read own rows only; nobody writes directly
-- ---------------------------------------------------------------------------
set role anon;
select t.expect_error('select count(*) from public.notifications', '%permission denied%', 'S1 anon cannot read notifications');
select t.expect_error('select * from public.my_notifications(''player'')', '%permission denied%', 'S1b anon cannot call my_notifications');
select t.expect_error('select public.publish_club_announcement(gen_random_uuid(), ''t'', ''m'', ''all'')', '%permission denied%',
                      'S1c anon cannot publish an announcement');
reset role;
set role authenticated;
select t.as_user(t.p(101));
select t.expect_error(format('insert into public.notifications (recipient_id, inbox, type, dedupe_key) values (%L, %L, %L, %L)',
                             t.p(101), 'player', 'announcement', 'x'), '%permission denied%', 'S2 a user cannot insert a notification');
select t.expect_error('update public.notifications set read_at = now()', '%permission denied%', 'S2b nor update one directly');
select t.expect_error('delete from public.notifications', '%permission denied%', 'S2c nor delete one');
select t.expect_error('select count(*) from public.club_announcements', '%permission denied%', 'S2d nor read announcements directly');
select t.expect_error('select count(*) from public.notification_lineup_state', '%permission denied%', 'S2e nor the line-up state');
select t.expect_error(format('select public.notification_add(%L, %L, %L, %L, %L)', t.p(102), 'player', 'announcement', 'x', '{}'),
                      '%permission denied%', 'S3 a user cannot call the internal notification_add');
select t.expect_error('select public.notification_person_name(gen_random_uuid())', '%permission denied%',
                      'S3b nor read names through the internal helper');
reset role;
set role service_role;
select t.nobody();
select t.expect_error('select count(*) from public.notifications', '%permission denied%', 'S4 service_role cannot read notifications directly');
select t.expect_error('select * from public.my_notifications(''player'')', '%permission denied%', 'S4b nor call the inbox API');
select t.expect_error(format('select public.notification_add(%L, %L, %L, %L, %L)', t.p(102), 'player', 'announcement', 'x', '{}'),
                      '%permission denied%', 'S4c nor notification_add');
reset role;

-- ---------------------------------------------------------------------------
-- J. Join requests
-- ---------------------------------------------------------------------------
set role authenticated;
select t.as_user(t.p(300));
select (public.request_to_join_club(t.code(1))).id is not null;
select t.ok(t.cnt(1, 'join_request_received') = 1 and t.total(300) = 0
            and (select n.inbox = 'club_owner' and n.club_id = t.club(1) and n.subject_id = t.req(300)
                        and n.person_id = t.p(300) and n.params ->> 'person_name' = 'Note Person 300'
                        and n.params ->> 'club_name' = 'Note Lions' and n.read_at is null
                   from t.one(1, 'join_request_received') n),
            'J1 a join request tells the owner (club_owner inbox, applicant''s name, the request) — not the applicant');
select t.as_user(t.p(1));
select (public.decide_join_request(t.req(300), true, 'player')).status;
select t.ok(t.cnt(300, 'join_request_approved') = 1 and t.total(1) = 1
            and (select n.inbox = 'player' and n.params = jsonb_build_object('club_name', 'Note Lions', 'role', 'player')
                   from t.one(300, 'join_request_approved') n),
            'J2 approval tells the applicant (player inbox, club and role); the owner is not told of their own action');
select t.as_user(t.p(301));
select (public.request_to_join_club(t.code(1))).id is not null;
select t.as_user(t.p(1));
select (public.decide_join_request(t.req(301), false, 'player', 'Squad is full')).status;
select t.ok(t.cnt(301, 'join_request_declined') = 1
            and (select n.params = jsonb_build_object('club_name', 'Note Lions') from t.one(301, 'join_request_declined') n),
            'J3 a decline tells the applicant — without the owner''s reason (no free text)');
select t.as_user(t.p(302));
select (public.request_to_join_club(t.code(1))).id is not null;
select (public.cancel_join_request(t.req(302))).status;
select t.ok(t.cnt(1, 'join_request_received') = 3 and t.total(302) = 0, 'J4 a cancelled request tells nobody more');
select t.as_user(t.p(300));
select t.expect_error(format('select public.request_to_join_club(%L)', t.code(1)), '%already member%',
                      'J5 a refused request …');
select t.ok(t.cnt(1, 'join_request_received') = 3, 'J5b … notifies nobody');
select t.as_user(t.p(302));
select (public.request_to_join_club(t.code(1))).id is not null;
reset role;

-- P1-A: a notification is part of its action. If writing it fails, the
-- action fails and nothing of it stays.
begin;
alter table public.notifications add constraint t_p1a_refuse check (type <> 'join_request_approved') not valid;
set local role authenticated;
select t.as_user(t.p(1));
select t.expect_error(format('select public.decide_join_request(%L, true, %L)', t.req(302), 'player'), '%t_p1a_refuse%',
                      'P1 a failing notification fails the approval …');
reset role;
select t.ok((select r.status = 'pending' from public.join_requests r where r.id = t.req(302))
            and not exists (select 1 from public.club_members m where m.user_id = t.p(302)),
            'P1b … and the request stays pending, no membership created');
rollback;
select t.nobody();

-- ---------------------------------------------------------------------------
-- M. Removed from a club
-- ---------------------------------------------------------------------------
set role authenticated;
select t.as_user(t.p(1));
select public.remove_club_member(t.mem(300)) is not null;
select t.ok(t.cnt(300, 'removed_from_club') = 1
            and (select n.inbox = 'player' and n.params = jsonb_build_object('club_name', 'Note Lions') and n.club_id = t.club(1)
                   from t.one(300, 'removed_from_club') n),
            'M1 the removed member is told, neutrally (club name only)');
select public.remove_club_member(t.mem(300)) is not null; -- idempotent (migration 11)
select t.ok(t.cnt(300, 'removed_from_club') = 1, 'M2 removing again (a no-op) tells nothing more');
reset role;
select t.nobody();
update public.club_members set status = 'removed', removed_at = now(), removed_by = user_id where user_id = t.p(118);
select t.ok(t.total(118) = 0, 'M3 leaving by oneself (removed_by = self) tells nobody');

-- ---------------------------------------------------------------------------
-- O. Ownership transfer (club C: owner 3 → member 401)
-- ---------------------------------------------------------------------------
set role authenticated;
select t.as_user(t.p(3));
select (public.offer_club_ownership(t.club(3), t.mem(401), 'manager')).status;
select t.ok(t.cnt(401, 'ownership_offered') = 1 and t.total(3) = 0
            and (select n.inbox = 'player' and n.subject_id = t.xfer() and n.person_id = t.p(3)
                        and n.params ->> 'person_name' = 'Note Person 3' and n.params ? 'expires_at'
                   from t.one(401, 'ownership_offered') n),
            'O1 an offer tells the member (player inbox, the owner''s name, the offer)');
select t.as_user(t.p(401));
select (public.reject_ownership_transfer(t.xfer())).status;
select t.ok(t.cnt(3, 'ownership_rejected') = 1
            and (select n.inbox = 'club_owner' and n.person_id = t.p(401) from t.one(3, 'ownership_rejected') n),
            'O2 a rejection tells the owner (club_owner inbox)');
select t.as_user(t.p(3));
select (public.offer_club_ownership(t.club(3), t.mem(401), 'manager')).status;
select (public.cancel_ownership_transfer(t.xfer())).status;
select t.ok(t.cnt(401, 'ownership_offered') = 2 and t.cnt(401, 'ownership_withdrawn') = 1,
            'O3 a withdrawn offer tells the member');
select (public.offer_club_ownership(t.club(3), t.mem(401), 'manager')).status;
select t.as_user(t.p(401));
select (public.accept_ownership_transfer(t.xfer())).status;
select t.ok(t.cnt(3, 'ownership_accepted') = 1 and t.cnt(401, 'ownership_offered') = 3
            and (select n.inbox = 'player' and n.params ->> 'person_name' = 'Note Person 401' from t.one(3, 'ownership_accepted') n),
            'O4 an acceptance tells the previous owner — in the player inbox (they are a member now)');
reset role;

-- ---------------------------------------------------------------------------
-- C. Challenges and the schedule (A challenges B)
-- ---------------------------------------------------------------------------
set role authenticated;
select t.as_user(t.p(1));
select (public.send_challenge(t.club(1), t.club(2), 't20', null, current_date + 10, 'Note Ground', 'Friendly?')).status;
select t.ok(t.cnt(2, 'challenge_received') = 1 and t.cnt(1, 'challenge_received') = 0
            and (select n.inbox = 'club_owner' and n.club_id = t.club(2) and n.subject_id = t.chal()
                        and n.params ->> 'opponent_name' = 'Note Lions' and n.params ->> 'format' = 't20'
                        and n.params ->> 'venue_name' = 'Note Ground' and not n.params ? 'message'
                   from t.one(2, 'challenge_received') n),
            'C1 a challenge tells the challenged owner (terms, no message text)');
select t.as_user(t.p(2));
select (public.respond_to_challenge(t.chal(), false)).status;
select t.ok(t.cnt(1, 'challenge_declined') = 1
            and (select n.club_id = t.club(1) and n.params ->> 'opponent_name' = 'Note Kings' from t.one(1, 'challenge_declined') n),
            'C2 a decline tells the challenger''s owner');
select t.as_user(t.p(1));
select (public.send_challenge(t.club(1), t.club(2), 't20', null, current_date + 10, 'Note Ground', null)).status;
select t.as_user(t.p(2));
select (public.respond_to_challenge(t.chal(), true)).status;
select t.ok(t.cnt(1, 'challenge_accepted') = 1 and t.cnt(2, 'challenge_received') = 2 and t.cnt(2, 'schedule_proposed') = 0
            and (select n.match_id = t.mx() from t.one(1, 'challenge_accepted') n),
            'C3 an acceptance tells the challenger (with the match); the challenge''s own schedule is no new proposal');
select (public.respond_to_match_schedule(t.mx(), t.ver(), true)).status;
select t.ok(t.cnt(1, 'schedule_accepted') = 1
            and (select n.params ->> 'reschedule' = 'false' and n.params ->> 'venue_name' = 'Note Ground' and n.match_id = t.mx()
                   from t.one(1, 'schedule_accepted') n)
            and t.typed('match_rescheduled') = 0,
            'C4 confirming the schedule tells the proposer; no line-ups yet, so no players (P1-B)');
select t.expect_error(format('select public.respond_to_match_schedule(%L, %s, true)', t.mx(), t.ver()), '%no proposal%',
                      'C5 a refused answer …');
-- Owner 1 so far: 4 join requests, the declined and the accepted challenge, the accepted schedule.
select t.ok(t.total(1) = 7, 'C5b … notifies nobody');

-- Line-ups (confirmed match only): told once, at commit, per changed player.
select t.as_user(t.p(1));
select (public.save_match_lineup(t.mx(), 'Note XI', null, t.squad(array(select generate_series(101, 111)), array[112, 113, 114, 115]),
                                 t.mem(101), t.mem(102))).name;
select t.ok(t.typed('lineup_selected') = 15
            and t.states() = 15
            and (select n.inbox = 'player' and n.params ->> 'selection' = 'playing' and n.params ->> 'leader' = 'captain'
                        and n.params ->> 'opponent_name' = 'Note Kings' and n.match_id = t.mx() and n.club_id = t.club(1)
                   from t.one(101, 'lineup_selected') n)
            and (select n.params ->> 'leader' = 'vice_captain' from t.one(102, 'lineup_selected') n)
            and (select n.params ->> 'selection' = 'sub' and not n.params ? 'leader' from t.one(115, 'lineup_selected') n)
            and t.total(116) = 0 and t.total(1) = 7,
            'L1 saving a line-up tells the 15 selected players once each (selection, captain / vice-captain)');
select (public.save_match_lineup(t.mx(), 'Note XI', null, t.squad(array(select generate_series(101, 111)), array[112, 113, 114, 115]),
                                 t.mem(101), t.mem(102))).name;
select t.ok(t.typed('lineup_selected') = 15 and t.typed('lineup_changed') = 0 and t.typed('lineup_dropped') = 0,
            'L2 re-saving the same line-up tells nobody');
select (public.save_match_lineup(t.mx(), 'Note XI', null, t.squad(array(select generate_series(102, 112)), array[101, 113, 114, 116]),
                                 t.mem(102), t.mem(103))).name;
select t.ok(t.typed('lineup_selected') = 16 and t.typed('lineup_changed') = 2 and t.typed('lineup_dropped') = 1
            and (select n.params ->> 'selection' = 'sub' and n.params ->> 'previous_selection' = 'playing' from t.one(101, 'lineup_changed') n)
            and (select n.params ->> 'selection' = 'playing' and n.params ->> 'previous_selection' = 'sub' from t.one(112, 'lineup_changed') n)
            and (select not n.params ? 'selection' and n.params ->> 'previous_selection' = 'sub' from t.one(115, 'lineup_dropped') n)
            and t.cnt(116, 'lineup_selected') = 1 and t.cnt(102, 'lineup_changed') = 0,
            'L3 a changed line-up tells exactly the 4 changed players (moved, dropped, added); a new captaincy alone tells nothing');
select t.as_user(t.p(2));
select (public.save_match_lineup(t.mx(), 'Kings XI', null, t.squad(array(select generate_series(201, 211)), array[212, 213, 214, 215]),
                                 null, null)).name;
select t.ok(t.typed('lineup_selected') = 31 and t.states() = 30,
            'L4 the other club''s line-up tells its 15 players');

-- Rescheduling: proposals between the owners; the players when it is agreed.
select t.as_user(t.p(1));
select (public.propose_match_schedule(t.mx(), now() + interval '12 days', 'Note Park', 'Lahore')).status;
select t.ok(t.cnt(2, 'schedule_proposed') = 1
            and (select n.params ->> 'reschedule' = 'true' and n.params ->> 'venue_name' = 'Note Park'
                        and n.params ->> 'opponent_name' = 'Note Lions'
                   from t.one(2, 'schedule_proposed') n),
            'R1 a reschedule proposal tells the other owner');
select t.as_user(t.p(2));
select (public.respond_to_match_schedule(t.mx(), t.ver(), false)).status;
select t.ok(t.cnt(1, 'schedule_declined') = 1 and t.typed('match_rescheduled') = 0, 'R2 a decline tells the proposer only');
select (public.propose_match_schedule(t.mx(), now() + interval '13 days', 'Kings Oval', null)).status;
select t.ok(t.cnt(1, 'schedule_proposed') = 1, 'R3 a counter-proposal tells the other owner');
select t.as_user(t.p(1));
select (public.respond_to_match_schedule(t.mx(), t.ver(), true)).status;
select t.ok(t.cnt(2, 'schedule_accepted') = 1 and t.typed('match_rescheduled') = 30
            and t.cnt(1, 'match_rescheduled') = 0 and t.cnt(2, 'match_rescheduled') = 0
            and (select n.params ->> 'venue_name' = 'Kings Oval' and n.params ? 'previous_starts_at'
                        and n.params ->> 'selection' = 'sub'
                   from t.one(101, 'match_rescheduled') n),
            'R4 an agreed reschedule tells the proposer and the 30 selected players (new time, previous time, their selection)');

-- Removed while selected: told about the removal only.
select public.remove_club_member(t.mem(116)) is not null;
select t.ok(t.cnt(116, 'removed_from_club') = 1 and t.cnt(116, 'lineup_dropped') = 0
            and t.state_of(116) is null,
            'L5 a selected member who is removed hears of the removal only (no "dropped"); their state is forgotten');

-- Cancellation: the other owner and the selected players of both clubs.
select t.as_user(t.p(2));
select (public.cancel_match(t.mx(), 'Ground unavailable')).status;
select t.ok(t.cnt(1, 'match_cancelled') = 1 and t.cnt(2, 'match_cancelled') = 0 and t.typed('match_cancelled') = 1 + 29
            and (select n.inbox = 'club_owner' and n.params ->> 'opponent_name' = 'Note Kings' and n.params ? 'starts_at'
                        and position('Ground unavailable' in n.params::text) = 0
                   from t.one(1, 'match_cancelled') n)
            and t.cnt(116, 'match_cancelled') = 0,
            'C6 a cancellation tells the other owner and the 29 selected active players — not the canceller, no reason text');
reset role;
select t.nobody();

-- ---------------------------------------------------------------------------
-- X. Official results (the trusted scorer path, service_role)
-- ---------------------------------------------------------------------------
insert into public.matches (id, club_a_id, club_b_id, format, status, starts_at, venue_name)
values (t.m(1), t.club(1), t.club(2), 't20', 'confirmed', now() - interval '1 day', 'Note Ground');
insert into public.scorer_clients (id, name, key_id) values
  (t.cl(1), 'Note Scorer', 'note.scorer.k1'), (t.cl(2), 'Note Verifier', 'note.verifier.k1');
select public.assign_match_official(t.m(1), t.cl(1), 'scorer');
select public.assign_match_official(t.m(1), t.cl(2), 'verifier');
set role service_role;
select (public.ingest_official_result(t.cl(1), 'note-1', t.m(1), t.res(150, 3, 120, 10, 105), 'req-1')).outcome;
select t.ok(t.typed('result_published') = 0 and t.typed('player_of_match') = 0, 'X1 a provisional (submitted) result tells nobody');
select (public.verify_official_result(t.cl(2), 'note-2', t.m(1), 1, true, null)).outcome;
reset role;
select t.ok(t.cnt(1, 'result_published') = 1 and t.cnt(2, 'result_published') = 1
            and (select n.inbox = 'club_owner' and n.params ->> 'result' = 'won' and n.params ->> 'opponent_name' = 'Note Kings'
                        and n.match_id = t.m(1) from t.one(1, 'result_published') n)
            and (select n.params ->> 'result' = 'lost' from t.one(2, 'result_published') n)
            and t.typed('result_published') = 2 + (select count(*) from public.club_members m
                                                     where m.club_id in (t.club(1), t.club(2)) and m.status = 'active'
                                                       and m.member_role <> 'owner')
            and (select bool_and(n.inbox = 'player') from public.notifications n
                  where n.type = 'result_published' and n.recipient_id not in (t.p(1), t.p(2)) and n.recipient_id::text like 'ee200000%')
            and t.cnt(300, 'result_published') = 0 and t.cnt(116, 'result_published') = 0,
            'X2 an official result tells both owners (won / lost) and every active member of both clubs — not former members');
select t.ok(t.cnt(105, 'player_of_match') = 1 and t.typed('player_of_match') = 1
            and (select n.inbox = 'player' and n.params ->> 'club_name' = 'Note Lions' from t.one(105, 'player_of_match') n),
            'X3 the Player of the Match is told');
set role service_role;
select (public.correct_official_result(t.cl(1), 'note-3', t.m(1), 1, 'Scoring error', t.res(150, 3, 140, 10, 106), 'req-3')).outcome;
select (public.verify_official_result(t.cl(2), 'note-4', t.m(1), 2, false, 'Totals do not match')).outcome;
reset role;
select t.ok(t.typed('result_corrected') = 0 and t.cnt(106, 'player_of_match') = 0,
            'X4 a correction still waiting, or rejected, tells nobody');
set role service_role;
select (public.correct_official_result(t.cl(1), 'note-5', t.m(1), 1, 'Scoring error', t.res(150, 3, 140, 10, 106), 'req-5')).outcome;
select (public.verify_official_result(t.cl(2), 'note-6', t.m(1), 3, true, null)).outcome;
reset role;
select t.ok(t.typed('result_corrected') = t.typed('result_published') and t.cnt(1, 'result_corrected') = 1
            and (select n.params ->> 'version' = '3' from t.one(1, 'result_corrected') n)
            and t.cnt(106, 'player_of_match') = 1 and t.cnt(105, 'player_of_match') = 1,
            'X5 an official correction tells everyone again (version 3); a new Player of the Match is told');
set role service_role;
select (public.correct_official_result(t.cl(1), 'note-7', t.m(1), 3, 'Extras fixed', t.res(151, 3, 140, 10, 106), 'req-7')).outcome;
select (public.verify_official_result(t.cl(2), 'note-8', t.m(1), 4, true, null)).outcome;
reset role;
select t.ok(t.cnt(106, 'player_of_match') = 1 and t.cnt(1, 'result_corrected') = 2,
            'X6 a correction keeping the same Player of the Match does not tell them again');

-- ---------------------------------------------------------------------------
-- N. Club announcements (server-side, D10)
-- (Each action is its own statement: a check reads the rows it wrote.)
-- ---------------------------------------------------------------------------
select count(*) as a_members from public.club_members m
 where m.club_id = t.club(1) and m.status = 'active' and m.member_role <> 'owner' \gset
set role authenticated;
select t.as_user(t.p(1));
select r.recipient_count as n1 from public.publish_club_announcement(t.club(1), '  Nets   on Friday ', 'Bring your kit.', 'all') r \gset
select t.ok(:n1 = :a_members and t.typed('announcement') = :a_members
            and t.cnt(1, 'announcement') = 0 and t.cnt(300, 'announcement') = 0 and t.cnt(116, 'announcement') = 0
            and (select n.inbox = 'player' and n.params = jsonb_build_object('club_name', 'Note Lions', 'title', 'Nets on Friday')
                        and n.club_id = t.club(1)
                   from t.one(101, 'announcement') n),
            'N1 "all": every active member except the author is told (title only, tidied)');
select r.recipient_count as n2 from public.publish_club_announcement(t.club(1), 'Players only', 'Fitness test.', 'players') r \gset
select t.ok(:n2 = :a_members - 1 and t.cnt(117, 'announcement') = 1 and t.cnt(101, 'announcement') = 2,
            'N2 "players": only members with a cricket profile (the staff member is not told)');
select r.recipient_count as n3 from public.publish_club_announcement(t.club(1), 'Staff only', 'Kit order.', 'staff') r \gset
select t.ok(:n3 = 1 and t.cnt(117, 'announcement') = 2 and t.cnt(101, 'announcement') = 2,
            'N3 "staff": only members without a cricket profile');
select t.expect_error(format('select public.publish_club_announcement(%L, %L, %L, %L)', t.club(1), '   ', 'x', 'all'),
                      '%invalid title%', 'N4 a blank title is refused');
select t.expect_error(format('select public.publish_club_announcement(%L, %L, %L, %L)', t.club(1), repeat('t', 61), 'x', 'all'),
                      '%invalid title%', 'N4b a 61-character title is refused');
select t.expect_error(format('select public.publish_club_announcement(%L, %L, %L, %L)', t.club(1), 't', repeat('m', 281), 'all'),
                      '%invalid message%', 'N4c a 281-character message is refused');
select t.expect_error(format('select public.publish_club_announcement(%L, %L, %L, %L)', t.club(1), 't', 'm', 'everyone'),
                      '%invalid audience%', 'N4d an unknown audience is refused');
select t.as_user(t.p(101));
select t.expect_error(format('select public.publish_club_announcement(%L, %L, %L, %L)', t.club(1), 't', 'm', 'all'),
                      '%not allowed%', 'N5 a member cannot publish');
select t.expect_error(format('select public.publish_club_announcement(%L, %L, %L, %L)', t.club(2), 't', 'm', 'all'),
                      '%not allowed%', 'N5b nor in another club');
reset role;
select t.ok((select count(*) from public.club_announcements a where a.club_id in (t.club(1), t.club(2))) = 3
            and t.typed('announcement') = :a_members + :n2 + :n3,
            'N5c refused publishes store and send nothing');
select n.subject_id as ann_all from public.notifications n
 where n.recipient_id = t.p(101) and n.params ->> 'title' = 'Nets on Friday' \gset
select n.subject_id as ann_players from public.notifications n
 where n.recipient_id = t.p(101) and n.params ->> 'title' = 'Players only' \gset
set role authenticated;
select t.as_user(t.p(101));
select t.ok((select a.title = 'Nets on Friday' and a.message = 'Bring your kit.' and a.audience = 'all'
                    and a.club_name = 'Note Lions' and a.recipient_count is null
               from public.club_announcement(:'ann_all') a),
            'N6 a recipient reads the announcement (no recipient count)');
select t.as_user(t.p(201));
select t.expect_error(format('select * from public.club_announcement(%L)', :'ann_all'), '%not found%',
                      'N6b someone it was not sent to cannot read it');
select t.as_user(t.p(117));
select t.expect_error(format('select * from public.club_announcement(%L)', :'ann_players'), '%not found%',
                      'N6c nor a member outside its audience');
select t.expect_error(format('select * from public.club_announcement_list(%L)', t.club(1)), '%not allowed%',
                      'N7 only the owner lists the club''s announcements');
select t.as_user(t.p(1));
select t.ok((select count(*) = 3 and bool_and(a.recipient_count is not null) from public.club_announcement_list(t.club(1)) a)
            and (select a.title from public.club_announcement_list(t.club(1), 1) a) = 'Staff only'
            and (select a.recipient_count = :a_members from public.club_announcement(:'ann_all') a),
            'N7b the owner lists them, newest first, and sees the recipient counts');
select count(*) from (select public.publish_club_announcement(t.club(1), 'Note ' || k, 'Message ' || k, 'staff')
                        from generate_series(1, 17) k) s;
select t.expect_error(format('select public.publish_club_announcement(%L, %L, %L, %L)', t.club(1), 'One more', 'm', 'all'),
                      '%too many%', 'N8 at most 20 announcements per club per 24 hours');
reset role;

-- ---------------------------------------------------------------------------
-- I. The inbox API: own rows, paging, unread count, marking read, 90 days
-- ---------------------------------------------------------------------------
set role authenticated;
select t.as_user(t.p(101));
select t.ok((select count(*) from public.notifications) = t.total(101) and t.total(101) = 9
            and (select count(*) from public.my_notifications('player', null, null, 100)) = 9
            and (select count(*) from public.my_notifications('club_owner')) = 0,
            'I1 a user reads exactly their own rows (direct select under RLS = the API), per inbox');
select t.ok((with p1 as (select * from public.my_notifications('player', null, null, 4)),
                  last as (select * from p1 order by created_at, notification_id limit 1),
                  p2 as (select * from public.my_notifications('player', (select created_at from last),
                                                               (select notification_id from last), 4))
             select (select count(*) from p1) = 4 and (select count(*) from p2) = 4
                    and not exists (select 1 from p1 join p2 using (notification_id))
                    and (select min(created_at) from p1) >= (select max(created_at) from p2)),
            'I2 paging: the next page continues after the last row, no overlap');
select t.expect_error('select * from public.my_notifications(''admin'')', '%invalid%', 'I3 an unknown inbox is refused');
select t.expect_error('select * from public.my_notifications(''player'', null, null, 101)', '%invalid%', 'I3b a page over 100 is refused');
select t.expect_error('select * from public.my_notifications(''player'', now(), null)', '%invalid%', 'I3c a half cursor is refused');
select t.ok(public.notification_unread_count('player') = 9, 'I4 everything starts unread');
select (select n.id from t.one(101, 'lineup_selected') n) as id_a, (select n.id from t.one(101, 'announcement') n) as id_b,
       (select n.id from t.one(102, 'lineup_selected') n) as id_other \gset
select public.mark_notifications_read(array[:'id_a', :'id_b', :'id_other']::uuid[]) as marked \gset
select t.ok(:marked = 2 and public.notification_unread_count('player') = 7
            and (select n.read_at is null from t.one(102, 'lineup_selected') n),
            'I5 marking read: own ids only (another person''s id is ignored)');
select public.mark_notifications_read(array[:'id_a']::uuid[]) as again \gset
select t.ok(:again = 0 and public.mark_notifications_read(null) = 0 and public.mark_notifications_read('{}') = 0,
            'I5b marking again, or nothing, changes nothing');
select t.expect_error(format('select public.mark_notifications_read(%L::uuid[])',
                             (select array_agg(gen_random_uuid())::text from generate_series(1, 201))),
                      '%invalid%', 'I5c at most 200 ids at once');
select max(n.created_at) - interval '1 microsecond' as up_to,
       count(*) filter (where n.created_at = (select max(x.created_at) from public.notifications x where x.read_at is null)) as newest
  from public.notifications n where n.read_at is null \gset
select public.mark_all_notifications_read('player', :'up_to') as upto_marked \gset
select t.ok(:newest >= 1 and public.notification_unread_count('player') = :newest,
            'I6 "mark all read" up to what the app showed leaves newer ones unread');
select public.mark_all_notifications_read('player') as all_marked \gset
select t.ok(:all_marked = :newest and public.notification_unread_count('player') = 0,
            'I6b "mark all read" marks the whole inbox');
select t.as_user(t.p(3));
select t.ok(public.notification_unread_count('club_owner') = 1 and public.notification_unread_count('player') = 1,
            'I7 owner 3 has one unread in each inbox …');
select public.mark_all_notifications_read('club_owner') as owner_marked \gset
select t.ok(:owner_marked = 1 and public.notification_unread_count('club_owner') = 0
            and public.notification_unread_count('player') = 1,
            'I7b … and the two inboxes are marked separately');
reset role;
select t.nobody();
insert into public.notifications (recipient_id, inbox, type, params, dedupe_key, created_at)
values (t.p(102), 'player', 'announcement', '{"title": "Old"}', 'note:old', now() - interval '91 days');
set role authenticated;
select t.as_user(t.p(102));
select t.ok(not exists (select 1 from public.my_notifications('player', null, null, 100) n where n.params ->> 'title' = 'Old')
            and public.notification_unread_count('player') = t.total(102) - 1,
            'I8 older than 90 days: not shown, not counted (D7)');
reset role;

-- A notification never changes, except being read once.
select t.expect_error(format('update public.notifications set type = %L where recipient_id = %L', 'announcement', t.p(101)),
                      '%invalid change%', 'G1 its type cannot change');
select t.expect_error(format('update public.notifications set params = %L where recipient_id = %L', '{}', t.p(101)),
                      '%invalid change%', 'G2 nor its parameters');
select t.expect_error(format('update public.notifications set read_at = null where recipient_id = %L and read_at is not null', t.p(101)),
                      '%invalid change%', 'G3 nor can it become unread');
select t.expect_error(format('update public.notifications set recipient_id = %L where recipient_id = %L', t.p(102), t.p(101)),
                      '%invalid change%', 'G4 nor move to someone else');
select t.expect_error(format('update public.notifications set read_at = now() where recipient_id = %L and read_at is not null', t.p(101)),
                      '%invalid change%', 'G5 nor be read twice');

-- ---------------------------------------------------------------------------
-- D. Account deletion (D11)
-- ---------------------------------------------------------------------------
select t.ok(t.total(300) = 2
            and (select count(*) = 1 from public.notifications n
                  where n.recipient_id = t.p(1) and n.person_id = t.p(300) and n.params ->> 'person_name' = 'Note Person 300'),
            'D0 before: 300 has 2 notifications; the owner''s request notice names them');
delete from auth.users where id = t.p(300);
select t.ok(t.total(300) = 0
            and (select count(*) = 1 and bool_and(n.person_id is null and not n.params ? 'person_name'
                                                  and n.params ->> 'club_name' = 'Note Lions' and n.subject_id is not null)
                   from public.notifications n
                  where n.recipient_id = t.p(1) and n.type = 'join_request_received' and n.params ->> 'person_deleted' = 'true')
            and (select count(*) = 3 from public.notifications n
                  where n.recipient_id = t.p(1) and n.type = 'join_request_received' and n.params ? 'person_name'),
            'D1 a deleted account''s own notifications go; in others'' its name is forgotten ("Deleted player"), other names stay');
select t.ok(t.total(113) > 0 and exists (select 1 from public.notification_lineup_state s where s.member_id = t.mem(113)),
            'D2 before: 113 (selected) has notifications and a line-up state');
select t.ours() as before_ours, t.total(113) as before_113 \gset
delete from auth.users where id = t.p(113);
select t.ok(t.total(113) = 0 and t.ours() = :before_ours - :before_113 and t.typed('lineup_dropped') = 1
            and not exists (select 1 from public.notification_lineup_state s
                             where not exists (select 1 from public.club_members m where m.id = s.member_id)),
            'D2b deleting a selected player removes their notifications and state, and tells nobody "dropped"');

-- ---------------------------------------------------------------------------
-- Clean up (this database only): only this check's own records (people
-- ee2…, matches ee2…aa, clients ec2e…), so it also runs on a copy that holds
-- other data.
-- ---------------------------------------------------------------------------
select t.nobody();
delete from public.clubs where owner_id::text like 'ee200000%';
select t.ok(exists (select 1 from public.notifications n where n.recipient_id::text like 'ee200000%')
            and not exists (select 1 from public.notifications n where n.recipient_id::text like 'ee200000%' and n.club_id is not null)
            and not exists (select 1 from public.club_announcements a where a.created_by::text like 'ee200000%'),
            'D3 deleting a club keeps its members'' notifications (club link cleared); its announcements go');
delete from public.matches where id::text like 'ee2000aa%';
delete from auth.users where id::text like 'ee200000%';
set session_replication_role = replica;
delete from public.result_submission_log where client_id::text like 'ec2e0000%' or match_id::text like 'ee2000aa%';
delete from public.result_change_log where match_id::text like 'ee2000aa%';
delete from public.scorer_clients where id::text like 'ec2e0000%';
set session_replication_role = default;
select t.ok(not exists (select 1 from public.profiles where id::text like 'ee200000%')
            and not exists (select 1 from public.notifications where recipient_id::text like 'ee200000%')
            and not exists (select 1 from public.notification_lineup_state s
                             join public.matches m on m.id = s.match_id where m.club_a_id is null)
            and not exists (select 1 from public.scorer_clients where id::text like 'ec2e0000%')
            and not exists (select 1 from public.result_submission_log
                             where client_id::text like 'ec2e0000%' or match_id::text like 'ee2000aa%')
            and not exists (select 1 from public.result_change_log where match_id::text like 'ee2000aa%')
            and not exists (select 1 from public.matches where id::text like 'ee2000aa%'),
            'Z cleanup done');
drop schema t cascade;
