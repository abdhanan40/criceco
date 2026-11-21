-- CricEco · ROLLBACK of migration 22 (player statistics).
--
-- NOT APPLIED. Run only with explicit approval, after a backup, inside
--   begin; set local lock_timeout = '5s'; <this file> commit;
-- Roll back migration 23 (my_matches) FIRST; this script refuses otherwise,
-- so the M2 migrations always roll back in reverse order (23 → 22 → 21 → 20).
-- Removes read functions only; no data is touched (statistics are computed
-- on read). An app built with CRICECO_RESULTS=true then gets errors on the
-- statistics screens — ship a build without it first.

do $$
begin
  if to_regprocedure('public.player_stats(uuid)') is null then
    raise exception 'rollback 22: migration 22 is not applied — nothing changed';
  end if;
  if to_regprocedure('public.my_matches()') is not null then
    raise exception 'rollback 22: migration 23 (my_matches) is applied — roll it back first';
  end if;
end $$;

drop function if exists public.player_match_log(uuid, integer);
drop function if exists public.club_member_stats(uuid);
drop function if exists public.player_stats(uuid);
drop function if exists public.can_view_player_stats(uuid);
drop function if exists public.member_stats(uuid[]);

notify pgrst, 'reload schema';
