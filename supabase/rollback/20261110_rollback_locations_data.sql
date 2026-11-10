-- CricEco · ROLLBACK of the location DATA load (D1:
-- supabase/seed/locations/apply_locations.sql). Keeps the schema of
-- migration 6; deletes every location row.
--
-- Only valid while no other table references cities / districts /
-- provinces (i.e. before Stage 4.3 adds city_id columns): it refuses
-- otherwise. Re-loading afterwards gives NEW ids — safe only because
-- nothing stores them yet.
-- DESTRUCTIVE for location data. Run only on purpose, after a backup.

begin;

do $$
declare
  v_refs text;
begin
  if to_regclass('public.cities') is null then
    raise exception 'rollback refused: migration 6 (location tables) is not applied';
  end if;
  select string_agg(c.conrelid::regclass::text || '.' || c.conname, ', ')
    into v_refs
    from pg_constraint c
   where c.contype = 'f'
     and c.confrelid in ('public.provinces'::regclass, 'public.districts'::regclass, 'public.cities'::regclass)
     and c.conrelid not in ('public.provinces'::regclass, 'public.districts'::regclass, 'public.cities'::regclass,
                            'public.city_districts'::regclass, 'public.city_aliases'::regclass);
  if v_refs is not null then
    raise exception 'rollback refused: other tables reference the location tables (%)', v_refs;
  end if;
end $$;

delete from public.city_aliases;
delete from public.city_districts;
-- replaced_by_city_id is ON DELETE RESTRICT: clear it before deleting.
update public.cities set replaced_by_city_id = null where replaced_by_city_id is not null;
delete from public.cities;
delete from public.districts;
delete from public.provinces;

commit;
