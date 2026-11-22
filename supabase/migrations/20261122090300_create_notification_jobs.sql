-- CricEco · migration 28 · scheduled notification jobs (M3 P6)
--
-- NOT APPLIED. Requires migrations 25–27 (inbox, preferences, push).
-- Rollback: supabase/rollback/20261122_rollback_notification_jobs.sql.
-- Read-only check: supabase/tests/28_notification_jobs_postcheck.sql.
-- Local tests: supabase/tests/local/23_notification_jobs_local_check.sql.
-- Design: docs/NOTIFICATIONS_BACKEND.md ("P6").
--
-- Approved 2026-11-22 (M3 P6):
--   * three reminders, each once (per schedule / offer / challenge):
--       match_reminder      — a confirmed match starts within 24 hours: both
--                             owners and the selected players (category
--                             "matches": can be muted);
--       challenge_expiring  — an unanswered challenge expires within 24 hours:
--                             the challenged club's owner ("challenges");
--       ownership_expiring  — an unanswered ownership offer expires within 24
--                             hours: the member it was offered to
--                             ("membership": always on);
--   * the cleanup (D7): notifications older than 90 days (read or not, with
--     their push records) and club announcements older than 90 days;
--   * the push sweeper (P5): pushes waiting more than 2 minutes wake the
--     dispatcher again;
--   * scheduled by pg_cron — reminders every 15 minutes, the sweeper every
--     5, the cleanup daily at 03:15 (Pakistan, 22:15 UTC). pg_cron is
--     enabled on production in a separate, approved settings step; until
--     then (and locally) the jobs exist but nothing runs them —
--     notification_jobs_schedule() schedules them once pg_cron is there.
-- Changes to earlier migrations: the notifications type list gains the three
-- reminder types, and notification_category (migration 26) knows them.

do $$
begin
  if to_regclass('public.push_deliveries') is null
     or to_regprocedure('public.notification_category(text)') is null then
    raise exception 'migration 28: migrations 25–27 are required';
  end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public'
                and p.proname in ('notification_send_reminders', 'notification_cleanup', 'push_sweep',
                                  'notification_jobs_schedule'))
     or exists (select 1 from pg_constraint k
                 where k.conrelid = 'public.notifications'::regclass and k.conname = 'notifications_type_check'
                   and pg_get_constraintdef(k.oid) like '%match_reminder%') then
    raise exception 'migration 28: already applied (or a name is taken) — nothing changed';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Three reminder types, and their categories
-- ---------------------------------------------------------------------------
alter table public.notifications
  drop constraint notifications_type_check,
  add constraint notifications_type_check check (type in (
    'join_request_received', 'join_request_approved', 'join_request_declined', 'removed_from_club',
    'ownership_offered', 'ownership_accepted', 'ownership_rejected', 'ownership_withdrawn',
    'challenge_received', 'challenge_accepted', 'challenge_declined',
    'schedule_proposed', 'schedule_accepted', 'schedule_declined', 'match_rescheduled', 'match_cancelled',
    'lineup_selected', 'lineup_changed', 'lineup_dropped',
    'result_published', 'result_corrected', 'player_of_match',
    'announcement',
    'match_reminder', 'challenge_expiring', 'ownership_expiring'));

