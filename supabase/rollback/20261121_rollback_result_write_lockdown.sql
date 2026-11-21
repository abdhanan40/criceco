-- CricEco · ROLLBACK of migration 24 (result write lockdown and the scorer
-- foundation).
--
-- NOT APPLIED. Run only with explicit approval, after a backup, inside
--   begin; set local lock_timeout = '5s'; <this file> commit;
--
-- WHAT IT KEEPS — on purpose, for security: the owner write functions
-- (submit / confirm / dispute_match_result, submit_match_result_with_scorecard)
-- and match_player_pool() stay DROPPED, and service_role stays without direct
-- write rights on the result tables. A rollback never reopens a way to write
-- official results; after it, results are frozen (nothing can write them).
--
-- WHAT IT REMOVES: the scorer clients, official assignments, the two audit
-- logs, the official write functions and the audit triggers; match_results
-- gets its migration-20 columns back; the read rules and match_result() /
-- match_scorecard() return to migrations 20–21.
--
-- REFUSES while any result exists (official results can't be represented in
-- the old columns — removing them is a separate, approved, destructive step),
-- and while the audit logs hold records, unless they were exported first and
-- the session says so:   set local criceco.rollback_audit_exported = 'yes';
-- (export: supabase db dump --data-only -t public.result_submission_log
-- -t public.result_change_log). Roll back 24 BEFORE 23 → 20.

do $$
begin
  if to_regclass('public.scorer_clients') is null and to_regclass('public.result_submission_log') is null then
    raise exception 'rollback 24: migration 24 is not applied — nothing changed';
  end if;
  if exists (select 1 from public.match_results) then
    raise exception 'rollback 24: official results exist — refusing (they can''t be kept in the old columns)';
  end if;
  if (exists (select 1 from public.result_submission_log) or exists (select 1 from public.result_change_log))
     and coalesce(current_setting('criceco.rollback_audit_exported', true), '') <> 'yes' then
    raise exception 'rollback 24: the audit logs hold records — export them, then set criceco.rollback_audit_exported = ''yes''';
  end if;
end $$;

-- The official write path and the audit triggers.
drop function if exists public.ingest_official_result(uuid, text, uuid, jsonb, text);
drop function if exists public.verify_official_result(uuid, text, uuid, integer, boolean, text, text);
drop function if exists public.correct_official_result(uuid, text, uuid, integer, text, jsonb, text);
drop function if exists public.official_result_submit(text, uuid, text, uuid, jsonb, integer, text, text);
drop function if exists public.official_result_store(uuid, uuid, jsonb, integer, text, bigint);
drop function if exists public.official_result_decide(uuid, uuid, integer, boolean, text, boolean);
drop function if exists public.assign_match_official(uuid, uuid, text);
drop function if exists public.unassign_match_official(uuid, uuid, text);
drop function if exists public.official_match_roster(uuid, uuid);
drop trigger if exists match_results_audit on public.match_results;
drop trigger if exists match_innings_audit on public.match_innings;
drop trigger if exists match_batting_audit on public.match_batting;
drop trigger if exists match_bowling_audit on public.match_bowling;

-- match_results: back to migration 20's columns (the table is empty).
drop index if exists public.match_results_scorer_client_idx;
drop index if exists public.match_results_decided_by_client_idx;
alter table public.match_results
  drop column source,
  drop column scorer_client_id,
  drop column submission_id,
  drop column decided_by_client_id,
  drop column decision_note,
  drop column corrects_version,
  drop column correction_reason,
  drop constraint match_results_status_check,
  add constraint match_results_status_check
    check (status in ('submitted', 'confirmed', 'disputed', 'superseded')),
  add column submitted_by_club_id uuid not null,
  add column submitted_by uuid
    constraint match_results_submitted_by_fkey references public.profiles (id) on delete set null,
  add column decided_by_club_id uuid,
  add column decided_by uuid
    constraint match_results_decided_by_fkey references public.profiles (id) on delete set null,
  add column dispute_reason text
    constraint match_results_dispute_reason_check
    check (dispute_reason is null or char_length(btrim(dispute_reason)) between 1 and 300),
  add constraint match_results_dispute_reason_only_when_disputed
    check ((status = 'disputed') = (dispute_reason is not null));
create index match_results_submitted_by_idx on public.match_results (submitted_by) where submitted_by is not null;
create index match_results_decided_by_idx on public.match_results (decided_by) where decided_by is not null;

drop table public.match_officials;
drop table public.result_submission_log;
drop table public.result_change_log;
drop table public.scorer_clients;
drop function if exists public.result_tables_audit();
drop function if exists public.audit_log_append_only();

-- Migration 20's comment, version guard and read rules (verbatim).
comment on table public.match_results is
  'Versions of a match result (M2). Written only by submit / confirm / dispute_match_result (migration 20).';

drop trigger match_results_guard_update on public.match_results;
create or replace function public.match_results_guard_update()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_fixed constant text[] := array['status', 'decided_by_club_id', 'decided_by', 'decided_at', 'dispute_reason',
                                   'submitted_by', 'player_of_match_member_id', 'player_of_match_name',
                                   'player_of_match_deleted'];
