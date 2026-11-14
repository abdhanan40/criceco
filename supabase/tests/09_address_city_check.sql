-- CricEco · migration 8 (city_id on the address tables): schema, backfill,
-- sync triggers, save_profile_setup_v2 and v1. Everything runs inside one
-- transaction and is ROLLED BACK at the end: no data is kept. Run after
-- migration 8, with the location data (D1) loaded.
--
-- PART 1 (catalog, backfill consistency, unmatched report) is read-only and
-- needs no test users. PART 2 needs ONE FRESH test user (Profile Setup not
-- done): create it in Dashboard → Authentication → Users → Add user
-- (auto-confirm) and search-replace USER_A below with its UUID.
-- Run the WHOLE script at once. A failing check raises an exception and
-- stops the script; then run `rollback;` on its own. Afterwards delete the
-- test user (its rows go with it).
-- Cities are looked up by GeoNames id (stable across databases).

begin;

-- ===================== PART 1 — as the database owner (read-only) =====================
do $$
declare
  t text;
begin
  foreach t in array array['current_addresses', 'permanent_addresses'] loop
    if not exists (select 1 from information_schema.columns
                    where table_schema = 'public' and table_name = t and column_name = 'city_id'
                      and data_type = 'integer' and is_nullable = 'YES') then
      raise exception 'FAIL: %.city_id must be a nullable integer', t;
    end if;
    if (select confdeltype from pg_constraint where conname = t || '_city_id_fkey') <> 'r'
       or (select confrelid from pg_constraint where conname = t || '_city_id_fkey') <> 'public.cities'::regclass then
      raise exception 'FAIL: %.city_id must reference cities ON DELETE RESTRICT', t;
    end if;
    if not exists (select 1 from pg_indexes where schemaname = 'public' and indexname = t || '_city_id_idx') then
      raise exception 'FAIL: index %_city_id_idx missing', t;
    end if;
    if (select tgenabled from pg_trigger where tgname = t || '_city_sync_1_from_id') is distinct from 'O'
       or (select tgenabled from pg_trigger where tgname = t || '_city_sync_2_from_text') is distinct from 'O'
       or (select tgenabled from pg_trigger where tgname = t || '_set_last_updated_at') is distinct from 'O' then
      raise exception 'FAIL: %: the sync and last_updated_at triggers must both be enabled', t;
    end if;
    if not has_table_privilege('authenticated', 'public.' || t, 'select')
       or not has_table_privilege('authenticated', 'public.' || t, 'insert')
       or not has_table_privilege('authenticated', 'public.' || t, 'update')
       or has_table_privilege('authenticated', 'public.' || t, 'delete')
       or has_table_privilege('anon', 'public.' || t, 'select') then
      raise exception 'FAIL: % grants changed', t;
    end if;
  end loop;

  if (select provolatile from pg_proc where oid = 'public.resolve_city_match(text)'::regprocedure) <> 's'
     or (select provolatile from pg_proc where oid = 'public.resolve_city_id(text)'::regprocedure) <> 's'
     or exists (select 1 from pg_proc where prosecdef and oid in (
          'public.resolve_city_match(text)'::regprocedure, 'public.resolve_city_id(text)'::regprocedure,
          'public.address_city_sync_from_id()'::regprocedure, 'public.address_city_sync_from_text()'::regprocedure,
          'public.save_profile_setup_v2(text, text, date, integer, text, text, boolean, integer, text, text)'::regprocedure)) then
    raise exception 'FAIL: resolvers must be STABLE; every migration 8 function SECURITY INVOKER';
  end if;
  if exists (select 1 from pg_proc
              where oid in ('public.resolve_city_match(text)'::regprocedure, 'public.resolve_city_id(text)'::regprocedure,
                            'public.address_city_sync_from_id()'::regprocedure,
                            'public.address_city_sync_from_text()'::regprocedure,
                            'public.save_profile_setup_v2(text, text, date, integer, text, text, boolean, integer, text, text)'::regprocedure)
                and not ('search_path=""' = any (coalesce(proconfig, '{}')))) then
    raise exception 'FAIL: every migration 8 function must pin search_path to ''''';
  end if;
  if has_function_privilege('anon', 'public.resolve_city_id(text)', 'execute')
     or has_function_privilege('anon', 'public.save_profile_setup_v2(text, text, date, integer, text, text, boolean, integer, text, text)', 'execute')
     or not has_function_privilege('authenticated', 'public.resolve_city_id(text)', 'execute')
     or not has_function_privilege('authenticated', 'public.resolve_city_match(text)', 'execute')
     or not has_function_privilege('authenticated', 'public.save_profile_setup_v2(text, text, date, integer, text, text, boolean, integer, text, text)', 'execute') then
    raise exception 'FAIL: function privileges (anon none; authenticated execute)';
  end if;
  if to_regprocedure('public.save_profile_setup(text, text, date, text, text, text, boolean, text, text, text)') is null then
    raise exception 'FAIL: save_profile_setup v1 must still exist';
  end if;
  raise notice 'PASSED: columns, foreign keys, indexes, triggers, functions, privileges, v1 kept';

  -- Every id is consistent with its text: the text is that city's name, or
  -- resolves to it.
  if exists (select 1 from (select city, city_id from public.current_addresses
                            union all select city, city_id from public.permanent_addresses) a
               join public.cities c on c.id = a.city_id
              where public.location_search_key(a.city) is distinct from c.search_key
                and public.resolve_city_id(a.city) is distinct from a.city_id) then
    raise exception 'FAIL: an address city_id does not match its city text';
  end if;
  -- Every NULL id is a text without a unique match (nothing resolvable left).
  if exists (select 1 from (select city, city_id from public.current_addresses
                            union all select city, city_id from public.permanent_addresses) a
              where a.city_id is null and public.resolve_city_id(a.city) is not null) then
    raise exception 'FAIL: a resolvable city text was left without city_id';
  end if;
  raise notice 'PASSED: ids consistent with the text (% with an id, % without)',
    (select count(*) from (select city_id from public.current_addresses
                           union all select city_id from public.permanent_addresses) x where city_id is not null),
    (select count(*) from (select city_id from public.current_addresses
                           union all select city_id from public.permanent_addresses) x where city_id is null);
end $$;

-- Unmatched / ambiguous city texts (aggregates, for the record).
select t.tbl, t.city, m.rule, count(*) as rows
  from (select 'current_addresses' as tbl, city, city_id from public.current_addresses
        union all select 'permanent_addresses', city, city_id from public.permanent_addresses) t
  cross join lateral public.resolve_city_match(t.city) m
 where t.city_id is null
 group by t.tbl, t.city, m.rule
 order by t.tbl, t.city;

-- ===================== PART 2 — as a fresh test user =====================
create temporary table g (k text primary key, id integer) on commit drop;
insert into g
select k, (select id from public.cities where geonames_id = gid)
  from (values ('lahore', 1172451), ('faisalabad', 1179400), ('karachi', 1174872),
               ('kamra_attock', 1340665), ('kamra_rwp', 1175082)) v(k, gid);
create temporary table other_user on commit drop as
  select (select p.id from public.profiles p where p.id <> 'USER_A' order by p.id limit 1) as id,
         (select count(*) from public.current_addresses where user_id <> 'USER_A') as rows;
grant select on other_user to authenticated;
grant select on g to authenticated;

select set_config('request.jwt.claims', json_build_object('sub', 'USER_A', 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare
  lahore int := (select id from g where k = 'lahore');
  faisalabad int := (select id from g where k = 'faisalabad');
  karachi int := (select id from g where k = 'karachi');
  kamra_attock int := (select id from g where k = 'kamra_attock');
  kamra_rwp int := (select id from g where k = 'kamra_rwp');
  c record;
  p record;
  n int;
begin
  if current_user <> 'authenticated' or auth.uid() is distinct from 'USER_A'::uuid then
    raise exception 'UNSAFE: not running as test user USER_A — stopping (nothing written)';
  end if;
  if exists (select 1 from public.current_addresses) or exists (select 1 from public.permanent_addresses) then
    raise exception 'FAIL: test needs a fresh USER_A (no addresses yet)';
  end if;
  if lahore is null or faisalabad is null or karachi is null or kamra_attock is null or kamra_rwp is null then
    raise exception 'FAIL: the location data (D1) must be loaded';
  end if;

  -- v2, same as current: both rows get the id and the city name.
  perform public.save_profile_setup_v2('Test User A', '0300 1234567', date '2000-05-01',
                                       faisalabad, 'Peoples Colony', 'House 1', true);
  select * into c from public.current_addresses;
  select * into p from public.permanent_addresses;
  if (c.city_id, c.city, p.city_id, p.city) is distinct from (faisalabad, 'Faisalabad', faisalabad, 'Faisalabad')
     or not (select profile_completed from public.profiles where id = 'USER_A') then
    raise exception 'FAIL: v2 (same as current) stored %/% and %/%', c.city_id, c.city, p.city_id, p.city;
  end if;

  -- v2, different permanent city; a qualified city keeps its id with the plain name.
  perform public.save_profile_setup_v2('Test User A', '+923001234567', date '2000-05-01',
                                       kamra_attock, 'Cantt', 'House 2', false, lahore, 'Gulberg', 'House 3');
  select * into c from public.current_addresses;
  select * into p from public.permanent_addresses;
  if (c.city_id, c.city, p.city_id, p.city, p.area) is distinct from (kamra_attock, 'Kamra', lahore, 'Lahore', 'Gulberg') then
    raise exception 'FAIL: v2 (different permanent) stored %/% and %/%', c.city_id, c.city, p.city_id, p.city;
  end if;
  perform public.save_profile_setup_v2('Test User A', '+923001234567', date '2000-05-01',
                                       lahore, 'Gulberg', 'House 4', true, 2147483647, 'Ignored', 'Ignored');
  select * into p from public.permanent_addresses;
  if (p.city_id, p.city, p.area, p.address) is distinct from (lahore, 'Lahore'::text, 'Gulberg'::text, 'House 4'::text) then
    raise exception 'FAIL: v2 with "same as current" must copy the current address and ignore the permanent arguments';
  end if;
  perform public.save_profile_setup_v2('Test User A', '+923001234567', date '2000-05-01',
                                       kamra_attock, 'Cantt', 'House 2', false, lahore, 'Gulberg', 'House 3');
  raise notice 'PASSED: save_profile_setup_v2 stores ids and city names';

  -- v2 refuses unknown cities and a missing permanent city.
  begin
    perform public.save_profile_setup_v2('Test User A', '+923001234567', date '2000-05-01',
                                         2147483647, 'Area', 'House', true);
    raise exception 'FAIL: v2 accepted an unknown city id';
  exception when check_violation then null;
  end;
  begin
    perform public.save_profile_setup_v2('Test User A', '+923001234567', date '2000-05-01',
                                         lahore, 'Area', 'House', false);
    raise exception 'FAIL: v2 accepted a missing permanent city';
  exception when check_violation then null;
  end;
  if (select city_id from public.current_addresses) <> kamra_attock then
    raise exception 'FAIL: a refused v2 call changed the address';
  end if;
  raise notice 'PASSED: v2 refuses unknown / missing cities (nothing changed)';

  -- Text written alone → id re-resolved.
  update public.current_addresses set city = 'Karachi';
  if (select city_id from public.current_addresses) is distinct from karachi then
    raise exception 'FAIL: text → id (Karachi)';
  end if;
  update public.current_addresses set city = 'Kamra';
  if (select city_id from public.current_addresses) is not null then
    raise exception 'FAIL: an ambiguous text (Kamra) must leave city_id NULL';
  end if;
  update public.current_addresses set city = 'Kamra (Rawalpindi)';
  if (select (city_id, city) from public.current_addresses) is distinct from (kamra_rwp, 'Kamra (Rawalpindi)'::text) then
    raise exception 'FAIL: a "Name (Qualifier)" text must resolve (text kept)';
  end if;
  update public.current_addresses set area = 'Saddar'; -- city untouched: id kept
  if (select city_id from public.current_addresses) is distinct from kamra_rwp then
    raise exception 'FAIL: an update without the city changed city_id';
  end if;
  raise notice 'PASSED: text → id (unique match, ambiguous → NULL, label, untouched city)';

  -- Id written → text follows; the id wins over a text written with it.
  update public.current_addresses set city_id = lahore;
  if (select city from public.current_addresses) <> 'Lahore' then
    raise exception 'FAIL: id → text';
  end if;
  update public.current_addresses set city = 'Karachi', city_id = faisalabad;
  if (select (city_id, city) from public.current_addresses) is distinct from (faisalabad, 'Faisalabad'::text) then
    raise exception 'FAIL: the id must win when both are written';
  end if;
  update public.current_addresses set city_id = null;
  if (select (city_id, city) from public.current_addresses) is distinct from (null::int, 'Faisalabad'::text) then
    raise exception 'FAIL: clearing the id must keep the text and leave NULL';
  end if;
  begin
    update public.current_addresses set city_id = 2147483647;
    raise exception 'FAIL: an unknown city id was stored';
  exception when foreign_key_violation then null;
  end;
  raise notice 'PASSED: id → text, id wins, cleared id stays NULL, unknown id refused';

  -- Review M1 / m1: an explicitly written id is kept (even unchanged), and a
  -- text that still names the city never drops it.
  update public.current_addresses set city_id = kamra_attock;            -- text → 'Kamra'
  update public.current_addresses set city = 'Kamra', city_id = kamra_attock;
  if (select (city_id, city) from public.current_addresses) is distinct from (kamra_attock, 'Kamra'::text) then
    raise exception 'FAIL M1a: both columns with the same id and the plain (ambiguous) name must keep the id';
  end if;
  update public.current_addresses set city = 'Kamra (Attock)';            -- text only: its label
  if (select (city_id, city) from public.current_addresses) is distinct from (kamra_attock, 'Kamra (Attock)'::text) then
    raise exception 'FAIL M1b: the qualified label of the same city must keep the id';
  end if;
  update public.current_addresses set city = 'Kamra';                     -- text only: label → plain name
  if (select (city_id, city) from public.current_addresses) is distinct from (kamra_attock, 'Kamra'::text) then
    raise exception 'FAIL M1b: changing the label to the plain name must keep the id';
  end if;
  update public.current_addresses set city = 'Lahore', city_id = kamra_attock;   -- same id, another city's text
  if (select (city_id, city) from public.current_addresses) is distinct from (kamra_attock, 'Kamra'::text) then
    raise exception 'FAIL M1c: a supplied id must win over text naming a different city';
  end if;
  update public.current_addresses set city = 'Lahore';                    -- text only, another city
  if (select (city_id, city) from public.current_addresses) is distinct from (lahore, 'Lahore'::text) then
    raise exception 'FAIL M1c: text alone naming a different city must re-resolve';
  end if;
  update public.current_addresses set city = 'Karachi', city_id = null;   -- id cleared with new text
  if (select (city_id, city) from public.current_addresses) is distinct from (karachi, 'Karachi'::text) then
    raise exception 'FAIL m1: a cleared id with new text must resolve the text';
  end if;
  update public.current_addresses set city = 'Karachi', city_id = null;   -- cleared, text unchanged
  if (select (city_id, city) from public.current_addresses) is distinct from (null::int, 'Karachi'::text) then
    raise exception 'FAIL m1: a cleared id with unchanged text must stay NULL';
  end if;
  raise notice 'PASSED: review M1 / m1 — supplied id kept, label ↔ name keeps the id, other city re-resolves, cleared id + new text resolves';

  -- v1 still works and now also fills city_id from the text.
  perform public.save_profile_setup('Test User A', '+923001234567', date '2000-05-01',
                                    'Lahore', 'Gulberg', 'House 1', false, 'Atlantis', 'Nowhere', 'House 9');
  select * into c from public.current_addresses;
  select * into p from public.permanent_addresses;
  if (c.city, c.city_id, p.city, p.city_id) is distinct from ('Lahore', lahore, 'Atlantis', null::int) then
    raise exception 'FAIL: v1 must keep its text and resolve ids (%/%, %/%)', c.city, c.city_id, p.city, p.city_id;
  end if;
  raise notice 'PASSED: save_profile_setup v1 unchanged, ids resolved from its text';

  -- RLS unchanged: only the own rows are visible, and another user's city_id
  -- can't be written.
  if (select count(*) from public.current_addresses) <> 1 or (select count(*) from public.permanent_addresses) <> 1 then
    raise exception 'FAIL: USER_A must see only their own address rows';
  end if;
  update public.current_addresses set city_id = lahore where user_id <> 'USER_A';
  get diagnostics n = row_count;
  if n <> 0 then
    raise exception 'FAIL: USER_A changed % address row(s) of other users', n;
  end if;
  if (select id from other_user) is not null then
    begin
      insert into public.permanent_addresses (user_id, city_id, city, area, address)
      values ((select id from other_user), lahore, 'Lahore', 'Area', 'House');
      raise exception 'FAIL: USER_A inserted an address for another user';
    exception when insufficient_privilege then null;
    end;
  end if;
  raise notice 'PASSED: no other user''s address can be read or written (% other row(s) untouched)',
    (select rows from other_user);
end $$;
reset role;

do $$ begin raise notice 'ALL 09_address_city_check CHECKS PASSED (rolling back)'; end $$;

rollback;
