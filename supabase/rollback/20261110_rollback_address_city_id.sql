-- CricEco · ROLLBACK of migration 20261110090200_add_address_city_id.sql (Stage 4.3.3).
--
-- Removes only what that migration added: save_profile_setup_v2(), the four
-- sync triggers and address_city_sync_from_id() / _from_text(), the resolver
-- functions and the city_id columns (with their foreign keys and indexes). The address rows,
-- their city text and every other column stay exactly as they are; the
-- city text is always in step with city_id, so no city is lost — only the
-- tie-breaker between same-named cities (e.g. the two Kamra towns).
-- save_profile_setup v1 (migration 4) is untouched.
-- Roll back any app build that calls save_profile_setup_v2 or reads
-- city_id FIRST.

begin;

drop function if exists public.save_profile_setup_v2(text, text, date, integer, text, text, boolean, integer, text, text);

drop trigger if exists current_addresses_city_sync_1_from_id on public.current_addresses;
drop trigger if exists current_addresses_city_sync_2_from_text on public.current_addresses;
drop trigger if exists permanent_addresses_city_sync_1_from_id on public.permanent_addresses;
drop trigger if exists permanent_addresses_city_sync_2_from_text on public.permanent_addresses;
drop function if exists public.address_city_sync_from_id();
drop function if exists public.address_city_sync_from_text();

-- Dropping a column drops its foreign key and index.
alter table public.current_addresses drop column if exists city_id;
alter table public.permanent_addresses drop column if exists city_id;

drop function if exists public.resolve_city_id(text);
drop function if exists public.resolve_city_match(text);

notify pgrst, 'reload schema';

commit;
