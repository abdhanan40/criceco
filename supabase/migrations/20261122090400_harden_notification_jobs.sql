-- CricEco · migration 29 · notification jobs: failure isolation and a run log
-- (M3 P6 hardening)
--
-- NOT APPLIED. Requires migration 28 (the scheduled notification jobs).
-- Rollback: supabase/rollback/20261122_rollback_notification_jobs_hardening.sql.
-- Read-only check: supabase/tests/29_notification_jobs_hardening_postcheck.sql.
-- Local tests: supabase/tests/local/24_notification_jobs_hardening_local_check.sql,
--              supabase/tests/local/24b_notification_jobs_concurrency.sh.
-- Design: docs/NOTIFICATIONS_BACKEND.md ("P6 hardening").
--
-- Approved for local implementation 2026-11-22. Closes two gaps of migration 28:
--   G1 one failing reminder stopped the whole run (one transaction), and the
--      same row failed again every 15 minutes, so nobody was reminded;
--   G2 nothing recorded what a run did (pg_cron keeps only succeeded/failed).
-- What changes:
--   * notification_send_reminders(): every recipient group of a match (owner
--     A, owner B, the selected players), every challenge and every offer is
--     sent on its own (a savepoint each). A failure is recorded and skipped;
--     everything else is still sent. Nothing marks a failed item: the next
--     run (15 minutes later) tries it again, and the dedupe keys of migration
--     28 keep anything already sent from being sent twice. A whole section
--     whose query fails (matches / challenges / offers) is recorded and the
--     other sections still run;
--   * notification_cleanup(): its three deletes (notifications, announcements,
--     job runs) fail independently; it also removes job runs older than 30
--     days (at most 10,000 a run);
--   * push_sweep(): a failure is recorded instead of failing the job;
--   * every run of the three jobs writes one row to notification_job_runs
--     (job, start/end, counts, errors, the first error, up to 20 failed
--     items). If even that row can't be written the job still finishes
--     (a WARNING goes to the database log).
--   * the number of reminders a run returns (and logs) counts only that
--     run's own: with migration 28 a run overlapping another counted the
--     other's reminders as its own (nothing was ever sent twice);
-- Unchanged: the functions' names, arguments and result types (pg_cron's commands
-- and the schedule of migration 28 stay as they are), who receives what,
-- preferences, dedupe keys, the 90-day rule, the sweeper's windows.
-- The run log holds no personal data (ids of matches / challenges / offers and
-- database error messages only). No app role can read or change it: no
-- grants, RLS on, no policies. The database owner reads it (SQL editor).

do $$
begin
  if to_regprocedure('public.notification_send_reminders()') is null
     or to_regprocedure('public.notification_cleanup()') is null
     or to_regprocedure('public.push_sweep()') is null then
    raise exception 'migration 29: migration 28 is required';
  end if;
  if to_regclass('public.notification_job_runs') is not null
     or exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public' and p.proname = 'notification_job_record') then
    raise exception 'migration 29: already applied (or a name is taken) — nothing changed';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. The run log
-- ---------------------------------------------------------------------------
create table public.notification_job_runs (
  id                    bigint generated always as identity primary key,
  job                   text not null check (job in ('reminders', 'cleanup', 'push_sweep')),
  status                text not null check (status in ('ok', 'partial', 'failed')),
  started_at            timestamptz not null,
  finished_at           timestamptz not null,
  processed             integer not null default 0 check (processed >= 0),
  created               integer not null default 0 check (created >= 0),
  removed_notifications integer not null default 0 check (removed_notifications >= 0),
  removed_announcements integer not null default 0 check (removed_announcements >= 0),
  removed_job_runs      integer not null default 0 check (removed_job_runs >= 0),
  errors                integer not null default 0 check (errors >= 0),
  first_error           text check (first_error is null or char_length(first_error) <= 300),
  failed_items          text[] not null default '{}' check (cardinality(failed_items) <= 20),
  constraint notification_job_runs_order check (finished_at >= started_at),
  -- ok ⇔ no error ⇔ no first error; partial and failed carry at least one.
  constraint notification_job_runs_outcome check ((status = 'ok') = (errors = 0)
                                                  and (errors = 0) = (first_error is null))
);
comment on table public.notification_job_runs is
  'One row per run of the scheduled notification jobs (migration 29). Database owner only; kept 30 days.';
