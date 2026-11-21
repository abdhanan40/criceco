-- CricEco · migration 21 · match scorecards (M2, P2)
--
-- NOT APPLIED. Requires migration 20 (match results). Review first; apply
-- only with separate approval, after a fresh backup, inside
--   begin; set local lock_timeout = '5s'; <this file> commit;
-- Rollback: supabase/rollback/20261121_rollback_match_scorecards.sql (roll back
-- migration 22 first). Read-only check: supabase/tests/21_match_scorecards_postcheck.sql.
-- Local test: supabase/tests/local/18_match_scorecards_local_check.sql (+ 18b_…sh).
-- Design: docs/MATCH_RESULTS_BACKEND.md.
--
-- Approved M2 decisions this migration implements:
--   2. Batting and bowling scorecards, the second step after innings totals.
--   4. Structured dismissals: type, bowler, fielder, direct hit (fielding stats).
--   5. The submitting owner enters every innings, both clubs' cards.
--   6. Substitutes may field, never bat or bowl.
--   7. Cards belong to a result version and never change.
--   8. A deleted account becomes "Deleted player": name and link dropped,
--      the rows (and the other players' figures) stay.
-- P2 decisions (2026-11-21):
--   * Player pool of a club in a match: its saved line-up (Playing XI bat and
--     bowl; the 4 substitutes may only field) — or, with no line-up, any
--     ACTIVE member of that club. Every entry is linked to a member.
--   * Once a match has started, the owners of BOTH clubs may read both pools
--     (names and member ids only) to enter the cards: match_player_pool().
--     Before the start, an owner sees only their own club's pool, as in M1.
--   * Scorecards are optional and all-or-nothing: a result is totals-only, or
--     every innings carries its batting AND bowling card, adding up to the
--     innings totals.
--
-- A result with cards is submitted by submit_match_result_with_scorecard(),
-- which runs migration 20's submit_match_result() and then stores the cards
-- in the SAME transaction: any invalid card refuses the whole submission.
-- Confirm / dispute are unchanged (migration 20).
-- RLS: SELECT only, exactly like match_innings. No direct writes.

do $$
begin
  if to_regclass('public.match_results') is null or to_regclass('public.match_innings') is null
     or to_regprocedure('public.submit_match_result(uuid, text, jsonb, uuid)') is null then
    raise exception 'migration 21: migration 20 (match results) is required';
  end if;
  if to_regclass('public.match_batting') is not null or to_regclass('public.match_bowling') is not null
     or exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public'
                   and p.proname in ('match_scorecards_guard', 'club_members_forget_match_scorecards',
                                     'match_bowler_max_balls', 'match_dismissal_text', 'match_club_player_pool',
                                     'match_player_pool', 'submit_match_result_with_scorecard',
                                     'match_scorecard')) then
    raise exception 'migration 21: already applied (or a name is taken) — nothing changed';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
-- The bowling card of one innings, in bowling order (bowler_no 1–11).
create table public.match_bowling (
  match_id        uuid not null,
  version         integer not null,
  innings_no      smallint not null,
  bowler_no       smallint not null
                  constraint match_bowling_bowler_no_check check (bowler_no between 1 and 11),
  member_id       uuid
                  constraint match_bowling_member_id_fkey references public.club_members (id) on delete set null,
  -- The player's name when the card was submitted; null once deleted.
  player_name     text
                  constraint match_bowling_player_name_check
                  check (player_name is null or char_length(player_name) between 1 and 100),
  player_deleted  boolean not null default false,
  balls           integer not null constraint match_bowling_balls_check check (balls between 0 and 3000),
  maidens         smallint not null default 0 constraint match_bowling_maidens_check check (maidens >= 0),
  runs            integer not null constraint match_bowling_runs_check check (runs between 0 and 2000),
  -- Computed from the batting card's dismissals credited to this bowler.
  wickets         smallint not null default 0 constraint match_bowling_wickets_check check (wickets between 0 and 10),
  wides           smallint not null default 0 constraint match_bowling_wides_check check (wides >= 0),
  no_balls        smallint not null default 0 constraint match_bowling_no_balls_check check (no_balls >= 0),
  constraint match_bowling_pkey primary key (match_id, version, innings_no, bowler_no),
  constraint match_bowling_innings_fkey foreign key (match_id, version, innings_no)
    references public.match_innings (match_id, version, innings_no) on delete cascade,
  constraint match_bowling_one_row_per_player unique (match_id, version, innings_no, member_id),
  constraint match_bowling_maidens_within_overs check (maidens * 6 <= balls),
  constraint match_bowling_extras_within_runs check (wides + no_balls <= runs),
  -- Only account deletion drops the link, and then the name too.
  constraint match_bowling_player_link
    check ((member_id is null) = player_deleted and (player_name is null) = player_deleted)
);

