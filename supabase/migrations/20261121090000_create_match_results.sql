-- CricEco · migration 20 · match results and innings totals (M2, P1)
--
-- NOT APPLIED. Requires migrations 17–18 (matches, lineups). Review first;
-- apply only with separate approval, after a fresh backup, inside
--   begin; set local lock_timeout = '5s'; <this file> commit;
-- Rollback: supabase/rollback/20261121_rollback_match_results.sql.
-- Read-only check: supabase/tests/20_match_results_postcheck.sql.
-- Local test: supabase/tests/local/17_match_results_local_check.sql (+ 17b_…sh).
-- Design: docs/MATCH_RESULTS_BACKEND.md.
--
-- Approved M2 decisions (2026-11-21) this migration implements:
--   1. Either club's owner SUBMITS a result; the OTHER club's owner CONFIRMS
--      it or DISPUTES it (with a reason). Only a confirmed result counts.
--   2. A result is the outcome plus the innings totals (runs, wickets, legal
--      balls); batting / bowling scorecards come in migration 21.
--   3. Each innings carries its extras (byes, leg byes, wides, no balls,
--      penalty runs). No fall of wickets.
--   5. The submitting owner enters every innings (both clubs').
--   7. Confirmed results are locked. A correction is a NEW submission that
--      the other club confirms: until then the confirmed result stands.
--      Every version is kept (submitted / confirmed / disputed / superseded,
--      by whom and when): the audit trail.
--   8. A deleted account becomes "Deleted player" as Player of the Match:
--      the stored name is dropped, the result stays.
--  12. Limited-overs formats first; Test (up to 4 innings, declarations) is
--      stored and checked too — its entry screens come later.
-- The margin ("by 24 runs" / "by 6 wickets" / "by an innings and 12 runs")
-- is computed here from the innings, never typed. A win must agree with the
-- totals; a tie needs equal totals; "abandoned" means no innings.
-- Not supported: DLS-adjusted results (choose "no result").
--
-- RLS: SELECT only. Every version: owners of both clubs. Confirmed results:
-- also active members of both clubs. No direct writes: the functions below
-- take the caller from auth.uid() and re-check everything in the database.

do $$
begin
  if to_regclass('public.matches') is null or to_regclass('public.match_lineups') is null
     or to_regprocedure('public.is_active_club_member(uuid)') is null then
    raise exception 'migration 20: migrations 17–18 (matches, lineups) are required';
  end if;
  if to_regclass('public.match_results') is not null or to_regclass('public.match_innings') is not null
     or exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public'
                   and p.proname in ('match_format_max_balls', 'match_results_guard_update', 'match_innings_guard',
                                     'club_members_forget_match_results', 'submit_match_result',
                                     'confirm_match_result', 'dispute_match_result', 'match_result',
                                     'club_results', 'club_record', 'match_result_summary')) then
    raise exception 'migration 20: already applied (or a name is taken) — nothing changed';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
