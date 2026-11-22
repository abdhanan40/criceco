-- CricEco · LOCAL TEST ONLY — migration 28 (scheduled notification jobs,
-- M3 P6) on a DISPOSABLE plain PostgreSQL 17 database, after 00_auth_stub.sql,
-- 02_legacy_profiles_fixture.sql, migrations 1–27 (+ the D1 location seed)
-- and migration 28. Synthetic data only (people ee5…, matches ee5…aa).
-- pg_cron, pg_net and Vault don't exist here: sections W and K install
-- throwaway stand-ins (schemas net, vault, cron) and remove them again.
-- Run with psql:  psql -X -v ON_ERROR_STOP=1 -f 23_notification_jobs_local_check.sql
-- Every check prints "PASS: …"; the first failure stops the run ("FAIL: …").
-- Refuses to run on a real Supabase project (its auth.users has passwords).
\set ON_ERROR_STOP on

do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password') then
    raise exception 'LOCAL ONLY: this looks like a real Supabase project — refusing';
  end if;
  if to_regprocedure('public.notification_send_reminders()') is null then
    raise exception 'apply migration 28 first';
  end if;
  if to_regnamespace('net') is not null or to_regnamespace('vault') is not null or to_regnamespace('cron') is not null then
    raise exception 'LOCAL ONLY: this database has pg_net / Vault / pg_cron — refusing (the check replaces them)';
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
  select ('ee500000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
$$;
create or replace function t.m(p_n int) returns uuid language sql immutable as $$
  select ('ee5000aa-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
$$;
create or replace function t.club(p_n int) returns uuid language sql stable as $$
  select c.id from public.clubs c where c.name = (array['Remind Lions', 'Remind Kings', 'Remind Riders'])[p_n];
$$;
create or replace function t.mem(p_n int) returns uuid language sql stable as $$
  select m.id from public.club_members m where m.user_id = ('ee500000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
$$;
create or replace function t.cnt(p_n int, p_type text) returns int language sql stable as $$
  select count(*)::int from public.notifications n
   where n.recipient_id = ('ee500000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid and n.type = p_type;
$$;
create or replace function t.typed(p_type text) returns int language sql stable as $$
  select count(*)::int from public.notifications n where n.recipient_id::text like 'ee500000%' and n.type = p_type;
$$;
create or replace function t.one(p_n int, p_type text) returns public.notifications language sql stable as $$
  select n.* from public.notifications n
   where n.recipient_id = ('ee500000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid and n.type = p_type
   order by n.created_at desc, n.id desc limit 1;
$$;
create or replace function t.make_person(p_n int) returns uuid language plpgsql as $$
declare
  v uuid := t.p(p_n);
begin
  insert into auth.users (id, email) values (v, format('remind%s@local.test', p_n));
  insert into public.current_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
  insert into public.permanent_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
  update public.profiles
     set full_name = format('Remind Person %s', p_n),
         phone = format('+923%s', lpad((670000000 + p_n)::text, 9, '0')),
         date_of_birth = date '2000-05-01', profile_completed = true
   where id = v;
  insert into public.player_profiles (user_id, player_role, batting_style, bowling_style, is_wicketkeeper)
  values (v, 'all_rounder', 'right_handed', 'right_arm_fast', false);
  return v;
end $$;

-- Synthetic data: owners 1 (A), 2 (B), 3 (C); A players 101–103; C member 401.
-- Matches (A v B): m1 in 20 h with 101, 102 selected; m2 in 30 h; m3 started
-- an hour ago; m4 cancelled, in 10 h.
select t.nobody();
select count(*) from (select t.make_person(n) from unnest(array[1, 2, 3, 101, 102, 103, 401]) n) s;
insert into public.clubs (owner_id, name, city, club_type) values
  (t.p(1), 'Remind Lions', 'Lahore', 'corporate'), (t.p(2), 'Remind Kings', 'Karachi', 'corporate'),
  (t.p(3), 'Remind Riders', 'Lahore', 'corporate');
insert into public.club_members (club_id, user_id, member_role, status)
select case when n = 401 then t.club(3) else t.club(1) end, t.p(n), 'player', 'active' from unnest(array[101, 102, 103, 401]) n;
insert into public.matches (id, club_a_id, club_b_id, format, status, starts_at, venue_name,
                            cancelled_at, cancelled_by_club_id, cancel_reason) values
  (t.m(1), t.club(1), t.club(2), 't20', 'confirmed', now() + interval '20 hours', 'Remind Ground', null, null, null),
  (t.m(2), t.club(1), t.club(2), 't20', 'confirmed', now() + interval '30 hours', 'Remind Ground', null, null, null),
  (t.m(3), t.club(1), t.club(2), 't20', 'confirmed', now() + interval '1 minute', 'Remind Ground', null, null, null),
  (t.m(4), t.club(1), t.club(2), 't20', 'cancelled', now() + interval '10 hours', 'Remind Ground', now(), t.club(1), 'Rain');
update public.matches set starts_at = now() - interval '1 hour' where id = t.m(3);
insert into public.match_lineups (match_id, club_id, name) values (t.m(1), t.club(1), 'Remind XI');
insert into public.match_lineup_players (match_id, club_id, member_id, selection, position) values
  (t.m(1), t.club(1), t.mem(101), 'playing', 1), (t.m(1), t.club(1), t.mem(102), 'sub', 2);

-- ---------------------------------------------------------------------------
-- S. Nobody runs the jobs through the API
-- ---------------------------------------------------------------------------
set role authenticated;
select t.as_user(t.p(1));
select t.expect_error('select public.notification_send_reminders()', '%permission denied%', 'S1 a user cannot run the reminders');
select t.expect_error('select public.notification_cleanup()', '%permission denied%', 'S1b nor the cleanup');
reset role;
set role service_role;
select t.nobody();
select t.expect_error('select public.push_sweep()', '%permission denied%', 'S2 service_role cannot run the sweeper');
select t.expect_error('select public.notification_jobs_schedule()', '%permission denied%', 'S2b nor change the schedule');
reset role;

-- ---------------------------------------------------------------------------
-- R. Reminders
-- ---------------------------------------------------------------------------
-- Challenges (A → C): one expiring in 10 h, one in 3 days, one expired.
insert into public.match_challenges (from_club_id, to_club_id, format, proposed_date, venue_name, status, expires_at, created_at)
values (t.club(1), t.club(3), 't20', current_date + 5, 'Remind Park', 'pending', now() + interval '10 hours', now() - interval '6 days');
insert into public.match_challenges (from_club_id, to_club_id, format, proposed_date, venue_name, status, expires_at)
values (t.club(2), t.club(3), 't10', current_date + 6, 'Remind Park', 'pending', now() + interval '3 days');
-- Offers (C: owner 3 → member 401): expiring in 5 h.
insert into public.club_ownership_transfers (club_id, from_user_id, to_user_id, to_member_id, status, expires_at, created_at)
values (t.club(3), t.p(3), t.p(401), t.mem(401), 'pending', now() + interval '5 hours', now() - interval '6 days');
-- 102 muted "matches"; 401 muted everything (ownership is always on).
set role authenticated;
select t.as_user(t.p(102));
select * from public.set_notification_preferences(true, true, false, true, true);
select t.as_user(t.p(401));
select * from public.set_notification_preferences(false, false, false, false, false);
reset role;
select t.nobody();

select public.notification_send_reminders() as sent \gset
select t.ok(:sent = 5, 'R0 one run sends 5 reminders (3 for the match, 1 challenge, 1 offer)');
select t.ok(t.cnt(1, 'match_reminder') = 1 and t.cnt(2, 'match_reminder') = 1 and t.cnt(101, 'match_reminder') = 1
            and (select n.inbox = 'club_owner' and n.match_id = t.m(1) and n.params ->> 'opponent_name' = 'Remind Kings'
                        and n.params ? 'starts_at' and n.params ->> 'venue_name' = 'Remind Ground'
                   from t.one(1, 'match_reminder') n)
            and (select n.inbox = 'player' and n.params ->> 'selection' = 'playing' from t.one(101, 'match_reminder') n),
            'R1 a match within 24 hours: both owners and the selected player');
select t.ok(t.cnt(102, 'match_reminder') = 0, 'R1b a selected player who muted "matches" is not reminded');
select t.ok(t.cnt(103, 'match_reminder') = 0 and t.typed('match_reminder') = 3,
            'R1c not the members who aren''t selected; not the match in 30 h, the started one, the cancelled one');
select t.ok(t.cnt(3, 'challenge_expiring') = 1
            and (select n.inbox = 'club_owner' and n.params ->> 'opponent_name' = 'Remind Lions' and n.params ? 'expires_at'
                   from t.one(3, 'challenge_expiring') n),
            'R2 an unanswered challenge expiring within 24 hours: the challenged owner (not the one in 3 days)');
select t.ok(t.cnt(401, 'ownership_expiring') = 1
            and (select n.inbox = 'player' and n.person_id = t.p(3) and n.params ->> 'club_name' = 'Remind Riders'
                   from t.one(401, 'ownership_expiring') n),
            'R3 an offer expiring within 24 hours: the member — even with everything muted (always on)');
select public.notification_send_reminders() as again \gset
select t.ok(:again = 0 and t.typed('match_reminder') = 3, 'R4 a second run sends nothing again');
update public.matches set starts_at = now() + interval '21 hours' where id = t.m(1);
select public.notification_send_reminders() as moved \gset
select t.ok(:moved = 3 and t.cnt(1, 'match_reminder') = 2, 'R5 a rescheduled match is a new reminder');

-- ---------------------------------------------------------------------------
-- C. The cleanup (90 days)
-- ---------------------------------------------------------------------------
insert into public.notifications (recipient_id, inbox, type, params, dedupe_key, created_at) values
  (t.p(101), 'player', 'announcement', '{"title": "Old"}', 'old:1', now() - interval '91 days'),
  (t.p(101), 'player', 'announcement', '{"title": "Recent"}', 'old:2', now() - interval '89 days');
insert into public.club_announcements (club_id, title, message, audience, created_at) values
  (t.club(1), 'Old one', 'Message', 'all', now() - interval '91 days'),
  (t.club(1), 'Recent one', 'Message', 'all', now() - interval '89 days');
insert into public.device_tokens (user_id, token, platform) values (t.p(101), 'fcm_remind_' || repeat('a', 30), 'android');
insert into public.push_deliveries (notification_id, created_at)
select n.id, now() - interval '91 days' from public.notifications n where n.dedupe_key = 'old:1';
select t.ok(public.notification_cleanup() = '{"notifications": 1, "announcements": 1}'::jsonb,
            'C1 the cleanup removes what is older than 90 days …');
select t.ok(not exists (select 1 from public.notifications where dedupe_key = 'old:1')
            and exists (select 1 from public.notifications where dedupe_key = 'old:2')
            and not exists (select 1 from public.club_announcements where title = 'Old one')
            and exists (select 1 from public.club_announcements where title = 'Recent one')
            and not exists (select 1 from public.push_deliveries d where d.created_at < now() - interval '90 days'),
            'C1b … and keeps 89 days; the push records go with their notifications');
select t.ok(public.notification_cleanup() = '{"notifications": 0, "announcements": 0}'::jsonb, 'C2 nothing more to remove');

-- ---------------------------------------------------------------------------
-- W. The push sweeper (stand-ins for pg_net and Vault)
-- ---------------------------------------------------------------------------
create schema net;
create table net.calls (id bigserial primary key, url text, headers jsonb);
create function net.http_post(url text, body jsonb, headers jsonb, timeout_milliseconds int)
returns bigint language sql as $$ insert into net.calls (url, headers) values (url, headers) returning id $$;
create schema vault;
create view vault.decrypted_secrets as
  select * from (values ('push_dispatch_url', 'https://example.local/functions/v1/push-dispatch'),
                        ('push_dispatch_secret', 'local-test-secret')) v(name, decrypted_secret);
delete from public.push_deliveries d using public.notifications n
 where n.id = d.notification_id and n.recipient_id::text like 'ee500000%';
select t.ok(public.push_sweep() = 0 and (select count(*) from net.calls) = 0, 'W1 nothing waiting: nobody woken');
insert into public.push_deliveries (notification_id, created_at)
select n.id, now() - interval '1 minute' from public.notifications n where n.dedupe_key = 'old:2';
select t.ok(public.push_sweep() = 0 and (select count(*) from net.calls) = 0, 'W2 just queued (under 2 minutes): left to its own wake-up');
update public.push_deliveries d set created_at = now() - interval '3 minutes'
  from public.notifications n where n.id = d.notification_id and n.dedupe_key = 'old:2';
select public.push_sweep() as waiting \gset
select t.ok(:waiting = 1 and (select count(*) from net.calls) = 1
            and (select c.headers ->> 'x-push-secret' from net.calls c) = 'local-test-secret',
            'W3 waiting over 2 minutes: the dispatcher is woken again');
drop schema net cascade;
drop schema vault cascade;
select t.ok(public.push_sweep() = 1, 'W4 without pg_net: the sweeper still runs (and only counts)');

-- ---------------------------------------------------------------------------
-- K. The schedule (a stand-in for pg_cron)
-- ---------------------------------------------------------------------------
select t.ok(public.notification_jobs_schedule() = 'pg_cron is not enabled: nothing scheduled',
            'K1 without pg_cron: nothing scheduled, no error');
create schema cron;
create table cron.job (jobid bigserial primary key, jobname text unique, schedule text, command text, active boolean default true);
create function cron.schedule(job_name text, schedule text, command text) returns bigint language sql as $$
  insert into cron.job (jobname, schedule, command) values (job_name, schedule, command)
  on conflict (jobname) do update set schedule = excluded.schedule, command = excluded.command
  returning jobid $$;
select public.notification_jobs_schedule();
select public.notification_jobs_schedule();
select t.ok((select string_agg(j.jobname || ' ' || j.schedule || ' ' || j.command, ' | ' order by j.jobname) from cron.job j)
            = 'criceco-notification-cleanup 15 22 * * * select public.notification_cleanup() | '
              'criceco-notification-reminders */15 * * * * select public.notification_send_reminders() | '
              'criceco-push-sweep */5 * * * * select public.push_sweep()',
            'K2 with pg_cron: the three jobs, scheduled once even when asked twice');
drop schema cron cascade;

-- ---------------------------------------------------------------------------
-- Clean up (this database only): only this check's own records.
-- ---------------------------------------------------------------------------
delete from public.clubs where owner_id::text like 'ee500000%';
delete from public.matches where id::text like 'ee5000aa%';
delete from auth.users where id::text like 'ee500000%';
select t.ok(not exists (select 1 from public.profiles where id::text like 'ee500000%')
            and not exists (select 1 from public.notifications where recipient_id::text like 'ee500000%')
            and to_regnamespace('net') is null and to_regnamespace('vault') is null and to_regnamespace('cron') is null,
            'Z cleanup done');
drop schema t cascade;
