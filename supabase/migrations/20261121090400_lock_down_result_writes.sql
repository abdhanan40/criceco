-- CricEco · migration 24 · official results: write lockdown and the trusted
-- scorer foundation (M2 security)
--
-- NOT APPLIED. Requires migrations 20–23. In production it is applied in the
-- SAME transaction as 20–23 (approved D1), so owners can never write a
-- result:   begin; set local lock_timeout = '5s'; <20> <21> <22> <23> <this> commit;
-- Rollback: supabase/rollback/20261121_rollback_result_write_lockdown.sql (it
-- keeps the lockdown; see there). Read-only check: supabase/tests/24_result_write_lockdown_postcheck.sql.
-- Local tests: supabase/tests/local/19_result_write_lockdown_local_check.sql (+ 19b_…sh).
-- Design: docs/MATCH_RESULTS_BACKEND.md ("M2 security").
--
-- Product decision (2026-11-21): official results and statistics come ONLY
-- from a trusted, authorized Scorer/Umpire system. Players and club owners
-- can never submit, edit, confirm, dispute or otherwise change them through
-- CricEco. Approved D1–D8:
--   D1  this migration, applied together with 20–23;
--   D2  two-step verification: a scorer submits a provisional version, a
--       DIFFERENT assigned official (verifier) approves or rejects it;
--       per-client single-step trust exists but is off by default;
--   D3  no disputes in CricEco: "disputed" is replaced by "rejected" (by an
--       official, with a reason);
--   D4  app users (owners included) see the OFFICIAL (confirmed) version only;
--   D5  match_player_pool() leaves the app: officials get a server-only roster;
--   D6  service_role cannot write the result tables directly — only through
--       the functions below;
--   D7  the database foundation now (clients, assignments, append-only audit
--       logs, ingestion / verification / correction functions); the Edge
--       Function that verifies the scorer's signed requests comes later;
--   D8  the app's write code is removed (Flutter, same phase).
--
-- Write path (only one):
--   Scorer system → Edge Function (later: verifies the signature, timestamp,
--   nonce, rate limit; holds the service key) → ingest_official_result /
--   verify_official_result / correct_official_result (SECURITY DEFINER,
--   EXECUTE: service_role only) → the result tables.
-- Every call is recorded in result_submission_log (append-only; accepted and
-- rejected alike, idempotent per client key); every row change of the result
-- tables and the official assignments in result_change_log (append-only,
-- with the database role and session user — postgres included).
-- Unchanged: statistics (22), my_matches (23), club_results / club_record,
-- account-deletion anonymization ("Deleted player").

do $$
begin
  if to_regclass('public.match_results') is null or to_regclass('public.match_batting') is null
     or to_regprocedure('public.player_stats(uuid)') is null or to_regprocedure('public.my_matches()') is null then
    raise exception 'migration 24: migrations 20–23 are required';
  end if;
  if to_regclass('public.scorer_clients') is not null or to_regclass('public.result_submission_log') is not null
     or exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public'
                   and p.proname in ('ingest_official_result', 'verify_official_result', 'correct_official_result',
                                     'assign_match_official', 'unassign_match_official', 'official_match_roster',
                                     'official_result_store', 'official_result_submit', 'official_result_decide',
                                     'result_tables_audit', 'audit_log_append_only')) then
    raise exception 'migration 24: already applied (or a name is taken) — nothing changed';
  end if;
  -- Fresh databases only: owner-entered rows can't become official.
  if exists (select 1 from public.match_results) then
    raise exception 'migration 24: match_results has rows — refusing (owner-entered results can''t become official; remove them first, with approval)';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. No owner / player writes (D1, D5)
-- ---------------------------------------------------------------------------
drop function if exists public.submit_match_result_with_scorecard(uuid, text, jsonb, uuid);
drop function if exists public.submit_match_result(uuid, text, jsonb, uuid);
drop function if exists public.confirm_match_result(uuid, integer);
drop function if exists public.dispute_match_result(uuid, integer, text);
drop function if exists public.match_player_pool(uuid);

-- ---------------------------------------------------------------------------
-- 2. No direct writes, even with the service key (D6)
-- ---------------------------------------------------------------------------
revoke insert, update, delete, truncate, references, trigger
  on table public.match_results, public.match_innings, public.match_batting, public.match_bowling
  from service_role;
-- Internal helpers: nobody calls them directly.
revoke execute on function public.match_format_max_balls(text, integer) from service_role;
revoke execute on function public.match_result_summary(uuid, integer) from service_role;
revoke execute on function public.match_results_guard_update() from service_role;
revoke execute on function public.match_innings_guard() from service_role;
revoke execute on function public.club_members_forget_match_results() from service_role;
revoke execute on function public.match_scorecards_guard() from service_role;
revoke execute on function public.club_members_forget_match_scorecards() from service_role;
revoke execute on function public.match_bowler_max_balls(text, integer) from service_role;
revoke execute on function public.match_dismissal_text(text, text, text, boolean, boolean) from service_role;
revoke execute on function public.match_club_player_pool(uuid, uuid) from service_role;
revoke execute on function public.member_stats(uuid[]) from service_role;
revoke execute on function public.can_view_player_stats(uuid) from service_role;

-- ---------------------------------------------------------------------------
-- 3. Trusted clients, official assignments, audit logs (D7)
-- ---------------------------------------------------------------------------
-- A registered Scorer/Umpire integration. key_id names the signing key the
-- Edge Function holds in its secrets — the secret itself is never stored.
-- Managed by an administrator (SQL), never by the app.
create table public.scorer_clients (
  id                  uuid primary key default gen_random_uuid(),
  name                text not null
                      constraint scorer_clients_name_check check (char_length(btrim(name)) between 1 and 100)
                      constraint scorer_clients_name_key unique,
  key_id              text not null
                      constraint scorer_clients_key_id_check check (key_id ~ '^[A-Za-z0-9._:-]{8,100}$')
                      constraint scorer_clients_key_id_key unique,
  status              text not null default 'active'
                      constraint scorer_clients_status_check check (status in ('active', 'revoked')),
  -- D2: a client may confirm its own submissions only when trusted for it.
  single_step_trusted boolean not null default false,
  created_at          timestamptz not null default now(),
  revoked_at          timestamptz,
  constraint scorer_clients_revoked_consistency check ((status = 'revoked') = (revoked_at is not null))
);

comment on table public.scorer_clients is
  'Trusted Scorer/Umpire integrations (M2 security). No app access; managed by administrators.';

-- Which client may score (submit / correct) or verify (approve / reject) a match.
create table public.match_officials (
  match_id    uuid not null constraint match_officials_match_id_fkey references public.matches (id) on delete cascade,
  client_id   uuid not null constraint match_officials_client_id_fkey references public.scorer_clients (id) on delete restrict,
  role        text not null constraint match_officials_role_check check (role in ('scorer', 'verifier')),
  assigned_at timestamptz not null default now(),
  constraint match_officials_pkey primary key (match_id, client_id, role)
);

create index match_officials_client_idx on public.match_officials (client_id);

