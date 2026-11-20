-- CricEco · ROLLBACK of migration 17 (match challenges and matches).
--
-- NOT APPLIED. Run only with explicit approval, after a backup, inside
--   begin; set local lock_timeout = '5s'; <this file> commit;
-- If migration 18 (lineups, P2) is applied, roll it back FIRST.
--
-- DESTRUCTIVE TO M1 MATCH DATA: every challenge and every match (with its
-- schedule, proposals and cancellations) is deleted. Take a data dump first
-- if any of it must be kept (supabase db dump --data-only, see the backup
-- script). Nothing else is touched: clubs, members, join requests, teams,
-- squads, profiles and roles stay exactly as they are.
-- An app built with CRICECO_MATCHES=true then gets errors on the match
-- screens — ship a build without it first.

do $$
begin
  if to_regclass('public.match_challenges') is null and to_regclass('public.matches') is null then
    raise exception 'rollback 17: migration 17 is not applied — nothing changed';
  end if;
  if to_regclass('public.match_lineups') is not null then
    raise exception 'rollback 17: migration 18 (match lineups) is applied — roll it back first';
  end if;
end $$;

drop function if exists public.club_matches(uuid);
drop function if exists public.cancel_match(uuid, text);
drop function if exists public.respond_to_match_schedule(uuid, integer, boolean);
drop function if exists public.propose_match_schedule(uuid, timestamptz, text, text);
drop function if exists public.club_challenges(uuid);
drop function if exists public.respond_to_challenge(uuid, boolean);
drop function if exists public.send_challenge(uuid, uuid, text, integer, date, text, text);
drop function if exists public.match_club_directory(text, text);
drop function if exists public.match_lock_clubs(uuid, uuid);
drop function if exists public.match_duration(text, integer);

-- The two tables reference each other: drop them in one statement (their
-- policies, indexes, constraints and triggers go with them).
drop table if exists public.matches, public.match_challenges;

drop function if exists public.matches_guard_update();
drop function if exists public.match_challenges_guard_update();
drop function if exists public.is_active_club_member(uuid);

notify pgrst, 'reload schema';
