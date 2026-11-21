-- CricEco · migration 22 · player statistics (M2, P2)
--
-- NOT APPLIED. Requires migration 21 (scorecards). Review first; apply only
-- with separate approval, after a fresh backup, inside
--   begin; set local lock_timeout = '5s'; <this file> commit;
-- Rollback: supabase/rollback/20261121_rollback_player_stats.sql (roll back
-- migration 23 first). Read-only check: supabase/tests/22_player_stats_postcheck.sql.
-- Local test: supabase/tests/local/19_player_stats_local_check.sql.
-- Design: docs/MATCH_RESULTS_BACKEND.md.
--
-- Statistics are computed on read from CONFIRMED results only (superseded,
-- disputed and waiting versions never count). Nothing is stored, so a
-- confirmed correction changes the figures at once. Approved M2 decisions:
--   4. Fielding from structured dismissals: catches (c & b included), run
--      outs, direct hits, stumpings.
--   8. A deleted account's rows no longer link to anyone: its figures leave
--      every statistic; the other players' figures stay.
--   9. Visible to the player, and to the owners and active members of the
--      clubs the player is an active member of.
--  10. No rating, skill or "verified" figure on the server.
-- A player is linked by member: career figures add up every membership
-- (any club, any status) of the same account.
--
-- Definitions: an innings is a batting row other than "did not bat"; not
-- outs are "not out" and "retired hurt"; batting average = runs / (innings −
-- not outs); strike rate = runs × 100 / balls; a duck = 0 and dismissed;
-- 50s = 50–99, 100s = 100+. Bowling: an innings is a bowling row with at
-- least one ball; average = runs / wickets; economy = runs × 6 / balls;
-- strike rate = balls / wickets; best = most wickets, then fewest runs, in
-- one innings. Matches = confirmed matches with any batting, bowling or
-- fielding row or a Player of the Match award. Averages are rounded to 2
-- places; null when the divisor is 0.

do $$
begin
  if to_regclass('public.match_batting') is null or to_regclass('public.match_bowling') is null then
    raise exception 'migration 22: migration 21 (scorecards) is required';
  end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public'
                and p.proname in ('member_stats', 'can_view_player_stats', 'player_stats', 'club_member_stats',
                                  'player_match_log')) then
    raise exception 'migration 22: already applied (or a name is taken) — nothing changed';
  end if;
end $$;

-- Errors (prefix "stats:" · SQLSTATE): not authenticated / not allowed (42501).