comment on table public.match_bowling is
  'Bowling cards of a match result version (M2). Written only by submit_match_result_with_scorecard (migration 21).';

-- The batting card of one innings, in batting order (position 1–11).
create table public.match_batting (
  match_id            uuid not null,
  version             integer not null,
  innings_no          smallint not null,
  position            smallint not null
                      constraint match_batting_position_check check (position between 1 and 11),
  member_id           uuid
                      constraint match_batting_member_id_fkey references public.club_members (id) on delete set null,
  player_name         text
                      constraint match_batting_player_name_check
                      check (player_name is null or char_length(player_name) between 1 and 100),
  player_deleted      boolean not null default false,
  runs                integer not null default 0 constraint match_batting_runs_check check (runs between 0 and 2000),
  balls               integer not null default 0 constraint match_batting_balls_check check (balls between 0 and 3000),
  fours               smallint not null default 0 constraint match_batting_fours_check check (fours >= 0),
  sixes               smallint not null default 0 constraint match_batting_sixes_check check (sixes >= 0),
  dismissal           text not null
                      constraint match_batting_dismissal_check
                      check (dismissal in ('not_out', 'did_not_bat', 'retired_hurt', 'retired_out', 'bowled', 'caught',
                                           'lbw', 'run_out', 'stumped', 'hit_wicket', 'obstructing_field',
                                           'hit_ball_twice', 'timed_out')),
  -- The bowler credited with the wicket: a row of this innings' bowling card.
  bowler_no           smallint,
  -- Catch, stumping or run out: a player of the fielding club (a substitute
  -- may field); null name once deleted.
  fielder_member_id   uuid
                      constraint match_batting_fielder_member_id_fkey references public.club_members (id) on delete set null,
  fielder_name        text
                      constraint match_batting_fielder_name_check
                      check (fielder_name is null or char_length(fielder_name) between 1 and 100),
  fielder_deleted     boolean not null default false,
  fielder_substitute  boolean not null default false,
  direct_hit          boolean not null default false,
  constraint match_batting_pkey primary key (match_id, version, innings_no, position),
  constraint match_batting_innings_fkey foreign key (match_id, version, innings_no)
    references public.match_innings (match_id, version, innings_no) on delete cascade,
  constraint match_batting_bowler_fkey foreign key (match_id, version, innings_no, bowler_no)
    references public.match_bowling (match_id, version, innings_no, bowler_no) on delete cascade,
  constraint match_batting_one_row_per_player unique (match_id, version, innings_no, member_id),
  constraint match_batting_boundaries_within_runs check (fours * 4 + sixes * 6 <= runs),
  constraint match_batting_did_not_bat_is_empty
    check (dismissal <> 'did_not_bat' or (runs = 0 and balls = 0 and fours = 0 and sixes = 0)),
  constraint match_batting_bowler_when_credited
    check ((bowler_no is not null) = (dismissal in ('bowled', 'caught', 'lbw', 'stumped', 'hit_wicket'))),
  constraint match_batting_fielder_when_needed
    check (dismissal not in ('caught', 'stumped') or fielder_member_id is not null or fielder_deleted),
  constraint match_batting_fielder_only_when_fielded
    check (dismissal in ('caught', 'run_out', 'stumped')
           or (fielder_member_id is null and fielder_name is null and not fielder_deleted and not fielder_substitute)),
  constraint match_batting_direct_hit_only_run_out check (not direct_hit or dismissal = 'run_out'),
  constraint match_batting_player_link
    check ((member_id is null) = player_deleted and (player_name is null) = player_deleted),
  constraint match_batting_fielder_link
    check (not fielder_deleted or (fielder_member_id is null and fielder_name is null)),
  constraint match_batting_fielder_named check (fielder_member_id is null or fielder_name is not null)
);