comment on table public.match_officials is
  'Officials (scorer clients) assigned to a match (M2 security). Written only by assign / unassign_match_official.';

-- Every call of the write functions, accepted or rejected — append-only.
-- No foreign keys: a record outlives its match, and an unknown client's
-- attempt is recorded too.
create sequence public.result_submission_log_id_seq;
create table public.result_submission_log (
  id              bigint primary key default nextval('public.result_submission_log_id_seq'),
  received_at     timestamptz not null default now(),
  client_id       uuid,
  action          text not null constraint result_submission_log_action_check check (action in ('ingest', 'verify', 'correct')),
  match_id        uuid,
  idempotency_key text not null constraint result_submission_log_key_check check (char_length(idempotency_key) between 1 and 100),
  payload         jsonb not null,
  payload_sha256  text not null constraint result_submission_log_sha_check check (payload_sha256 ~ '^[0-9a-f]{64}$'),
  request_id      text constraint result_submission_log_request_check check (request_id is null or char_length(request_id) between 1 and 100),
  outcome         text not null constraint result_submission_log_outcome_check check (outcome in ('accepted', 'rejected')),
  reason          text,
  version         integer,
  db_role         text not null default coalesce(nullif(current_setting('role', true), 'none'), current_user),
  constraint result_submission_log_client_key unique (client_id, idempotency_key),
  constraint result_submission_log_reason_when_rejected check ((outcome = 'rejected') = (reason is not null))
);
alter sequence public.result_submission_log_id_seq owned by public.result_submission_log.id;

comment on table public.result_submission_log is
  'Append-only record of every official result write call (M2 security).';

-- Every row change of the result tables and the assignments — append-only.
create table public.result_change_log (
  id          bigint generated always as identity primary key,
  changed_at  timestamptz not null default now(),
  table_name  text not null,
  operation   text not null constraint result_change_log_operation_check check (operation in ('INSERT', 'UPDATE', 'DELETE')),
  match_id    uuid,
  version     integer,
  detail      jsonb not null default '{}'::jsonb,
  db_role     text not null default coalesce(nullif(current_setting('role', true), 'none'), current_user),
  session_role text not null default session_user,
  auth_uid    uuid,
  txid        bigint not null default txid_current()
);

create index result_change_log_match_idx on public.result_change_log (match_id);

comment on table public.result_change_log is
  'Append-only audit of every change to official results and assignments (M2 security).';

-- ---------------------------------------------------------------------------
-- 4. match_results: official provenance; no owner / dispute fields (D2, D3)
-- ---------------------------------------------------------------------------
alter table public.match_results
  drop column submitted_by_club_id,
  drop column submitted_by,
  drop column decided_by_club_id,
  drop column decided_by,
  drop column dispute_reason,
  drop constraint match_results_status_check,
  add constraint match_results_status_check check (status in ('submitted', 'confirmed', 'rejected', 'superseded')),
  add column source text not null default 'official_scorer'
    constraint match_results_source_check check (source = 'official_scorer'),
  add column scorer_client_id uuid not null
    constraint match_results_scorer_client_id_fkey references public.scorer_clients (id) on delete restrict,
  add column submission_id bigint not null
    constraint match_results_submission_id_key unique
    constraint match_results_submission_id_fkey references public.result_submission_log (id)
      deferrable initially deferred,
  add column decided_by_client_id uuid
    constraint match_results_decided_by_client_id_fkey references public.scorer_clients (id) on delete restrict,
  add column decision_note text
    constraint match_results_decision_note_check check (decision_note is null or char_length(decision_note) between 1 and 300),
  add column corrects_version integer
    constraint match_results_corrects_version_check check (corrects_version is null or corrects_version >= 1),
  add column correction_reason text
    constraint match_results_correction_reason_check
    check (correction_reason is null or char_length(correction_reason) between 1 and 300),
  add constraint match_results_decided_by_when_decided check ((decided_at is null) = (decided_by_client_id is null)),
  add constraint match_results_note_only_when_rejected check ((status = 'rejected') = (decision_note is not null)),
  add constraint match_results_correction_complete check ((corrects_version is null) = (correction_reason is null));

create index match_results_scorer_client_idx on public.match_results (scorer_client_id);
create index match_results_decided_by_client_idx on public.match_results (decided_by_client_id)
  where decided_by_client_id is not null;

comment on table public.match_results is
  'Versions of a match''s OFFICIAL result (M2). Written only by the scorer functions (migration 24).';

-- A version is written once, as provisional, and never changes — only its
-- status moves on, once:
--   submitted → confirmed | rejected | superseded (with who / when),
--   confirmed → superseded (keeps who confirmed it),
-- plus account deletion dropping the Player of the Match ("Deleted player").
create or replace function public.match_results_guard_update()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_fixed constant text[] := array['status', 'decided_at', 'decided_by_client_id', 'decision_note',
                                   'player_of_match_member_id', 'player_of_match_name', 'player_of_match_deleted'];
begin
  if tg_op = 'INSERT' then
    if new.status <> 'submitted' or new.decided_at is not null then
      raise exception 'result: invalid transition' using errcode = '23514';
    end if;
    return new;
  end if;
  if (to_jsonb(new) - v_fixed) is distinct from (to_jsonb(old) - v_fixed) then
    raise exception 'result: invalid transition' using errcode = '23514';
  end if;
  if (new.player_of_match_member_id is not null
      and new.player_of_match_member_id is distinct from old.player_of_match_member_id)
     or (new.player_of_match_name is not null and new.player_of_match_name is distinct from old.player_of_match_name)
     or (old.player_of_match_deleted and not new.player_of_match_deleted) then
    raise exception 'result: invalid transition' using errcode = '23514';
  end if;
  if new.status is distinct from old.status then
    if old.status = 'submitted' and new.status in ('confirmed', 'rejected', 'superseded') then
      if new.decided_at is null or new.decided_by_client_id is null then
        raise exception 'result: invalid transition' using errcode = '23514';
      end if;
    elsif old.status = 'confirmed' and new.status = 'superseded' then
      if (new.decided_at, new.decided_by_client_id, new.decision_note)
         is distinct from (old.decided_at, old.decided_by_client_id, old.decision_note) then
        raise exception 'result: invalid transition' using errcode = '23514';
      end if;
    else
      raise exception 'result: invalid transition' using errcode = '23514';
    end if;
  elsif (new.decided_at, new.decided_by_client_id, new.decision_note)
        is distinct from (old.decided_at, old.decided_by_client_id, old.decision_note) then
    raise exception 'result: invalid transition' using errcode = '23514';
  end if;
  return new;
end;
$$;

drop trigger match_results_guard_update on public.match_results;
create trigger match_results_guard_update
  before insert or update on public.match_results
  for each row execute function public.match_results_guard_update();

-- ---------------------------------------------------------------------------
-- 5. Audit triggers (append-only logs; every result-table change recorded)
-- ---------------------------------------------------------------------------
create or replace function public.audit_log_append_only()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'audit: append only' using errcode = '42501';
end;
$$;

