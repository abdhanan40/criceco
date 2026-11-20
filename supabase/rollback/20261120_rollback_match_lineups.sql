-- CricEco · ROLLBACK of migration 18 (match lineups).
--
-- NOT APPLIED. Run only with explicit approval, after a backup, inside
--   begin; set local lock_timeout = '5s'; <this file> commit;
-- Roll back migration 19 (player availability) FIRST; this script refuses
-- otherwise. Run it BEFORE the rollback of migration 17.
--
-- DESTRUCTIVE TO P2 DATA: every match lineup (names, players, captains) is
-- deleted. Take a data dump first if any of it must be kept (supabase db dump
-- --data-only, see the backup script). Nothing else is touched: matches,
-- challenges, clubs, members, teams, squads and profiles stay. Teams that
-- lineups referenced can be deleted again afterwards (nothing deletes them).
-- An app built with CRICECO_MATCHES=true then gets errors on the lineup
-- screens — ship a build without it first.

do $$
begin
  if to_regclass('public.match_lineups') is null and to_regclass('public.match_lineup_players') is null then
    raise exception 'rollback 18: migration 18 is not applied — nothing changed';
  end if;
  if to_regclass('public.player_availability') is not null then
    raise exception 'rollback 18: migration 19 (player availability) is applied — roll it back first';
  end if;
end $$;

drop trigger if exists club_members_leave_match_lineups on public.club_members;
drop function if exists public.club_members_leave_match_lineups();

drop function if exists public.match_lineup(uuid);
drop function if exists public.save_match_lineup(uuid, text, uuid, jsonb, uuid, uuid);

drop table if exists public.match_lineup_players;
drop table if exists public.match_lineups;
drop function if exists public.match_lineup_players_validate();
drop function if exists public.match_lineups_validate();

notify pgrst, 'reload schema';