comment on table public.match_batting is
  'Batting cards of a match result version (M2). Written only by submit_match_result_with_scorecard (migration 21).';

-- Account deletion and the statistics (migration 22) look players up by member.
create index match_batting_member_idx on public.match_batting (member_id) where member_id is not null;
create index match_batting_fielder_idx on public.match_batting (fielder_member_id) where fielder_member_id is not null;
create index match_bowling_member_idx on public.match_bowling (member_id) where member_id is not null;

-- ---------------------------------------------------------------------------
-- 2. Integrity triggers (defence in depth)
-- ---------------------------------------------------------------------------
-- Cards are written once, while their version waits for the other club, and
-- never change — except that account deletion drops a person's name and link.
-- Every player belongs to the right club of the match: batters to the batting
-- club; bowlers and fielders to the fielding club.
create or replace function public.match_scorecards_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_fixed text[];
  v_inn   public.match_innings;
begin
  if tg_op = 'UPDATE' then
    v_fixed := case tg_table_name
                 when 'match_batting' then array['member_id', 'player_name', 'player_deleted',
                                                 'fielder_member_id', 'fielder_name', 'fielder_deleted']
                 else array['member_id', 'player_name', 'player_deleted'] end;
    if (to_jsonb(new) - v_fixed) is distinct from (to_jsonb(old) - v_fixed)
       or (new.member_id is not null and new.member_id is distinct from old.member_id)
       or (new.player_name is not null and new.player_name is distinct from old.player_name)
       or (old.player_deleted and not new.player_deleted)
       or (tg_table_name = 'match_batting'
           and ((to_jsonb(new) ->> 'fielder_member_id') is not null
                and (to_jsonb(new) ->> 'fielder_member_id') is distinct from (to_jsonb(old) ->> 'fielder_member_id')
                or (to_jsonb(new) ->> 'fielder_name') is not null
                   and (to_jsonb(new) ->> 'fielder_name') is distinct from (to_jsonb(old) ->> 'fielder_name')
                or (to_jsonb(old) ->> 'fielder_deleted')::boolean and not (to_jsonb(new) ->> 'fielder_deleted')::boolean)) then
      raise exception 'result: invalid transition' using errcode = '23514';
    end if;
    return new;
  end if;
  select i.* into v_inn
    from public.match_innings i
    join public.match_results r on r.match_id = i.match_id and r.version = i.version and r.status = 'submitted'
   where i.match_id = new.match_id and i.version = new.version and i.innings_no = new.innings_no;
  if not found
     or not exists (select 1 from public.club_members m
                     where m.id = new.member_id
                       and m.club_id = case tg_table_name when 'match_batting' then v_inn.batting_club_id
                                                          else v_inn.bowling_club_id end)
     or (tg_table_name = 'match_batting' and (to_jsonb(new) ->> 'fielder_member_id') is not null
         and not exists (select 1 from public.club_members m
                          where m.id = (to_jsonb(new) ->> 'fielder_member_id')::uuid
                            and m.club_id = v_inn.bowling_club_id)) then
    raise exception 'result: invalid scorecard' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger match_bowling_guard
  before insert or update on public.match_bowling
  for each row execute function public.match_scorecards_guard();
