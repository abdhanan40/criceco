-- CricEco · location DATA (D1, supabase/seed/locations/apply_locations.sql): checks
-- after the load. Read-only and ROLLED BACK; needs no test users. Run after
-- migration 6 and the D1 load. Run the WHOLE script at once; a failing check
-- raises an exception (then run `rollback;` on its own).
-- The expected counts are those of supabase/seed/locations/import_report.md —
-- update them together with a regenerated seed.

begin;

do $$
declare
  featured_expected constant int[] := array[1174872, 1172451, 1176615, 1166993, 1179400, 1169825, 1168197,
    1167528, 1164909, 1176734, 1177662, 1166000, 1183880, 1164408, 1172128, 1185056, 1170880, 1166548,
    1177654, 1167460];
  featured_names constant text[] := array['Karachi', 'Lahore', 'Islamabad', 'Rawalpindi', 'Faisalabad', 'Multan',
    'Peshawar', 'Quetta', 'Sialkot', 'Hyderabad', 'Gujranwala', 'Sargodha', 'Bahawalpur', 'Sukkur', 'Larkana',
    'Abbottabad', 'Mardan', 'Sahiwal', 'Gujrat', 'Rahim Yar Khan'];
begin
  -- Counts (import_report.md).
  if (select count(*) from public.provinces) <> 7 or (select count(*) from public.districts) <> 156
     or (select count(*) from public.cities) <> 436 or (select count(*) from public.city_districts) <> 432
     or (select count(*) from public.city_aliases) <> 491
     or (select count(*) from public.city_aliases where is_searchable) <> 486 then
    raise exception 'FAIL D1-1: counts differ from import_report.md (7/156/436/432/491, 486 searchable): %/%/%/%/%',
      (select count(*) from public.provinces), (select count(*) from public.districts),
      (select count(*) from public.cities), (select count(*) from public.city_districts),
      (select count(*) from public.city_aliases);
  end if;
  if exists (select 1 from public.provinces where source <> 'geonames' or source_version is null)
     or exists (select 1 from public.districts where source <> 'geonames' or source_version is null)
     or exists (select 1 from public.cities where source <> 'geonames' or source_version is null)
     or exists (select 1 from public.city_districts where source <> 'geonames')
     or exists (select 1 from public.city_aliases where source <> 'geonames' or geonames_alternatename_id is null) then
    raise exception 'FAIL D1-1: every row must come from GeoNames, with its source version';
  end if;
  raise notice 'PASSED D1-1: counts and provenance';

  -- Provinces: approved display names, kinds and order.
  if array(select coalesce(display_name, name) || '/' || kind from public.provinces order by sort_order)
     <> array['Punjab/province', 'Sindh/province', 'Khyber Pakhtunkhwa/province', 'Balochistan/province',
              'Islamabad Capital Territory/federal_territory', 'Gilgit-Baltistan/administrative_territory',
              'Azad Jammu and Kashmir/administrative_territory'] then
    raise exception 'FAIL D1-1: province names / kinds / order';
  end if;
  raise notice 'PASSED D1-1: provinces (Azad Jammu and Kashmir, Gilgit-Baltistan display names)';

  -- Featured cities: ranks 1–20 = kPakistanCities order, pinned GeoNames ids, active.
  if array(select geonames_id from public.cities where featured_rank is not null order by featured_rank)
     <> featured_expected
     or array(select name from public.cities where featured_rank is not null order by featured_rank) <> featured_names
     or exists (select 1 from public.cities where featured_rank is not null and not is_active)
     or (select geonames_id from public.cities where featured_rank = 18) <> 1166548 then
    raise exception 'FAIL D1-2: featured cities (ranks, ids, names, active; Sahiwal = 1166548)';
  end if;
  raise notice 'PASSED D1-2: 20 featured cities';

  -- Reviewed exclusions and selection rules.
  if exists (select 1 from public.cities where geonames_id in (1166547, 1332083, 1177009, 11250625))
     or exists (select 1 from public.districts where geonames_id = 1178336) then
    raise exception 'FAIL D1-3: an excluded record was loaded';
  end if;
  if array(select qualifier from public.cities where search_key = 'kamra' order by qualifier)
     <> array['Attock', 'Rawalpindi'] then
    raise exception 'FAIL D1-3: the two Kamra towns need their qualifiers';
  end if;
  if exists (select 1 from public.cities where geonames_fcode in ('PPLX', 'PPLQ', 'PPLW', 'PPLH'))
     or exists (select 1 from public.city_aliases where language is not null and language not in ('en', 'ur'))
     or exists (select 1 from public.city_aliases where alias ~* '^https?://') then
    raise exception 'FAIL D1-3: excluded place codes or non-name aliases present';
  end if;
  if exists (select 1 from public.city_districts where not is_primary)
     or exists (select 1 from public.city_districts cd join public.districts d on d.id = cd.district_id
                 where not d.is_active) then
    raise exception 'FAIL D1-3: every GeoNames link is one primary link to an active district';
  end if;
  if exists (select 1 from public.city_districts where city_id = (select id from public.cities where geonames_id = 1174872))
     or not exists (select 1 from public.cities where geonames_id = 1174872 and is_active) then
    raise exception 'FAIL D1-3: Karachi must be present, with no district link (GeoNames has none)';
  end if;
  if exists (select 1 from public.cities where search_key is null)
     or exists (select 1 from public.districts where search_key is null)
     or exists (select 1 from public.city_aliases where search_key is null) then
    raise exception 'FAIL D1-3: a row without a search key';
  end if;
  if (select count(*) from public.v_city_options) <> (select count(*) from public.cities where is_active) then
    raise exception 'FAIL D1-3: every active city must be listed by v_city_options';
  end if;
  raise notice 'PASSED D1-3: exclusions, qualifiers, codes, links, Karachi, search keys, view';
