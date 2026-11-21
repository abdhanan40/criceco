-- CricEco · ROLLBACK of migration 21 (match scorecards).
--
-- NOT APPLIED. Run only with explicit approval, after a backup, inside
--   begin; set local lock_timeout = '5s'; <this file> commit;
-- Roll back migration 22 (statistics) FIRST; this script refuses otherwise.
--
-- DESTRUCTIVE TO M2 SCORECARD DATA: every batting and bowling row of every
-- result version is deleted. Take a data dump first if any of it must be
-- kept (supabase db dump --data-only, see the backup script). The results
-- and innings totals of migration 20 stay; results submitted with cards
-- become totals-only. An app built with CRICECO_RESULTS=true then gets
-- errors on the scorecard screens — ship a build without it first.

do $$
begin
  if to_regclass('public.match_batting') is null and to_regclass('public.match_bowling') is null then
    raise exception 'rollback 21: migration 21 is not applied — nothing changed';
  end if;
  if to_regprocedure('public.player_stats(uuid)') is not null or to_regprocedure('public.member_stats(uuid[])') is not null then
    raise exception 'rollback 21: migration 22 (statistics) is applied — roll it back first';
  end if;
end $$;

drop trigger if exists club_members_forget_match_scorecards on public.club_members;
drop function if exists public.club_members_forget_match_scorecards();

drop function if exists public.match_scorecard(uuid, integer);
drop function if exists public.submit_match_result_with_scorecard(uuid, text, jsonb, uuid);
drop function if exists public.match_player_pool(uuid);
drop function if exists public.match_club_player_pool(uuid, uuid);
drop function if exists public.match_dismissal_text(text, text, text, boolean, boolean);
drop function if exists public.match_bowler_max_balls(text, integer);

drop table if exists public.match_batting;
drop table if exists public.match_bowling;
drop function if exists public.match_scorecards_guard();

notify pgrst, 'reload schema';
