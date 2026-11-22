-- CricEco · LOCAL TEST ONLY — migration 27 (push delivery, M3 P5) on a
-- DISPOSABLE plain PostgreSQL 17 database, after 00_auth_stub.sql,
-- 02_legacy_profiles_fixture.sql, migrations 1–26 (+ the D1 location seed)
-- and migration 27. Synthetic data only (people ee4…). pg_net and Vault
-- don't exist here: section W installs throwaway stand-ins (schemas net and
-- vault) to see the wake-up, and removes them again.
-- Run with psql:  psql -X -v ON_ERROR_STOP=1 -f 22_push_delivery_local_check.sql
-- Every check prints "PASS: …"; the first failure stops the run ("FAIL: …").
-- Concurrency (two sessions) is in 22b_push_delivery_concurrency.sh.
-- Refuses to run on a real Supabase project (its auth.users has passwords).
\set ON_ERROR_STOP on

do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password') then
    raise exception 'LOCAL ONLY: this looks like a real Supabase project — refusing';
  end if;
  if to_regclass('public.device_tokens') is null then
    raise exception 'apply migration 27 first';
  end if;
  if to_regnamespace('net') is not null or to_regnamespace('vault') is not null then
    raise exception 'LOCAL ONLY: this database has pg_net / Vault — refusing (section W replaces them)';
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
  select ('ee400000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
$$;
-- A token shaped like an FCM registration token.
create or replace function t.tok(p_label text) returns text language sql immutable as $$
  select 'fcm_' || p_label || '_' || repeat('a', 40);
$$;
create or replace function t.club() returns uuid language sql stable security definer set search_path = '' as $$
  select c.id from public.clubs c where c.name = 'Push Lions';
$$;
create or replace function t.code() returns text language sql stable security definer set search_path = '' as $$
  select c.code from public.clubs c where c.name = 'Push Lions';
$$;
create or replace function t.tokens(p_n int) returns text[] language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(d.token order by d.token), '{}') from public.device_tokens d
   where d.user_id = ('ee400000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
$$;
-- Deliveries of [p_n]'s notifications: "status:attempts" each, oldest first.
create or replace function t.queue(p_n int) returns text language sql stable security definer set search_path = '' as $$
  select coalesce(string_agg(d.status || ':' || d.attempts, ',' order by n.created_at, n.id), '-')
    from public.push_deliveries d join public.notifications n on n.id = d.notification_id
   where n.recipient_id = ('ee400000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
$$;
create or replace function t.notes(p_n int) returns int language sql stable security definer set search_path = '' as $$
  select count(*)::int from public.notifications n
   where n.recipient_id = ('ee400000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
$$;
create or replace function t.last_note(p_n int) returns uuid language sql stable security definer set search_path = '' as $$
  select n.id from public.notifications n
   where n.recipient_id = ('ee400000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid
   order by n.created_at desc, n.id desc limit 1;
$$;
create or replace function t.register(p_n int, p_label text) returns void language plpgsql as $$
begin
  perform t.as_user(t.p(p_n));
  perform public.register_push_device(t.tok(p_label), 'android');
end $$;
create or replace function t.publish(p_title text) returns int language plpgsql as $$
declare v int;
begin
  perform t.as_user(t.p(1));
  select r.recipient_count into v from public.publish_club_announcement(t.club(), p_title, 'Message.', 'all') r;
  return v;
end $$;
create or replace function t.make_person(p_n int) returns uuid language plpgsql as $$
declare
  v uuid := t.p(p_n);
begin
  insert into auth.users (id, email) values (v, format('push%s@local.test', p_n));
  insert into public.current_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
  insert into public.permanent_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
  update public.profiles
     set full_name = format('Push Person %s', p_n),
         phone = format('+923%s', lpad((650000000 + p_n)::text, 9, '0')),
         date_of_birth = date '2000-05-01', profile_completed = true
   where id = v;
  insert into public.player_profiles (user_id, player_role, batting_style, bowling_style, is_wicketkeeper)
  values (v, 'all_rounder', 'right_handed', 'right_arm_fast', false);
  return v;
end $$;
grant execute on all functions in schema t to anon, authenticated, service_role;

-- Synthetic data: owner 1 (Push Lions), members 101–103; 300 and 301 in no club.
select t.nobody();
select count(*) from (select t.make_person(n) from unnest(array[1, 101, 102, 103, 300, 301]) n) s;
insert into public.clubs (owner_id, name, city, club_type) values (t.p(1), 'Push Lions', 'Lahore', 'corporate');
insert into public.club_members (club_id, user_id, member_role, status)
select t.club(), t.p(n), 'player', 'active' from unnest(array[101, 102, 103]) n;

-- ---------------------------------------------------------------------------
-- S. Access
-- ---------------------------------------------------------------------------
set role anon;
select t.expect_error(format('select public.register_push_device(%L)', t.tok('x')), '%permission denied%',
                      'S1 anon cannot register a device');
reset role;
set role authenticated;
select t.as_user(t.p(101));
select t.expect_error('select count(*) from public.device_tokens', '%permission denied%',
                      'S2 a user cannot read device tokens (not even their own)');
select t.expect_error('select count(*) from public.push_deliveries', '%permission denied%',
                      'S2b nor the push queue');
select t.expect_error('select * from public.push_claim(10)', '%permission denied%',
                      'S3 nor claim deliveries (the dispatcher''s)');
select t.expect_error('select public.push_report(''[]'')', '%permission denied%', 'S3b nor report results');
select t.expect_error('select public.push_wake()', '%permission denied%', 'S3c nor wake the dispatcher');
reset role;
set role service_role;
select t.nobody();
select t.expect_error('select count(*) from public.device_tokens', '%permission denied%',
                      'S4 service_role cannot read the tokens directly (only through push_claim)');
select t.expect_error(format('select public.register_push_device(%L)', t.tok('x')), '%permission denied%',
                      'S4b nor register a device for someone');
reset role;

-- ---------------------------------------------------------------------------
-- R. Registering devices
-- ---------------------------------------------------------------------------
set role authenticated;
select t.as_user(t.p(101));
select t.expect_error('select public.register_push_device(''short'')', '%invalid token%', 'R1 a malformed token is refused');
select t.expect_error(format('select public.register_push_device(%L)', 'fcm token with spaces ' || repeat('a', 30)),
                      '%invalid token%', 'R1b … whitespace too');
select t.expect_error(format('select public.register_push_device(%L, %L)', t.tok('x'), 'ios'), '%invalid platform%',
                      'R1c Android only for now');
select t.nobody();
select t.expect_error(format('select public.register_push_device(%L)', t.tok('x')), '%not authenticated%',
                      'R1d without a signed-in user: not authenticated');
select t.register(101, 'phone');
select t.register(101, 'phone');
select t.register(101, 'tablet');
select t.ok(t.tokens(101) = array[t.tok('phone'), t.tok('tablet')], 'R2 one row per device; registering again is no duplicate');
select t.register(102, 'phone');
select t.ok(t.tokens(101) = array[t.tok('tablet')] and t.tokens(102) = array[t.tok('phone')],
            'R3 signing in on the same phone as someone else moves the token to them');
-- Twelve devices, one after another (each its own transaction, as in real life).
select format('select t.register(103, %L)', 'd' || k) from generate_series(1, 12) k \gexec
select t.ok(cardinality(t.tokens(103)) = 10 and not (t.tok('d1') = any (t.tokens(103))) and not (t.tok('d2') = any (t.tokens(103)))
            and t.tok('d12') = any (t.tokens(103)),
            'R4 at most 10 devices per person: the longest unseen go');
select t.as_user(t.p(101));
select t.ok(public.unregister_push_device(t.tok('phone')) = 0 and t.tokens(102) = array[t.tok('phone')],
            'R5 nobody can remove someone else''s device');
select public.unregister_push_device(t.tok('tablet')) as removed \gset
select t.ok(:removed = 1 and t.tokens(101) = '{}', 'R5b … but their own, yes (the device switch off / sign-out)');
reset role;

-- ---------------------------------------------------------------------------
-- Q. The queue
-- ---------------------------------------------------------------------------
-- Devices now: 102 (1), 103 (10); 101 none.
set role authenticated;
select t.ok(t.publish('One') = 3, 'Q0 an announcement to the 3 members');
reset role;
select t.ok(t.queue(101) = '-' and t.notes(101) = 1, 'Q1 no device: notified in the app, nothing queued');
select t.ok(t.queue(102) = 'pending:0' and t.queue(103) = 'pending:0', 'Q2 with a device: one pending delivery each');
set role authenticated;
select t.as_user(t.p(102));
select * from public.set_notification_preferences(true, true, true, true, false);
select t.publish('Two');
reset role;
select t.ok(t.queue(102) = 'pending:0' and t.queue(103) = 'pending:0,pending:0',
            'Q3 a muted category is neither created nor pushed (102 muted announcements)');
set role authenticated;
select t.as_user(t.p(102));
select * from public.set_notification_preferences(true, true, true, true, true);
select t.as_user(t.p(101));
select t.expect_error(format('select public.publish_club_announcement(%L, %L, %L, %L)', t.club(), 'x', 'm', 'all'),
                      '%not allowed%', 'Q4 a refused action …');
reset role;
select t.ok(t.queue(102) = 'pending:0', 'Q4b … queues nothing');

-- ---------------------------------------------------------------------------
-- W. Waking the dispatcher (with stand-ins for pg_net and Vault)
-- ---------------------------------------------------------------------------
select t.ok(true, 'W0 without pg_net / Vault every action above ran — the queue just waits');
create schema net;
create table net.calls (id bigserial primary key, url text, body jsonb, headers jsonb, timeout_ms int, tx bigint);
create function net.http_post(url text, body jsonb, headers jsonb, timeout_milliseconds int)
returns bigint language plpgsql as $$
declare v bigint;
begin
  if current_setting('t.net_fail', true) = 'yes' then raise exception 'net is down'; end if;
  insert into net.calls (url, body, headers, timeout_ms, tx) values (url, body, headers, timeout_milliseconds, txid_current())
  returning id into v;
  return v;
end $$;
create schema vault;
create view vault.decrypted_secrets as
  select * from (values ('push_dispatch_url', 'https://example.local/functions/v1/push-dispatch'),
                        ('push_dispatch_secret', 'local-test-secret')) v(name, decrypted_secret);

set role authenticated;
select t.ok(t.publish('Three') = 3, 'W1 an announcement to 3 members, 2 with devices …');
reset role;
select t.ok((select count(*) = 1 and bool_and(c.url = 'https://example.local/functions/v1/push-dispatch'
                                              and c.headers ->> 'x-push-secret' = 'local-test-secret'
                                              and c.body = '{}'::jsonb and c.timeout_ms = 5000)
               from net.calls c),
            'W1b … wakes the dispatcher ONCE for the whole transaction, with the secret, no content');
set role authenticated;
select t.as_user(t.p(300));
select (public.request_to_join_club(t.code())).status;
reset role;
select t.ok((select count(*) from net.calls) = 1, 'W2 a notification for someone without a device wakes nobody');
set role authenticated;
select t.register(1, 'owner');
select t.as_user(t.p(301));
select (public.request_to_join_club(t.code())).status;
reset role;
select t.ok((select count(*) from net.calls) = 2 and t.queue(1) = 'pending:0', 'W3 the next transaction wakes it again');
begin;
set local role authenticated;
select t.publish('Rolled back');
rollback;
select t.ok((select count(*) from net.calls) = 2 and t.queue(103) = 'pending:0,pending:0,pending:0',
            'W4 a rolled-back action queues nothing and wakes nobody');
set t.net_fail = 'yes';
set role authenticated;
select t.ok(t.publish('Net down') = 3, 'W5 pg_net failing …');
reset role;
select t.ok(t.queue(103) = 'pending:0,pending:0,pending:0,pending:0' and (select count(*) from net.calls) = 2,
            'W5b … never fails the action: the delivery waits in the queue');
reset t.net_fail;
drop schema net cascade;
drop schema vault cascade;

-- ---------------------------------------------------------------------------
-- C. Claiming and reporting (service_role: the push-dispatch Edge Function)
-- ---------------------------------------------------------------------------
set role service_role;
select t.nobody();
create temp table claimed on commit preserve rows as select * from public.push_claim(500);
reset role;
select t.ok((select count(*) from claimed) = (select count(*) from public.push_deliveries)
            and (select bool_and(c.attempts = 1 and cardinality(c.tokens) > 0 and c.inbox in ('player', 'club_owner'))
                   from claimed c)
            and (select c.tokens from claimed c where c.notification_id = t.last_note(102)) = array[t.tok('phone')]
            and (select c.type = 'announcement' and c.params ->> 'title' = 'Net down' and c.params ->> 'club_name' = 'Push Lions'
                   from claimed c where c.notification_id = t.last_note(103))
            and not exists (select 1 from public.push_deliveries d where d.status <> 'sending'),
            'C1 a claim returns each delivery with its type, parameters and the recipient''s tokens; all now "sending"');
set role service_role;
select t.ok(not exists (select 1 from public.push_claim(500)), 'C2 a second claim gets nothing (they are being sent)');
select t.ok(public.push_report(jsonb_build_array(
              jsonb_build_object('notification_id', t.last_note(102), 'outcome', 'sent'),
              jsonb_build_object('notification_id', t.last_note(1), 'outcome', 'retry', 'error', 'UNAVAILABLE'),
              jsonb_build_object('notification_id', t.last_note(103), 'outcome', 'failed', 'error', 'INVALID_ARGUMENT',
                                 'invalid_tokens', jsonb_build_array(t.tok('d12'), t.tok('phone'))))) = 3,
            'C3 results are recorded');
reset role;
select t.ok((select d.status = 'sent' and d.finished_at is not null and d.last_error is null
               from public.push_deliveries d where d.notification_id = t.last_note(102))
            and (select d.status = 'pending' and d.finished_at is null and d.last_error = 'UNAVAILABLE'
                   from public.push_deliveries d where d.notification_id = t.last_note(1))
            and (select d.status = 'failed' and d.last_error = 'INVALID_ARGUMENT'
                   from public.push_deliveries d where d.notification_id = t.last_note(103)),
            'C3b sent / back to pending / failed');
select t.ok(not (t.tok('d12') = any (t.tokens(103))) and t.tokens(102) = array[t.tok('phone')],
            'C4 an invalid token is removed — only the recipient''s own (102''s phone stays)');
set role service_role;
select t.ok(public.push_report(jsonb_build_array(jsonb_build_object('notification_id', t.last_note(102), 'outcome', 'failed'))) = 0,
            'C5 a result for a delivery not being sent is ignored');
select t.expect_error('select public.push_report(''[{"notification_id": "x", "outcome": "sent"}]'')', '%invalid%',
                      'C6 a malformed report is refused');
select t.expect_error('select public.push_report(''{"a": 1}'')', '%invalid%', 'C6b … an object too');
-- Retries: up to 3 attempts, then failed.
select count(*) from public.push_claim(500);
select public.push_report(jsonb_build_array(jsonb_build_object('notification_id', t.last_note(1), 'outcome', 'retry')));
select count(*) from public.push_claim(500);
select public.push_report(jsonb_build_array(jsonb_build_object('notification_id', t.last_note(1), 'outcome', 'retry')));
reset role;
select t.ok(t.queue(1) = 'failed:3', 'C7 a delivery is tried at most 3 times');
-- A dispatcher that died: "sending" for 5 minutes is claimed again.
set role service_role;
select count(*) from public.push_claim(500);
reset role;
update public.push_deliveries set claimed_at = now() - interval '6 minutes' where status = 'sending';
set role service_role;
select t.ok((select count(*) from public.push_claim(500)) > 0, 'C8 a delivery stuck "sending" for 5 minutes is claimed again');
reset role;
-- Too old, or no device any more: skipped.
select t.last_note(102) as old102 \gset
update public.push_deliveries set status = 'pending', finished_at = null, created_at = now() - interval '2 days'
 where notification_id = :'old102';
set role authenticated;
select t.as_user(t.p(103));
select count(*) from (select public.unregister_push_device(x) from unnest(t.tokens(103)) x) s;
select t.publish('After');
reset role;
update public.push_deliveries d set status = 'pending'
  from public.notifications n where n.id = d.notification_id and n.recipient_id = t.p(103) and d.status = 'sending';
-- 103 has no device now, but a new delivery for them (queued before) is faked:
insert into public.push_deliveries (notification_id) values (t.last_note(103)) on conflict do nothing;
set role service_role;
select count(*) from public.push_claim(500);
reset role;
select t.ok((select d.status = 'skipped' and d.last_error = 'EXPIRED' from public.push_deliveries d
              where d.notification_id = :'old102')
            and (select bool_and(d.status = 'skipped' and d.last_error = 'NO_DEVICE')
                   from public.push_deliveries d join public.notifications n on n.id = d.notification_id
                  where n.recipient_id = t.p(103) and d.status not in ('failed', 'sent')),
            'C9 older than a day: skipped (EXPIRED); no device any more: skipped (NO_DEVICE)');

-- ---------------------------------------------------------------------------
-- D. Account deletion
-- ---------------------------------------------------------------------------
select t.nobody();
delete from auth.users where id = t.p(102);
select t.ok(t.tokens(102) = '{}' and t.queue(102) = '-', 'D1 deleting an account deletes its devices and its queue');

-- ---------------------------------------------------------------------------
-- Clean up (this database only): only this check's own records.
-- ---------------------------------------------------------------------------
drop table claimed;
delete from public.clubs where owner_id::text like 'ee400000%';
delete from auth.users where id::text like 'ee400000%';
select t.ok(not exists (select 1 from public.profiles where id::text like 'ee400000%')
            and not exists (select 1 from public.device_tokens d where d.token like 'fcm\_%')
            and to_regnamespace('net') is null and to_regnamespace('vault') is null,
            'Z cleanup done');
drop schema t cascade;