begin
  if (to_jsonb(new) - v_fixed) is distinct from (to_jsonb(old) - v_fixed) then
    raise exception 'result: invalid transition' using errcode = '23514';
  end if;
  -- People leaving: only ever towards null / "deleted".
  if (new.submitted_by is not null and new.submitted_by is distinct from old.submitted_by)
     or (new.decided_by is not null and old.decided_by is not null and new.decided_by is distinct from old.decided_by)
     or (new.player_of_match_member_id is not null
         and new.player_of_match_member_id is distinct from old.player_of_match_member_id)
     or (new.player_of_match_name is not null and new.player_of_match_name is distinct from old.player_of_match_name)
     or (old.player_of_match_deleted and not new.player_of_match_deleted) then
    raise exception 'result: invalid transition' using errcode = '23514';
  end if;
  if new.status is distinct from old.status then
    if not ((old.status = 'submitted' and new.status in ('confirmed', 'disputed', 'superseded'))
            or (old.status = 'confirmed' and new.status = 'superseded')) then
      raise exception 'result: invalid transition' using errcode = '23514';
    end if;
  elsif (new.decided_by_club_id, new.decided_at, new.dispute_reason)
        is distinct from (old.decided_by_club_id, old.decided_at, old.dispute_reason)
        or (new.decided_by is distinct from old.decided_by and new.decided_by is not null) then
    raise exception 'result: invalid transition' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger match_results_guard_update
  before update on public.match_results
  for each row execute function public.match_results_guard_update();

drop policy "match_results: select clubs of the match" on public.match_results;
drop policy "match_innings: select with its result" on public.match_innings;
create policy "match_results: select clubs of the match"
  on public.match_results for select to authenticated
  using (exists (select 1 from public.matches m
                  where m.id = match_results.match_id
                    and (public.is_club_owner(m.club_a_id) or public.is_club_owner(m.club_b_id)
                         or (match_results.status = 'confirmed'
                             and (public.is_active_club_member(m.club_a_id) or public.is_active_club_member(m.club_b_id))))));

create policy "match_innings: select with its result"
  on public.match_innings for select to authenticated
  using (exists (select 1 from public.match_results r
                   join public.matches m on m.id = r.match_id
                  where r.match_id = match_innings.match_id and r.version = match_innings.version
                    and (public.is_club_owner(m.club_a_id) or public.is_club_owner(m.club_b_id)
                         or (r.status = 'confirmed'
                             and (public.is_active_club_member(m.club_a_id) or public.is_active_club_member(m.club_b_id))))));

-- Migration 21's card read rules (verbatim).
drop policy "match_batting: select with its result" on public.match_batting;
drop policy "match_bowling: select with its result" on public.match_bowling;
create policy "match_batting: select with its result"
  on public.match_batting for select to authenticated
  using (exists (select 1 from public.match_results r
                   join public.matches m on m.id = r.match_id
                  where r.match_id = match_batting.match_id and r.version = match_batting.version
                    and (public.is_club_owner(m.club_a_id) or public.is_club_owner(m.club_b_id)
                         or (r.status = 'confirmed'
                             and (public.is_active_club_member(m.club_a_id) or public.is_active_club_member(m.club_b_id))))));

create policy "match_bowling: select with its result"
  on public.match_bowling for select to authenticated
  using (exists (select 1 from public.match_results r
                   join public.matches m on m.id = r.match_id
                  where r.match_id = match_bowling.match_id and r.version = match_bowling.version
                    and (public.is_club_owner(m.club_a_id) or public.is_club_owner(m.club_b_id)
                         or (r.status = 'confirmed'
                             and (public.is_active_club_member(m.club_a_id) or public.is_active_club_member(m.club_b_id))))));

