-- CricEco · locations (migration 6): schema, keys, indexes, functions and
-- access rules. Safe on the live project: needs no test users, writes
-- nothing (every attempted write must be refused), and the whole script is
-- ROLLED BACK at the end. Run after migration 6, with or without data.
-- Run the WHOLE script at once. A failing check raises an exception and
-- stops the script; then run `rollback;` on its own.

begin;

-- ---- As the database owner: catalog checks (read-only) ----
do $$
declare
  t text;
  n int;
begin
  -- Tables, RLS, one read policy each.
  foreach t in array array['provinces', 'districts', 'cities', 'city_districts', 'city_aliases'] loop
    if to_regclass('public.' || t) is null then
      raise exception 'FAIL: table public.% is missing', t;
    end if;
    if not (select relrowsecurity from pg_class where oid = ('public.' || t)::regclass) then
      raise exception 'FAIL: RLS is not enabled on %', t;
    end if;
    select count(*) into n from pg_policies where schemaname = 'public' and tablename = t;
    if n <> 1 or not exists (select 1 from pg_policies where schemaname = 'public' and tablename = t
                                and cmd = 'SELECT' and roles = '{authenticated}' and qual = 'true') then
      raise exception 'FAIL: % must have exactly one policy: SELECT to authenticated using (true)', t;
    end if;
  end loop;
  raise notice 'PASSED: 5 tables, RLS on, one read policy each';

  -- Identity keys (generated always) and stored search keys.
  if (select count(*) from pg_attribute a
       where a.attrelid in ('public.provinces'::regclass, 'public.districts'::regclass,
                            'public.cities'::regclass, 'public.city_aliases'::regclass)
         and a.attname = 'id' and a.attidentity = 'a') <> 4 then
    raise exception 'FAIL: id must be GENERATED ALWAYS AS IDENTITY on provinces, districts, cities, city_aliases';
  end if;
  if (select count(*) from pg_attribute a
       where a.attrelid in ('public.provinces'::regclass, 'public.districts'::regclass,
                            'public.cities'::regclass, 'public.city_aliases'::regclass)
         and a.attname = 'search_key' and a.attgenerated = 's') <> 4 then
    raise exception 'FAIL: search_key must be a stored generated column on 4 tables';
  end if;
  if format_type((select atttypid from pg_attribute where attrelid = 'public.cities'::regclass and attname = 'id'), null) <> 'integer'
     or format_type((select atttypid from pg_attribute where attrelid = 'public.provinces'::regclass and attname = 'id'), null) <> 'smallint' then
    raise exception 'FAIL: cities.id must be integer and provinces.id smallint';
  end if;
  raise notice 'PASSED: identity keys and generated search keys';

  -- Foreign keys: RESTRICT everywhere, CASCADE only aliases → cities.
  if exists (select 1 from pg_constraint
              where contype = 'f'
                and conname in ('districts_province_id_fkey', 'cities_province_id_fkey', 'cities_replaced_by_city_id_fkey',
                                'city_districts_city_fkey', 'city_districts_district_fkey')
                and confdeltype <> 'r')
     or (select count(*) from pg_constraint
          where contype = 'f' and conname in ('districts_province_id_fkey', 'cities_province_id_fkey',
                'cities_replaced_by_city_id_fkey', 'city_districts_city_fkey', 'city_districts_district_fkey')) <> 5 then
    raise exception 'FAIL: the 5 location foreign keys must exist with ON DELETE RESTRICT';
  end if;
  if (select confdeltype from pg_constraint where conname = 'city_aliases_city_id_fkey') <> 'c' then
    raise exception 'FAIL: city_aliases.city_id must cascade';
  end if;
  if (select array_length(conkey, 1) from pg_constraint where conname = 'city_districts_city_fkey') <> 2
     or (select array_length(conkey, 1) from pg_constraint where conname = 'city_districts_district_fkey') <> 2 then
    raise exception 'FAIL: city_districts must use composite (id, province_id) foreign keys';
  end if;
  raise notice 'PASSED: foreign keys (RESTRICT, composite province consistency, alias cascade)';

  -- Indexes.
  select count(*) into n from pg_indexes
   where schemaname = 'public' and indexname in (
     'provinces_search_key_key', 'districts_province_id_idx', 'districts_province_search_key_key',
     'cities_province_id_idx', 'cities_province_name_key', 'cities_featured_rank_key', 'cities_search_prefix_idx',
     'cities_search_trgm_idx', 'cities_replaced_by_city_id_idx', 'city_districts_district_id_idx',
     'city_districts_one_primary_key', 'city_aliases_city_search_key_key', 'city_aliases_search_prefix_idx',
     'city_aliases_search_trgm_idx');
  if n <> 14 then
    raise exception 'FAIL: expected 14 named location indexes, found %', n;
  end if;
  raise notice 'PASSED: 14 indexes';

  -- pg_trgm in schema extensions.
  if not exists (select 1 from pg_extension e join pg_namespace s on s.oid = e.extnamespace
                  where e.extname = 'pg_trgm' and s.nspname = 'extensions') then
    raise exception 'FAIL: pg_trgm must be installed in schema extensions';
  end if;

  -- Functions and the view.
  if (select provolatile from pg_proc where oid = 'public.location_search_key(text)'::regprocedure) <> 'i'
     or (select provolatile from pg_proc where oid = 'public.search_cities(text, smallint, integer, integer)'::regprocedure) <> 's'
     or (select prosecdef from pg_proc where oid = 'public.search_cities(text, smallint, integer, integer)'::regprocedure)
     or (select prosecdef from pg_proc where oid = 'public.location_search_key(text)'::regprocedure) then
    raise exception 'FAIL: location_search_key must be IMMUTABLE and search_cities STABLE, both SECURITY INVOKER';
  end if;
  if not exists (select 1 from pg_class where oid = 'public.v_city_options'::regclass
                    and 'security_invoker=true' = any (reloptions)) then
    raise exception 'FAIL: v_city_options must be security_invoker';
  end if;
  raise notice 'PASSED: pg_trgm, function properties, security_invoker view';

  -- Privileges: nothing for anon; read-only for authenticated.
  foreach t in array array['provinces', 'districts', 'cities', 'city_districts', 'city_aliases', 'v_city_options'] loop
    if has_table_privilege('anon', 'public.' || t, 'select') or has_table_privilege('anon', 'public.' || t, 'insert')
       or has_table_privilege('anon', 'public.' || t, 'update') or has_table_privilege('anon', 'public.' || t, 'delete')
       or has_table_privilege('anon', 'public.' || t, 'truncate') then
      raise exception 'FAIL: anon holds a privilege on %', t;
    end if;
    if not has_table_privilege('authenticated', 'public.' || t, 'select')
       or has_table_privilege('authenticated', 'public.' || t, 'insert')
       or has_table_privilege('authenticated', 'public.' || t, 'update')
       or has_table_privilege('authenticated', 'public.' || t, 'delete')
       or has_table_privilege('authenticated', 'public.' || t, 'truncate')
       or has_table_privilege('authenticated', 'public.' || t, 'references')
       or has_table_privilege('authenticated', 'public.' || t, 'trigger') then
      raise exception 'FAIL: authenticated must hold SELECT only on %', t;
    end if;
  end loop;
  if has_function_privilege('anon', 'public.search_cities(text, smallint, integer, integer)', 'execute')
     or has_function_privilege('anon', 'public.location_search_key(text)', 'execute')
     or not has_function_privilege('authenticated', 'public.search_cities(text, smallint, integer, integer)', 'execute')
     or not has_function_privilege('authenticated', 'public.location_search_key(text)', 'execute') then
    raise exception 'FAIL: function execute must be granted to authenticated only';
  end if;
  raise notice 'PASSED: privileges (anon none; authenticated read-only; functions authenticated only)';

  -- The search key.
  if public.location_search_key('Jāfarābād') <> 'jafarabad'
     or public.location_search_key('  Rahim-Yar  Khan ') <> 'rahim yar khan'
     or public.location_search_key('D.I. Khan') <> 'd i khan'
     or public.location_search_key('ÑÇṢṬḌẒḤṚŚ') <> 'ncstdzhrs'
     or public.location_search_key('ĀĪŪĒŌ') <> 'aiueo'
     or public.location_search_key('کراچی') <> 'کراچی'
     or public.location_search_key('---') is not null then
    raise exception 'FAIL: location_search_key normalisation';
  end if;
  raise notice 'PASSED: location_search_key';