create trigger match_batting_guard
  before insert or update on public.match_batting
  for each row execute function public.match_scorecards_guard();

-- Account deletion (decision 8): "Deleted player" on every card row; the
-- figures stay. BEFORE DELETE, so it runs before the foreign keys clear the
-- links.
create or replace function public.club_members_forget_match_scorecards()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.match_batting b
     set member_id = null, player_name = null, player_deleted = true
   where b.member_id = old.id;
  update public.match_batting b
     set fielder_member_id = null, fielder_name = null, fielder_deleted = true
   where b.fielder_member_id = old.id;
  update public.match_bowling w
     set member_id = null, player_name = null, player_deleted = true
   where w.member_id = old.id;
  return old;
end;
$$;

create trigger club_members_forget_match_scorecards
  before delete on public.club_members
  for each row execute function public.club_members_forget_match_scorecards();

-- ---------------------------------------------------------------------------
-- 3. Row level security (read only; exactly like match_innings)
-- ---------------------------------------------------------------------------
alter table public.match_batting enable row level security;
alter table public.match_bowling enable row level security;

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

revoke all on table public.match_batting, public.match_bowling from public, anon, authenticated;
grant select on table public.match_batting, public.match_bowling to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Functions
-- ---------------------------------------------------------------------------
-- Errors (prefix "result:" · SQLSTATE): as migration 20, plus
--   invalid scorecard (22023: shape, players, dismissals, or the cards don't
--   add up to the innings totals; 23514 from the guard trigger).

-- The most legal balls ONE bowler may bowl in [p_format]: T10 2 overs,
-- T20 4, ODI 10, custom a fifth of the overs (rounded up); Test no limit.
create or replace function public.match_bowler_max_balls(p_format text, p_custom_overs integer)
returns integer
language sql
immutable
set search_path = ''
as $$
  select case p_format
           when 't10' then 12
           when 't20' then 24
           when 'odi' then 60
           when 'custom' then ceil(coalesce(p_custom_overs, 50) / 5.0)::int * 6
           else null
         end;
$$;

-- "c Ali b Khan" / "c & b Khan" / "c sub (Ali) b Khan" / "b Khan" /
-- "lbw b Khan" / "st Ali b Khan" / "hit wicket b Khan" / "run out (Ali)" /
-- "not out" / "did not bat" / "retired hurt" / … Names already resolved
-- ("Deleted player" for a deleted account).
create or replace function public.match_dismissal_text(p_dismissal text, p_bowler text, p_fielder text,
                                                       p_substitute boolean, p_caught_and_bowled boolean)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_dismissal
           when 'not_out' then 'not out'
           when 'did_not_bat' then 'did not bat'
           when 'retired_hurt' then 'retired hurt'
           when 'retired_out' then 'retired out'
           when 'bowled' then 'b ' || p_bowler
           when 'lbw' then 'lbw b ' || p_bowler
           when 'hit_wicket' then 'hit wicket b ' || p_bowler
           when 'caught' then
             case when p_caught_and_bowled then 'c & b ' || p_bowler
                  when p_substitute then 'c sub (' || p_fielder || ') b ' || p_bowler
                  else 'c ' || p_fielder || ' b ' || p_bowler end
           when 'stumped' then
             case when p_substitute then 'st sub (' || p_fielder || ') b ' || p_bowler
                  else 'st ' || p_fielder || ' b ' || p_bowler end
           when 'run_out' then
             case when p_fielder is null then 'run out'
                  when p_substitute then 'run out (sub (' || p_fielder || '))'
                  else 'run out (' || p_fielder || ')' end
           when 'obstructing_field' then 'obstructing the field'
           when 'hit_ball_twice' then 'hit the ball twice'
           when 'timed_out' then 'timed out'
         end;
$$;

