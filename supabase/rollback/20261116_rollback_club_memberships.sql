-- CricEco · ROLLBACK of migration 11 (club_members, join_requests).
--
-- NOT APPLIED. Run only with explicit approval, after a backup, and only
-- AFTER rollback/20261116_rollback_teams.sql (it refuses while teams exist),
-- inside begin; set local lock_timeout = '5s'; … commit;
--
-- DATA LOSS: every club membership, join request and throttle record is
-- deleted. clubs,
-- profiles, player_profiles and user_roles are untouched (approval never
-- changed them). Roll back the app build that uses memberships first
-- (CRICECO_MEMBERSHIPS=false), or its calls fail.

do $$
begin
  if to_regclass('public.teams') is not null or to_regclass('public.team_players') is not null then
    raise exception 'rollback 11: roll back migration 12 (teams) first — nothing changed';
  end if;
  if to_regclass('public.club_members') is null and to_regclass('public.join_requests') is null then
    raise exception 'rollback 11: club memberships are not installed — nothing to do';
  end if;
end $$;

drop trigger if exists clubs_add_owner_member on public.clubs;
drop function if exists public.clubs_add_owner_member();

drop function if exists public.my_join_requests();
drop function if exists public.my_club_memberships();
drop function if exists public.club_member_list(uuid);
drop function if exists public.club_join_requests(uuid);
drop function if exists public.remove_club_member(uuid);
drop function if exists public.decide_join_request(uuid, boolean, text, text);
drop function if exists public.cancel_join_request(uuid);
drop function if exists public.request_to_join_club(text, text);
drop function if exists public.lookup_club_by_code(text);

drop function if exists public.club_code_failed(uuid);
drop function if exists public.club_code_throttled(uuid);

drop table if exists public.club_code_attempts;
drop table if exists public.join_requests;
drop table if exists public.club_members;
drop function if exists public.is_club_owner(uuid);

notify pgrst, 'reload schema';