create trigger result_submission_log_append_only
  before update or delete on public.result_submission_log
  for each row execute function public.audit_log_append_only();
create trigger result_submission_log_no_truncate
  before truncate on public.result_submission_log
  for each statement execute function public.audit_log_append_only();
create trigger result_change_log_append_only
  before update or delete on public.result_change_log
  for each row execute function public.audit_log_append_only();
create trigger result_change_log_no_truncate
  before truncate on public.result_change_log
  for each statement execute function public.audit_log_append_only();

create or replace function public.result_tables_audit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  r   jsonb := to_jsonb(coalesce(new, old));
  v_detail jsonb := '{}'::jsonb;
begin
  if tg_table_name = 'match_results' then
    v_detail := jsonb_build_object('status', r ->> 'status')
                || case when tg_op = 'UPDATE' then jsonb_build_object('old_status', to_jsonb(old) ->> 'status') else '{}'::jsonb end;
  elsif tg_table_name = 'match_officials' then
    v_detail := jsonb_build_object('client_id', r ->> 'client_id', 'role', r ->> 'role');
  else
    v_detail := jsonb_strip_nulls(jsonb_build_object('innings_no', r -> 'innings_no', 'position', r -> 'position',
                                                     'bowler_no', r -> 'bowler_no'));
  end if;
  insert into public.result_change_log (table_name, operation, match_id, version, detail, auth_uid)
  values (tg_table_name, tg_op, (r ->> 'match_id')::uuid, (r ->> 'version')::int, v_detail, auth.uid());
  return null;
end;
$$;

create trigger match_results_audit after insert or update or delete on public.match_results
  for each row execute function public.result_tables_audit();
create trigger match_innings_audit after insert or update or delete on public.match_innings
  for each row execute function public.result_tables_audit();
create trigger match_batting_audit after insert or update or delete on public.match_batting
  for each row execute function public.result_tables_audit();
create trigger match_bowling_audit after insert or update or delete on public.match_bowling
  for each row execute function public.result_tables_audit();
create trigger match_officials_audit after insert or update or delete on public.match_officials
  for each row execute function public.result_tables_audit();

-- ---------------------------------------------------------------------------
-- 6. Read access: the official version only, for every app user (D4)
-- ---------------------------------------------------------------------------
drop policy "match_results: select clubs of the match" on public.match_results;
create policy "match_results: select clubs of the match"
  on public.match_results for select to authenticated
  using (match_results.status = 'confirmed'
         and exists (select 1 from public.matches m
                      where m.id = match_results.match_id
                        and (public.is_club_owner(m.club_a_id) or public.is_club_owner(m.club_b_id)
                             or public.is_active_club_member(m.club_a_id) or public.is_active_club_member(m.club_b_id))));

drop policy "match_innings: select with its result" on public.match_innings;
create policy "match_innings: select with its result"
  on public.match_innings for select to authenticated
  using (exists (select 1 from public.match_results r
                   join public.matches m on m.id = r.match_id
                  where r.match_id = match_innings.match_id and r.version = match_innings.version
                    and r.status = 'confirmed'
                    and (public.is_club_owner(m.club_a_id) or public.is_club_owner(m.club_b_id)
                         or public.is_active_club_member(m.club_a_id) or public.is_active_club_member(m.club_b_id))));

drop policy "match_batting: select with its result" on public.match_batting;
create policy "match_batting: select with its result"
  on public.match_batting for select to authenticated
  using (exists (select 1 from public.match_results r
                   join public.matches m on m.id = r.match_id
                  where r.match_id = match_batting.match_id and r.version = match_batting.version
                    and r.status = 'confirmed'
                    and (public.is_club_owner(m.club_a_id) or public.is_club_owner(m.club_b_id)
                         or public.is_active_club_member(m.club_a_id) or public.is_active_club_member(m.club_b_id))));

drop policy "match_bowling: select with its result" on public.match_bowling;
create policy "match_bowling: select with its result"
  on public.match_bowling for select to authenticated
  using (exists (select 1 from public.match_results r
                   join public.matches m on m.id = r.match_id
                  where r.match_id = match_bowling.match_id and r.version = match_bowling.version
                    and r.status = 'confirmed'
                    and (public.is_club_owner(m.club_a_id) or public.is_club_owner(m.club_b_id)
                         or public.is_active_club_member(m.club_a_id) or public.is_active_club_member(m.club_b_id))));