-- match_result() and match_scorecard() as in migrations 20–21 (verbatim).
drop function public.match_result(uuid);
create or replace function public.match_result(p_match_id uuid)
returns table (
  version               integer,
  status                text,
  outcome               text,
  margin_runs           integer,
  margin_wickets        smallint,
  innings_victory       boolean,
  summary               text,
  player_of_match_member_id uuid,
  player_of_match_name  text,
  player_of_match_deleted boolean,
  submitted_by_me       boolean,
  submitted_at          timestamptz,
  decided_at            timestamptz,
  dispute_reason        text,
  club_a_id             uuid,
  club_b_id             uuid,
  innings               jsonb
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_match public.matches;
  v_owner boolean;
  v_my    uuid;
begin
  if v_uid is null then
    raise exception 'result: not authenticated' using errcode = '42501';
  end if;
  select * into v_match from public.matches m where m.id = p_match_id;
  if not found then
    raise exception 'result: not found' using errcode = 'P0002';
  end if;
  v_owner := public.is_club_owner(v_match.club_a_id) or public.is_club_owner(v_match.club_b_id);
  if not v_owner and not (public.is_active_club_member(v_match.club_a_id) or public.is_active_club_member(v_match.club_b_id)) then
    raise exception 'result: not allowed' using errcode = '42501';
  end if;
  select c.id into v_my from public.clubs c where c.id in (v_match.club_a_id, v_match.club_b_id) and c.owner_id = v_uid;
  return query
    select r.version, r.status, r.outcome, r.margin_runs, r.margin_wickets, r.innings_victory,
           public.match_result_summary(r.match_id, r.version),
           r.player_of_match_member_id, r.player_of_match_name, r.player_of_match_deleted,
           v_my is not null and r.submitted_by_club_id = v_my,
           r.submitted_at, r.decided_at, r.dispute_reason, v_match.club_a_id, v_match.club_b_id,
           coalesce((select jsonb_agg(jsonb_build_object(
                       'innings_no', i.innings_no, 'batting_club_id', i.batting_club_id,
                       'bowling_club_id', i.bowling_club_id, 'runs', i.runs, 'wickets', i.wickets,
                       'balls', i.balls, 'byes', i.byes, 'leg_byes', i.leg_byes, 'wides', i.wides,
                       'no_balls', i.no_balls, 'penalty', i.penalty, 'declared', i.declared)
                       order by i.innings_no)
                       from public.match_innings i where i.match_id = r.match_id and i.version = r.version),
                    '[]'::jsonb)
      from public.match_results r
     where r.match_id = p_match_id and (v_owner or r.status = 'confirmed')
     order by r.version desc;
end;
$$;

revoke execute on function public.match_result(uuid) from public, anon;
grant execute on function public.match_result(uuid) to authenticated;

create or replace function public.match_scorecard(p_match_id uuid, p_version integer default null)
returns table (
  version          integer,
  innings_no       smallint,
  batting_club_id  uuid,
  bowling_club_id  uuid,
  batting          jsonb,
  bowling          jsonb
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_match   public.matches;
  v_owner   boolean;
  v_version integer;
begin
  if v_uid is null then
    raise exception 'result: not authenticated' using errcode = '42501';
  end if;
  select * into v_match from public.matches m where m.id = p_match_id;
  if not found then
    raise exception 'result: not found' using errcode = 'P0002';
  end if;
  v_owner := public.is_club_owner(v_match.club_a_id) or public.is_club_owner(v_match.club_b_id);
  if not v_owner and not (public.is_active_club_member(v_match.club_a_id) or public.is_active_club_member(v_match.club_b_id)) then
    raise exception 'result: not allowed' using errcode = '42501';
  end if;
  select r.version into v_version
    from public.match_results r
   where r.match_id = p_match_id
     and case when p_version is null then r.status = 'confirmed' else r.version = p_version end
     and (v_owner or r.status = 'confirmed');
  if v_version is null then
    return;
  end if;
  return query
    select v_version, i.innings_no, i.batting_club_id, i.bowling_club_id,
           coalesce((select jsonb_agg(jsonb_build_object(
                       'position', b.position, 'member_id', b.member_id, 'name', b.player_name,
                       'deleted', b.player_deleted, 'runs', b.runs, 'balls', b.balls, 'fours', b.fours,
                       'sixes', b.sixes, 'dismissal', b.dismissal,
                       'dismissal_text', public.match_dismissal_text(
                          b.dismissal, coalesce(w.player_name, 'Deleted player'),
                          case when b.fielder_member_id is null and not b.fielder_deleted then null
                               else coalesce(b.fielder_name, 'Deleted player') end,
                          b.fielder_substitute,
                          b.fielder_member_id is not null and b.fielder_member_id = w.member_id),
                       'bowler_member_id', w.member_id, 'bowler_name', w.player_name,
                       'fielder_member_id', b.fielder_member_id, 'fielder_name', b.fielder_name,
                       'fielder_deleted', b.fielder_deleted, 'fielder_substitute', b.fielder_substitute,
                       'direct_hit', b.direct_hit)
                       order by b.position)
                       from public.match_batting b
                       left join public.match_bowling w
                         on w.match_id = b.match_id and w.version = b.version and w.innings_no = b.innings_no
                        and w.bowler_no = b.bowler_no
                      where b.match_id = i.match_id and b.version = i.version and b.innings_no = i.innings_no),
                    '[]'::jsonb),
           coalesce((select jsonb_agg(jsonb_build_object(
                       'bowler_no', w.bowler_no, 'member_id', w.member_id, 'name', w.player_name,
                       'deleted', w.player_deleted, 'balls', w.balls, 'maidens', w.maidens, 'runs', w.runs,
                       'wickets', w.wickets, 'wides', w.wides, 'no_balls', w.no_balls)
                       order by w.bowler_no)
                       from public.match_bowling w
                      where w.match_id = i.match_id and w.version = i.version and w.innings_no = i.innings_no),
                    '[]'::jsonb)
      from public.match_innings i
     where i.match_id = p_match_id and i.version = v_version
       and exists (select 1 from public.match_batting b
                    where b.match_id = i.match_id and b.version = i.version and b.innings_no = i.innings_no)
     order by i.innings_no;
end;
$$;

notify pgrst, 'reload schema';
