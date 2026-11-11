-- CricEco · Migration 8 PREFLIGHT (read-only). Run in the SQL Editor BEFORE
-- migration 8 (city_id on the address tables). Changes nothing: catalog
-- reads, and aggregate counts of the city text in use (no ids, no names of
-- people).
--
-- Expected before migration 8: every check = OK. The second result is the
-- backfill PREVIEW: for each distinct city text, how many rows and what
-- migration 8 will do (rule featured / name / label / alias → an id;
-- ambiguous / unmatched → NULL, reported). It applies the same rules as
-- public.resolve_city_match() — the local test cycle checks the preview
-- equals the real backfill.
-- Also run tests/00g_address_fingerprint.sql now and again right after
-- migration 8: the results must match (no address text or timestamp moved).

-- 1. Checks.
select check_name, case when ok then 'OK' else 'STOP' end as result, detail
from (
  select 1 as n, 'migration 6 location tables present' as check_name,
         to_regclass('public.cities') is not null and to_regclass('public.city_aliases') is not null
           and to_regprocedure('public.location_search_key(text)') is not null as ok,
         '' as detail
  union all
  select 2, 'location data loaded (D1)',
         to_regclass('public.cities') is not null
           and (select count(*) from public.cities where is_active) > 0,
         'active cities: ' || coalesce((select count(*)::text from public.cities where is_active), '0')
  union all
  select 3, 'address tables present',
         to_regclass('public.current_addresses') is not null and to_regclass('public.permanent_addresses') is not null, ''
  union all
  select 4, 'address city_id absent',
         not exists (select 1 from information_schema.columns
                      where table_schema = 'public' and column_name = 'city_id'
                        and table_name in ('current_addresses', 'permanent_addresses')), ''
  union all
  select 5, 'migration 8 functions absent',
         not exists (select 1 from pg_proc p join pg_namespace s on s.oid = p.pronamespace
                      where s.nspname = 'public' and p.proname in ('resolve_city_match', 'resolve_city_id',
                                                                 'address_city_sync_from_id', 'address_city_sync_from_text',
                                                                 'save_profile_setup_v2')),
         coalesce((select string_agg(p.proname, ', ') from pg_proc p join pg_namespace s on s.oid = p.pronamespace
                    where s.nspname = 'public' and p.proname in ('resolve_city_match', 'resolve_city_id',
                                                               'address_city_sync_from_id', 'address_city_sync_from_text',
                                                               'save_profile_setup_v2')),
                  'none present')
  union all
  select 6, 'last_updated_at triggers present and enabled',
         (select count(*) from pg_trigger
           where tgname in ('current_addresses_set_last_updated_at', 'permanent_addresses_set_last_updated_at')
             and tgenabled = 'O') = 2,
         'migration 8 switches them off for the backfill only'
  union all
  select 7, 'save_profile_setup v1 present',
         to_regprocedure('public.save_profile_setup(text, text, date, text, text, text, boolean, text, text, text)')
           is not null, 'kept unchanged'
) checks
order by n;

-- 2. Backfill preview (aggregates). Columns: table | city text | rows | rule | city id.
with addr as (
  select 'current_addresses' as tbl, city from public.current_addresses
  union all
  select 'permanent_addresses', city from public.permanent_addresses
), v as (
  select tbl, city, count(*) as n, public.location_search_key(city) as key from addr group by tbl, city
), m as (
  select v.*,
         (select count(*) from public.cities c
           where c.is_active and c.featured_rank is not null and c.search_key = v.key) as f,
         (select min(c.id) from public.cities c
           where c.is_active and c.featured_rank is not null and c.search_key = v.key) as f_id,
         (select count(*) from public.cities c where c.is_active and c.search_key = v.key) as nm,
         (select min(c.id) from public.cities c where c.is_active and c.search_key = v.key) as nm_id,
         (select count(*) from public.cities c
           where c.is_active and c.qualifier is not null
             and c.search_key || ' ' || public.location_search_key(c.qualifier) = v.key) as l,
         (select min(c.id) from public.cities c
           where c.is_active and c.qualifier is not null
             and c.search_key || ' ' || public.location_search_key(c.qualifier) = v.key) as l_id,
         (select count(distinct a.city_id) from public.city_aliases a
            join public.cities c on c.id = a.city_id and c.is_active
           where a.is_searchable and a.search_key = v.key) as al,
         (select min(a.city_id) from public.city_aliases a
            join public.cities c on c.id = a.city_id and c.is_active
           where a.is_searchable and a.search_key = v.key) as al_id
    from v
)
select tbl, city, n as rows,
       case when key is null then 'empty'
            when f = 1 then 'featured'
            when nm > 1 then 'ambiguous'
            when nm = 1 then 'name'
            when l > 1 then 'ambiguous'
            when l = 1 then 'label'
            when al > 1 then 'ambiguous'
            when al = 1 then 'alias'
            else 'unmatched' end as rule,
       case when key is null then null
            when f = 1 then f_id
            when nm > 1 then null
            when nm = 1 then nm_id
            when l > 1 then null
            when l = 1 then l_id
            when al = 1 then al_id end as city_id
  from m
 order by tbl, city;
