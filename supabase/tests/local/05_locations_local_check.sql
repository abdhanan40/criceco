-- CricEco · LOCAL TEST ONLY — locations (migration 6): constraints and
-- search behaviour, on small made-up rows (source 'manual', invented names
-- prefixed "Zz", never real locations). Rolled back: nothing is kept.
-- Refuses to run on a real Supabase project (whose auth.users has an
-- encrypted_password column). Run after migration 6 on the local test
-- database, as the database owner, on EMPTY location tables.

do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password') then
    raise exception 'LOCAL ONLY: this looks like a real Supabase auth schema';
  end if;
  if exists (select 1 from public.provinces) then
    raise exception 'LOCAL ONLY: run on empty location tables';
  end if;
end $$;

begin;

-- Two provinces, three districts, a handful of cities.
insert into public.provinces (name, display_name, kind, source, source_version, sort_order) values
  ('Zz North', 'Zz North Display', 'province', 'manual', 'test', 1),
  ('Zz South', null, 'administrative_territory', 'manual', 'test', 2);

insert into public.districts (province_id, name, source, source_ref)
select p.id, d.name, 'manual', 'test'
  from (values ('Zz North', 'Zz Alpha'), ('Zz North', 'Zz Beta'), ('Zz South', 'Zz Gamma')) d(prov, name)
  join public.provinces p on p.name = d.prov;

insert into public.cities (province_id, name, kind, featured_rank, source, source_ref)
select p.id, c.name, 'city', c.rank, 'manual', 'test'
  from (values ('Zz North', 'Zzmetro', 1), ('Zz North', 'Zzlahra', 2), ('Zz North', 'Zzlahore Cantt', null),
               ('Zz South', 'Zzquetta', 3), ('Zz South', 'Zzkhanpur', null), ('Zz North', 'Zzkhanpur', null))
       c(prov, name, rank)
  join public.provinces p on p.name = c.prov;

do $$
declare
  north smallint := (select id from public.provinces where name = 'Zz North');
  south smallint := (select id from public.provinces where name = 'Zz South');
  alpha int := (select id from public.districts where name = 'Zz Alpha');
  beta  int := (select id from public.districts where name = 'Zz Beta');
  gamma int := (select id from public.districts where name = 'Zz Gamma');
  metro int := (select id from public.cities where name = 'Zzmetro');
  quetta int := (select id from public.cities where name = 'Zzquetta');
  ok boolean;
  n int;
