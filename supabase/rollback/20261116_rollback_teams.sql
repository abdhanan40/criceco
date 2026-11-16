-- CricEco · ROLLBACK of migration 12 (teams, team_players).
--
-- NOT APPLIED. Run only with explicit approval, after a backup, BEFORE
-- rollback/20261116_rollback_club_memberships.sql, inside
-- begin; set local lock_timeout = '5s'; … commit;
--
-- DATA LOSS: every team and squad is deleted. Take a dump first if any team
-- data must be kept (supabase db dump --data-only, see the backup script).
-- Nothing else is touched: clubs, members and join requests stay.

do $$
begin
  if to_regclass('public.teams') is null and to_regclass('public.team_players') is null then
    raise exception 'rollback 12: teams are not installed — nothing to do';
  end if;
end $$;

drop trigger if exists club_members_leave_teams on public.club_members;
drop function if exists public.club_members_leave_teams();

drop function if exists public.archive_team(uuid);
drop function if exists public.save_team(uuid, text, text, integer, uuid, uuid, jsonb);
drop function if exists public.create_team(uuid, text, text, integer);

drop table if exists public.team_players;
drop function if exists public.team_players_validate();
drop table if exists public.teams;
drop function if exists public.team_name_key(text);

notify pgrst, 'reload schema';