-- One row per submitted version of a match's result.
create table public.match_results (
  match_id                   uuid not null
                             constraint match_results_match_id_fkey references public.matches (id) on delete cascade,
  version                    integer not null
                             constraint match_results_version_check check (version >= 1),
  status                     text not null default 'submitted'
                             constraint match_results_status_check
                             check (status in ('submitted', 'confirmed', 'disputed', 'superseded')),
  outcome                    text not null
                             constraint match_results_outcome_check
                             check (outcome in ('club_a_won', 'club_b_won', 'tie', 'no_result', 'abandoned')),
  -- Computed from the innings by submit_match_result (never typed).
  margin_runs                integer
                             constraint match_results_margin_runs_check check (margin_runs is null or margin_runs >= 1),
  margin_wickets             smallint
                             constraint match_results_margin_wickets_check
                             check (margin_wickets is null or margin_wickets between 0 and 10),
  innings_victory            boolean not null default false,
  player_of_match_member_id  uuid
                             constraint match_results_player_of_match_member_id_fkey
                             references public.club_members (id) on delete set null,
  player_of_match_name       text
                             constraint match_results_player_of_match_name_check
                             check (player_of_match_name is null or char_length(btrim(player_of_match_name)) between 1 and 100),
  -- Set when that person deleted their account (shown as "Deleted player").
  player_of_match_deleted    boolean not null default false,
  submitted_by_club_id       uuid not null,
  submitted_by               uuid
                             constraint match_results_submitted_by_fkey references public.profiles (id) on delete set null,
  submitted_at               timestamptz not null default now(),
  -- Confirmed / disputed: by the other club; superseded: by the newer version.
  decided_by_club_id         uuid,
  decided_by                 uuid
                             constraint match_results_decided_by_fkey references public.profiles (id) on delete set null,
  decided_at                 timestamptz,
  dispute_reason             text
                             constraint match_results_dispute_reason_check
                             check (dispute_reason is null or char_length(btrim(dispute_reason)) between 1 and 300),
  constraint match_results_pkey primary key (match_id, version),
  constraint match_results_one_margin check (margin_runs is null or margin_wickets is null),
  constraint match_results_margin_only_for_wins
    check ((outcome in ('club_a_won', 'club_b_won')) or (margin_runs is null and margin_wickets is null and not innings_victory)),
  constraint match_results_decided_consistency check ((status = 'submitted') = (decided_at is null)),
  constraint match_results_dispute_reason_only_when_disputed check ((status = 'disputed') = (dispute_reason is not null)),
  constraint match_results_player_of_match_consistency
    check (player_of_match_member_id is null or player_of_match_name is not null),
  constraint match_results_deleted_player_has_no_name
    check (not player_of_match_deleted or (player_of_match_name is null and player_of_match_member_id is null))
);

comment on table public.match_results is
  'Versions of a match result (M2). Written only by submit / confirm / dispute_match_result (migration 20).';

-- At most one version waiting for the other club, and one confirmed.
create unique index match_results_one_submitted_key on public.match_results (match_id) where status = 'submitted';
create unique index match_results_one_confirmed_key on public.match_results (match_id) where status = 'confirmed';
create index match_results_player_of_match_idx on public.match_results (player_of_match_member_id)
  where player_of_match_member_id is not null;
create index match_results_submitted_by_idx on public.match_results (submitted_by) where submitted_by is not null;
create index match_results_decided_by_idx on public.match_results (decided_by) where decided_by is not null;

-- The innings of one result version.
create table public.match_innings (
  match_id         uuid not null,
  version          integer not null,
  innings_no       smallint not null
                   constraint match_innings_innings_no_check check (innings_no between 1 and 4),
  batting_club_id  uuid not null,
  bowling_club_id  uuid not null,
  runs             integer not null
                   constraint match_innings_runs_check check (runs between 0 and 2000),
  wickets          smallint not null
                   constraint match_innings_wickets_check check (wickets between 0 and 10),
  -- Legal balls bowled (overs = balls / 6 . balls % 6).
  balls            integer not null
                   constraint match_innings_balls_check check (balls between 0 and 3000),
  byes             smallint not null default 0 constraint match_innings_byes_check check (byes >= 0),
  leg_byes         smallint not null default 0 constraint match_innings_leg_byes_check check (leg_byes >= 0),
  wides            smallint not null default 0 constraint match_innings_wides_check check (wides >= 0),
  no_balls         smallint not null default 0 constraint match_innings_no_balls_check check (no_balls >= 0),
  penalty          smallint not null default 0 constraint match_innings_penalty_check check (penalty >= 0),
  declared         boolean not null default false,
  constraint match_innings_pkey primary key (match_id, version, innings_no),
  constraint match_innings_result_fkey foreign key (match_id, version)
    references public.match_results (match_id, version) on delete cascade,
  constraint match_innings_two_clubs check (batting_club_id <> bowling_club_id),
  constraint match_innings_extras_within_runs check (byes + leg_byes + wides + no_balls + penalty <= runs),
  constraint match_innings_declared_not_all_out check (not declared or wickets < 10)
);

comment on table public.match_innings is 'Innings totals of a match result version (M2). Written only by submit_match_result.';