-- The players [p_club_id] may field in [p_match_id]: its saved line-up
-- (selection 'playing' / 'sub', in pick order), or — with no line-up — its
-- active members (selection 'member', by name). No access check: internal.
create or replace function public.match_club_player_pool(p_match_id uuid, p_club_id uuid)
returns table (member_id uuid, full_name text, selection text, pick_order smallint)
language sql
stable
security definer
set search_path = ''
as $$
  select lp.member_id, left(coalesce(nullif(btrim(p.full_name), ''), 'Unnamed player'), 100), lp.selection, lp.position
    from public.match_lineup_players lp
    join public.club_members m on m.id = lp.member_id
    join public.profiles p on p.id = m.user_id
   where lp.match_id = p_match_id and lp.club_id = p_club_id
  union all
  select m.id, left(coalesce(nullif(btrim(p.full_name), ''), 'Unnamed player'), 100), 'member', null::smallint
    from public.club_members m
    join public.profiles p on p.id = m.user_id
   where m.club_id = p_club_id and m.status = 'active'
     and not exists (select 1 from public.match_lineups l where l.match_id = p_match_id and l.club_id = p_club_id);
$$;

-- The players an owner of either club may put on the cards of [p_match_id]:
-- their own club's pool always; the other club's once the match has started
-- (confirmed or completed, start time passed). Names and member ids only.
create or replace function public.match_player_pool(p_match_id uuid)
returns table (club_id uuid, member_id uuid, full_name text, selection text, pick_order smallint)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_match   public.matches;
  v_my      uuid;
  v_started boolean;
begin
  if v_uid is null then
    raise exception 'result: not authenticated' using errcode = '42501';
  end if;
  select * into v_match from public.matches m where m.id = p_match_id;
  if not found then
    raise exception 'result: not found' using errcode = 'P0002';
  end if;
  select c.id into v_my from public.clubs c where c.id in (v_match.club_a_id, v_match.club_b_id) and c.owner_id = v_uid;
  if v_my is null then
    raise exception 'result: not allowed' using errcode = '42501';
  end if;
  v_started := v_match.status in ('confirmed', 'completed') and v_match.starts_at is not null and v_match.starts_at <= now();
  return query
    select c.id, p.member_id, p.full_name, p.selection, p.pick_order
      from unnest(array[v_match.club_a_id, v_match.club_b_id]) as c(id)
     cross join lateral public.match_club_player_pool(p_match_id, c.id) p
     where c.id = v_my or v_started
     order by c.id = v_my desc, p.pick_order nulls last, p.full_name, p.member_id;
end;
$$;

