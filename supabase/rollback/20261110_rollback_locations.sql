-- CricEco · ROLLBACK of migration 20261110090000_create_locations.sql (Stage 4.2).
--
-- Removes only what that migration added: search_cities(), v_city_options,
-- the five location tables (and every location row) and
-- location_search_key(). Touches no other table, column, policy, grant or
-- row. The pg_trgm extension and schema "extensions" are left in place
-- (harmless, and possibly used by something else).
-- DESTRUCTIVE for location data. Run only on purpose, after a backup.
--
-- Refuses (changes nothing) while any table outside the location tables
-- references them — e.g. after a later stage adds addresses.city_id.

begin;

do $$
declare
  v_refs text;
begin
  select string_agg(c.conrelid::regclass::text || '.' || c.conname, ', ')
    into v_refs
    from pg_constraint c
   where c.contype = 'f'
     and c.confrelid in (select to_regclass(t) from unnest(array[
           'public.provinces', 'public.districts', 'public.cities']) t where to_regclass(t) is not null)
     and c.conrelid not in (select to_regclass(t) from unnest(array[
           'public.provinces', 'public.districts', 'public.cities',
           'public.city_districts', 'public.city_aliases']) t where to_regclass(t) is not null);
  if v_refs is not null then
    raise exception 'rollback refused: other tables reference the location tables (%)', v_refs;
  end if;
end $$;

drop function if exists public.search_cities(text, smallint, integer, integer);
drop view if exists public.v_city_options;

-- Dropping a table drops its triggers, policies, constraints, indexes and grants.
drop table if exists public.city_aliases;
drop table if exists public.city_districts;
drop table if exists public.cities;
drop table if exists public.districts;
drop table if exists public.provinces;

drop function if exists public.location_search_key(text);

notify pgrst, 'reload schema';

commit;
