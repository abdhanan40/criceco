-- CricEco · ROLLBACK of migration 16 (club ownership transfer).
-- Only with explicit approval, inside
--   begin; set local lock_timeout = '5s'; <this file> commit;
--
-- Removes the feature: the functions and the club_ownership_transfers table —
-- WITH its history (take a data dump first if the history must be kept).
-- Transfers already ACCEPTED stay in effect: clubs.owner_id, the memberships'
-- roles and user_roles are not reverted (that would be a new transfer).
-- An app built with CRICECO_ACCOUNT_PRIVACY=true then gets errors on the
-- transfer screens — ship a build without them first.

do $$
begin
  if to_regclass('public.club_ownership_transfers') is null then
    raise exception 'rollback 16: migration 16 is not applied — nothing changed';
  end if;
end $$;

drop function if exists public.my_ownership_offers();
drop function if exists public.club_ownership_transfers(uuid);
drop function if exists public.accept_ownership_transfer(uuid);
drop function if exists public.reject_ownership_transfer(uuid);
drop function if exists public.cancel_ownership_transfer(uuid);
drop function if exists public.offer_club_ownership(uuid, uuid, text);
drop function if exists public.ownership_recipient_problem(uuid, public.club_members);
drop table if exists public.club_ownership_transfers;

notify pgrst, 'reload schema';
