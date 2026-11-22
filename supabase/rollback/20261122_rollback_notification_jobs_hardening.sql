-- CricEco · ROLLBACK of migration 29 (notification jobs: failure isolation and
-- a run log, M3 P6 hardening).
--
-- NOT APPLIED. Run only with explicit approval, after a backup, inside
--   begin; set local lock_timeout = '5s'; <this file> commit;
--
-- Restores migration 28's notification_send_reminders, notification_cleanup
-- and push_sweep verbatim (below), then drops notification_job_record and the
-- notification_job_runs table. The pg_cron schedule is not touched (its
-- commands are the same before and after). The run log would be lost: it
-- REFUSES while it has any row, unless you confirm in the same transaction:
--   set local criceco.rollback_job_runs_discarded = 'yes';
-- Nothing else changes; no notification, announcement or push is touched.
-- Generated from migration 28 (commit cb492e1, lines 82–207) for M3 P6 hardening.

do $$
begin
  if to_regclass('public.notification_job_runs') is null
     or to_regprocedure('public.notification_send_reminders()') is null then
    raise exception 'rollback 29: migration 29 is not applied — nothing changed';
  end if;
  if exists (select 1 from public.notification_job_runs)
     and coalesce(current_setting('criceco.rollback_job_runs_discarded', true), '') <> 'yes' then
    raise exception 'rollback 29: the job run log has rows — set criceco.rollback_job_runs_discarded = ''yes'' to delete them (nothing changed)';
  end if;
end $$;

-- Migration 28's three job functions, verbatim.
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

-- The run log and its writer.
drop function if exists public.notification_job_record(text, timestamptz, integer, integer, integer, integer, integer, text[], text[], boolean);
drop table if exists public.notification_job_runs;

revoke execute on function public.notification_send_reminders() from public, anon, authenticated, service_role;
revoke execute on function public.notification_cleanup() from public, anon, authenticated, service_role;
revoke execute on function public.push_sweep() from public, anon, authenticated, service_role;