-- The figures of the given memberships in confirmed results. Internal: no
-- access check.
create or replace function public.member_stats(p_member_ids uuid[])
returns table (
  matches             integer,
  bat_innings         integer,
  not_outs            integer,
  runs                integer,
  balls_faced         integer,
  batting_average     numeric,
  strike_rate         numeric,
  highest             integer,
  highest_not_out     boolean,
  fifties             integer,
  hundreds            integer,
  ducks               integer,
  fours               integer,
  sixes               integer,
  bowl_innings        integer,
  balls_bowled        integer,
  maidens             integer,
  runs_conceded       integer,
  wickets             integer,
  bowling_average     numeric,
  economy             numeric,
  bowling_strike_rate numeric,
  best_wickets        integer,
  best_runs           integer,
  five_wickets        integer,
  catches             integer,
  run_outs            integer,
  direct_hits         integer,
  stumpings           integer,
  player_of_match     integer
)
language sql
stable
security definer
set search_path = ''
as $$
  with bat as (
    select b.match_id, b.runs, b.balls, b.fours, b.sixes, b.dismissal
      from public.match_batting b
      join public.match_results r on r.match_id = b.match_id and r.version = b.version and r.status = 'confirmed'
     where b.member_id = any (p_member_ids)
  ), bowl as (
    select w.match_id, w.balls, w.maidens, w.runs, w.wickets
      from public.match_bowling w
      join public.match_results r on r.match_id = w.match_id and r.version = w.version and r.status = 'confirmed'
     where w.member_id = any (p_member_ids)
  ), fld as (
    select b.match_id, b.dismissal, b.direct_hit
      from public.match_batting b
      join public.match_results r on r.match_id = b.match_id and r.version = b.version and r.status = 'confirmed'
     where b.fielder_member_id = any (p_member_ids)
  ), pom as (
    select r.match_id from public.match_results r
     where r.status = 'confirmed' and r.player_of_match_member_id = any (p_member_ids)
  ), bs as (
    select count(*) filter (where dismissal <> 'did_not_bat') as inns,
           count(*) filter (where dismissal in ('not_out', 'retired_hurt')) as nos,
           coalesce(sum(runs), 0) as runs, coalesce(sum(balls), 0) as balls,
           max(runs) filter (where dismissal <> 'did_not_bat') as hi,
           count(*) filter (where runs between 50 and 99) as fifties,
           count(*) filter (where runs >= 100) as hundreds,
           count(*) filter (where runs = 0 and dismissal not in ('not_out', 'did_not_bat', 'retired_hurt')) as ducks,
           coalesce(sum(fours), 0) as fours, coalesce(sum(sixes), 0) as sixes
      from bat
  ), ws as (
    select count(*) filter (where balls > 0) as inns, coalesce(sum(balls), 0) as balls,
           coalesce(sum(maidens), 0) as maidens, coalesce(sum(runs), 0) as runs,
           coalesce(sum(wickets), 0) as wkts, count(*) filter (where wickets >= 5) as fives
      from bowl
  )
  select (select count(*) from (select match_id from bat union select match_id from bowl
                                union select match_id from fld union select match_id from pom) a)::int,
         bs.inns::int, bs.nos::int, bs.runs::int, bs.balls::int,
         round(bs.runs::numeric / nullif(bs.inns - bs.nos, 0), 2),
         round(bs.runs * 100.0 / nullif(bs.balls, 0), 2),
         bs.hi::int,
         case when bs.hi is null then null
              else exists (select 1 from bat where bat.runs = bs.hi and bat.dismissal in ('not_out', 'retired_hurt')) end,
         bs.fifties::int, bs.hundreds::int, bs.ducks::int, bs.fours::int, bs.sixes::int,
         ws.inns::int, ws.balls::int, ws.maidens::int, ws.runs::int, ws.wkts::int,
         round(ws.runs::numeric / nullif(ws.wkts, 0), 2),
         round(ws.runs * 6.0 / nullif(ws.balls, 0), 2),
         round(ws.balls::numeric / nullif(ws.wkts, 0), 2),
         (select bowl.wickets from bowl where bowl.balls > 0 order by bowl.wickets desc, bowl.runs limit 1)::int,
         (select bowl.runs from bowl where bowl.balls > 0 order by bowl.wickets desc, bowl.runs limit 1)::int,
         ws.fives::int,
         (select count(*) from fld where fld.dismissal = 'caught')::int,
         (select count(*) from fld where fld.dismissal = 'run_out')::int,
         (select count(*) from fld where fld.dismissal = 'run_out' and fld.direct_hit)::int,
         (select count(*) from fld where fld.dismissal = 'stumped')::int,
         (select count(*) from pom)::int
    from bs, ws;
$$;