create index notification_job_runs_started_at on public.notification_job_runs (started_at);

-- ---------------------------------------------------------------------------
-- 2. Writing a run (never fails the job that calls it)
-- ---------------------------------------------------------------------------
create or replace function public.notification_job_record(
  p_job text, p_started_at timestamptz, p_processed integer, p_created integer,
  p_removed_notifications integer, p_removed_announcements integer, p_removed_job_runs integer,
  p_errors text[], p_failed_items text[], p_failed boolean)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_errors integer := coalesce(cardinality(p_errors), 0);
begin
  insert into public.notification_job_runs (
    job, status, started_at, finished_at, processed, created,
    removed_notifications, removed_announcements, removed_job_runs,
    errors, first_error, failed_items)
  values (
    p_job,
    case when p_failed then 'failed' when v_errors > 0 then 'partial' else 'ok' end,
    p_started_at, greatest(clock_timestamp(), p_started_at),
    greatest(coalesce(p_processed, 0), 0), greatest(coalesce(p_created, 0), 0),
    greatest(coalesce(p_removed_notifications, 0), 0), greatest(coalesce(p_removed_announcements, 0), 0),
    greatest(coalesce(p_removed_job_runs, 0), 0),
    v_errors,
    case when v_errors > 0 then left(coalesce(p_errors[1], 'unknown error'), 300) end,
    coalesce((p_failed_items)[1:20], '{}'));
exception when others then
  raise warning 'notification job log: a % run was not recorded [% %]', p_job, sqlstate, sqlerrm;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. The reminders: each recipient group / challenge / offer on its own
-- ---------------------------------------------------------------------------
create or replace function public.notification_send_reminders()
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_started   timestamptz := clock_timestamp();
  v_before    integer;
  v_created   integer := 0;
  v_processed integer := 0;
  v_errors    text[] := '{}';
  v_failed    text[] := '{}';
  v_whole     boolean := false;
  v_match     public.matches;
  v_key       text;
  v_a         public.clubs;
  v_b         public.clubs;
  v_ch        record;
  v_x         record;
