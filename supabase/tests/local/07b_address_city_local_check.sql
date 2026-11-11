-- CricEco · LOCAL TEST ONLY — migration 8: the backfill of the local/07a
-- fixture (exact result per city text), text and last_updated_at untouched,
-- the last_updated_at trigger back on, sync on insert, an ambiguous alias,
-- an inactive city, and v2 refusing it. Rolled back: nothing is kept.
-- Run after local/07a and migration 8, as the database owner.

do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password') then
    raise exception 'LOCAL ONLY: this looks like a real Supabase auth schema';
  end if;
  if to_regclass('s43_fixture.addresses_before') is null then
    raise exception 'LOCAL ONLY: run local/07a_address_city_fixture.sql before migration 8 first';
  end if;
end $$;

begin;

do $$
declare
  lahore int := (select id from public.cities where geonames_id = 1172451);
  karachi int := (select id from public.cities where geonames_id = 1174872);
  faisalabad int := (select id from public.cities where geonames_id = 1179400);
  kamra_attock int := (select id from public.cities where geonames_id = 1340665);
  jhelum int := (select id from public.cities where geonames_id = 1175864);
  attock_city int := (select id from public.cities where geonames_id = 1184249);
  got text;
  want text;
begin
  -- B1: the exact backfill result per fixture account (current / permanent).
  select string_agg(split_part(u.email, '@', 1) || '=' || coalesce(ca.city_id::text, 'NULL') || '/'
                    || coalesce(pa.city_id::text, 'NULL'), ' ' order by u.email)
    into got
    from auth.users u
    join public.current_addresses ca on ca.user_id = u.id
    join public.permanent_addresses pa on pa.user_id = u.id
   where u.email like '%@s43.local.test';
  want := 'atlantis=NULL/' || attock_city || ' jhelum=' || jhelum || '/' || kamra_attock
       || ' kamra-label=' || kamra_attock || '/NULL kamra=NULL/NULL'
       || ' karachi=' || karachi || '/' || faisalabad
       || ' lahore-a=' || lahore || '/' || karachi
       || ' lahore-b=' || lahore || '/' || lahore
       || ' lahore-c=' || lahore || '/' || lahore
       || ' lyallpur=' || faisalabad || '/NULL'
       || ' other=NULL/' || karachi;
  if got is distinct from want then
    raise exception 'FAIL B1: backfill gave %, expected %', got, want;
  end if;
  if (select rule from public.resolve_city_match('Kamra')) <> 'ambiguous'
     or (select rule from public.resolve_city_match('Kamra (Attock)')) <> 'label'
     or (select rule from public.resolve_city_match('Lyallpur')) <> 'alias'
     or (select rule from public.resolve_city_match('  lahore  ')) <> 'featured'
     or (select rule from public.resolve_city_match('Jhelum')) <> 'name'
     or (select rule from public.resolve_city_match('Attock')) <> 'alias'
     or (select rule from public.resolve_city_match('Atlantis')) <> 'unmatched'
     or (select rule from public.resolve_city_match('---')) <> 'empty' then
    raise exception 'FAIL B1: resolve_city_match rules';
  end if;
  raise notice 'PASSED B1: backfill — featured (any case / spacing), name, label, alias; ambiguous and unmatched NULL';

  -- B2: nothing else changed — city text, area, address, created_at, last_updated_at.
  if exists (select 1 from s43_fixture.addresses_before b
               left join (select 'current_addresses' as tbl, user_id, city, area, address, created_at, last_updated_at
                            from public.current_addresses
                          union all
                          select 'permanent_addresses', user_id, city, area, address, created_at, last_updated_at
                            from public.permanent_addresses) a
                 on a.tbl = b.tbl and a.user_id = b.user_id
              where (a.city, a.area, a.address, a.created_at, a.last_updated_at)
                    is distinct from (b.city, b.area, b.address, b.created_at, b.last_updated_at)) then
    raise exception 'FAIL B2: the backfill changed an address column or timestamp';
  end if;
  raise notice 'PASSED B2: city text and last_updated_at untouched by the backfill';

  -- B3: the last_updated_at trigger is back on.
  update public.current_addresses set area = 'Area 2'
   where user_id = (select id from auth.users where email = 'karachi@s43.local.test');
  if (select last_updated_at from public.current_addresses
       where user_id = (select id from auth.users where email = 'karachi@s43.local.test'))
     = (select b.last_updated_at from s43_fixture.addresses_before b
         where b.tbl = 'current_addresses'
           and b.user_id = (select id from auth.users where email = 'karachi@s43.local.test')) then
    raise exception 'FAIL B3: last_updated_at did not move — its trigger is still disabled';
  end if;
  raise notice 'PASSED B3: last_updated_at trigger re-enabled';

  -- B4: sync on insert (as the owner, like any write).
  insert into auth.users (email) values ('insert-a@s43.local.test'), ('insert-b@s43.local.test');
  insert into public.current_addresses (user_id, city, area, address)
  values ((select id from auth.users where email = 'insert-a@s43.local.test'), 'faisalabad', 'A', 'H');
  insert into public.current_addresses (user_id, city, city_id, area, address)
  values ((select id from auth.users where email = 'insert-b@s43.local.test'), 'whatever', karachi, 'A', 'H');
  if (select (city_id, city) from public.current_addresses
       where user_id = (select id from auth.users where email = 'insert-a@s43.local.test'))
     is distinct from (faisalabad, 'faisalabad'::text)
     or (select (city_id, city) from public.current_addresses
          where user_id = (select id from auth.users where email = 'insert-b@s43.local.test'))
     is distinct from (karachi, 'Karachi'::text) then
    raise exception 'FAIL B4: sync on insert (text → id; id → name)';
  end if;
  raise notice 'PASSED B4: sync on insert';

  -- B5: an alias shared by two cities is ambiguous.
  insert into public.city_aliases (city_id, alias, source) values (lahore, 'Zzshared', 'manual'),
                                                                  (karachi, 'Zzshared', 'manual');
  if (select (city_id, rule) from public.resolve_city_match('Zzshared')) is distinct from (null::int, 'ambiguous'::text) then
    raise exception 'FAIL B5: an alias of two cities must be ambiguous';
  end if;
  raise notice 'PASSED B5: ambiguous alias → NULL';

  -- B6: an inactive city is never resolved.
  update public.cities set is_active = false where id = jhelum;
  if public.resolve_city_id('Jhelum') is not null then
    raise exception 'FAIL B6: an inactive city was resolved';
  end if;
  raise notice 'PASSED B6: inactive cities are skipped';
end $$;

-- B7: v2 refuses an inactive city (as a signed-in user, Jhelum still inactive).
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from auth.users where email = 'insert-a@s43.local.test'),
                    'role', 'authenticated')::text, true);
set local role authenticated;
do $$
begin
  begin
    perform public.save_profile_setup_v2('Insert A', '+923001234567', date '2000-01-01',
      (select c.id from public.cities c where c.search_key = 'jhelum'), 'Area', 'House', true);
    raise exception 'FAIL B7: v2 accepted an inactive city';
  exception when check_violation then null;
  end;
  raise notice 'PASSED B7: v2 refuses an inactive city';
end $$;
reset role;

do $$ begin raise notice 'ALL local/07b_address_city_local_check CHECKS PASSED (rolling back)'; end $$;

rollback;