-- ---------------------------------------------------------------------------
-- 2. Integrity triggers (defence in depth)
-- ---------------------------------------------------------------------------
-- A version is immutable. Only its status moves on, once:
--   submitted → confirmed | disputed | superseded,   confirmed → superseded,
-- with who / when / why — plus the foreign keys' own ON DELETE SET NULL and
-- the account-deletion trigger below, which drop a deleted person's link.
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

-- Innings rows are written once, with their version, and never changed.
-- Each innings is batted by one of the match's two clubs and bowled by the
-- other.
create or replace function public.match_innings_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' then
    raise exception 'result: invalid transition' using errcode = '23514';
  end if;
  if not exists (select 1 from public.matches m
                  where m.id = new.match_id
                    and new.batting_club_id in (m.club_a_id, m.club_b_id)
                    and new.bowling_club_id in (m.club_a_id, m.club_b_id)) then
    raise exception 'result: invalid innings' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger match_innings_guard
  before insert or update on public.match_innings
  for each row execute function public.match_innings_guard();

-- Account deletion (decision 8): a deleted person's name leaves the results
-- they were Player of the Match in ("Deleted player"); the results stay.
-- BEFORE DELETE, so it runs before the foreign key clears the link.
create or replace function public.club_members_forget_match_results()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.match_results r
     set player_of_match_name = null, player_of_match_member_id = null, player_of_match_deleted = true
   where r.player_of_match_member_id = old.id;
  return old;
end;
$$;

create trigger club_members_forget_match_results
  before delete on public.club_members
  for each row execute function public.club_members_forget_match_results();

-- ---------------------------------------------------------------------------
-- 3. Row level security (read only; writes through the functions)
-- ---------------------------------------------------------------------------
alter table public.match_results enable row level security;
alter table public.match_innings enable row level security;

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