begin
  begin
    -- Only this run's own reminders are counted: notifications are stamped
    -- with their transaction's start (created_at defaults to now()), so a
    -- run overlapping this one (whose rows commit while this one waits on
    -- them) is not counted as sent by this one.
    v_before := (select count(*) from public.notifications n
                  where n.type in ('match_reminder', 'challenge_expiring', 'ownership_expiring')
                    and n.created_at = now());

    -- A confirmed match starting within 24 hours: both owners, then the
    -- selected players (an owner who is selected is told once).
    begin
      for v_match in
        select m.* from public.matches m
         where m.status = 'confirmed' and m.starts_at > now() and m.starts_at <= now() + interval '24 hours'
      loop
        v_processed := v_processed + 1;
        v_key := 'reminder:match:' || v_match.id || ':' || floor(extract(epoch from v_match.starts_at))::bigint;
        begin
          select * into strict v_a from public.clubs c where c.id = v_match.club_a_id;
          select * into strict v_b from public.clubs c where c.id = v_match.club_b_id;
        exception when others then
          v_errors := v_errors || ('match:' || v_match.id || ': ' || sqlstate || ' ' || sqlerrm);
          v_failed := v_failed || ('match:' || v_match.id);
          continue;
        end;
        begin
          perform public.notification_add(
                    v_a.owner_id, 'club_owner', 'match_reminder', v_key,
                    jsonb_build_object('club_name', v_a.name, 'opponent_name', v_b.name, 'starts_at', v_match.starts_at,
                                       'venue_name', v_match.venue_name, 'city', v_match.city),
                    v_a.id, v_match.id);
        exception when others then
          v_errors := v_errors || ('match:' || v_match.id || ':owner_a: ' || sqlstate || ' ' || sqlerrm);
          v_failed := v_failed || ('match:' || v_match.id || ':owner_a');
        end;
        begin
          perform public.notification_add(
                    v_b.owner_id, 'club_owner', 'match_reminder', v_key,
                    jsonb_build_object('club_name', v_b.name, 'opponent_name', v_a.name, 'starts_at', v_match.starts_at,
                                       'venue_name', v_match.venue_name, 'city', v_match.city),
                    v_b.id, v_match.id);
        exception when others then
          v_errors := v_errors || ('match:' || v_match.id || ':owner_b: ' || sqlstate || ' ' || sqlerrm);
          v_failed := v_failed || ('match:' || v_match.id || ':owner_b');
        end;
        begin
          perform public.notification_lineup_fanout(
                    v_match, 'match_reminder', v_key,
                    jsonb_build_object('starts_at', v_match.starts_at, 'venue_name', v_match.venue_name, 'city', v_match.city));
        exception when others then
          v_errors := v_errors || ('match:' || v_match.id || ':players: ' || sqlstate || ' ' || sqlerrm);
          v_failed := v_failed || ('match:' || v_match.id || ':players');
        end;
      end loop;
    exception when others then
      v_errors := v_errors || ('matches: ' || sqlstate || ' ' || sqlerrm);
      v_failed := v_failed || 'matches'::text;
    end;

    -- An unanswered challenge expiring within 24 hours: the challenged owner.
    begin
      for v_ch in
        select ch.id, ch.expires_at, ch.format, ch.custom_overs, ch.proposed_date, ch.venue_name,
               t.id as to_club_id, t.owner_id as to_owner_id, f.name as from_name
          from public.match_challenges ch
          join public.clubs t on t.id = ch.to_club_id
          join public.clubs f on f.id = ch.from_club_id
         where ch.status = 'pending' and ch.expires_at > now() and ch.expires_at <= now() + interval '24 hours'
      loop
        v_processed := v_processed + 1;
        begin
          perform public.notification_add(
                    v_ch.to_owner_id, 'club_owner', 'challenge_expiring', 'reminder:challenge:' || v_ch.id,
                    jsonb_build_object('opponent_name', v_ch.from_name, 'expires_at', v_ch.expires_at, 'format', v_ch.format,
                                       'custom_overs', v_ch.custom_overs, 'proposed_date', v_ch.proposed_date,
                                       'venue_name', v_ch.venue_name),
                    v_ch.to_club_id, null, v_ch.id);
        exception when others then
          v_errors := v_errors || ('challenge:' || v_ch.id || ': ' || sqlstate || ' ' || sqlerrm);
          v_failed := v_failed || ('challenge:' || v_ch.id);
        end;
      end loop;
    exception when others then
      v_errors := v_errors || ('challenges: ' || sqlstate || ' ' || sqlerrm);
      v_failed := v_failed || 'challenges'::text;
    end;

    -- An unanswered ownership offer expiring within 24 hours: the member.
    begin
      for v_x in
        select x.id, x.club_id, x.from_user_id, x.to_user_id, x.expires_at, c.name as club_name
          from public.club_ownership_transfers x
          join public.clubs c on c.id = x.club_id
         where x.status = 'pending' and x.expires_at > now() and x.expires_at <= now() + interval '24 hours'
      loop
        v_processed := v_processed + 1;
        begin
          perform public.notification_add(
                    v_x.to_user_id, 'player', 'ownership_expiring', 'reminder:ownership:' || v_x.id,
                    jsonb_build_object('club_name', v_x.club_name, 'person_name', public.notification_person_name(v_x.from_user_id),
                                       'expires_at', v_x.expires_at),
                    v_x.club_id, null, v_x.id, v_x.from_user_id);
        exception when others then
          v_errors := v_errors || ('offer:' || v_x.id || ': ' || sqlstate || ' ' || sqlerrm);
          v_failed := v_failed || ('offer:' || v_x.id);
        end;
      end loop;
    exception when others then
      v_errors := v_errors || ('offers: ' || sqlstate || ' ' || sqlerrm);
      v_failed := v_failed || 'offers'::text;
    end;

    v_created := (select count(*) from public.notifications n
                   where n.type in ('match_reminder', 'challenge_expiring', 'ownership_expiring')
                     and n.created_at = now()) - v_before;
  exception when others then
    -- Anything outside the sections: nothing of this run is kept.
    v_whole := true;
    v_created := 0;
    v_errors := v_errors || ('run: ' || sqlstate || ' ' || sqlerrm);
    v_failed := v_failed || 'run'::text;
  end;

  perform public.notification_job_record('reminders', v_started, v_processed, v_created, 0, 0, 0,
                                         v_errors, v_failed, v_whole);
  return v_created;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. The cleanup: three independent deletes; job runs kept 30 days