-- The official result of a match (at most one row), for the two clubs'
-- owners and active members.
drop function public.match_result(uuid);
create function public.match_result(p_match_id uuid)
returns table (
  version                   integer,
  status                    text,
  outcome                   text,
  margin_runs               integer,
  margin_wickets            smallint,
  innings_victory           boolean,
  summary                   text,
  player_of_match_member_id uuid,
  player_of_match_name      text,
  player_of_match_deleted   boolean,
  submitted_at              timestamptz,
  decided_at                timestamptz,
  club_a_id                 uuid,
  club_b_id                 uuid,
  innings                   jsonb
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_match public.matches;
begin
  if auth.uid() is null then
    raise exception 'result: not authenticated' using errcode = '42501';
  end if;
  select * into v_match from public.matches m where m.id = p_match_id;
  if not found then
    raise exception 'result: not found' using errcode = 'P0002';
  end if;
  if not (public.is_club_owner(v_match.club_a_id) or public.is_club_owner(v_match.club_b_id)
          or public.is_active_club_member(v_match.club_a_id) or public.is_active_club_member(v_match.club_b_id)) then
    raise exception 'result: not allowed' using errcode = '42501';
  end if;
  return query
    select r.version, r.status, r.outcome, r.margin_runs, r.margin_wickets, r.innings_victory,
           public.match_result_summary(r.match_id, r.version),
           r.player_of_match_member_id, r.player_of_match_name, r.player_of_match_deleted,
           r.submitted_at, r.decided_at, v_match.club_a_id, v_match.club_b_id,
           coalesce((select jsonb_agg(jsonb_build_object(
                       'innings_no', i.innings_no, 'batting_club_id', i.batting_club_id,
                       'bowling_club_id', i.bowling_club_id, 'runs', i.runs, 'wickets', i.wickets,
                       'balls', i.balls, 'byes', i.byes, 'leg_byes', i.leg_byes, 'wides', i.wides,
                       'no_balls', i.no_balls, 'penalty', i.penalty, 'declared', i.declared)
                       order by i.innings_no)
                       from public.match_innings i where i.match_id = r.match_id and i.version = r.version),
                    '[]'::jsonb)
      from public.match_results r
     where r.match_id = p_match_id and r.status = 'confirmed';
end;
$$;

revoke execute on function public.match_result(uuid) from public, anon;
grant execute on function public.match_result(uuid) to authenticated;

-- The official scorecard (the confirmed version; [p_version], when given,
-- must be it), innings by innings.
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
  v_match   public.matches;
  v_version integer;
begin
  if auth.uid() is null then
    raise exception 'result: not authenticated' using errcode = '42501';
  end if;
  select * into v_match from public.matches m where m.id = p_match_id;
  if not found then
    raise exception 'result: not found' using errcode = 'P0002';
  end if;
  if not (public.is_club_owner(v_match.club_a_id) or public.is_club_owner(v_match.club_b_id)
          or public.is_active_club_member(v_match.club_a_id) or public.is_active_club_member(v_match.club_b_id)) then
    raise exception 'result: not allowed' using errcode = '42501';
  end if;
  select r.version into v_version
    from public.match_results r
   where r.match_id = p_match_id and r.status = 'confirmed' and (p_version is null or r.version = p_version);
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

-- ---------------------------------------------------------------------------
-- 7. The official write path (EXECUTE: service_role only)
-- ---------------------------------------------------------------------------
-- Errors inside (prefix "result:"): not found · match not played · invalid
-- · invalid payload · invalid innings · inconsistent result · invalid player
-- · invalid scorecard · invalid reason · correction required · nothing to
-- correct · version changed · not pending · same official · client not
-- allowed · not assigned · idempotency conflict. The public functions turn
-- them into a 'rejected' outcome (recorded) instead of an error.

-- Validates [p_payload] for [p_match_id] and stores it as a new PROVISIONAL
-- version written by [p_client] (with its cards when given). The rules are
-- migration 20's (outcome, innings, margin, Player of the Match) and 21's
-- (cards, player pools) — now for the official path only.
--   p_payload = {"outcome": "club_a_won", "innings": [ … as migration 20,
--                with optional "batting" / "bowling" as migration 21 … ],
--                "player_of_match_member_id": "…" | null}
-- Internal: no caller checks (the public functions do them).
create or replace function public.official_result_store(
  p_client            uuid,
  p_match_id          uuid,
  p_payload           jsonb,
  p_corrects_version  integer,
  p_correction_reason text,
  p_log_id            bigint
)
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  c_uuid       constant text := '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';
  c_dismissals constant text[] := array['not_out', 'did_not_bat', 'retired_hurt', 'retired_out', 'bowled', 'caught',
                                        'lbw', 'run_out', 'stumped', 'hit_wicket', 'obstructing_field',
                                        'hit_ball_twice', 'timed_out'];
  c_not_out    constant text[] := array['not_out', 'did_not_bat', 'retired_hurt'];
  c_credited   constant text[] := array['bowled', 'caught', 'lbw', 'stumped', 'hit_wicket'];
  v_match      public.matches;
  v_outcome    text;
  v_innings    jsonb;
  v_pom        uuid;
  v_pom_name   text;
  v_reason     text;
  v_test       boolean;
  v_max_balls  integer;
  v_max_bowler integer;
  v_count      integer;
  v_cards      integer;
  v_winner     uuid;
  v_loser      uuid;
  v_win_runs   integer;
  v_lose_runs  integer;
  v_last       record;
  v_win_inns   integer;
  v_lose_inns  integer;
  v_m_runs     integer;
  v_m_wkts     smallint;
  v_innings_v  boolean := false;
  v_confirmed  integer;
  v_version    integer;
  v_outs       integer;
  v_batted     integer;
  v_not_outs   integer;
  v_bat_runs   integer;
  i            public.match_innings;
  e            record;
  v_bat        jsonb;
  v_bowl       jsonb;
begin
  -- The match row first: every result change of one match runs one at a time.
  select * into v_match from public.matches m where m.id = p_match_id for update;
  if not found then
    raise exception 'result: not found' using errcode = 'P0002';
  end if;
  if v_match.status not in ('confirmed', 'completed') or v_match.starts_at is null or v_match.starts_at > now() then
    raise exception 'result: match not played' using errcode = 'P0001';
  end if;

  -- The correction rule: with an official result, only a correction of it.
  select r.version into v_confirmed from public.match_results r
   where r.match_id = p_match_id and r.status = 'confirmed';
  if v_confirmed is not null and p_corrects_version is null then
    raise exception 'result: correction required' using errcode = 'P0001';
  end if;
  if v_confirmed is null and p_corrects_version is not null then
    raise exception 'result: nothing to correct' using errcode = 'P0001';
  end if;
  if p_corrects_version is not null then
    if p_corrects_version <> v_confirmed then
      raise exception 'result: version changed' using errcode = 'P0001';
    end if;
    v_reason := regexp_replace(btrim(coalesce(p_correction_reason, '')), '\s+', ' ', 'g');
    if char_length(v_reason) not between 1 and 300 then
      raise exception 'result: invalid reason' using errcode = '22023';
    end if;
  end if;

  -- The payload's shape.
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'result: invalid payload' using errcode = '22023';
  end if;
  v_outcome := lower(btrim(coalesce(p_payload ->> 'outcome', '')));
  v_innings := p_payload -> 'innings';
  if v_outcome not in ('club_a_won', 'club_b_won', 'tie', 'no_result', 'abandoned') then
    raise exception 'result: invalid' using errcode = '22023';
  end if;
  if jsonb_typeof(p_payload -> 'player_of_match_member_id') is distinct from 'null'
     and p_payload ? 'player_of_match_member_id' then
    if coalesce(p_payload ->> 'player_of_match_member_id', '') !~ c_uuid then
      raise exception 'result: invalid player' using errcode = '22023';
    end if;
    v_pom := (p_payload ->> 'player_of_match_member_id')::uuid;
  end if;

  -- The innings: well-formed, numbered by their order, within the format (as migration 20).
  v_test := v_match.format = 'test';
  v_max_balls := public.match_format_max_balls(v_match.format, v_match.custom_overs);
  if v_innings is null or jsonb_typeof(v_innings) <> 'array' then
    raise exception 'result: invalid innings' using errcode = '22023';
  end if;
  v_count := jsonb_array_length(v_innings);
  if v_count > (case when v_test then 4 else 2 end) then
    raise exception 'result: invalid innings' using errcode = '22023';
  end if;
  for e in select value as v, ordinality as n from jsonb_array_elements(v_innings) with ordinality loop
    if jsonb_typeof(e.v) <> 'object'
       or coalesce(e.v ->> 'batting_club_id', '') not in (v_match.club_a_id::text, v_match.club_b_id::text)
       or coalesce(e.v ->> 'runs', '') !~ '^\d{1,4}$' or coalesce(e.v ->> 'wickets', '') !~ '^\d{1,2}$'
       or coalesce(e.v ->> 'balls', '') !~ '^\d{1,4}$'
       or exists (select 1 from unnest(array['byes', 'leg_byes', 'wides', 'no_balls', 'penalty']) k
                   where e.v ? k and coalesce(e.v ->> k, '') !~ '^\d{1,3}$')
       or (e.v ? 'declared' and jsonb_typeof(e.v -> 'declared') <> 'boolean') then
      raise exception 'result: invalid innings' using errcode = '22023';
    end if;
    if (e.v ->> 'runs')::int > 2000 or (e.v ->> 'wickets')::int > 10 or (e.v ->> 'balls')::int > 3000
       or (v_max_balls is not null and (e.v ->> 'balls')::int > v_max_balls)
       or (coalesce((e.v ->> 'declared')::boolean, false) and (not v_test or (e.v ->> 'wickets')::int >= 10))
       or coalesce((e.v ->> 'byes')::int, 0) + coalesce((e.v ->> 'leg_byes')::int, 0)
          + coalesce((e.v ->> 'wides')::int, 0) + coalesce((e.v ->> 'no_balls')::int, 0)
          + coalesce((e.v ->> 'penalty')::int, 0) > (e.v ->> 'runs')::int then
      raise exception 'result: invalid innings' using errcode = '22023';
    end if;
  end loop;
  if (not v_test and v_count = 2
      and (v_innings -> 0 ->> 'batting_club_id') = (v_innings -> 1 ->> 'batting_club_id'))
     or (v_test and exists (select 1 from jsonb_array_elements(v_innings) x
                             group by x ->> 'batting_club_id' having count(*) > 2)) then
    raise exception 'result: invalid innings' using errcode = '22023';
  end if;

  -- The outcome agrees with the totals; the margin is computed (as migration 20).
  if v_outcome = 'abandoned' and v_count > 0 then
    raise exception 'result: inconsistent result' using errcode = '22023';
  end if;
  if v_outcome = 'tie' or v_outcome like '%_won' then
    if v_count < 2 then
      raise exception 'result: inconsistent result' using errcode = '22023';
    end if;
    select coalesce(sum((x ->> 'runs')::int) filter (where (x ->> 'batting_club_id')::uuid = v_match.club_a_id), 0),
           coalesce(sum((x ->> 'runs')::int) filter (where (x ->> 'batting_club_id')::uuid = v_match.club_b_id), 0)
      into v_win_runs, v_lose_runs
      from jsonb_array_elements(v_innings) x;
    if v_outcome = 'tie' then
      if v_win_runs <> v_lose_runs then
        raise exception 'result: inconsistent result' using errcode = '22023';
      end if;
    else
      if v_outcome = 'club_a_won' then
        v_winner := v_match.club_a_id; v_loser := v_match.club_b_id;
      else
        v_winner := v_match.club_b_id; v_loser := v_match.club_a_id;
        select v_lose_runs, v_win_runs into v_win_runs, v_lose_runs;
      end if;
      if v_win_runs <= v_lose_runs then
        raise exception 'result: inconsistent result' using errcode = '22023';
      end if;
      select (x ->> 'batting_club_id')::uuid as club, (x ->> 'wickets')::int as wickets
        into v_last
        from jsonb_array_elements(v_innings) with ordinality as t(x, n)
       order by n desc limit 1;
      select count(*) filter (where (x ->> 'batting_club_id')::uuid = v_winner),
             count(*) filter (where (x ->> 'batting_club_id')::uuid = v_loser)
        into v_win_inns, v_lose_inns
        from jsonb_array_elements(v_innings) x;
      if v_last.club = v_winner then
        v_m_wkts := 10 - v_last.wickets;
      else
        v_m_runs := v_win_runs - v_lose_runs;
        v_innings_v := v_test and v_win_inns < v_lose_inns;
      end if;
    end if;
  end if;

  -- Player of the Match: optional, a member of one of the two clubs.
  if v_pom is not null then
    select btrim(p.full_name) into v_pom_name
      from public.club_members cm
      join public.profiles p on p.id = cm.user_id
     where cm.id = v_pom and cm.club_id in (v_match.club_a_id, v_match.club_b_id);
    if not found or char_length(coalesce(v_pom_name, '')) not between 1 and 100 then
      raise exception 'result: invalid player' using errcode = '22023';
    end if;
  end if;

  -- Cards: none, or both cards on every innings (as migration 21).
  select count(*) filter (where x ? 'batting' or x ? 'bowling') into v_cards from jsonb_array_elements(v_innings) x;
  if v_cards > 0 and (v_cards <> v_count
                      or exists (select 1 from jsonb_array_elements(v_innings) x
                                  where jsonb_typeof(x -> 'batting') is distinct from 'array'
                                     or jsonb_typeof(x -> 'bowling') is distinct from 'array')) then
    raise exception 'result: invalid scorecard' using errcode = '22023';
  end if;

  -- A provisional version still waiting is replaced by this one.
  update public.match_results
     set status = 'superseded', decided_at = now(), decided_by_client_id = p_client
   where match_id = p_match_id and status = 'submitted';
  select coalesce(max(version), 0) + 1 into v_version from public.match_results where match_id = p_match_id;

  insert into public.match_results (match_id, version, outcome, margin_runs, margin_wickets, innings_victory,
                                    player_of_match_member_id, player_of_match_name,
                                    scorer_client_id, submission_id, corrects_version, correction_reason)
  values (p_match_id, v_version, v_outcome, v_m_runs, v_m_wkts, v_innings_v, v_pom, v_pom_name,
          p_client, p_log_id, p_corrects_version, v_reason);

  insert into public.match_innings (match_id, version, innings_no, batting_club_id, bowling_club_id, runs, wickets,
                                    balls, byes, leg_byes, wides, no_balls, penalty, declared)
  select p_match_id, v_version, t.n::smallint, (t.x ->> 'batting_club_id')::uuid,
         case when (t.x ->> 'batting_club_id')::uuid = v_match.club_a_id then v_match.club_b_id else v_match.club_a_id end,
         (t.x ->> 'runs')::int, (t.x ->> 'wickets')::smallint, (t.x ->> 'balls')::int,
         coalesce((t.x ->> 'byes')::smallint, 0), coalesce((t.x ->> 'leg_byes')::smallint, 0),
         coalesce((t.x ->> 'wides')::smallint, 0), coalesce((t.x ->> 'no_balls')::smallint, 0),
         coalesce((t.x ->> 'penalty')::smallint, 0), coalesce((t.x ->> 'declared')::boolean, false)
    from jsonb_array_elements(v_innings) with ordinality as t(x, n);

  if v_cards = 0 then
    return v_version;
  end if;
  v_max_bowler := public.match_bowler_max_balls(v_match.format, v_match.custom_overs);

  for i in select * from public.match_innings mi
            where mi.match_id = p_match_id and mi.version = v_version order by mi.innings_no loop
    v_bat := v_innings -> (i.innings_no - 1) -> 'batting';
    v_bowl := v_innings -> (i.innings_no - 1) -> 'bowling';

    if jsonb_array_length(v_bowl) not between 1 and 11 or jsonb_array_length(v_bat) not between 1 and 11
       or exists (select 1 from jsonb_array_elements(v_bowl) b
                   where jsonb_typeof(b) <> 'object'
                      or coalesce(b ->> 'member_id', '') !~ c_uuid
                      or coalesce(b ->> 'balls', '') !~ '^\d{1,4}$' or coalesce(b ->> 'runs', '') !~ '^\d{1,4}$'
                      or exists (select 1 from unnest(array['maidens', 'wides', 'no_balls', 'wickets']) k
                                  where jsonb_typeof(b -> k) is distinct from 'null' and b ? k
                                    and coalesce(b ->> k, '') !~ '^\d{1,3}$'))
       or exists (select 1 from jsonb_array_elements(v_bat) b
                   where jsonb_typeof(b) <> 'object'
                      or coalesce(b ->> 'member_id', '') !~ c_uuid
                      or coalesce(b ->> 'runs', '0') !~ '^\d{1,4}$' or coalesce(b ->> 'balls', '0') !~ '^\d{1,4}$'
                      or exists (select 1 from unnest(array['fours', 'sixes']) k
                                  where jsonb_typeof(b -> k) is distinct from 'null' and b ? k
                                    and coalesce(b ->> k, '') !~ '^\d{1,3}$')
                      or lower(coalesce(b ->> 'dismissal', '')) <> all (c_dismissals)
                      or coalesce(b ->> 'bowler_member_id', '00000000-0000-0000-0000-000000000000') !~ c_uuid
                      or coalesce(b ->> 'fielder_member_id', '00000000-0000-0000-0000-000000000000') !~ c_uuid
                      or (jsonb_typeof(b -> 'direct_hit') is distinct from 'null' and b ? 'direct_hit'
                          and jsonb_typeof(b -> 'direct_hit') <> 'boolean')) then
      raise exception 'result: invalid scorecard' using errcode = '22023';
    end if;

    if exists (select 1 from jsonb_array_elements(v_bowl) b
                 left join public.match_club_player_pool(p_match_id, i.bowling_club_id) p
                   on p.member_id = (b ->> 'member_id')::uuid
                where p.member_id is null or p.selection = 'sub'
                   or (v_max_bowler is not null and (b ->> 'balls')::int > v_max_bowler)
                   or coalesce((b ->> 'maidens')::int, 0) * 6 > (b ->> 'balls')::int
                   or coalesce((b ->> 'wides')::int, 0) + coalesce((b ->> 'no_balls')::int, 0) > (b ->> 'runs')::int)
       or (select count(distinct (b ->> 'member_id')::uuid) from jsonb_array_elements(v_bowl) b) <> jsonb_array_length(v_bowl)
       or (select row(sum((b ->> 'balls')::int), sum((b ->> 'runs')::int),
                      sum(coalesce((b ->> 'wides')::int, 0)), sum(coalesce((b ->> 'no_balls')::int, 0)))
             from jsonb_array_elements(v_bowl) b)
          is distinct from row(i.balls::bigint, (i.runs - i.byes - i.leg_byes - i.penalty)::bigint,
                               i.wides::bigint, i.no_balls::bigint) then
      raise exception 'result: invalid scorecard' using errcode = '22023';
    end if;

    if exists (select 1 from jsonb_array_elements(v_bat) b
                 left join public.match_club_player_pool(p_match_id, i.batting_club_id) p
                   on p.member_id = (b ->> 'member_id')::uuid
                 cross join lateral (select lower(b ->> 'dismissal') as d,
                                            coalesce((b ->> 'runs')::int, 0) as runs,
                                            coalesce((b ->> 'balls')::int, 0) as balls,
                                            coalesce((b ->> 'fours')::int, 0) as fours,
                                            coalesce((b ->> 'sixes')::int, 0) as sixes,
                                            (b ->> 'bowler_member_id')::uuid as bowler,
                                            (b ->> 'fielder_member_id')::uuid as fielder,
                                            coalesce((b ->> 'direct_hit')::boolean, false) as direct_hit) x
                where p.member_id is null or p.selection = 'sub'
                   or x.runs > i.runs or x.balls > i.balls + i.no_balls
                   or x.fours * 4 + x.sixes * 6 > x.runs
                   or (x.d = 'did_not_bat' and (x.runs > 0 or x.balls > 0 or x.fours > 0 or x.sixes > 0))
                   or (x.d = any (c_credited)) <> (x.bowler is not null)
                   or (x.bowler is not null
                       and not exists (select 1 from jsonb_array_elements(v_bowl) w where (w ->> 'member_id')::uuid = x.bowler))
                   or (x.d in ('caught', 'stumped') and x.fielder is null)
                   or (x.fielder is not null and x.d not in ('caught', 'run_out', 'stumped'))
                   or (x.fielder is not null
                       and not exists (select 1 from public.match_club_player_pool(p_match_id, i.bowling_club_id) f
                                        where f.member_id = x.fielder))
                   or (x.direct_hit and x.d <> 'run_out'))
       or (select count(distinct (b ->> 'member_id')::uuid) from jsonb_array_elements(v_bat) b) <> jsonb_array_length(v_bat)
       or exists (select 1 from jsonb_array_elements(v_bowl) w
                   where jsonb_typeof(w -> 'wickets') = 'number'
                     and (w ->> 'wickets')::int <> (select count(*) from jsonb_array_elements(v_bat) b
                                                     where (b ->> 'bowler_member_id')::uuid = (w ->> 'member_id')::uuid
                                                       and lower(b ->> 'dismissal') = any (c_credited))) then
      raise exception 'result: invalid scorecard' using errcode = '22023';
    end if;
    select count(*) filter (where lower(b ->> 'dismissal') <> all (c_not_out)),
           count(*) filter (where lower(b ->> 'dismissal') <> 'did_not_bat'),
           count(*) filter (where lower(b ->> 'dismissal') = 'not_out'),
           coalesce(sum(coalesce((b ->> 'runs')::int, 0)), 0)
      into v_outs, v_batted, v_not_outs, v_bat_runs
      from jsonb_array_elements(v_bat) b;
    if v_outs <> i.wickets or v_batted < i.wickets + 1 or v_not_outs > 2
       or v_bat_runs <> i.runs - i.byes - i.leg_byes - i.wides - i.no_balls - i.penalty then
      raise exception 'result: invalid scorecard' using errcode = '22023';
    end if;

    insert into public.match_bowling (match_id, version, innings_no, bowler_no, member_id, player_name,
                                      balls, maidens, runs, wickets, wides, no_balls)
    select p_match_id, v_version, i.innings_no, t.n::smallint, p.member_id, p.full_name,
           (t.b ->> 'balls')::int, coalesce((t.b ->> 'maidens')::smallint, 0), (t.b ->> 'runs')::int,
           (select count(*) from jsonb_array_elements(v_bat) x
             where (x ->> 'bowler_member_id')::uuid = p.member_id and lower(x ->> 'dismissal') = any (c_credited))::smallint,
           coalesce((t.b ->> 'wides')::smallint, 0), coalesce((t.b ->> 'no_balls')::smallint, 0)
      from jsonb_array_elements(v_bowl) with ordinality as t(b, n)
      join public.match_club_player_pool(p_match_id, i.bowling_club_id) p on p.member_id = (t.b ->> 'member_id')::uuid;

    insert into public.match_batting (match_id, version, innings_no, position, member_id, player_name, runs, balls,
                                      fours, sixes, dismissal, bowler_no, fielder_member_id, fielder_name,
                                      fielder_substitute, direct_hit)
    select p_match_id, v_version, i.innings_no, t.n::smallint, p.member_id, p.full_name,
           coalesce((t.b ->> 'runs')::int, 0), coalesce((t.b ->> 'balls')::int, 0),
           coalesce((t.b ->> 'fours')::smallint, 0), coalesce((t.b ->> 'sixes')::smallint, 0),
           lower(t.b ->> 'dismissal'),
           (select w.bowler_no from public.match_bowling w
             where w.match_id = p_match_id and w.version = v_version and w.innings_no = i.innings_no
               and w.member_id = (t.b ->> 'bowler_member_id')::uuid),
           f.member_id, f.full_name, coalesce(f.selection = 'sub', false),
           coalesce((t.b ->> 'direct_hit')::boolean, false)
      from jsonb_array_elements(v_bat) with ordinality as t(b, n)
      join public.match_club_player_pool(p_match_id, i.batting_club_id) p on p.member_id = (t.b ->> 'member_id')::uuid
      left join public.match_club_player_pool(p_match_id, i.bowling_club_id) f
        on f.member_id = (t.b ->> 'fielder_member_id')::uuid;
  end loop;

  return v_version;
end;
$$;

-- Approves or rejects the waiting version [p_version] of [p_match_id] as
-- [p_client]. Two-person rule (D2): the scorer who wrote it can't decide it,
-- unless [p_self] (a single-step trusted client confirming its own). Approving
-- makes it the official result (the previous one is superseded, keeping who
-- confirmed it) and completes the match. Internal.
create or replace function public.official_result_decide(
  p_client   uuid,
  p_match_id uuid,
  p_version  integer,
  p_approve  boolean,
  p_note     text,
  p_self     boolean
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_match public.matches;
  v_row   public.match_results;
  v_note  text := regexp_replace(btrim(coalesce(p_note, '')), '\s+', ' ', 'g');
begin
  select * into v_match from public.matches m where m.id = p_match_id for update;
  if not found then
    raise exception 'result: not found' using errcode = 'P0002';
  end if;
  select * into v_row from public.match_results r where r.match_id = p_match_id and r.status = 'submitted' for update;
  if not found then
    raise exception 'result: not pending' using errcode = 'P0001';
  end if;
  if v_row.version <> coalesce(p_version, -1) then
    raise exception 'result: version changed' using errcode = 'P0001';
  end if;
  if v_row.scorer_client_id = p_client and not p_self then
    raise exception 'result: same official' using errcode = '42501';
  end if;
  if p_approve then
    update public.match_results set status = 'superseded'
     where match_id = p_match_id and status = 'confirmed';
    update public.match_results
       set status = 'confirmed', decided_at = now(), decided_by_client_id = p_client
     where match_id = p_match_id and version = v_row.version;
    if v_match.status = 'confirmed' then
      update public.matches set status = 'completed' where id = p_match_id;
    end if;
  else
    if char_length(v_note) not between 1 and 300 then
      raise exception 'result: invalid reason' using errcode = '22023';
    end if;
    update public.match_results
       set status = 'rejected', decided_at = now(), decided_by_client_id = p_client, decision_note = v_note
     where match_id = p_match_id and version = v_row.version;
  end if;
end;
$$;

-- The shared skeleton of the three public write functions: idempotency per
-- (client, key) — a repeated call returns the first outcome, a different
-- request under the same key is refused —, the client and its assignment,
-- the work itself, and ONE submission-log record whatever the outcome.
-- Rule refusals ("result: …" / "match: …") become a 'rejected' outcome;
-- anything unexpected stays an error (and nothing is stored). Internal.
create or replace function public.official_result_submit(
  p_action            text,
  p_client_id         uuid,
  p_idempotency_key   text,
  p_match_id          uuid,
  p_payload           jsonb,
  p_corrects_version  integer,
  p_correction_reason text,
  p_request_id        text
)
returns table (outcome text, version integer, reason text, log_id bigint, replayed boolean)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_key      text := btrim(coalesce(p_idempotency_key, ''));
  v_payload  jsonb := coalesce(p_payload, 'null'::jsonb);
  v_sha      text := encode(sha256(convert_to(coalesce(p_payload, 'null'::jsonb)::text, 'UTF8')), 'hex');
  v_existing public.result_submission_log;
  v_client   public.scorer_clients;
  v_log      bigint;
  v_version  integer;
  v_outcome  text := 'accepted';
  v_reason   text;
  v_role     text := case p_action when 'verify' then 'verifier' else 'scorer' end;
begin
  if char_length(v_key) not between 1 and 100 or p_client_id is null then
    raise exception 'result: invalid key' using errcode = '22023';
  end if;
  if p_request_id is not null and char_length(p_request_id) not between 1 and 100 then
    raise exception 'result: invalid request id' using errcode = '22023';
  end if;
  -- Same client and key: one call at a time; a repeat replays the first.
  perform pg_advisory_xact_lock(hashtextextended(p_client_id::text || '/' || v_key, 24));
  select * into v_existing from public.result_submission_log l
   where l.client_id = p_client_id and l.idempotency_key = v_key;
  if found then
    if v_existing.action <> p_action or v_existing.match_id is distinct from p_match_id
       or v_existing.payload_sha256 <> v_sha then
      return query select 'rejected'::text, null::integer, 'result: idempotency conflict'::text, v_existing.id, true;
      return;
    end if;
    return query select v_existing.outcome, v_existing.version, v_existing.reason, v_existing.id, true;
    return;
  end if;

  v_log := nextval('public.result_submission_log_id_seq');
  begin
    select * into v_client from public.scorer_clients c where c.id = p_client_id;
    if not found or v_client.status <> 'active' then
      raise exception 'result: client not allowed' using errcode = '42501';
    end if;
    if not exists (select 1 from public.match_officials o
                    where o.match_id = p_match_id and o.client_id = p_client_id and o.role = v_role) then
      raise exception 'result: not assigned' using errcode = '42501';
    end if;
    if p_action = 'verify' then
      if jsonb_typeof(v_payload -> 'version') is distinct from 'number'
         or jsonb_typeof(v_payload -> 'approve') is distinct from 'boolean' then
        raise exception 'result: invalid payload' using errcode = '22023';
      end if;
      v_version := (v_payload ->> 'version')::int;
      perform public.official_result_decide(p_client_id, p_match_id, v_version,
                                            (v_payload ->> 'approve')::boolean, v_payload ->> 'note', false);
    else
      v_version := public.official_result_store(p_client_id, p_match_id, v_payload, p_corrects_version,
                                                p_correction_reason, v_log);
      if v_client.single_step_trusted then
        perform public.official_result_decide(p_client_id, p_match_id, v_version, true, null, true);
      end if;
    end if;
  exception when others then
    if sqlerrm not like 'result:%' and sqlerrm not like 'match:%' then
      raise;
    end if;
    v_outcome := 'rejected';
    v_reason := sqlerrm;
    v_version := null;
  end;

  insert into public.result_submission_log (id, client_id, action, match_id, idempotency_key, payload, payload_sha256,
                                            request_id, outcome, reason, version)
  values (v_log, p_client_id, p_action, p_match_id, v_key, v_payload, v_sha, p_request_id, v_outcome, v_reason,
          v_version);
  return query select v_outcome, v_version, v_reason, v_log, false;
end;
$$;

-- A scorer submits a match's result (a provisional version: officials only
-- see it until a verifier approves it). [p_payload]: see
-- official_result_store. A match that already has an official result needs
-- correct_official_result instead.
create or replace function public.ingest_official_result(
  p_client_id       uuid,
  p_idempotency_key text,
  p_match_id        uuid,
  p_payload         jsonb,
  p_request_id      text default null
)
returns table (outcome text, version integer, reason text, log_id bigint, replayed boolean)
language sql
volatile
security definer
set search_path = ''
as $$
  select * from public.official_result_submit('ingest', p_client_id, p_idempotency_key, p_match_id, p_payload,
                                              null, null, p_request_id);
$$;

-- A verifier (a DIFFERENT assigned official) approves or rejects the waiting
-- version [p_version]; a rejection needs [p_note] (1–300 characters).
create or replace function public.verify_official_result(
  p_client_id       uuid,
  p_idempotency_key text,
  p_match_id        uuid,
  p_version         integer,
  p_approve         boolean,
  p_note            text default null,
  p_request_id      text default null
)
returns table (outcome text, version integer, reason text, log_id bigint, replayed boolean)
language sql
volatile
security definer
set search_path = ''
as $$
  select * from public.official_result_submit('verify', p_client_id, p_idempotency_key, p_match_id,
                                              jsonb_strip_nulls(jsonb_build_object('version', p_version,
                                                                                   'approve', p_approve,
                                                                                   'note', p_note)),
                                              null, null, p_request_id);
$$;

-- A scorer corrects the official result [p_corrects_version] with a reason
-- (1–300 characters): a new provisional version, verified again; until then
-- the official result stands.
create or replace function public.correct_official_result(
  p_client_id        uuid,
  p_idempotency_key  text,
  p_match_id         uuid,
  p_corrects_version integer,
  p_reason           text,
  p_payload          jsonb,
  p_request_id       text default null
)
returns table (outcome text, version integer, reason text, log_id bigint, replayed boolean)
language sql
volatile
security definer
set search_path = ''
as $$
  select * from public.official_result_submit('correct', p_client_id, p_idempotency_key, p_match_id,
                                              coalesce(p_payload, 'null'::jsonb)
                                                || jsonb_build_object('corrects_version', p_corrects_version,
                                                                      'correction_reason', p_reason),
                                              p_corrects_version, p_reason, p_request_id);
$$;

-- Assigns an active client to a match as scorer or verifier (by the league
-- / ground integration). Recorded in result_change_log.
create or replace function public.assign_match_official(p_match_id uuid, p_client_id uuid, p_role text)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.matches m where m.id = p_match_id) then
    raise exception 'result: not found' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.scorer_clients c where c.id = p_client_id and c.status = 'active') then
    raise exception 'result: client not allowed' using errcode = '42501';
  end if;
  if p_role is null or p_role not in ('scorer', 'verifier') then
    raise exception 'result: invalid' using errcode = '22023';
  end if;
  insert into public.match_officials (match_id, client_id, role) values (p_match_id, p_client_id, p_role)
  on conflict do nothing;