revoke all on table public.match_results, public.match_innings from public, anon, authenticated;
grant select on table public.match_results, public.match_innings to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Functions
-- ---------------------------------------------------------------------------
-- Errors (message prefix "result:" · SQLSTATE):
--   not authenticated / not allowed (42501) · not found (P0002) ·
--   match not played (P0001: not confirmed, or not started yet) ·
--   invalid / invalid innings / invalid player / invalid reason (22023) ·
--   inconsistent result (22023: the outcome doesn't match the totals) ·
--   not pending / version changed (P0001) · invalid transition (23514)

-- The most legal balls one innings may have in [p_format]; null = no limit (Test).
create or replace function public.match_format_max_balls(p_format text, p_custom_overs integer)
returns integer
language sql
immutable
set search_path = ''
as $$
  select case p_format
           when 't10' then 60
           when 't20' then 120
           when 'odi' then 300
           when 'custom' then coalesce(p_custom_overs, 50) * 6
           else null
         end;
$$;

-- "Lahore Lions won by 24 runs" / "… by 6 wickets" / "… by an innings and
-- 12 runs" / "Match tied" / "No result" / "Match abandoned", with the
-- clubs' current names.
create or replace function public.match_result_summary(p_match_id uuid, p_version integer)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case r.outcome
           when 'tie' then 'Match tied'
           when 'no_result' then 'No result'
           when 'abandoned' then 'Match abandoned'
           else (select c.name from public.clubs c
                  where c.id = case r.outcome when 'club_a_won' then m.club_a_id else m.club_b_id end)
                || ' won by '
                || case
                     when r.margin_wickets is not null
                       then r.margin_wickets || case when r.margin_wickets = 1 then ' wicket' else ' wickets' end
                     when r.innings_victory
                       then 'an innings and ' || r.margin_runs || case when r.margin_runs = 1 then ' run' else ' runs' end
                     else r.margin_runs || case when r.margin_runs = 1 then ' run' else ' runs' end
                   end
         end
    from public.match_results r
    join public.matches m on m.id = r.match_id
   where r.match_id = p_match_id and r.version = p_version;
$$;

-- Submits a result for a played match (confirmed, start time passed) — or a
-- correction of its confirmed result. p_innings: a JSON array in batting
-- order, e.g.
--   [{"batting_club_id": "…", "runs": 186, "wickets": 6, "balls": 120,
--     "byes": 2, "leg_byes": 3, "wides": 7, "no_balls": 1, "penalty": 0,
--     "declared": false}, …]
-- The bowling club of each innings is the other club. Replaces a version
-- still waiting for the other club (either club's). Returns the new version.
create or replace function public.submit_match_result(
  p_match_id                  uuid,
  p_outcome                   text,
  p_innings                   jsonb,
  p_player_of_match_member_id uuid default null
)
returns public.match_results
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid       uuid := auth.uid();
  v_match     public.matches;
  v_club      uuid;
  v_outcome   text := lower(btrim(coalesce(p_outcome, '')));
  v_test      boolean;
  v_max_balls integer;
  v_count     integer;
  v_winner    uuid;
  v_loser     uuid;
  v_win_runs  integer;
  v_lose_runs integer;
  v_last      record;
  v_win_inns  integer;
  v_lose_inns integer;
  v_m_runs    integer;
  v_m_wkts    smallint;
  v_innings_v boolean := false;
  v_pom_name  text;
  v_version   integer;
  v_row       public.match_results;
  e           record;
begin
  if v_uid is null then
    raise exception 'result: not authenticated' using errcode = '42501';
  end if;
  -- The match row first: every result change of one match runs one at a time.
  select * into v_match from public.matches m where m.id = p_match_id for update;
  if not found then
    raise exception 'result: not found' using errcode = 'P0002';
  end if;
  select c.id into v_club from public.clubs c
   where c.id in (v_match.club_a_id, v_match.club_b_id) and c.owner_id = v_uid;
  if v_club is null then
    raise exception 'result: not allowed' using errcode = '42501';
  end if;
  if v_match.status not in ('confirmed', 'completed') or v_match.starts_at is null or v_match.starts_at > now() then
    raise exception 'result: match not played' using errcode = 'P0001';
  end if;
  if v_outcome not in ('club_a_won', 'club_b_won', 'tie', 'no_result', 'abandoned') then
    raise exception 'result: invalid' using errcode = '22023';
  end if;

  -- The innings: well-formed, numbered by their order, within the format.
  v_test := v_match.format = 'test';
  v_max_balls := public.match_format_max_balls(v_match.format, v_match.custom_overs);
  if p_innings is null or jsonb_typeof(p_innings) <> 'array' then
    raise exception 'result: invalid innings' using errcode = '22023';
  end if;
  v_count := jsonb_array_length(p_innings);
  if v_count > (case when v_test then 4 else 2 end) then
    raise exception 'result: invalid innings' using errcode = '22023';
  end if;
  for e in select value as v, ordinality as n from jsonb_array_elements(p_innings) with ordinality loop
    -- The shape first (no cast can fail after it)…
    if jsonb_typeof(e.v) <> 'object'
       or coalesce(e.v ->> 'batting_club_id', '') not in (v_match.club_a_id::text, v_match.club_b_id::text)
       or coalesce(e.v ->> 'runs', '') !~ '^\d{1,4}$' or coalesce(e.v ->> 'wickets', '') !~ '^\d{1,2}$'
       or coalesce(e.v ->> 'balls', '') !~ '^\d{1,4}$'
       or exists (select 1 from unnest(array['byes', 'leg_byes', 'wides', 'no_balls', 'penalty']) k
                   where e.v ? k and coalesce(e.v ->> k, '') !~ '^\d{1,3}$')
       or (e.v ? 'declared' and jsonb_typeof(e.v -> 'declared') <> 'boolean') then
      raise exception 'result: invalid innings' using errcode = '22023';
    end if;
    -- … then the values: limits, the format's overs, extras within the runs,
    -- declarations (Test only, not all out).
    if (e.v ->> 'runs')::int > 2000 or (e.v ->> 'wickets')::int > 10 or (e.v ->> 'balls')::int > 3000
       or (v_max_balls is not null and (e.v ->> 'balls')::int > v_max_balls)
       or (coalesce((e.v ->> 'declared')::boolean, false) and (not v_test or (e.v ->> 'wickets')::int >= 10))
       or coalesce((e.v ->> 'byes')::int, 0) + coalesce((e.v ->> 'leg_byes')::int, 0)
          + coalesce((e.v ->> 'wides')::int, 0) + coalesce((e.v ->> 'no_balls')::int, 0)
          + coalesce((e.v ->> 'penalty')::int, 0) > (e.v ->> 'runs')::int then
      raise exception 'result: invalid innings' using errcode = '22023';
    end if;
  end loop;
  -- Who bats when: limited overs — one innings each; Test — at most two each.
  if (not v_test and v_count = 2
      and (p_innings -> 0 ->> 'batting_club_id') = (p_innings -> 1 ->> 'batting_club_id'))
     or (v_test and exists (select 1 from jsonb_array_elements(p_innings) x
                             group by x ->> 'batting_club_id' having count(*) > 2)) then
    raise exception 'result: invalid innings' using errcode = '22023';
  end if;

  -- The outcome agrees with the totals; the margin is computed.
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
      from jsonb_array_elements(p_innings) x;
    if v_outcome = 'tie' then
      if v_win_runs <> v_lose_runs then
        raise exception 'result: inconsistent result' using errcode = '22023';
      end if;
    else
      if v_outcome = 'club_a_won' then
        v_winner := v_match.club_a_id; v_loser := v_match.club_b_id;
      else
        v_winner := v_match.club_b_id; v_loser := v_match.club_a_id;
        select v_lose_runs, v_win_runs into v_win_runs, v_lose_runs; -- swap: (winner, loser)
      end if;
      if v_win_runs <= v_lose_runs then
        raise exception 'result: inconsistent result' using errcode = '22023';
      end if;
      select (x ->> 'batting_club_id')::uuid as club, (x ->> 'wickets')::int as wickets
        into v_last
        from jsonb_array_elements(p_innings) with ordinality as t(x, n)
       order by n desc limit 1;
      select count(*) filter (where (x ->> 'batting_club_id')::uuid = v_winner),
             count(*) filter (where (x ->> 'batting_club_id')::uuid = v_loser)
        into v_win_inns, v_lose_inns
        from jsonb_array_elements(p_innings) x;
      if v_last.club = v_winner then
        v_m_wkts := 10 - v_last.wickets; -- chased the target down
      else
        v_m_runs := v_win_runs - v_lose_runs;
        v_innings_v := v_test and v_win_inns < v_lose_inns;
      end if;
    end if;
  end if;

  -- Player of the Match: optional, a member of one of the two clubs.
  if p_player_of_match_member_id is not null then
    select btrim(p.full_name) into v_pom_name
      from public.club_members cm
      join public.profiles p on p.id = cm.user_id
     where cm.id = p_player_of_match_member_id and cm.club_id in (v_match.club_a_id, v_match.club_b_id);
    if not found or char_length(coalesce(v_pom_name, '')) not between 1 and 100 then
      raise exception 'result: invalid player' using errcode = '22023';
    end if;
  end if;

  -- A version still waiting for an answer is replaced by this one.
  update public.match_results
     set status = 'superseded', decided_by_club_id = v_club, decided_by = v_uid, decided_at = now()
   where match_id = p_match_id and status = 'submitted';
  select coalesce(max(version), 0) + 1 into v_version from public.match_results where match_id = p_match_id;

  insert into public.match_results (match_id, version, outcome, margin_runs, margin_wickets, innings_victory,
                                    player_of_match_member_id, player_of_match_name,
                                    submitted_by_club_id, submitted_by)
  values (p_match_id, v_version, v_outcome, v_m_runs, v_m_wkts, v_innings_v,
          p_player_of_match_member_id, v_pom_name, v_club, v_uid)
  returning * into v_row;

  insert into public.match_innings (match_id, version, innings_no, batting_club_id, bowling_club_id, runs, wickets,
                                    balls, byes, leg_byes, wides, no_balls, penalty, declared)
  select p_match_id, v_version, t.n::smallint, (t.x ->> 'batting_club_id')::uuid,
         case when (t.x ->> 'batting_club_id')::uuid = v_match.club_a_id then v_match.club_b_id else v_match.club_a_id end,
         (t.x ->> 'runs')::int, (t.x ->> 'wickets')::smallint, (t.x ->> 'balls')::int,
         coalesce((t.x ->> 'byes')::smallint, 0), coalesce((t.x ->> 'leg_byes')::smallint, 0),
         coalesce((t.x ->> 'wides')::smallint, 0), coalesce((t.x ->> 'no_balls')::smallint, 0),
         coalesce((t.x ->> 'penalty')::smallint, 0), coalesce((t.x ->> 'declared')::boolean, false)
    from jsonb_array_elements(p_innings) with ordinality as t(x, n);

  return v_row;
end;
$$;

-- The OTHER club's owner confirms version [p_version]: it becomes the
-- match's result (a previously confirmed one is superseded) and the match
-- is completed. Returns the confirmed version.
create or replace function public.confirm_match_result(p_match_id uuid, p_version integer)
returns public.match_results
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_match public.matches;
  v_club  uuid;
  v_row   public.match_results;
begin
  if v_uid is null then
    raise exception 'result: not authenticated' using errcode = '42501';
  end if;
  select * into v_match from public.matches m where m.id = p_match_id for update;
  if not found then
    raise exception 'result: not found' using errcode = 'P0002';
  end if;
  select c.id into v_club from public.clubs c
   where c.id in (v_match.club_a_id, v_match.club_b_id) and c.owner_id = v_uid;
  if v_club is null then
    raise exception 'result: not allowed' using errcode = '42501';
  end if;
  select * into v_row from public.match_results r where r.match_id = p_match_id and r.status = 'submitted' for update;
  if not found then
    raise exception 'result: not pending' using errcode = 'P0001';
  end if;
  if v_row.submitted_by_club_id = v_club then
    raise exception 'result: not allowed' using errcode = '42501'; -- the submitter can't confirm it
  end if;
  if v_row.version <> coalesce(p_version, -1) then
    raise exception 'result: version changed' using errcode = 'P0001';
  end if;
  -- The previous confirmed version stays as history, with who confirmed it.
  update public.match_results set status = 'superseded'
   where match_id = p_match_id and status = 'confirmed';
  update public.match_results
     set status = 'confirmed', decided_by_club_id = v_club, decided_by = v_uid, decided_at = now()
   where match_id = p_match_id and version = v_row.version
  returning * into v_row;
  if v_match.status = 'confirmed' then
    update public.matches set status = 'completed' where id = p_match_id;
  end if;
  return v_row;
end;
$$;

-- The OTHER club's owner disputes version [p_version] with a reason
-- (1–300 characters). Nothing else changes; either club may submit again.
create or replace function public.dispute_match_result(p_match_id uuid, p_version integer, p_reason text)
returns public.match_results
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_match  public.matches;
  v_club   uuid;
  v_row    public.match_results;
  v_reason text := regexp_replace(btrim(coalesce(p_reason, '')), '\s+', ' ', 'g');
begin
  if v_uid is null then
    raise exception 'result: not authenticated' using errcode = '42501';
  end if;
  select * into v_match from public.matches m where m.id = p_match_id for update;
  if not found then
    raise exception 'result: not found' using errcode = 'P0002';
  end if;
  select c.id into v_club from public.clubs c
   where c.id in (v_match.club_a_id, v_match.club_b_id) and c.owner_id = v_uid;
  if v_club is null then
    raise exception 'result: not allowed' using errcode = '42501';
  end if;
  select * into v_row from public.match_results r where r.match_id = p_match_id and r.status = 'submitted' for update;
  if not found then
    raise exception 'result: not pending' using errcode = 'P0001';
  end if;
  if v_row.submitted_by_club_id = v_club then
    raise exception 'result: not allowed' using errcode = '42501';
  end if;
  if v_row.version <> coalesce(p_version, -1) then
    raise exception 'result: version changed' using errcode = 'P0001';
  end if;
  if char_length(v_reason) not between 1 and 300 then
    raise exception 'result: invalid reason' using errcode = '22023';
  end if;
  update public.match_results
     set status = 'disputed', decided_by_club_id = v_club, decided_by = v_uid, decided_at = now(),
         dispute_reason = v_reason
   where match_id = p_match_id and version = v_row.version
  returning * into v_row;
  return v_row;
end;
$$;

-- A match's result versions, newest first, as the caller may see them:
-- every version for the two clubs' owners; the confirmed one for their
-- active members. Innings as a JSON array in batting order.
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

-- A club's confirmed results, newest match first, from the club's side —
-- for its owner and active members.
create or replace function public.club_results(p_club_id uuid)
returns table (
  match_id         uuid,
  opponent_club_id uuid,
  opponent_name    text,
  starts_at        timestamptz,
  format           text,
  custom_overs     smallint,
  result           text,
  margin_runs      integer,
  margin_wickets   smallint,
  innings_victory  boolean,
  summary          text,
  version          integer
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'result: not authenticated' using errcode = '42501';
  end if;
  if not (public.is_club_owner(p_club_id) or public.is_active_club_member(p_club_id)) then
    raise exception 'result: not allowed' using errcode = '42501';
  end if;
  return query
    select m.id, o.id, o.name, m.starts_at, m.format, m.custom_overs,
           case r.outcome
             when 'tie' then 'tied'
             when 'no_result' then 'no_result'
             when 'abandoned' then 'abandoned'
             else case when (r.outcome = 'club_a_won') = (m.club_a_id = p_club_id) then 'won' else 'lost' end
           end,
           r.margin_runs, r.margin_wickets, r.innings_victory,
           public.match_result_summary(r.match_id, r.version), r.version
      from public.matches m
      join public.match_results r on r.match_id = m.id and r.status = 'confirmed'
      join public.clubs o on o.id = case when m.club_a_id = p_club_id then m.club_b_id else m.club_a_id end
     where m.club_a_id = p_club_id or m.club_b_id = p_club_id
     order by m.starts_at desc, m.id;
end;
$$;

-- A club's record from its confirmed results.
create or replace function public.club_record(p_club_id uuid)
returns table (played integer, won integer, lost integer, tied integer, no_result integer, abandoned integer)
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::int,
         count(*) filter (where r.result = 'won')::int,
         count(*) filter (where r.result = 'lost')::int,
         count(*) filter (where r.result = 'tied')::int,
         count(*) filter (where r.result = 'no_result')::int,
         count(*) filter (where r.result = 'abandoned')::int
    from public.club_results(p_club_id) r;
$$;

-- ---------------------------------------------------------------------------
-- 5. Privileges
-- ---------------------------------------------------------------------------
revoke execute on function public.match_results_guard_update() from public, anon, authenticated;
revoke execute on function public.match_innings_guard() from public, anon, authenticated;
revoke execute on function public.club_members_forget_match_results() from public, anon, authenticated;
revoke execute on function public.match_format_max_balls(text, integer) from public, anon, authenticated;
revoke execute on function public.match_result_summary(uuid, integer) from public, anon, authenticated;
revoke execute on function public.submit_match_result(uuid, text, jsonb, uuid) from public, anon;
revoke execute on function public.confirm_match_result(uuid, integer) from public, anon;
revoke execute on function public.dispute_match_result(uuid, integer, text) from public, anon;
revoke execute on function public.match_result(uuid) from public, anon;
revoke execute on function public.club_results(uuid) from public, anon;
revoke execute on function public.club_record(uuid) from public, anon;

grant execute on function public.submit_match_result(uuid, text, jsonb, uuid) to authenticated;
grant execute on function public.confirm_match_result(uuid, integer) to authenticated;
grant execute on function public.dispute_match_result(uuid, integer, text) to authenticated;
grant execute on function public.match_result(uuid) to authenticated;
grant execute on function public.club_results(uuid) to authenticated;
grant execute on function public.club_record(uuid) to authenticated;

notify pgrst, 'reload schema';