-- May the caller see [p_user_id]'s statistics? The player themself, or an
-- owner / active member of a club the player is an active member of.
create or replace function public.can_view_player_stats(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select (select auth.uid()) is not null
         and ((select auth.uid()) = p_user_id
              or exists (select 1 from public.club_members t
                          where t.user_id = p_user_id and t.status = 'active'
                            and (public.is_club_owner(t.club_id) or public.is_active_club_member(t.club_id))));
$$;

-- A player's career statistics (every club). [p_user_id] null = the caller.
create or replace function public.player_stats(p_user_id uuid default null)
returns table (
  matches             integer,
  bat_innings         integer,
  not_outs            integer,
  runs                integer,
  balls_faced         integer,
  batting_average     numeric,
  strike_rate         numeric,
  highest             integer,
  highest_not_out     boolean,
  fifties             integer,
  hundreds            integer,
  ducks               integer,
  fours               integer,
  sixes               integer,
  bowl_innings        integer,
  balls_bowled        integer,
  maidens             integer,
  runs_conceded       integer,
  wickets             integer,
  bowling_average     numeric,
  economy             numeric,
  bowling_strike_rate numeric,
  best_wickets        integer,
  best_runs           integer,
  five_wickets        integer,
  catches             integer,
  run_outs            integer,
  direct_hits         integer,
  stumpings           integer,
  player_of_match     integer
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_target uuid := coalesce(p_user_id, auth.uid());
begin
  if v_uid is null then
    raise exception 'stats: not authenticated' using errcode = '42501';
  end if;
  if not public.can_view_player_stats(v_target) then
    raise exception 'stats: not allowed' using errcode = '42501';
  end if;
  return query
    select s.* from public.member_stats(array(select m.id from public.club_members m where m.user_id = v_target)) s;
end;
$$;

-- The squad's statistics in [p_club_id]'s matches: one row per active member,
-- by name — for the club's owner and active members.
create or replace function public.club_member_stats(p_club_id uuid)
returns table (
  member_id           uuid,
  full_name           text,
  member_role         text,
  matches             integer,
  bat_innings         integer,
  not_outs            integer,
  runs                integer,
  balls_faced         integer,
  batting_average     numeric,
  strike_rate         numeric,
  highest             integer,
  highest_not_out     boolean,
  fifties             integer,
  hundreds            integer,
  ducks               integer,
  fours               integer,
  sixes               integer,
  bowl_innings        integer,
  balls_bowled        integer,
  maidens             integer,
  runs_conceded       integer,
  wickets             integer,
  bowling_average     numeric,
  economy             numeric,
  bowling_strike_rate numeric,
  best_wickets        integer,
  best_runs           integer,
  five_wickets        integer,
  catches             integer,
  run_outs            integer,
  direct_hits         integer,
  stumpings           integer,
  player_of_match     integer
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'stats: not authenticated' using errcode = '42501';
  end if;
  if not (public.is_club_owner(p_club_id) or public.is_active_club_member(p_club_id)) then
    raise exception 'stats: not allowed' using errcode = '42501';
  end if;
  return query
    select m.id, btrim(p.full_name), m.member_role, s.*
      from public.club_members m
      join public.profiles p on p.id = m.user_id
     cross join lateral public.member_stats(array[m.id]) s
     where m.club_id = p_club_id and m.status = 'active'
     order by btrim(p.full_name), m.id;
end;
$$;

-- A player's confirmed matches, newest first (at most p_limit, 1–200): the
-- club they played for, the opponent, the result from their side, and their
-- own figures in that match (summed over a Test's two innings).
create or replace function public.player_match_log(p_user_id uuid default null, p_limit integer default 50)
returns table (
  match_id         uuid,
  starts_at        timestamptz,
  format           text,
  custom_overs     smallint,
  club_id          uuid,
  club_name        text,
  opponent_club_id uuid,
  opponent_name    text,
  result           text,
  summary          text,
  bat_innings      integer,
  bat_runs         integer,
  bat_balls        integer,
  bat_fours        integer,
  bat_sixes        integer,
  bat_outs         integer,
  bowl_balls       integer,
  bowl_maidens     integer,
  bowl_runs        integer,
  bowl_wickets     integer,
  catches          integer,
  run_outs         integer,
  stumpings        integer,
  player_of_match  boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_target uuid := coalesce(p_user_id, auth.uid());
begin
  if v_uid is null then
    raise exception 'stats: not authenticated' using errcode = '42501';
  end if;
  if not public.can_view_player_stats(v_target) then
    raise exception 'stats: not allowed' using errcode = '42501';
  end if;
  return query
    with mine as (
      select m.id as member_id, m.club_id from public.club_members m where m.user_id = v_target
    ), apps as (
      select distinct r.match_id, r.version, mine.member_id, mine.club_id
        from public.match_results r
        join mine on true
       where r.status = 'confirmed'
         and (r.player_of_match_member_id = mine.member_id
              or exists (select 1 from public.match_batting b
                          where b.match_id = r.match_id and b.version = r.version
                            and (b.member_id = mine.member_id or b.fielder_member_id = mine.member_id))
              or exists (select 1 from public.match_bowling w
                          where w.match_id = r.match_id and w.version = r.version and w.member_id = mine.member_id))
    )
    select a.match_id, mt.starts_at, mt.format, mt.custom_overs, a.club_id, c.name, o.id, o.name,
           case rr.outcome
             when 'tie' then 'tied'
             when 'no_result' then 'no_result'
             when 'abandoned' then 'abandoned'
             else case when (rr.outcome = 'club_a_won') = (mt.club_a_id = a.club_id) then 'won' else 'lost' end
           end,
           public.match_result_summary(a.match_id, a.version),
           bt.inns, bt.runs, bt.balls, bt.fours, bt.sixes, bt.outs,
           bw.balls, bw.maidens, bw.runs, bw.wkts,
           fd.catches, fd.run_outs, fd.stumpings,
           rr.player_of_match_member_id is not distinct from a.member_id
      from apps a
      join public.matches mt on mt.id = a.match_id
      join public.match_results rr on rr.match_id = a.match_id and rr.version = a.version
      join public.clubs c on c.id = a.club_id
      join public.clubs o on o.id = case when mt.club_a_id = a.club_id then mt.club_b_id else mt.club_a_id end
     cross join lateral (
       select count(*) filter (where b.dismissal <> 'did_not_bat')::int as inns,
              coalesce(sum(b.runs), 0)::int as runs, coalesce(sum(b.balls), 0)::int as balls,
              coalesce(sum(b.fours), 0)::int as fours, coalesce(sum(b.sixes), 0)::int as sixes,
              count(*) filter (where b.dismissal not in ('not_out', 'did_not_bat', 'retired_hurt'))::int as outs
         from public.match_batting b
        where b.match_id = a.match_id and b.version = a.version and b.member_id = a.member_id) bt
     cross join lateral (
       select coalesce(sum(w.balls), 0)::int as balls, coalesce(sum(w.maidens), 0)::int as maidens,
              coalesce(sum(w.runs), 0)::int as runs, coalesce(sum(w.wickets), 0)::int as wkts
         from public.match_bowling w
        where w.match_id = a.match_id and w.version = a.version and w.member_id = a.member_id) bw
     cross join lateral (
       select count(*) filter (where b.dismissal = 'caught')::int as catches,
              count(*) filter (where b.dismissal = 'run_out')::int as run_outs,
              count(*) filter (where b.dismissal = 'stumped')::int as stumpings
         from public.match_batting b
        where b.match_id = a.match_id and b.version = a.version and b.fielder_member_id = a.member_id) fd
     order by mt.starts_at desc, a.match_id
     limit greatest(1, least(coalesce(p_limit, 50), 200));
end;
$$;

-- ---------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------
revoke execute on function public.member_stats(uuid[]) from public, anon, authenticated;
revoke execute on function public.can_view_player_stats(uuid) from public, anon, authenticated;
revoke execute on function public.player_stats(uuid) from public, anon;
revoke execute on function public.club_member_stats(uuid) from public, anon;
revoke execute on function public.player_match_log(uuid, integer) from public, anon;

grant execute on function public.player_stats(uuid) to authenticated;
grant execute on function public.club_member_stats(uuid) to authenticated;
grant execute on function public.player_match_log(uuid, integer) to authenticated;

notify pgrst, 'reload schema';