create or replace function public.notification_category(p_type text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
           when p_type = 'join_request_received' then 'join_requests'
           when p_type in ('challenge_received', 'challenge_accepted', 'challenge_declined',
                           'schedule_proposed', 'schedule_accepted', 'schedule_declined',
                           'challenge_expiring') then 'challenges'
           when p_type in ('lineup_selected', 'lineup_changed', 'lineup_dropped',
                           'match_rescheduled', 'match_cancelled', 'match_reminder') then 'matches'
           when p_type in ('result_published', 'result_corrected', 'player_of_match') then 'results'
           when p_type = 'announcement' then 'announcements'
           else 'membership'
         end;
$$;

-- ---------------------------------------------------------------------------
-- 2. The reminders (every 15 minutes). Each is sent once: the dedupe key
--    names the match's schedule (a reschedule is a new reminder), the
--    challenge, the offer. Muted categories are skipped by notification_add.
-- ---------------------------------------------------------------------------
create or replace function public.notification_send_reminders()
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_before integer := (select count(*) from public.notifications n
                        where n.type in ('match_reminder', 'challenge_expiring', 'ownership_expiring'));
  v_match  public.matches;
  v_key    text;
  v_a      public.clubs;
  v_b      public.clubs;
begin
  -- A confirmed match starting within 24 hours: both owners, then the
  -- selected players (an owner who is selected is told once).
  for v_match in
    select m.* from public.matches m
     where m.status = 'confirmed' and m.starts_at > now() and m.starts_at <= now() + interval '24 hours'
  loop
    v_key := 'reminder:match:' || v_match.id || ':' || floor(extract(epoch from v_match.starts_at))::bigint;
    select * into v_a from public.clubs c where c.id = v_match.club_a_id;
    select * into v_b from public.clubs c where c.id = v_match.club_b_id;
    perform public.notification_add(
              v_a.owner_id, 'club_owner', 'match_reminder', v_key,
              jsonb_build_object('club_name', v_a.name, 'opponent_name', v_b.name, 'starts_at', v_match.starts_at,
                                 'venue_name', v_match.venue_name, 'city', v_match.city),
              v_a.id, v_match.id);
    perform public.notification_add(
              v_b.owner_id, 'club_owner', 'match_reminder', v_key,
              jsonb_build_object('club_name', v_b.name, 'opponent_name', v_a.name, 'starts_at', v_match.starts_at,
                                 'venue_name', v_match.venue_name, 'city', v_match.city),
              v_b.id, v_match.id);
    perform public.notification_lineup_fanout(
              v_match, 'match_reminder', v_key,
              jsonb_build_object('starts_at', v_match.starts_at, 'venue_name', v_match.venue_name, 'city', v_match.city));
  end loop;

  -- An unanswered challenge expiring within 24 hours: the challenged owner.
  perform public.notification_add(
            t.owner_id, 'club_owner', 'challenge_expiring', 'reminder:challenge:' || ch.id,
            jsonb_build_object('opponent_name', f.name, 'expires_at', ch.expires_at, 'format', ch.format,
                               'custom_overs', ch.custom_overs, 'proposed_date', ch.proposed_date,
                               'venue_name', ch.venue_name),
            t.id, null, ch.id)
     from public.match_challenges ch
     join public.clubs t on t.id = ch.to_club_id
     join public.clubs f on f.id = ch.from_club_id
    where ch.status = 'pending' and ch.expires_at > now() and ch.expires_at <= now() + interval '24 hours';

  -- An unanswered ownership offer expiring within 24 hours: the member.
  perform public.notification_add(
            x.to_user_id, 'player', 'ownership_expiring', 'reminder:ownership:' || x.id,
            jsonb_build_object('club_name', c.name, 'person_name', public.notification_person_name(x.from_user_id),
                               'expires_at', x.expires_at),
            x.club_id, null, x.id, x.from_user_id)
     from public.club_ownership_transfers x
     join public.clubs c on c.id = x.club_id
    where x.status = 'pending' and x.expires_at > now() and x.expires_at <= now() + interval '24 hours';

  return (select count(*) from public.notifications n
           where n.type in ('match_reminder', 'challenge_expiring', 'ownership_expiring')) - v_before;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. The cleanup (daily, D7): older than 90 days. At most 10,000 of each per
--    run (short locks); a backlog clears over the following days.
-- ---------------------------------------------------------------------------
create or replace function public.notification_cleanup()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_notifications integer;
  v_announcements integer;
begin
  delete from public.notifications n
   where n.id in (select x.id from public.notifications x
                   where x.created_at < now() - interval '90 days'
                   order by x.created_at limit 10000);
  get diagnostics v_notifications = row_count;
  delete from public.club_announcements a
   where a.id in (select x.id from public.club_announcements x
                   where x.created_at < now() - interval '90 days'
                   order by x.created_at limit 10000);
  get diagnostics v_announcements = row_count;
  return jsonb_build_object('notifications', v_notifications, 'announcements', v_announcements);
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. The push sweeper (every 5 minutes): pushes still waiting after 2
--    minutes (a wake-up that failed or found the dispatcher busy) wake it
--    again. Returns how many are waiting.
-- ---------------------------------------------------------------------------
create or replace function public.push_sweep()
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_waiting integer;
begin
  select count(*) into v_waiting
    from public.push_deliveries d
   where d.created_at > now() - interval '1 day'
     and ((d.status = 'pending' and d.created_at < now() - interval '2 minutes')
          or (d.status = 'sending' and d.claimed_at < now() - interval '5 minutes'));
  if v_waiting > 0 then
    perform public.push_wake();
  end if;
  return v_waiting;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. The schedule (pg_cron). Idempotent: scheduling a job name again
--    replaces it. Without pg_cron it does nothing and says so.
-- ---------------------------------------------------------------------------
create or replace function public.notification_jobs_schedule()
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if to_regnamespace('cron') is null then
    return 'pg_cron is not enabled: nothing scheduled';
  end if;
  execute 'select cron.schedule($1, $2, $3)'
    using 'criceco-notification-reminders', '*/15 * * * *', 'select public.notification_send_reminders()';
  execute 'select cron.schedule($1, $2, $3)'
    using 'criceco-push-sweep', '*/5 * * * *', 'select public.push_sweep()';
  execute 'select cron.schedule($1, $2, $3)'
    using 'criceco-notification-cleanup', '15 22 * * *', 'select public.notification_cleanup()';
  return 'scheduled: reminders every 15 minutes, push sweep every 5 minutes, cleanup daily 22:15 UTC';
end;
$$;

do $$
begin
  raise notice 'migration 28: %', public.notification_jobs_schedule();
end $$;

-- ---------------------------------------------------------------------------
-- 6. Privileges: the jobs run as the database owner (pg_cron); nobody calls
--    them through the API.
-- ---------------------------------------------------------------------------
revoke execute on function public.notification_send_reminders() from public, anon, authenticated, service_role;
revoke execute on function public.notification_cleanup() from public, anon, authenticated, service_role;
revoke execute on function public.push_sweep() from public, anon, authenticated, service_role;
revoke execute on function public.notification_jobs_schedule() from public, anon, authenticated, service_role;