end;
$$;

create or replace function public.unassign_match_official(p_match_id uuid, p_client_id uuid, p_role text)
returns void
language sql
volatile
security definer
set search_path = ''
as $$
  delete from public.match_officials o
   where o.match_id = p_match_id and o.client_id = p_client_id and o.role = p_role;
$$;

-- The players an assigned official may put on a match's cards (both clubs'
-- pools: the saved line-up, or the active members): names and membership ids
-- only. Replaces match_player_pool() for officials (D5).
create or replace function public.official_match_roster(p_client_id uuid, p_match_id uuid)
returns table (club_id uuid, member_id uuid, full_name text, selection text, pick_order smallint)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_match public.matches;
begin
  if not exists (select 1 from public.scorer_clients c where c.id = p_client_id and c.status = 'active') then
    raise exception 'result: client not allowed' using errcode = '42501';
  end if;
  if not exists (select 1 from public.match_officials o where o.match_id = p_match_id and o.client_id = p_client_id) then
    raise exception 'result: not assigned' using errcode = '42501';
  end if;
  select * into v_match from public.matches m where m.id = p_match_id;
  if not found or v_match.status not in ('confirmed', 'completed') then
    raise exception 'result: match not played' using errcode = 'P0001';
  end if;
  return query
    select c.id, p.member_id, p.full_name, p.selection, p.pick_order
      from unnest(array[v_match.club_a_id, v_match.club_b_id]) as c(id)
     cross join lateral public.match_club_player_pool(p_match_id, c.id) p
     order by c.id = v_match.club_a_id desc, p.pick_order nulls last, p.full_name, p.member_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. Privileges
