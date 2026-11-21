-- CricEco · migration 23 · the player's match list (M2, P2)
--
-- NOT APPLIED. Requires migrations 18 (lineups) and 20 (results). Review
-- first; apply only with separate approval, after a fresh backup, inside
--   begin; set local lock_timeout = '5s'; <this file> commit;
-- Rollback: supabase/rollback/20261121_rollback_my_matches.sql.
-- Read-only check: supabase/tests/23_my_matches_postcheck.sql.
-- Local test: supabase/tests/local/20_my_matches_local_check.sql.
-- Design: docs/MATCH_RESULTS_BACKEND.md.
--
-- my_matches() (approved M2 decision 11; deferred from M1 P6): the caller's
-- scheduled matches across every club they are an ACTIVE member of — the
-- prototype's My Matches tabs Upcoming / Past / Cancelled. A match appears
-- once it has a start time (confirmed, completed, or cancelled after being
-- scheduled); pending proposals never do. Per row: the caller's own
-- selection in their club's line-up (never the opponent's line-up — M1
-- decision 4), whether a line-up is saved, captaincy, and the confirmed
-- result from the caller's club's side. Read only; no new tables.

do $$
begin
  if to_regclass('public.match_lineups') is null or to_regclass('public.match_results') is null
     or to_regprocedure('public.match_result_summary(uuid, integer)') is null then
    raise exception 'migration 23: migrations 18 and 20 (lineups, results) are required';
  end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'my_matches') then
    raise exception 'migration 23: already applied (or a name is taken) — nothing changed';
  end if;
end $$;

-- Errors: "match: not authenticated" (42501).
create or replace function public.my_matches()
returns table (
  match_id         uuid,
  club_id          uuid,
  club_name        text,
  opponent_club_id uuid,
  opponent_name    text,
  format           text,
  custom_overs     smallint,
  status           text,
  starts_at        timestamptz,
  venue_name       text,
  city             text,
  cancel_reason    text,
  lineup_saved     boolean,
  selection        text,
  is_captain       boolean,
  is_vice_captain  boolean,
  result           text,
  summary          text,
  result_version   integer
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'match: not authenticated' using errcode = '42501';
  end if;
  return query
    select mt.id, me.club_id, c.name, o.id, o.name, mt.format, mt.custom_overs, mt.status, mt.starts_at,
           mt.venue_name, mt.city, mt.cancel_reason,
           l.match_id is not null,
           lp.selection,
           l.captain_member_id is not distinct from me.id and l.captain_member_id is not null,
           l.vice_captain_member_id is not distinct from me.id and l.vice_captain_member_id is not null,
           case r.outcome
             when 'tie' then 'tied'
             when 'no_result' then 'no_result'
             when 'abandoned' then 'abandoned'
             when 'club_a_won' then case when mt.club_a_id = me.club_id then 'won' else 'lost' end
             when 'club_b_won' then case when mt.club_b_id = me.club_id then 'won' else 'lost' end
           end,
           case when r.version is not null then public.match_result_summary(mt.id, r.version) end,
           r.version
      from public.club_members me
      join public.matches mt on me.club_id in (mt.club_a_id, mt.club_b_id)
      join public.clubs c on c.id = me.club_id
      join public.clubs o on o.id = case when mt.club_a_id = me.club_id then mt.club_b_id else mt.club_a_id end
      left join public.match_lineups l on l.match_id = mt.id and l.club_id = me.club_id
      left join public.match_lineup_players lp
        on lp.match_id = mt.id and lp.club_id = me.club_id and lp.member_id = me.id
      left join public.match_results r on r.match_id = mt.id and r.status = 'confirmed'
     where me.user_id = v_uid and me.status = 'active'
       and mt.starts_at is not null
       and mt.status in ('confirmed', 'completed', 'cancelled')
     order by mt.starts_at desc, mt.id, me.club_id;
end;
$$;

revoke execute on function public.my_matches() from public, anon;
grant execute on function public.my_matches() to authenticated;

notify pgrst, 'reload schema';
