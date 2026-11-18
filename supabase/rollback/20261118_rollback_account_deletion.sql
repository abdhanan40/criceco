-- CricEco · ROLLBACK of migration 14 (account deletion data function).
-- Only with explicit approval, inside
--   begin; set local lock_timeout = '5s'; <this file> commit;
-- Undeploy (or leave unused) the delete-account Edge Function first: without
-- this function it can no longer delete anything (it answers 500).

do $$
begin
  if to_regprocedure('public.delete_account_data(uuid)') is null then
    raise exception 'rollback 14: migration 14 is not applied — nothing changed';
  end if;
end $$;

drop function public.delete_account_data(uuid);

notify pgrst, 'reload schema';
