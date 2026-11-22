-- CricEco · ROLLBACK of migration 28 (scheduled notification jobs, M3 P6).
--
-- NOT APPLIED. Run only with explicit approval, after a backup, inside
--   begin; set local lock_timeout = '5s'; <this file> commit;
--
-- Stops the jobs (their pg_cron schedules are removed when pg_cron exists),
-- removes the reminder types and the job functions, and restores migration
-- 26's notification_category verbatim (below) and migration 25's type list.
-- Reminders already sent would no longer fit the type list: it REFUSES
-- while any exist, unless you confirm in the same transaction that they may
-- be deleted:
--   set local criceco.rollback_reminders_discarded = 'yes';
-- Nothing else changes. An app with the reminder types keeps working (it
-- simply receives none).
-- Generated from migration 26 (commit 371c7ce) by the M3 P6 build script.

do $$
begin
  if to_regprocedure('public.notification_send_reminders()') is null then
    raise exception 'rollback 28: migration 28 is not applied — nothing changed';
  end if;
  if exists (select 1 from public.notifications
              where type in ('match_reminder', 'challenge_expiring', 'ownership_expiring'))
     and coalesce(current_setting('criceco.rollback_reminders_discarded', true), '') <> 'yes' then
    raise exception 'rollback 28: reminders were sent — set criceco.rollback_reminders_discarded = ''yes'' to delete them (nothing changed)';
  end if;
end $$;

-- The schedules (only where pg_cron exists).
do $$
declare
  v_job text;
begin
  if to_regnamespace('cron') is null then
    return;
  end if;
  foreach v_job in array array['criceco-notification-reminders', 'criceco-push-sweep', 'criceco-notification-cleanup'] loop
    if exists (select 1 from cron.job j where j.jobname = v_job) then
      perform cron.unschedule(v_job);
    end if;
  end loop;
end $$;

delete from public.notifications where type in ('match_reminder', 'challenge_expiring', 'ownership_expiring');

drop function if exists public.notification_jobs_schedule();
drop function if exists public.push_sweep();
drop function if exists public.notification_cleanup();
drop function if exists public.notification_send_reminders();

-- Migration 25's type list.
alter table public.notifications
  drop constraint notifications_type_check,
  add constraint notifications_type_check check (type in (
    'join_request_received', 'join_request_approved', 'join_request_declined', 'removed_from_club',
    'ownership_offered', 'ownership_accepted', 'ownership_rejected', 'ownership_withdrawn',
    'challenge_received', 'challenge_accepted', 'challenge_declined',
    'schedule_proposed', 'schedule_accepted', 'schedule_declined', 'match_rescheduled', 'match_cancelled',
    'lineup_selected', 'lineup_changed', 'lineup_dropped',
    'result_published', 'result_corrected', 'player_of_match',
    'announcement'));

-- Migration 26's notification_category, verbatim.
create or replace function public.notification_category(p_type text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
           when p_type = 'join_request_received' then 'join_requests'
           when p_type in ('challenge_received', 'challenge_accepted', 'challenge_declined',
                           'schedule_proposed', 'schedule_accepted', 'schedule_declined') then 'challenges'
           when p_type in ('lineup_selected', 'lineup_changed', 'lineup_dropped',
                           'match_rescheduled', 'match_cancelled') then 'matches'
           when p_type in ('result_published', 'result_corrected', 'player_of_match') then 'results'
           when p_type = 'announcement' then 'announcements'
           else 'membership'
         end;
$$;

notify pgrst, 'reload schema';