-- Submits a result WITH its scorecards: migration 20's submit_match_result
-- (same rules, same locking), then the cards, in one transaction. Each
-- innings object of p_innings may carry
--   "batting": [{"member_id": "…", "runs": 54, "balls": 38, "fours": 6, "sixes": 1,
--                "dismissal": "caught", "bowler_member_id": "…", "fielder_member_id": "…",
--                "direct_hit": false}, …]   (batting order, 1–11 rows)
--   "bowling": [{"member_id": "…", "balls": 24, "maidens": 0, "runs": 31,
--                "wides": 2, "no_balls": 1, "wickets": 2}, …]   (bowling order, 1–11 rows)
-- Either no innings carries cards (a totals-only result) or every innings
-- carries both. Dismissals: not_out, did_not_bat, retired_hurt, retired_out,
-- bowled, caught, lbw, run_out, stumped, hit_wicket, obstructing_field,
-- hit_ball_twice, timed_out. Bowler: required for bowled / caught / lbw /
-- stumped / hit_wicket (a bowler of this innings), never otherwise.
-- Fielder: required for caught / stumped, optional for run_out, never
-- otherwise; a substitute may field. "wickets" on a bowling row is optional
-- and, when given, must equal the dismissals credited to that bowler.
-- The cards must add up: batters' runs + extras = innings runs; bowlers'
-- balls = innings balls; bowlers' runs = innings runs − byes − leg byes −
-- penalty; bowlers' wides / no balls = the innings'; dismissals = wickets.
create or replace function public.submit_match_result_with_scorecard(
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
  c_uuid       constant text := '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';
  c_dismissals constant text[] := array['not_out', 'did_not_bat', 'retired_hurt', 'retired_out', 'bowled', 'caught',
                                        'lbw', 'run_out', 'stumped', 'hit_wicket', 'obstructing_field',
                                        'hit_ball_twice', 'timed_out'];
  c_not_out    constant text[] := array['not_out', 'did_not_bat', 'retired_hurt'];
  c_credited   constant text[] := array['bowled', 'caught', 'lbw', 'stumped', 'hit_wicket'];
  v_row        public.match_results;
  v_match      public.matches;
  v_cards      integer;
  v_max_bowler integer;
  i            public.match_innings;
  v_bat        jsonb;
  v_bowl       jsonb;
  v_outs       integer;
  v_batted     integer;
  v_not_out    integer;
  v_bat_runs   integer;
begin
  -- The result and its innings, exactly as migration 20 checks them (this
  -- also locks the match row and checks the caller).
  v_row := public.submit_match_result(p_match_id, p_outcome, p_innings, p_player_of_match_member_id);

  select count(*) filter (where x ? 'batting' or x ? 'bowling') into v_cards from jsonb_array_elements(p_innings) x;
  if v_cards = 0 then
    return v_row; -- totals only
  end if;
  if v_cards <> jsonb_array_length(p_innings)
     or exists (select 1 from jsonb_array_elements(p_innings) x
                 where jsonb_typeof(x -> 'batting') is distinct from 'array'
                    or jsonb_typeof(x -> 'bowling') is distinct from 'array') then
    raise exception 'result: invalid scorecard' using errcode = '22023';
  end if;
  select * into v_match from public.matches m where m.id = p_match_id;
  v_max_bowler := public.match_bowler_max_balls(v_match.format, v_match.custom_overs);

  for i in select * from public.match_innings mi
            where mi.match_id = p_match_id and mi.version = v_row.version order by mi.innings_no loop
    v_bat := p_innings -> (i.innings_no - 1) -> 'batting';
    v_bowl := p_innings -> (i.innings_no - 1) -> 'bowling';

    -- The shape first (no cast can fail after it)…
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

    -- … the bowling card: the fielding club's players (no substitutes), once
    -- each, within the format's overs per bowler, adding up to the innings …
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

    -- … and the batting card: the batting club's players (no substitutes),
    -- once each, structured dismissals, adding up to the innings.
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
       -- A bowler's "wickets", when given, are the dismissals credited to them.
       or exists (select 1 from jsonb_array_elements(v_bowl) w
                   where jsonb_typeof(w -> 'wickets') = 'number'
                     and (w ->> 'wickets')::int <> (select count(*) from jsonb_array_elements(v_bat) b
                                                     where (b ->> 'bowler_member_id')::uuid = (w ->> 'member_id')::uuid
                                                       and lower(b ->> 'dismissal') = any (c_credited))) then
      raise exception 'result: invalid scorecard' using errcode = '22023';
    end if;
    -- The batting card adds up: dismissals = wickets; at least wickets + 1
    -- batted (the not-out partner); at most two not out; batters' runs +
    -- extras = the innings' runs.
    select count(*) filter (where lower(b ->> 'dismissal') <> all (c_not_out)),
           count(*) filter (where lower(b ->> 'dismissal') <> 'did_not_bat'),
           count(*) filter (where lower(b ->> 'dismissal') = 'not_out'),
           coalesce(sum(coalesce((b ->> 'runs')::int, 0)), 0)
      into v_outs, v_batted, v_not_out, v_bat_runs
      from jsonb_array_elements(v_bat) b;
    if v_outs <> i.wickets or v_batted < i.wickets + 1 or v_not_out > 2
       or v_bat_runs <> i.runs - i.byes - i.leg_byes - i.wides - i.no_balls - i.penalty then
      raise exception 'result: invalid scorecard' using errcode = '22023';
    end if;

    insert into public.match_bowling (match_id, version, innings_no, bowler_no, member_id, player_name,
                                      balls, maidens, runs, wickets, wides, no_balls)
    select p_match_id, v_row.version, i.innings_no, t.n::smallint, p.member_id, p.full_name,
           (t.b ->> 'balls')::int, coalesce((t.b ->> 'maidens')::smallint, 0), (t.b ->> 'runs')::int,
           (select count(*) from jsonb_array_elements(v_bat) x
             where (x ->> 'bowler_member_id')::uuid = p.member_id and lower(x ->> 'dismissal') = any (c_credited))::smallint,
           coalesce((t.b ->> 'wides')::smallint, 0), coalesce((t.b ->> 'no_balls')::smallint, 0)
      from jsonb_array_elements(v_bowl) with ordinality as t(b, n)
      join public.match_club_player_pool(p_match_id, i.bowling_club_id) p on p.member_id = (t.b ->> 'member_id')::uuid;

    insert into public.match_batting (match_id, version, innings_no, position, member_id, player_name, runs, balls,
                                      fours, sixes, dismissal, bowler_no, fielder_member_id, fielder_name,
                                      fielder_substitute, direct_hit)
    select p_match_id, v_row.version, i.innings_no, t.n::smallint, p.member_id, p.full_name,
           coalesce((t.b ->> 'runs')::int, 0), coalesce((t.b ->> 'balls')::int, 0),
           coalesce((t.b ->> 'fours')::smallint, 0), coalesce((t.b ->> 'sixes')::smallint, 0),
           lower(t.b ->> 'dismissal'),
           (select w.bowler_no from public.match_bowling w
             where w.match_id = p_match_id and w.version = v_row.version and w.innings_no = i.innings_no
               and w.member_id = (t.b ->> 'bowler_member_id')::uuid),
           f.member_id, f.full_name, coalesce(f.selection = 'sub', false),
           coalesce((t.b ->> 'direct_hit')::boolean, false)
      from jsonb_array_elements(v_bat) with ordinality as t(b, n)
      join public.match_club_player_pool(p_match_id, i.batting_club_id) p on p.member_id = (t.b ->> 'member_id')::uuid
      left join public.match_club_player_pool(p_match_id, i.bowling_club_id) f
        on f.member_id = (t.b ->> 'fielder_member_id')::uuid;
  end loop;

  return v_row;
end;
$$;

-- The scorecards of one result version, innings by innings, as JSON arrays:
-- [p_version] null = the confirmed result. Owners of either club see any
-- version; their active members the confirmed one only (other versions:
-- no rows). Deleted players: name null, "deleted" true; the dismissal text
-- says "Deleted player".
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

-- ---------------------------------------------------------------------------
-- 5. Privileges
-- ---------------------------------------------------------------------------
revoke execute on function public.match_scorecards_guard() from public, anon, authenticated;
revoke execute on function public.club_members_forget_match_scorecards() from public, anon, authenticated;
revoke execute on function public.match_bowler_max_balls(text, integer) from public, anon, authenticated;
revoke execute on function public.match_dismissal_text(text, text, text, boolean, boolean) from public, anon, authenticated;
revoke execute on function public.match_club_player_pool(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.match_player_pool(uuid) from public, anon;
revoke execute on function public.submit_match_result_with_scorecard(uuid, text, jsonb, uuid) from public, anon;
revoke execute on function public.match_scorecard(uuid, integer) from public, anon;

grant execute on function public.match_player_pool(uuid) to authenticated;
grant execute on function public.submit_match_result_with_scorecard(uuid, text, jsonb, uuid) to authenticated;
grant execute on function public.match_scorecard(uuid, integer) to authenticated;

notify pgrst, 'reload schema';
