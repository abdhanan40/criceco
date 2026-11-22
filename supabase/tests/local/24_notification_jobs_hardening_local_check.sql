-- CricEco · LOCAL TEST ONLY — migration 29 (notification jobs: failure
-- isolation and a run log, M3 P6 hardening) on a DISPOSABLE plain PostgreSQL
-- 17 database, after 00_auth_stub.sql, 02_legacy_profiles_fixture.sql,
-- migrations 1–28 (+ the D1 location seed) and migration 29. Synthetic data
-- only (people ee6…, matches ee6000aa…, challenge ee6000cc…, offer ee6000dd…).
-- Failures are FORCED with throwaway test triggers (schema t) and by
-- renaming a table for one call; everything is put back before the end.
-- pg_cron, pg_net and Vault don't exist here (and must not).
-- Run with psql:  psql -X -v ON_ERROR_STOP=1 -f 24_notification_jobs_hardening_local_check.sql
-- Every check prints "PASS: …"; the first failure stops the run ("FAIL: …").
-- Refuses to run on a real Supabase project (its auth.users has passwords).
\set ON_ERROR_STOP on

do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password') then
    raise exception 'LOCAL ONLY: this looks like a real Supabase project — refusing';
  end if;
  if to_regclass('public.notification_job_runs') is null then
    raise exception 'apply migration 29 first';
  end if;
  if to_regnamespace('net') is not null or to_regnamespace('vault') is not null or to_regnamespace('cron') is not null then
    raise exception 'LOCAL ONLY: this database has pg_net / Vault / pg_cron — refusing';
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
  select ('ee600000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
$$;
create or replace function t.m(p_n int) returns uuid language sql immutable as $$
  select ('ee6000aa-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
$$;
create or replace function t.club(p_n int) returns uuid language sql stable as $$
  select c.id from public.clubs c where c.name = (array['Harden Lions', 'Harden Kings', 'Harden Riders'])[p_n];
$$;
create or replace function t.mem(p_n int) returns uuid language sql stable as $$
  select m.id from public.club_members m where m.user_id = ('ee600000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
$$;
-- Reminders of one type for one person.
create or replace function t.cnt(p_n int, p_type text) returns int language sql stable as $$
  select count(*)::int from public.notifications n
   where n.recipient_id = ('ee600000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid and n.type = p_type;
$$;
-- More than one row for the same person and key? (must never happen)
create or replace function t.dupes() returns int language sql stable as $$
  select count(*)::int from (select 1 from public.notifications n where n.recipient_id::text like 'ee600000%'
                              group by n.recipient_id, n.dedupe_key having count(*) > 1) d;
$$;
create or replace function t.make_person(p_n int) returns uuid language plpgsql as $$
declare
  v uuid := t.p(p_n);
begin
  insert into auth.users (id, email) values (v, format('harden%s@local.test', p_n));
  insert into public.current_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
  insert into public.permanent_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
  update public.profiles
     set full_name = format('Harden Person %s', p_n),
         phone = format('+923%s', lpad((680000000 + p_n)::text, 9, '0')),
         date_of_birth = date '2000-05-01', profile_completed = true
   where id = v;
  insert into public.player_profiles (user_id, player_role, batting_style, bowling_style, is_wicketkeeper)
  values (v, 'all_rounder', 'right_handed', 'right_arm_fast', false);
  return v;
end $$;

-- The runs this check makes (ids above the starting point).
create table t.base (run0 bigint not null);
insert into t.base select coalesce(max(id), 0) from public.notification_job_runs;
create or replace function t.last(p_job text) returns public.notification_job_runs language sql stable as $$
  select r.* from public.notification_job_runs r
   where r.job = p_job and r.id > (select run0 from t.base) order by r.id desc limit 1;
$$;
create or replace function t.runs() returns int language sql stable as $$
  select count(*)::int from public.notification_job_runs r where r.id > (select run0 from t.base);
$$;

-- Forced failures: a notification for a listed person whose key matches is refused.
create table t.fault (recipient uuid not null, key_like text not null, message text not null default 'forced failure');
create or replace function t.fault_check() returns trigger language plpgsql as $$
declare
  v text;
begin
  select f.message into v from t.fault f where f.recipient = new.recipient_id and new.dedupe_key like f.key_like limit 1;
  if v is not null then raise exception '%', v; end if;
  return new;
end $$;
create trigger t_fault before insert on public.notifications for each row execute function t.fault_check();

-- Synthetic data: owners 1 (A), 2 (B), 3 (C); A players 101 (playing), 102
-- (sub) in m1's line-up; C member 401. m1: A v B in 20 h. A challenge A → C
-- expiring in 10 h; an offer C (owner 3) → 401 expiring in 5 h.
select t.nobody();
select count(*) from (select t.make_person(n) from unnest(array[1, 2, 3, 101, 102, 401]) n) s;
insert into public.clubs (owner_id, name, city, club_type) values
  (t.p(1), 'Harden Lions', 'Lahore', 'corporate'), (t.p(2), 'Harden Kings', 'Karachi', 'corporate'),
  (t.p(3), 'Harden Riders', 'Lahore', 'corporate');
insert into public.club_members (club_id, user_id, member_role, status)
select case when n = 401 then t.club(3) else t.club(1) end, t.p(n), 'player', 'active' from unnest(array[101, 102, 401]) n;
insert into public.matches (id, club_a_id, club_b_id, format, status, starts_at, venue_name) values
  (t.m(1), t.club(1), t.club(2), 't20', 'confirmed', now() + interval '20 hours', 'Harden Ground');
insert into public.match_lineups (match_id, club_id, name) values (t.m(1), t.club(1), 'Harden XI');
insert into public.match_lineup_players (match_id, club_id, member_id, selection, position) values
  (t.m(1), t.club(1), t.mem(101), 'playing', 1), (t.m(1), t.club(1), t.mem(102), 'sub', 2);
insert into public.match_challenges (id, from_club_id, to_club_id, format, proposed_date, venue_name, status, expires_at, created_at)
values ('ee6000cc-0000-4000-8000-000000000001', t.club(1), t.club(3), 't20', current_date + 5, 'Harden Park', 'pending',
        now() + interval '10 hours', now() - interval '6 days');
insert into public.club_ownership_transfers (id, club_id, from_user_id, to_user_id, to_member_id, status, expires_at, created_at)
values ('ee6000dd-0000-4000-8000-000000000001', t.club(3), t.p(3), t.p(401), t.mem(401), 'pending',
        now() + interval '5 hours', now() - interval '6 days');

-- ---------------------------------------------------------------------------
-- S. The run log is the database owner's alone
-- ---------------------------------------------------------------------------
set role anon;
select t.expect_error('select * from public.notification_job_runs', '%permission denied%', 'S1 anon cannot read the run log');
reset role;
set role authenticated;
select t.as_user(t.p(1));
select t.expect_error('select * from public.notification_job_runs', '%permission denied%', 'S2 a signed-in user cannot read it');
select t.expect_error($q$insert into public.notification_job_runs (job, status, started_at, finished_at)
                        values ('reminders', 'ok', now(), now())$q$, '%permission denied%', 'S2b nor write to it');
select t.expect_error($q$select public.notification_job_record('reminders', now(), 0, 0, 0, 0, 0, '{}', '{}', false)$q$,
                      '%permission denied%', 'S2c nor call its writer');
reset role;
set role service_role;
select t.nobody();
select t.expect_error('select count(*) from public.notification_job_runs', '%permission denied%', 'S3 service_role cannot read it');
select t.expect_error('delete from public.notification_job_runs', '%permission denied%', 'S3b nor delete from it');
select t.expect_error($q$select public.notification_job_record('cleanup', now(), 0, 0, 0, 0, 0, '{}', '{}', false)$q$,
                      '%permission denied%', 'S3c nor call its writer');
reset role;

-- ---------------------------------------------------------------------------
-- F. Forced failures in the reminders, and retries
-- ---------------------------------------------------------------------------
-- F1: player 101's reminder and the challenged owner 3's reminder fail.
insert into t.fault (recipient, key_like) values (t.p(101), 'reminder:match:%'), (t.p(3), 'reminder:challenge:%');
select public.notification_send_reminders() as sent \gset
select t.ok(:sent = 3, 'F1 one run with two failing items still sends the other 3 (both owners, the offer): ' || :sent);
select t.ok(t.cnt(1, 'match_reminder') = 1 and t.cnt(2, 'match_reminder') = 1 and t.cnt(401, 'ownership_expiring') = 1
            and t.cnt(101, 'match_reminder') = 0 and t.cnt(102, 'match_reminder') = 0 and t.cnt(3, 'challenge_expiring') = 0,
            'F1b the failing groups are skipped whole (the line-up: 101 and 102), everything else is sent');
select t.ok((select r.status = 'partial' and r.processed = 3 and r.created = 3 and r.errors = 2
                    and r.failed_items = array['match:' || t.m(1) || ':players', 'challenge:ee6000cc-0000-4000-8000-000000000001']
                    and r.first_error like 'match:' || t.m(1) || ':players: P0001 forced failure%'
                    and r.finished_at >= r.started_at
               from t.last('reminders') r),
            'F1c the run is logged: partial, 3 processed, 3 created, 2 errors, the failed items and the first error');
-- F2: the faults are still there: tried again, fail again, nothing sent twice.
select public.notification_send_reminders() as again \gset
select t.ok(:again = 0 and t.dupes() = 0 and t.cnt(1, 'match_reminder') = 1
            and (select r.status = 'partial' and r.errors = 2 and r.created = 0 from t.last('reminders') r),
            'F2 the next run retries the failing items (2 errors again) and sends nothing twice');
-- F3: the faults are gone: the retry delivers what was missing, once.
delete from t.fault;
select public.notification_send_reminders() as retried \gset
select t.ok(:retried = 3 and t.cnt(101, 'match_reminder') = 1 and t.cnt(102, 'match_reminder') = 1
            and t.cnt(3, 'challenge_expiring') = 1 and t.cnt(1, 'match_reminder') = 1 and t.cnt(2, 'match_reminder') = 1
            and t.cnt(401, 'ownership_expiring') = 1 and t.dupes() = 0,
            'F3 once fixed, the retry sends exactly the 3 missing reminders (101, 102, the challenge) — no repeats');
select t.ok((select r.status = 'ok' and r.errors = 0 and r.first_error is null and r.failed_items = '{}' and r.created = 3
               from t.last('reminders') r),
            'F3b … and is logged ok with no error');
select public.notification_send_reminders() as idle \gset
select t.ok(:idle = 0 and t.dupes() = 0 and (select r.status = 'ok' and r.created = 0 and r.processed = 3 from t.last('reminders') r),
            'F4 a further run sends nothing (3 processed, 0 created, ok)');

-- F5: a whole section fails (its table is missing for one call): the others still run.
insert into public.matches (id, club_a_id, club_b_id, format, status, starts_at, venue_name) values
  (t.m(2), t.club(1), t.club(2), 't20', 'confirmed', now() + interval '8 hours', 'Harden Ground');
alter table public.club_ownership_transfers rename to club_ownership_transfers_t24;
select public.notification_send_reminders() as sect \gset
alter table public.club_ownership_transfers_t24 rename to club_ownership_transfers;
select t.ok(:sect = 2 and t.cnt(1, 'match_reminder') = 2 and t.cnt(2, 'match_reminder') = 2
            and (select r.status = 'partial' and r.errors = 1 and r.failed_items = array['offers']
                        and r.first_error like 'offers: 42P01 %' from t.last('reminders') r),
            'F5 the offers section fails (logged "offers: 42P01 …"); the new match''s reminders are still sent');
select public.notification_send_reminders() as back \gset
select t.ok(:back = 0 and (select r.status = 'ok' from t.last('reminders') r) and t.dupes() = 0,
            'F5b with the table back the next run is ok again');

-- F6: a failure outside the sections (the notifications table is missing):
-- the run is logged as failed, the function itself does not fail.
alter table public.notifications rename to notifications_t24;
select public.notification_send_reminders() as whole \gset
alter table public.notifications_t24 rename to notifications;
select t.ok(:whole = 0 and (select r.status = 'failed' and r.errors >= 1 and 'run' = any (r.failed_items)
                                   and r.created = 0 from t.last('reminders') r),
            'F6 a whole-run failure is logged "failed" (created 0) and the job still returns');

-- F7: the log itself can't be written: the reminders are still sent.
create or replace function t.no_log() returns trigger language plpgsql as $$
begin raise exception 'log refused'; end $$;
create trigger t_no_log before insert on public.notification_job_runs for each row execute function t.no_log();
update public.matches set starts_at = now() + interval '9 hours' where id = t.m(2);
select t.runs() as runs_before \gset
select public.notification_send_reminders() as unlogged \gset
select t.ok(:unlogged = 2 and t.runs() = :runs_before and t.cnt(1, 'match_reminder') = 3,
            'F7 when the run log refuses, the reminders are still sent (2) — only the log row is missing');
drop trigger t_no_log on public.notification_job_runs;

-- F8: 25 failing owner reminders: every other one sent; the log keeps 20
-- items and a first error of at most 300 characters.
insert into public.matches (id, club_a_id, club_b_id, format, status, starts_at, venue_name)
select t.m(100 + g), t.club(1), t.club(2), 't10', 'confirmed', now() + g * interval '30 minutes', 'Harden Ground'
  from generate_series(1, 25) g;
insert into t.fault (recipient, key_like, message)
values (t.p(1), 'reminder:match:ee6000aa-0000-4000-8000-0000000001__:%', 'forced ' || repeat('x', 400));
select public.notification_send_reminders() as many \gset
delete from t.fault;
select t.ok(:many = 25 and (select r.status = 'partial' and r.errors = 25 and cardinality(r.failed_items) = 20
                                  and char_length(r.first_error) = 300 and r.first_error like 'match:%:owner_a: P0001 forced xxx%'
                                  and r.processed = 25 + 2 + 1 + 1
                             from t.last('reminders') r),
            'F8 25 failing owners: the other owner''s 25 are sent; logged 25 errors, 20 items, 300 characters');
select public.notification_send_reminders() as caught_up \gset
select t.ok(:caught_up = 25 and t.dupes() = 0 and (select r.status = 'ok' from t.last('reminders') r),
            'F8b the retry sends the 25 missing ones, once');

-- ---------------------------------------------------------------------------
-- C. The cleanup: independent deletes; the run log kept 30 days
-- ---------------------------------------------------------------------------
insert into public.notifications (recipient_id, inbox, type, params, dedupe_key, created_at) values
  (t.p(101), 'player', 'announcement', '{"title": "Old"}', 'harden:old', now() - interval '91 days');
insert into public.club_announcements (club_id, title, message, audience, created_at) values
  (t.club(1), 'Harden old one', 'Message', 'all', now() - interval '91 days');
insert into public.notification_job_runs (job, status, started_at, finished_at)
select 'push_sweep', 'ok', now() - interval '31 days' - g * interval '1 minute', now() - interval '31 days' - g * interval '1 minute'
  from generate_series(1, 3) g;
insert into public.notification_job_runs (job, status, started_at, finished_at)
values ('push_sweep', 'ok', now() - interval '29 days', now() - interval '29 days');
create or replace function t.no_delete() returns trigger language plpgsql as $$
begin raise exception 'forced failure'; end $$;
create trigger t_no_delete before delete on public.club_announcements for each row execute function t.no_delete();
-- (A job and the reads of its effects are separate statements: a read in the
-- same statement would still see the rows as they were when it began.)
select public.notification_cleanup() as c1 \gset
select t.ok(:'c1'::jsonb = '{"notifications": 1, "announcements": 0}'::jsonb
            and not exists (select 1 from public.notifications where dedupe_key = 'harden:old')
            and exists (select 1 from public.club_announcements where title = 'Harden old one'),
            'C1 the announcements delete fails: the old notification is still removed (result shape unchanged)');
select t.ok((select r.status = 'partial' and r.errors = 1 and r.failed_items = array['announcements']
                    and r.first_error like 'announcements: P0001 forced failure%'
                    and r.removed_notifications = 1 and r.removed_announcements = 0 and r.removed_job_runs = 3
               from t.last('cleanup') r)
            and (select count(*) from public.notification_job_runs where started_at < now() - interval '30 days') = 0
            and exists (select 1 from public.notification_job_runs where started_at between now() - interval '29 days 1 minute'
                                                                                    and now() - interval '28 days'),
            'C1b logged partial; the job runs older than 30 days are removed (3), the 29-day one kept');
drop trigger t_no_delete on public.club_announcements;
select public.notification_cleanup() as c2 \gset
select t.ok(:'c2'::jsonb = '{"notifications": 0, "announcements": 1}'::jsonb
            and (select r.status = 'ok' and r.removed_announcements = 1 from t.last('cleanup') r),
            'C2 the retry the next day removes the announcement');
insert into public.notification_job_runs (job, status, started_at, finished_at)
select 'push_sweep', 'ok', now() - interval '40 days', now() - interval '40 days' from generate_series(1, 10005);
select public.notification_cleanup() as c3 \gset
select t.ok((select r.removed_job_runs = 10000 from t.last('cleanup') r), 'C3 at most 10,000 job runs a run …');
select public.notification_cleanup() as c4 \gset
select t.ok((select r.removed_job_runs = 5 from t.last('cleanup') r), 'C3b … the rest the next run');

-- ---------------------------------------------------------------------------
-- W. The push sweeper (pg_net is absent: it only counts)
-- ---------------------------------------------------------------------------
insert into public.push_deliveries (notification_id, created_at)
select n.id, now() - interval '3 minutes' from public.notifications n
 where n.recipient_id = t.p(101) and n.type = 'match_reminder' limit 1;
select public.push_sweep() as w1 \gset
select t.ok(:w1 = 1
            and (select r.status = 'ok' and r.processed = 1 and r.errors = 0 from t.last('push_sweep') r),
            'W1 a sweep is logged ok with the number waiting');
alter table public.push_deliveries rename to push_deliveries_t24;
select public.push_sweep() as swept \gset
alter table public.push_deliveries_t24 rename to push_deliveries;
select t.ok(:swept = 0 and (select r.status = 'failed' and r.failed_items = array['sweep'] and r.first_error like 'sweep: 42P01 %'
                                   from t.last('push_sweep') r),
            'W2 a failing sweep is logged "failed" and the job still returns');

-- ---------------------------------------------------------------------------
-- R. Every row the log holds obeys its rule; nothing of the tests is left over
-- ---------------------------------------------------------------------------
select t.ok(not exists (select 1 from public.notification_job_runs r
                         where (r.status = 'ok') <> (r.errors = 0) or r.finished_at < r.started_at),
            'R1 every logged run: ok exactly when there is no error; finished after it started');
select t.expect_error($q$insert into public.notification_job_runs (job, status, started_at, finished_at, errors)
                        values ('reminders', 'ok', now(), now(), 1)$q$, '%notification_job_runs_outcome%',
                      'R2 the table refuses an "ok" run with errors');

-- ---------------------------------------------------------------------------
-- Clean up (this database only): only this check's own records.
-- ---------------------------------------------------------------------------
drop trigger t_fault on public.notifications;
delete from public.notification_job_runs where id > (select run0 from t.base);
delete from public.clubs where owner_id::text like 'ee600000%';
delete from public.matches where id::text like 'ee6000aa%';
delete from auth.users where id::text like 'ee600000%';
select t.ok(not exists (select 1 from public.profiles where id::text like 'ee600000%')
            and not exists (select 1 from public.notifications where recipient_id::text like 'ee600000%')
            and t.runs() = 0
            and to_regclass('public.notifications') is not null and to_regclass('public.push_deliveries') is not null
            and to_regclass('public.club_ownership_transfers') is not null
            and not exists (select 1 from pg_trigger where tgname in ('t_fault', 't_no_log', 't_no_delete')),
            'Z cleanup done (tables back, test triggers gone)');
drop schema t cascade;