begin
  -- L3: a city linked to a district of another province is refused.
  begin
    insert into public.city_districts (city_id, district_id, province_id, source) values (metro, gamma, north, 'manual');
    raise exception 'FAIL L3: cross-province link accepted (city province)';
  exception when foreign_key_violation then null;
  end;
  begin
    insert into public.city_districts (city_id, district_id, province_id, source) values (metro, gamma, south, 'manual');
    raise exception 'FAIL L3: cross-province link accepted (district province)';
  exception when foreign_key_violation then null;
  end;
  -- A city in two districts (like Karachi); only one primary.
  insert into public.city_districts (city_id, district_id, province_id, is_primary, source)
  values (metro, alpha, north, true, 'manual'), (metro, beta, north, false, 'manual');
  begin
    update public.city_districts set is_primary = true where city_id = metro and district_id = beta;
    raise exception 'FAIL L3: a second primary district accepted';
  exception when unique_violation then null;
  end;
  raise notice 'PASSED L3: composite province FKs; one primary district per city';

  -- L4: same name twice in one province needs a qualifier; other provinces are fine.
  begin
    insert into public.cities (province_id, name, source, source_ref) values (north, 'ZZKHANPUR', 'manual', 't');
    raise exception 'FAIL L4: duplicate name in one province accepted';
  exception when unique_violation then null;
  end;
  insert into public.cities (province_id, name, qualifier, source, source_ref)
  values (north, 'Zzkhanpur', 'Zz Beta', 'manual', 't');
  raise notice 'PASSED L4: duplicate names need a qualifier within a province; allowed across provinces';

  -- Value checks.
  begin
    insert into public.cities (province_id, name, source) values (north, 'Zz No Source Key', 'manual');
    raise exception 'FAIL: a manual city without source_ref accepted';
  exception when check_violation then null;
  end;
  begin
    insert into public.cities (province_id, name, source, source_ref) values (north, ' Zz Untrimmed', 'manual', 't');
    raise exception 'FAIL: an untrimmed name accepted';
  exception when check_violation then null;
  end;
  begin
    insert into public.provinces (name, kind, source) values ('Zz Bad Kind', 'state', 'manual');
    raise exception 'FAIL: an unknown province kind accepted';
  exception when check_violation then null;
  end;
  begin
    update public.cities set featured_rank = 1 where id = quetta;
    raise exception 'FAIL: a duplicate featured rank accepted';
  exception when unique_violation then null;
  end;
  begin
    insert into public.cities (id, province_id, name, source, source_ref) values (999999, north, 'Zz Own Id', 'manual', 't');
    raise exception 'FAIL: an explicit id accepted (identity must be generated always)';
  exception when generated_always then null;
  end;
  raise notice 'PASSED: value checks, featured rank unique, ids database-generated';

  -- L5: deletes are blocked; aliases cascade; replaced_by rules.
  begin
    delete from public.provinces where id = north;
    raise exception 'FAIL L5: deleting a province in use succeeded';
  exception when foreign_key_violation then null;
  end;
  begin
    delete from public.districts where id = alpha;
    raise exception 'FAIL L5: deleting a linked district succeeded';
  exception when foreign_key_violation then null;
  end;
  begin
    update public.cities set replaced_by_city_id = quetta where id = metro;
    raise exception 'FAIL L5: an ACTIVE city with replaced_by accepted';
  exception when check_violation then null;
  end;
  begin
    update public.cities set is_active = false, replaced_by_city_id = metro where id = metro;
    raise exception 'FAIL L5: a city replaced by itself accepted';
  exception when check_violation then null;
  end;
  insert into public.city_aliases (city_id, alias, language, source) values (quetta, 'Zz Shal', 'en', 'manual');
  begin
    insert into public.city_aliases (city_id, alias, source) values (quetta, 'ZZ-SHAL', 'manual');
    raise exception 'FAIL: a duplicate alias (same search key) accepted';
  exception when unique_violation then null;
  end;
  raise notice 'PASSED L5: RESTRICT deletes; replaced_by rules; alias uniqueness';

  -- L6: the search key.
  if (select search_key from public.cities where id = metro) <> 'zzmetro'
     or public.location_search_key('Jāfarābād') <> 'jafarabad'
     or public.location_search_key('  Rahim-Yar  Khan ') <> 'rahim yar khan'
     or public.location_search_key('D.I. Khan') <> 'd i khan' then
    raise exception 'FAIL L6: search key';
  end if;
  raise notice 'PASSED L6: search key';

  -- L7: search_cities().
  -- Empty and 1-character queries → featured cities in rank order.
  if array(select id from public.search_cities(null)) <> array[metro, (select id from public.cities where name = 'Zzlahra'), quetta]
     or array(select id from public.search_cities('z')) <> array(select id from public.search_cities(''))
     or array(select id from public.search_cities('   ')) <> array(select id from public.search_cities(null)) then
    raise exception 'FAIL L7: empty / short query must return the featured cities in rank order';
  end if;
  -- Ranking: exact name before name prefix before alias prefix.
  insert into public.city_aliases (city_id, alias, source) values (metro, 'Zzlahr Old', 'manual');
  -- 'zzlah': two name prefixes (featured Zzlahra first), then Zzmetro via its alias.
  if (select array_agg(name order by ord) from (
        select name, row_number() over () as ord from public.search_cities('zzlah')) s)
     <> array['Zzlahra', 'Zzlahore Cantt', 'Zzmetro'] then
    raise exception 'FAIL L7: ranking (got %)',
      (select array_agg(name) from public.search_cities('zzlah'));
  end if;
  if (select name from public.search_cities('zzlahra') limit 1) <> 'Zzlahra' then
    raise exception 'FAIL L7: exact match must come first';
  end if;
  -- Similar spelling (trigram) finds a misspelling.
  if not exists (select 1 from public.search_cities('zzquettaa') where id = quetta) then
    raise exception 'FAIL L7: similar-spelling search did not find Zzquetta';
  end if;
  -- Filters: province; district (a two-district city appears under both).
  if exists (select 1 from public.search_cities('zz', south) where province_id <> south)
     or not exists (select 1 from public.search_cities('zz', null, alpha) where id = metro)
     or not exists (select 1 from public.search_cities('zz', null, beta) where id = metro)
     or not exists (select 1 from public.search_cities(null, null, beta) where id = metro) then
    raise exception 'FAIL L7: province / district filters';
  end if;
  -- One row per city, limit capped 1–50.
  select count(*) into n from public.search_cities('zz', null, null, 1000);
  if n <> (select count(distinct id) from public.search_cities('zz', null, null, 1000)) then
    raise exception 'FAIL L7: duplicate rows for one city';
  end if;
  if (select count(*) from public.search_cities('zz', null, null, 0)) <> 1
     or (select count(*) from public.search_cities('zz', null, null, 1000)) > 50 then
    raise exception 'FAIL L7: limit must be clamped to 1–50';
  end if;
  -- View: district names and counts.
  select (primary_district_name = 'Zz Alpha' and district_count = 2) into ok
    from public.v_city_options where id = metro;
  if not ok then
    raise exception 'FAIL L7: v_city_options primary district / count for a two-district city';
  end if;
  if (select province_name from public.v_city_options where id = metro) <> 'Zz North Display' then
    raise exception 'FAIL L7: province display_name must be shown';
  end if;
  -- Inactive rows are hidden from the view and search, but stay readable in the table.
  update public.cities set is_active = false where id = quetta;
  if exists (select 1 from public.v_city_options where id = quetta)
     or exists (select 1 from public.search_cities('zzquetta') where id = quetta)
     or not exists (select 1 from public.cities where id = quetta) then
    raise exception 'FAIL L7: an inactive city must be hidden from view/search only';
  end if;
  -- A city whose only district is inactive is hidden; with no links it shows.
  update public.districts set is_active = false where id in (alpha, beta);
  if exists (select 1 from public.v_city_options where id = metro) then
    raise exception 'FAIL L7: a city with only inactive districts must be hidden';
  end if;
  if not exists (select 1 from public.v_city_options where name = 'Zzlahra') then
    raise exception 'FAIL L7: a city with no district link must be listed';
  end if;
  update public.provinces set is_active = false where id = north;
  if exists (select 1 from public.v_city_options where province_id = north) then
    raise exception 'FAIL L7: cities of an inactive province must be hidden';
  end if;
  raise notice 'PASSED L7: search ranking, similar spelling, filters, limits, view visibility';

  -- last_updated_at follows updates; created_at can't change (migration 1 trigger).
  begin
    update public.cities set created_at = now() - interval '1 day' where id = metro;
    if (select created_at from public.cities where id = metro) < now() - interval '1 hour' then
      raise exception 'FAIL: created_at changed';
    end if;
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
  raise notice 'PASSED: timestamps';
end $$;

do $$ begin raise notice 'ALL local/05_locations_local_check CHECKS PASSED (rolling back)'; end $$;

rollback;