-- ---------------------------------------------------------------------------
create or replace function public.notification_cleanup()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_started       timestamptz := clock_timestamp();
  v_notifications integer := 0;
  v_announcements integer := 0;
  v_job_runs      integer := 0;
  v_errors        text[] := '{}';
  v_failed        text[] := '{}';
begin
  begin
    delete from public.notifications n
     where n.id in (select x.id from public.notifications x
                     where x.created_at < now() - interval '90 days'
                     order by x.created_at limit 10000);
    get diagnostics v_notifications = row_count;
  exception when others then
    v_notifications := 0;
    v_errors := v_errors || ('notifications: ' || sqlstate || ' ' || sqlerrm);
    v_failed := v_failed || 'notifications'::text;
  end;
  begin
    delete from public.club_announcements a
     where a.id in (select x.id from public.club_announcements x
                     where x.created_at < now() - interval '90 days'
                     order by x.created_at limit 10000);
    get diagnostics v_announcements = row_count;
  exception when others then
    v_announcements := 0;
    v_errors := v_errors || ('announcements: ' || sqlstate || ' ' || sqlerrm);
    v_failed := v_failed || 'announcements'::text;
  end;
  begin
    delete from public.notification_job_runs r
     where r.id in (select x.id from public.notification_job_runs x
                     where x.started_at < now() - interval '30 days'
                     order by x.started_at limit 10000);
    get diagnostics v_job_runs = row_count;
  exception when others then
    v_job_runs := 0;
    v_errors := v_errors || ('job_runs: ' || sqlstate || ' ' || sqlerrm);
    v_failed := v_failed || 'job_runs'::text;
  end;

  perform public.notification_job_record('cleanup', v_started, v_notifications + v_announcements + v_job_runs, 0,
                                         v_notifications, v_announcements, v_job_runs, v_errors, v_failed, false);
  return jsonb_build_object('notifications', v_notifications, 'announcements', v_announcements);
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. The push sweeper: a failure is recorded, not raised
-- ---------------------------------------------------------------------------
create or replace function public.push_sweep()
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_started timestamptz := clock_timestamp();
  v_waiting integer := 0;
  v_errors  text[] := '{}';
  v_failed  text[] := '{}';
  v_whole   boolean := false;
begin
  begin
    select count(*) into v_waiting
      from public.push_deliveries d
     where d.created_at > now() - interval '1 day'
       and ((d.status = 'pending' and d.created_at < now() - interval '2 minutes')
            or (d.status = 'sending' and d.claimed_at < now() - interval '5 minutes'));
    if v_waiting > 0 then
      perform public.push_wake();
    end if;
  exception when others then
    v_whole := true;
    v_errors := v_errors || ('sweep: ' || sqlstate || ' ' || sqlerrm);
    v_failed := v_failed || 'sweep'::text;
  end;

  perform public.notification_job_record('push_sweep', v_started, v_waiting, 0, 0, 0, 0, v_errors, v_failed, v_whole);
  return v_waiting;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Privileges: the jobs and the log are the database owner's alone
-- ---------------------------------------------------------------------------
revoke all on table public.notification_job_runs from public, anon, authenticated, service_role;
revoke all on sequence public.notification_job_runs_id_seq from public, anon, authenticated, service_role;
alter table public.notification_job_runs enable row level security;

revoke execute on function public.notification_job_record(text, timestamptz, integer, integer, integer, integer, integer, text[], text[], boolean)
  from public, anon, authenticated, service_role;
revoke execute on function public.notification_send_reminders() from public, anon, authenticated, service_role;
revoke execute on function public.notification_cleanup() from public, anon, authenticated, service_role;
revoke execute on function public.push_sweep() from public, anon, authenticated, service_role;
