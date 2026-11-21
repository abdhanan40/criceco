-- CricEco · LOCAL TEST ONLY — migration 24 (result write lockdown and the
-- trusted scorer foundation) on a DISPOSABLE plain PostgreSQL 17 database,
-- after 00_auth_stub.sql (which grants like Supabase: new tables and
-- functions to anon / authenticated / service_role), 02_legacy_profiles_fixture.sql,
-- migrations 1–23 (+ the D1 location seed) and migration 24. Synthetic data
-- only (ids ee1…, clients ec1e…).
-- Run with psql:  psql -X -v ON_ERROR_STOP=1 -f 19_result_write_lockdown_local_check.sql
-- Every check prints "PASS: …"; the first failure stops the run ("FAIL: …").
-- Concurrency (two sessions) is in 19b_result_write_lockdown_concurrency.sh.
-- Refuses to run on a real Supabase project (its auth.users has passwords).
\set ON_ERROR_STOP on

do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password') then
    raise exception 'LOCAL ONLY: this looks like a real Supabase project — refusing';
  end if;
  if to_regclass('public.scorer_clients') is null then
    raise exception 'apply migration 24 first';
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
create or replace function t.p(p_n int) returns uuid language sql immutable as $$
  select ('ee100000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
$$;
create or replace function t.m(p_n int) returns uuid language sql immutable as $$
  select ('ee1000aa-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
$$;
-- Clients: 1 scorer S, 2 verifier V, 3 single-step trusted T, 4 revoked R,
-- 5 never assigned U, 9 unknown (not registered).
create or replace function t.cl(p_n int) returns uuid language sql immutable as $$
  select ('ec1e0000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
$$;
create or replace function t.mem(p_n int) returns uuid language sql stable security definer set search_path = '' as $$
  select m.id from public.club_members m where m.user_id = ('ee100000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
$$;
create or replace function t.club(p_owner int) returns uuid language sql stable security definer set search_path = '' as $$
  select c.id from public.clubs c where c.owner_id = ('ee100000-0000-4000-8000-' || lpad(p_owner::text, 12, '0'))::uuid;
$$;
create or replace function t.make_person(p_n int) returns uuid language plpgsql as $$
declare
  v uuid := t.p(p_n);
begin
  insert into auth.users (id, email) values (v, format('lock%s@local.test', p_n));
  insert into public.current_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
  insert into public.permanent_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
  update public.profiles
     set full_name = format('Lock Person %s', p_n),
         phone = format('+923%s', lpad((600000000 + p_n)::text, 9, '0')),
         date_of_birth = date '2000-05-01', profile_completed = true
   where id = v;
  insert into public.player_profiles (user_id, player_role, batting_style, bowling_style, is_wicketkeeper)
  values (v, 'all_rounder', 'right_handed', 'right_arm_fast', false);
  return v;
end $$;
-- A T20 result: A scores a_runs / a_wkts (120 balls), B b_runs / b_wkts (110).
create or replace function t.totals(p_outcome text, p_a int, p_a_w int, p_b int, p_b_w int) returns jsonb
language sql stable as $$
  select jsonb_build_object('outcome', p_outcome, 'innings', jsonb_build_array(
           jsonb_build_object('batting_club_id', t.club(1), 'runs', p_a, 'wickets', p_a_w, 'balls', 120),
           jsonb_build_object('batting_club_id', t.club(2), 'runs', p_b, 'wickets', p_b_w, 'balls', 110)));
$$;
-- "outcome|version|reason|replayed" of one call.
create or replace function t.fmt(p_outcome text, p_version int, p_reason text, p_replayed boolean) returns text
language sql immutable as $$
  select p_outcome || '|' || coalesce(p_version::text, '-') || '|' || coalesce(p_reason, '-') || '|' || p_replayed;
$$;
create or replace function t.ing(p_client int, p_key text, p_match int, p_payload jsonb) returns text language sql as $$
  select t.fmt(r.outcome, r.version, r.reason, r.replayed)
    from public.ingest_official_result(t.cl(p_client), p_key, t.m(p_match), p_payload, 'req-' || p_key) r;
$$;
create or replace function t.ver(p_client int, p_key text, p_match int, p_version int, p_approve boolean,
                                 p_note text default null) returns text language sql as $$
  select t.fmt(r.outcome, r.version, r.reason, r.replayed)
    from public.verify_official_result(t.cl(p_client), p_key, t.m(p_match), p_version, p_approve, p_note) r;
$$;
create or replace function t.cor(p_client int, p_key text, p_match int, p_corrects int, p_reason text, p_payload jsonb)
returns text language sql as $$
  select t.fmt(r.outcome, r.version, r.reason, r.replayed)
    from public.correct_official_result(t.cl(p_client), p_key, t.m(p_match), p_corrects, p_reason, p_payload) r;
$$;
grant execute on all functions in schema t to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Synthetic data: owners 1 (club A), 2 (club B), 3 (club C); members 101–112
-- of A, 201–212 of B (no line-ups: the pools are the active members); 300 in
-- no club. Matches A v B: m1, m2, m4 T20 played; m3 tomorrow; m5 cancelled.
-- ---------------------------------------------------------------------------
select count(*) from (select t.make_person(n) from unnest(array[1, 2, 3, 300]
                        || array(select generate_series(101, 112)) || array(select generate_series(201, 212))) n) s;
insert into public.clubs (owner_id, name, city, club_type) values
  (t.p(1), 'Lock Lions', 'Lahore', 'corporate'),
  (t.p(2), 'Lock Kings', 'Karachi', 'corporate'),
  (t.p(3), 'Lock Riders', 'Lahore', 'corporate');
insert into public.club_members (club_id, user_id, member_role, status)
select t.club(case when n < 200 then 1 else 2 end), t.p(n), 'player', 'active'
  from unnest(array(select generate_series(101, 112)) || array(select generate_series(201, 212))) n;
insert into public.matches (id, club_a_id, club_b_id, format, status, starts_at, venue_name,
                            cancelled_at, cancelled_by_club_id, cancel_reason)
select t.m(k), t.club(1), t.club(2), 't20', s, st, 'Lock Ground',
       case when s = 'cancelled' then now() end, case when s = 'cancelled' then t.club(1) end,
       case when s = 'cancelled' then 'Rain' end
  from (values (1, 'confirmed', now() - interval '1 day'), (2, 'confirmed', now() - interval '2 days'),
               (3, 'confirmed', now() + interval '1 day'), (4, 'confirmed', now() - interval '3 days'),
               (5, 'cancelled', now() - interval '4 days')) v(k, s, st);
-- Clients are registered by an administrator (SQL). key_id names the key
-- in the Edge Function's secrets — never the secret.
insert into public.scorer_clients (id, name, key_id, single_step_trusted, status, revoked_at) values
  (t.cl(1), 'Lock Scorer', 'lock.scorer.k1', false, 'active', null),
  (t.cl(2), 'Lock Verifier', 'lock.verifier.k1', false, 'active', null),
  (t.cl(3), 'Lock Trusted', 'lock.trusted.k1', true, 'active', null),
  (t.cl(4), 'Lock Revoked', 'lock.revoked.k1', false, 'revoked', now()),
  (t.cl(5), 'Lock Unassigned', 'lock.unassigned.k1', false, 'active', null);

-- ---------------------------------------------------------------------------
-- S. Who may write: nobody in the app; service_role only through the functions
-- ---------------------------------------------------------------------------
select t.ok(to_regprocedure('public.submit_match_result(uuid, text, jsonb, uuid)') is null
            and to_regprocedure('public.submit_match_result_with_scorecard(uuid, text, jsonb, uuid)') is null
            and to_regprocedure('public.confirm_match_result(uuid, integer)') is null
            and to_regprocedure('public.dispute_match_result(uuid, integer, text)') is null
            and to_regprocedure('public.match_player_pool(uuid)') is null,
            'S1 the owner write functions and match_player_pool no longer exist');
set role anon;
select t.expect_error(format('select * from public.ingest_official_result(%L, %L, %L, %L)', t.cl(1), 'k', t.m(1), '{}'),
                      '%permission denied%', 'S2 anon cannot ingest');
select t.expect_error(format('select count(*) from public.scorer_clients'), '%permission denied%', 'S2b anon cannot read clients');
reset role;
set role authenticated;
select t.as_user(t.p(1));
select t.expect_error(format('select * from public.ingest_official_result(%L, %L, %L, %L)', t.cl(1), 'k', t.m(1),
                             t.totals('club_a_won', 150, 3, 120, 10)),
                      '%permission denied%', 'S3 a club owner cannot ingest');
select t.expect_error(format('select * from public.verify_official_result(%L, %L, %L, 1, true)', t.cl(2), 'k', t.m(1)),
                      '%permission denied%', 'S3b a club owner cannot verify');
select t.expect_error(format('select * from public.correct_official_result(%L, %L, %L, 1, %L, %L)', t.cl(1), 'k', t.m(1), 'x', '{}'),
                      '%permission denied%', 'S3c a club owner cannot correct');
select t.expect_error(format('select public.assign_match_official(%L, %L, %L)', t.m(1), t.cl(1), 'scorer'),
                      '%permission denied%', 'S3d a club owner cannot assign officials');
select t.expect_error(format('select * from public.official_match_roster(%L, %L)', t.cl(1), t.m(1)),
                      '%permission denied%', 'S3e a club owner cannot read the officials'' roster');
select t.expect_error(format('select public.official_result_store(%L, %L, %L, null, null, 1)', t.cl(1), t.m(1), '{}'),
                      '%permission denied%', 'S3f a club owner cannot call the internal store');
select t.expect_error('insert into public.match_results (match_id, version, outcome) values (gen_random_uuid(), 1, ''tie'')',
                      '%permission denied%', 'S3g a club owner cannot insert a result');
select t.expect_error('select count(*) from public.result_submission_log', '%permission denied%',
                      'S3h a club owner cannot read the submission log');
select t.expect_error('select count(*) from public.match_officials', '%permission denied%',
                      'S3i a club owner cannot read the assignments');
select t.as_user(t.p(101));
select t.expect_error(format('select * from public.ingest_official_result(%L, %L, %L, %L)', t.cl(1), 'k', t.m(1), '{}'),
                      '%permission denied%', 'S4 a player cannot ingest');
reset role;
set role service_role;
select t.expect_error(format('insert into public.match_results (match_id, version, outcome, scorer_client_id, submission_id) values (%L, 1, %L, %L, 1)',
                             t.m(1), 'tie', t.cl(1)), '%permission denied%', 'S5 service_role cannot insert a result directly');
select t.expect_error(format('update public.match_results set outcome = %L', 'tie'), '%permission denied%',
                      'S5b service_role cannot update results directly');
select t.expect_error('delete from public.match_batting', '%permission denied%', 'S5c service_role cannot delete card rows directly');
select t.expect_error('truncate public.match_innings', '%permission denied%', 'S5d service_role cannot truncate innings');
select t.expect_error('select count(*) from public.scorer_clients', '%permission denied%', 'S5e service_role cannot read clients directly');
select t.expect_error('insert into public.result_submission_log (client_id, action, idempotency_key, payload, payload_sha256, outcome) values (null, ''ingest'', ''x'', ''{}'', repeat(''0'', 64), ''accepted'')',
                      '%permission denied%', 'S5f service_role cannot write the submission log directly');
select t.expect_error(format('select public.official_result_store(%L, %L, %L, null, null, 1)', t.cl(1), t.m(1), '{}'),
                      '%permission denied%', 'S5g service_role cannot call the internal store');
select t.expect_error(format('select public.official_result_decide(%L, %L, 1, true, null, true)', t.cl(1), t.m(1)),
                      '%permission denied%', 'S5h service_role cannot call the internal decision');
select t.expect_error(format('select public.match_club_player_pool(%L, %L)', t.m(1), t.club(1)),
                      '%permission denied%', 'S5i service_role cannot call the internal pool');
reset role;

-- ---------------------------------------------------------------------------
-- A. Assignments (service_role: the league / ground integration)
-- ---------------------------------------------------------------------------
set role service_role;
select t.expect_error(format('select public.assign_match_official(%L, %L, %L)', gen_random_uuid(), t.cl(1), 'scorer'),
                      '%result: not found%', 'A1 assigning to an unknown match: not found');
select t.expect_error(format('select public.assign_match_official(%L, %L, %L)', t.m(1), t.cl(4), 'scorer'),
                      '%client not allowed%', 'A2 a revoked client can''t be assigned');
select t.expect_error(format('select public.assign_match_official(%L, %L, %L)', t.m(1), t.cl(1), 'umpire'),
                      '%result: invalid%', 'A3 an unknown role: invalid');
select public.assign_match_official(t.m(k), t.cl(1), 'scorer') from unnest(array[1, 3, 4, 5]) k;
select public.assign_match_official(t.m(k), t.cl(2), 'verifier') from unnest(array[1, 4]) k;
select public.assign_match_official(t.m(2), t.cl(3), 'scorer');
select public.assign_match_official(t.m(1), t.cl(1), 'scorer'); -- twice: no error, one row
reset role;
select t.ok((select count(*) from public.match_officials) = 7
            and (select count(*) from public.result_change_log where table_name = 'match_officials' and operation = 'INSERT') = 7,
            'A4 seven assignments (a repeat is ignored), each recorded in the change log');

-- ---------------------------------------------------------------------------
-- I. Ingestion: refusals are recorded, nothing is stored
-- ---------------------------------------------------------------------------
set role service_role;
select t.ok(t.ing(9, 'i1', 1, t.totals('club_a_won', 150, 3, 120, 10)) = 'rejected|-|result: client not allowed|false',
            'I1 an unknown client: rejected');
select t.ok(t.ing(4, 'i2', 1, t.totals('club_a_won', 150, 3, 120, 10)) = 'rejected|-|result: client not allowed|false',
            'I2 a revoked client: rejected');
select t.ok(t.ing(5, 'i3', 1, t.totals('club_a_won', 150, 3, 120, 10)) = 'rejected|-|result: not assigned|false',
            'I3 a client not assigned to the match: rejected');
select t.ok(t.ing(2, 'i4', 1, t.totals('club_a_won', 150, 3, 120, 10)) = 'rejected|-|result: not assigned|false',
            'I4 a verifier can''t submit (no scorer role): rejected');
select t.ok(t.ing(1, 'i5', 3, t.totals('club_a_won', 150, 3, 120, 10)) = 'rejected|-|result: match not played|false',
            'I5 a match that hasn''t started: rejected');
select t.ok(t.ing(1, 'i6', 5, t.totals('club_a_won', 150, 3, 120, 10)) = 'rejected|-|result: match not played|false',
            'I6 a cancelled match: rejected');
select t.ok(t.ing(1, 'i7', 1, '[]') = 'rejected|-|result: invalid payload|false', 'I7 a payload that isn''t an object');
select t.ok(t.ing(1, 'i8', 1, t.totals('a_won', 150, 3, 120, 10)) = 'rejected|-|result: invalid|false', 'I8 an unknown outcome');
select t.ok(t.ing(1, 'i9', 1, t.totals('club_b_won', 150, 3, 120, 10)) = 'rejected|-|result: inconsistent result|false',
            'I9 a win for the side with fewer runs');
select t.ok(t.ing(1, 'i10', 1, jsonb_set(t.totals('club_a_won', 150, 3, 120, 10), '{innings,0,balls}', '121'))
              = 'rejected|-|result: invalid innings|false', 'I10 121 balls in a T20 innings');
select t.ok(t.ing(1, 'i11', 1, t.totals('club_a_won', 150, 3, 120, 10) || jsonb_build_object('player_of_match_member_id', 'x'))
              = 'rejected|-|result: invalid player|false', 'I11 a malformed Player of the Match');
select t.ok(t.ing(1, 'i12', 1, jsonb_set(t.totals('club_a_won', 150, 3, 120, 10), '{innings,0,batting}', '[]'))
              = 'rejected|-|result: invalid scorecard|false', 'I12 a card on one innings only');
reset role;
select t.ok(not exists (select 1 from public.match_results)
            and (select count(*) from public.result_submission_log where outcome = 'rejected') = 12
            and (select bool_and(reason like 'result: %' and payload_sha256 ~ '^[0-9a-f]{64}$')
                   from public.result_submission_log),
            'I13 every refusal is recorded (12, with reason and payload hash); nothing stored');

-- ---------------------------------------------------------------------------
-- P. A provisional version: officials only; replay and idempotency
-- ---------------------------------------------------------------------------
set role service_role;
select t.ok(t.ing(1, 'p1', 1, t.totals('club_a_won', 150, 3, 120, 10)) = 'accepted|1|-|false', 'P1 the scorer submits: version 1');
reset role;
select t.ok((select status = 'submitted' and scorer_client_id = t.cl(1) and source = 'official_scorer'
                    and margin_runs = 30 and decided_at is null
                    and submission_id = (select id from public.result_submission_log where idempotency_key = 'p1')
               from public.match_results where match_id = t.m(1)),
            'P2 stored as provisional, by the scorer, linked to its submission record');
set role authenticated;
select t.as_user(t.p(1));
select t.ok((select count(*) from public.match_result(t.m(1))) = 0 and (select count(*) from public.match_results) = 0
            and (select count(*) from public.match_innings) = 0 and (select count(*) from public.club_results(t.club(1))) = 0,
            'P3 a club owner sees nothing while it is provisional (function and RLS)');
select t.as_user(t.p(101));
select t.ok((select count(*) from public.match_result(t.m(1))) = 0, 'P4 a member sees nothing while it is provisional');
reset role;
set role service_role;
select t.ok(t.ing(1, 'p1', 1, t.totals('club_a_won', 150, 3, 120, 10)) = 'accepted|1|-|true',
            'P5 the same call again: the first outcome replayed');
select t.ok(t.ing(1, 'p1', 1, t.totals('club_a_won', 151, 3, 120, 10)) = 'rejected|-|result: idempotency conflict|true',
            'P6 the same key with another payload: idempotency conflict');
select t.ok(t.ing(1, 'p2', 1, t.totals('club_a_won', 160, 3, 120, 10)) = 'accepted|2|-|false',
            'P7 a new submission replaces the waiting one: version 2');
reset role;
select t.ok((select count(*) from public.match_results where match_id = t.m(1)) = 2
            and (select status = 'superseded' and decided_by_client_id = t.cl(1) from public.match_results
                  where match_id = t.m(1) and version = 1)
            and (select count(*) from public.result_submission_log where idempotency_key in ('p1', 'p2')) = 2,
            'P8 version 1 superseded (by the scorer); replays add no record');

-- ---------------------------------------------------------------------------
-- V. Verification by a different official (D2)
-- ---------------------------------------------------------------------------
set role service_role;
select t.ok(t.ver(1, 'v1', 1, 2, true) = 'rejected|-|result: not assigned|false', 'V1 the scorer isn''t a verifier: rejected');
select public.assign_match_official(t.m(1), t.cl(1), 'verifier');
select t.ok(t.ver(1, 'v2', 1, 2, true) = 'rejected|-|result: same official|false',
            'V2 the scorer can''t approve its own submission (two-person rule)');
select t.ok(t.ver(2, 'v3', 1, 1, true) = 'rejected|-|result: version changed|false', 'V3 answering a replaced version');
select t.ok(t.ver(2, 'v4', 1, 2, false) = 'rejected|-|result: invalid reason|false', 'V4 a rejection without a reason');
select t.ok(t.ver(2, 'v5', 1, 2, false, ' Wrong   total ') = 'accepted|2|-|false', 'V5 the verifier rejects version 2 with a reason');
reset role;
select t.ok((select status = 'rejected' and decision_note = 'Wrong total' and decided_by_client_id = t.cl(2)
               from public.match_results where match_id = t.m(1) and version = 2)
            and (select status from public.matches where id = t.m(1)) = 'confirmed',
            'V6 rejected, with the note and the verifier; the match is not completed');
set role service_role;
select t.ok(t.ing(1, 'p3', 1, t.totals('club_a_won', 150, 3, 120, 10)) = 'accepted|3|-|false', 'V7 the scorer resubmits: version 3');
select t.ok(t.ver(2, 'v6', 1, 3, true) = 'accepted|3|-|false', 'V8 the verifier approves version 3');
select t.ok(t.ver(2, 'v7', 1, 3, true) = 'rejected|-|result: not pending|false', 'V9 approving again: not pending');
reset role;
select t.ok((select status = 'confirmed' and decided_by_client_id = t.cl(2) from public.match_results
              where match_id = t.m(1) and version = 3)
            and (select status from public.matches where id = t.m(1)) = 'completed',
            'V10 version 3 is the official result; the match is completed');
set role authenticated;
select t.as_user(t.p(1));
select t.ok((select count(*) = 1 and bool_and(status = 'confirmed' and version = 3) from public.match_result(t.m(1)))
            and (select count(*) from public.match_results) = 1
            and (select result from public.club_results(t.club(1))) = 'won',
            'V11 the owner sees the official result only (function, RLS, club results)');
select t.as_user(t.p(201));
select t.ok((select result from public.club_results(t.club(2))) = 'lost'
            and (select summary from public.match_result(t.m(1))) = 'Lock Lions won by 30 runs',
            'V12 the other club''s member sees it too, from their side');
reset role;

-- ---------------------------------------------------------------------------
-- C. Corrections: a new version, verified again; the official result stands
-- ---------------------------------------------------------------------------
set role service_role;
select t.ok(t.ing(1, 'c1', 1, t.totals('club_a_won', 155, 3, 120, 10)) = 'rejected|-|result: correction required|false',
            'C1 a plain submission once a result is official: correction required');
select t.ok(t.cor(1, 'c2', 1, 2, 'Typo', t.totals('club_a_won', 155, 3, 120, 10)) = 'rejected|-|result: version changed|false',
            'C2 correcting a version that isn''t the official one: version changed');
select t.ok(t.cor(1, 'c3', 1, 3, '  ', t.totals('club_a_won', 155, 3, 120, 10)) = 'rejected|-|result: invalid reason|false',
            'C3 a correction without a reason');
select t.ok(t.cor(1, 'c4', 4, 1, 'Typo', t.totals('club_a_won', 155, 3, 120, 10)) = 'rejected|-|result: nothing to correct|false',
            'C4 correcting a match without an official result');
select t.ok(t.cor(1, 'c5', 1, 3, ' Scorer   typo ', t.totals('club_a_won', 155, 3, 120, 10)) = 'accepted|4|-|false',
            'C5 the scorer corrects version 3: version 4 (provisional)');
reset role;
set role authenticated;
select t.as_user(t.p(101));
select t.ok((select version from public.match_result(t.m(1))) = 3, 'C6 until verified, the official result stands (3)');
reset role;
set role service_role;
select t.ok(t.ver(2, 'c6', 1, 4, true) = 'accepted|4|-|false', 'C7 the verifier approves the correction');
reset role;
select t.ok((select corrects_version = 3 and correction_reason = 'Scorer typo' and status = 'confirmed'
               from public.match_results where match_id = t.m(1) and version = 4)
            and (select status = 'superseded' and decided_by_client_id = t.cl(2)
                   from public.match_results where match_id = t.m(1) and version = 3),
            'C8 version 4 official (it names what it corrects and why); 3 superseded, keeping who confirmed it');

-- ---------------------------------------------------------------------------
-- T. A single-step trusted client (off by default)
-- ---------------------------------------------------------------------------
set role service_role;
select t.ok(t.ing(3, 't1', 2, t.totals('tie', 150, 7, 150, 9)) = 'accepted|1|-|false', 'T1 the trusted client submits m2');
reset role;
select t.ok((select status = 'confirmed' and decided_by_client_id = t.cl(3) and scorer_client_id = t.cl(3)
               from public.match_results where match_id = t.m(2))
            and (select status from public.matches where id = t.m(2)) = 'completed',
            'T2 confirmed at once, by itself (single-step trust only)');

-- ---------------------------------------------------------------------------
-- K. A full scorecard through the official path; statistics; the roster
-- ---------------------------------------------------------------------------
-- A 20/1 (12 balls): 101 15 c 201 b 202, 102 5*; 202 bowls 2-0-20.
-- B 10/0 (6 balls): 201 6*, 203 4*; 101 bowls 1-0-10. A won by 10 runs.
select jsonb_build_object('outcome', 'club_a_won', 'player_of_match_member_id', t.mem(101), 'innings', jsonb_build_array(
  jsonb_build_object('batting_club_id', t.club(1), 'runs', 20, 'wickets', 1, 'balls', 12,
    'batting', jsonb_build_array(
      jsonb_build_object('member_id', t.mem(101), 'runs', 15, 'balls', 8, 'fours', 2, 'dismissal', 'caught',
                         'bowler_member_id', t.mem(202), 'fielder_member_id', t.mem(201)),
      jsonb_build_object('member_id', t.mem(102), 'runs', 5, 'balls', 4, 'dismissal', 'not_out')),
    'bowling', jsonb_build_array(jsonb_build_object('member_id', t.mem(202), 'balls', 12, 'runs', 20))),
  jsonb_build_object('batting_club_id', t.club(2), 'runs', 10, 'wickets', 0, 'balls', 6,
    'batting', jsonb_build_array(
      jsonb_build_object('member_id', t.mem(201), 'runs', 6, 'balls', 3, 'dismissal', 'not_out'),
      jsonb_build_object('member_id', t.mem(203), 'runs', 4, 'balls', 3, 'dismissal', 'not_out')),
    'bowling', jsonb_build_array(jsonb_build_object('member_id', t.mem(101), 'balls', 6, 'runs', 10))))) as card \gset
set role service_role;
select t.ok((select count(*) = 26 and count(distinct club_id) = 2 from public.official_match_roster(t.cl(1), t.m(4))),
            'K1 the assigned scorer reads both pools (13 + 13 active members)');
select t.expect_error(format('select * from public.official_match_roster(%L, %L)', t.cl(5), t.m(4)), '%not assigned%',
                      'K2 an unassigned client can''t read the roster');
select t.ok(t.ing(1, 'k1', 4, jsonb_set(:'card'::jsonb, '{innings,0,batting,0,runs}', '16'))
              = 'rejected|-|result: invalid scorecard|false', 'K3 a card that doesn''t add up: rejected');
select t.ok(t.ing(1, 'k2', 4, :'card') = 'accepted|1|-|false', 'K4 the scorer submits the full scorecard');
select t.ok(t.ver(2, 'k3', 4, 1, true) = 'accepted|1|-|false', 'K5 the verifier approves it');
reset role;
set role authenticated;
select t.as_user(t.p(101));
select t.ok((select s.runs = 15 and s.matches = 1 and s.player_of_match = 1 and s.balls_bowled = 6
               from public.player_stats() s)
            and (select count(*) from public.match_scorecard(t.m(4))) = 2,
            'K6 the player''s official statistics and the scorecard, from the official result');
select t.as_user(t.p(201));
select t.ok((select s.catches from public.player_stats() s) = 1, 'K7 the fielder''s catch is counted');
reset role;

-- ---------------------------------------------------------------------------
-- G. Guards and append-only logs (even for the database owner)
-- ---------------------------------------------------------------------------
select t.expect_error(format('update public.match_results set outcome = %L where match_id = %L and version = 4', 'tie', t.m(1)),
                      '%invalid transition%', 'G1 an official result never changes');
select t.expect_error(format('update public.match_results set status = %L where match_id = %L and version = 2', 'confirmed', t.m(1)),
                      '%invalid transition%', 'G2 a rejected version stays rejected');
select t.expect_error(format('insert into public.match_results (match_id, version, outcome, status, scorer_client_id, submission_id) values (%L, 9, %L, %L, %L, 999)',
                             t.m(4), 'tie', 'confirmed', t.cl(1)), '%invalid transition%',
                      'G3 a row can''t be inserted as official');
select t.expect_error('update public.result_submission_log set outcome = ''accepted''', '%append only%',
                      'G4 the submission log can''t be changed');
select t.expect_error('delete from public.result_submission_log', '%append only%', 'G5 nor deleted');
select t.expect_error('truncate public.result_change_log', '%append only%', 'G6 the change log can''t be truncated');
select t.expect_error('truncate public.result_submission_log', '%', 'G6b nor the submission log (referenced by the results, and append-only)');
select t.expect_error('delete from public.result_change_log', '%append only%', 'G7 the change log can''t be deleted');
select t.expect_error('update public.result_change_log set db_role = ''x''', '%append only%', 'G8 nor changed');

-- ---------------------------------------------------------------------------
-- L. The audit trail
-- ---------------------------------------------------------------------------
select t.ok((select count(*) from public.result_submission_log) = 32
            and (select count(*) filter (where outcome = 'accepted') from public.result_submission_log) = 10
            and (select bool_and(db_role = 'service_role') from public.result_submission_log)
            and (select count(*) from public.result_submission_log where request_id like 'req-%') = 19
            and (select count(*) from public.result_submission_log where action = 'ingest') = 19,
            'L1 every call recorded once (32: 10 accepted; replays add none), by service_role, with its request id');
select t.ok((select count(*) filter (where operation = 'INSERT') from public.result_change_log where table_name = 'match_results') = 6
            and (select count(*) from public.result_change_log
                  where table_name = 'match_results' and operation = 'UPDATE'
                    and detail ->> 'old_status' = 'submitted' and detail ->> 'status' = 'confirmed') = 4
            and (select count(*) from public.result_change_log where table_name = 'match_batting') = 4
            and (select bool_and(db_role = 'service_role' and session_role is not null and txid > 0)
                   from public.result_change_log where table_name <> 'match_officials' or operation = 'INSERT'),
            'L2 every row change recorded: 6 versions, 4 confirmations, 4 batting rows — by service_role, with session and transaction');

-- ---------------------------------------------------------------------------
-- D. Account deletion still makes a "Deleted player"
-- ---------------------------------------------------------------------------
delete from auth.users where id = t.p(102);
select t.ok((select player_deleted and player_name is null from public.match_batting
              where match_id = t.m(4) and innings_no = 1 and position = 2)
            and exists (select 1 from public.result_change_log
                         where table_name = 'match_batting' and operation = 'UPDATE' and match_id = t.m(4)),
            'D1 the deleted player''s card row is anonymized, and the change recorded');

-- Clean up (this database only): the synthetic rows, then — triggers off —
-- the logs and clients they produced.
delete from public.clubs where owner_id::text like 'ee100000%';
delete from auth.users where id::text like 'ee100000%';
set session_replication_role = replica;
delete from public.result_submission_log;
delete from public.result_change_log;
delete from public.scorer_clients where id::text like 'ec1e0000%';
set session_replication_role = default;
select t.ok(not exists (select 1 from public.profiles where id::text like 'ee100000%')
            and not exists (select 1 from public.match_results) and not exists (select 1 from public.scorer_clients)
            and not exists (select 1 from public.result_submission_log) and not exists (select 1 from public.result_change_log)
            and not exists (select 1 from public.matches),
            'Z cleanup done');
