-- CricEco · ROLLBACK of migration 19 (player availability).
--
-- NOT APPLIED. Run only with explicit approval, after a backup, inside
--   begin; set local lock_timeout = '5s'; <this file> commit;
-- Run it BEFORE the rollbacks of migrations 18 and 17.
--
-- DESTRUCTIVE TO P2 DATA: every player's availability record (status,
-- reason, until date, notes) is deleted. Take a data dump first if any of it
-- must be kept. Lineups stay as saved, but no longer refuse injured /
-- unavailable players. Nothing else is touched: lineups, matches, clubs,
-- members, teams and profiles stay.
-- An app built with CRICECO_MATCHES=true then gets errors on the
-- availability screens — ship a build without it first.

do $$
begin
  if to_regclass('public.player_availability') is null then
    raise exception 'rollback 19: migration 19 is not applied — nothing changed';
  end if;
end $$;

drop trigger if exists match_lineup_players_check_availability on public.match_lineup_players;
drop function if exists public.match_lineup_players_check_availability();

drop function if exists public.club_player_availability(uuid);
drop function if exists public.my_availability();
drop function if exists public.set_my_availability(text, text, date, text);

drop table if exists public.player_availability;
drop function if exists public.is_owner_of_active_member(uuid);
drop function if exists public.availability_locks_on(text, date, date);

notify pgrst, 'reload schema';