end $$;

-- ---- As a signed-in user (no real account needed: reads are open) ----
select set_config('request.jwt.claims',
  json_build_object('sub', '00000000-0000-4000-8000-0000000000aa', 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
begin
  if current_user <> 'authenticated' then
    raise exception 'UNSAFE: not running as authenticated — stopping';
  end if;
  perform count(*) from public.provinces;
  perform count(*) from public.districts;
  perform count(*) from public.cities;
  perform count(*) from public.city_districts;
  perform count(*) from public.city_aliases;
  perform count(*) from public.v_city_options;
  perform count(*) from public.search_cities(null);
  perform count(*) from public.search_cities('la');
  raise notice 'PASSED: authenticated can read the tables, the view and search_cities()';

  begin
    insert into public.provinces (name, kind, source) values ('Test Province', 'province', 'manual');
    raise exception 'FAIL: authenticated inserted a province';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.cities set name = name;
    raise exception 'FAIL: authenticated updated cities';
  exception when insufficient_privilege then null;
  end;
  begin
    delete from public.city_aliases;
    raise exception 'FAIL: authenticated deleted aliases';
  exception when insufficient_privilege then null;
  end;
  raise notice 'PASSED: authenticated cannot write';
end $$;

reset role;

-- ---- As anon: nothing ----
set local role anon;
do $$
begin
  if current_user <> 'anon' then
    raise exception 'UNSAFE: not running as anon — stopping';
  end if;
  begin
    perform count(*) from public.cities;
    raise exception 'FAIL: anon read cities';
  exception when insufficient_privilege then null;
  end;
  begin
    perform count(*) from public.v_city_options;
    raise exception 'FAIL: anon read v_city_options';
  exception when insufficient_privilege then null;
  end;
  begin
    perform count(*) from public.search_cities('la');
    raise exception 'FAIL: anon ran search_cities()';
  exception when insufficient_privilege then null;
  end;
  raise notice 'PASSED: anon has no access';
end $$;
reset role;

do $$ begin raise notice 'ALL 06_locations_check CHECKS PASSED (rolling back)'; end $$;

rollback;