end $$;

-- ---- As a signed-in user: the picker reads (no real account needed) ----
select set_config('request.jwt.claims',
  json_build_object('sub', '00000000-0000-4000-8000-0000000000aa', 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare
  lahore_district int;
begin
  if current_user <> 'authenticated' then
    raise exception 'UNSAFE: not running as authenticated — stopping';
  end if;
  if array(select name from public.search_cities(null)) <> array['Karachi', 'Lahore', 'Islamabad', 'Rawalpindi',
       'Faisalabad', 'Multan', 'Peshawar', 'Quetta', 'Sialkot', 'Hyderabad', 'Gujranwala', 'Sargodha', 'Bahawalpur',
       'Sukkur', 'Larkana', 'Abbottabad', 'Mardan', 'Sahiwal', 'Gujrat', 'Rahim Yar Khan'] then
    raise exception 'FAIL D1-4: the empty search must list the 20 featured cities in order';
  end if;
  if (select name from public.search_cities('lahore') limit 1) <> 'Lahore'
     or (select name from public.search_cities('rahim yar') limit 1) <> 'Rahim Yar Khan'
     or (select name from public.search_cities('karach') limit 1) <> 'Karachi' then
    raise exception 'FAIL D1-4: exact / prefix search';
  end if;
  if (select count(*) from public.search_cities('kamra')) < 2 then
    raise exception 'FAIL D1-4: both Kamra towns must be found';
  end if;
  if not exists (select 1 from public.search_cities('peshawer') where name = 'Peshawar') then
    raise exception 'FAIL D1-4: similar-spelling search (peshawer → Peshawar)';
  end if;
  select primary_district_id into lahore_district from public.v_city_options where name = 'Lahore';
  if lahore_district is null
     or not exists (select 1 from public.search_cities(null, null, lahore_district) where name = 'Lahore')
     or exists (select 1 from public.search_cities('a', (select id from public.provinces where geonames_admin1 = '05'))
                 where province_name <> 'Sindh') then
    raise exception 'FAIL D1-4: province / district filters';
  end if;
  raise notice 'PASSED D1-4: search as a signed-in user (featured list, prefix, similar spelling, filters)';
end $$;
reset role;

do $$ begin raise notice 'ALL 07_locations_data_check CHECKS PASSED (rolling back)'; end $$;

rollback;
