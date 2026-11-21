-- CricEco · ROLLBACK of migration 23 (my_matches).
--
-- NOT APPLIED. Run only with explicit approval, after a backup, inside
--   begin; set local lock_timeout = '5s'; <this file> commit;
-- Removes one read function; no data is touched. An app built with
-- CRICECO_RESULTS=true then gets errors on the player's My Matches screen —
-- ship a build without it first.

do $$
begin
  if to_regprocedure('public.my_matches()') is null then
    raise exception 'rollback 23: migration 23 is not applied — nothing changed';
  end if;
end $$;

drop function if exists public.my_matches();

notify pgrst, 'reload schema';
