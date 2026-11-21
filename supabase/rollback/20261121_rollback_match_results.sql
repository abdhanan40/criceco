-- CricEco · ROLLBACK of migration 20 (match results and innings totals).
--
-- NOT APPLIED. Run only with explicit approval, after a backup, inside
--   begin; set local lock_timeout = '5s'; <this file> commit;
-- Roll back any later M2 migration (21: scorecards) FIRST; this script
-- refuses otherwise.
--
-- DESTRUCTIVE TO M2 RESULT DATA: every result version (submitted,
-- confirmed, disputed, superseded) and every innings total is deleted.
-- Take a data dump first if any of it must be kept (supabase db dump
-- --data-only, see the backup script). Matches already marked 'completed'
-- STAY completed (that status belongs to migration 17's table): they then
-- show as played without a result. Nothing else is touched: matches,
-- challenges, lineups, availability, clubs, members, teams and profiles stay.
-- An app built with CRICECO_RESULTS=true then gets errors on the result
-- screens — ship a build without it first.

do $$
begin
  if to_regclass('public.match_results') is null and to_regclass('public.match_innings') is null then
    raise exception 'rollback 20: migration 20 is not applied — nothing changed';
  end if;
  if to_regclass('public.scorer_clients') is not null or to_regclass('public.result_submission_log') is not null then
    raise exception 'rollback 20: migration 24 (result write lockdown) is applied — roll it back first';
  end if;
  if to_regclass('public.match_batting') is not null or to_regclass('public.match_bowling') is not null then
    raise exception 'rollback 20: migration 21 (scorecards) is applied — roll it back first';
  end if;
end $$;

drop trigger if exists club_members_forget_match_results on public.club_members;
drop function if exists public.club_members_forget_match_results();

drop function if exists public.club_record(uuid);
drop function if exists public.club_results(uuid);
drop function if exists public.match_result(uuid);
drop function if exists public.dispute_match_result(uuid, integer, text);
drop function if exists public.confirm_match_result(uuid, integer);
drop function if exists public.submit_match_result(uuid, text, jsonb, uuid);
drop function if exists public.match_result_summary(uuid, integer);
drop function if exists public.match_format_max_balls(text, integer);

drop table if exists public.match_innings;
drop table if exists public.match_results;
drop function if exists public.match_innings_guard();
drop function if exists public.match_results_guard_update();

notify pgrst, 'reload schema';