-- ---------------------------------------------------------------------------
revoke all on table public.scorer_clients, public.match_officials, public.result_submission_log,
                    public.result_change_log
  from public, anon, authenticated, service_role;
revoke all on sequence public.result_submission_log_id_seq from public, anon, authenticated, service_role;
revoke all on sequence public.result_change_log_id_seq from public, anon, authenticated, service_role;
alter table public.scorer_clients enable row level security;
alter table public.match_officials enable row level security;
alter table public.result_submission_log enable row level security;
alter table public.result_change_log enable row level security;

revoke execute on function public.official_result_store(uuid, uuid, jsonb, integer, text, bigint)
  from public, anon, authenticated, service_role;
revoke execute on function public.official_result_decide(uuid, uuid, integer, boolean, text, boolean)
  from public, anon, authenticated, service_role;
revoke execute on function public.official_result_submit(text, uuid, text, uuid, jsonb, integer, text, text)
  from public, anon, authenticated, service_role;
revoke execute on function public.result_tables_audit() from public, anon, authenticated, service_role;
revoke execute on function public.audit_log_append_only() from public, anon, authenticated, service_role;

revoke execute on function public.ingest_official_result(uuid, text, uuid, jsonb, text) from public, anon, authenticated;
revoke execute on function public.verify_official_result(uuid, text, uuid, integer, boolean, text, text)
  from public, anon, authenticated;
revoke execute on function public.correct_official_result(uuid, text, uuid, integer, text, jsonb, text)
  from public, anon, authenticated;
revoke execute on function public.assign_match_official(uuid, uuid, text) from public, anon, authenticated;
revoke execute on function public.unassign_match_official(uuid, uuid, text) from public, anon, authenticated;
revoke execute on function public.official_match_roster(uuid, uuid) from public, anon, authenticated;

grant execute on function public.ingest_official_result(uuid, text, uuid, jsonb, text) to service_role;
grant execute on function public.verify_official_result(uuid, text, uuid, integer, boolean, text, text) to service_role;
grant execute on function public.correct_official_result(uuid, text, uuid, integer, text, jsonb, text) to service_role;
grant execute on function public.assign_match_official(uuid, uuid, text) to service_role;
grant execute on function public.unassign_match_official(uuid, uuid, text) to service_role;
grant execute on function public.official_match_roster(uuid, uuid) to service_role;

notify pgrst, 'reload schema';
