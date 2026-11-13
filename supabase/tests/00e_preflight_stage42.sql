-- CricEco · Stage 4.2 PREFLIGHT (read-only). Run in the SQL Editor BEFORE
-- migration 6 (locations) and migration 7 (user_roles). Changes nothing:
-- only catalog reads and aggregate counts (no personal data, no ids).
--
-- Expected before Stage 4.2: every "absent" check = OK, prerequisites = OK.
-- "pg_trgm" may be installed already, but only in schema extensions.
-- The two reports at the end are for the record (city text values and the
-- profiles.role / data-row comparison the user_roles backfill is based on).

-- 1. Checks (one row each: check | result | detail).
select check_name, case when ok then 'OK' else 'STOP' end as result, detail
from (
  select 1 as n, 'server version' as check_name, true as ok, current_setting('server_version') as detail
  union all
  select 2, 'location tables / view absent',
         to_regclass('public.provinces') is null and to_regclass('public.districts') is null
           and to_regclass('public.cities') is null and to_regclass('public.city_districts') is null
           and to_regclass('public.city_aliases') is null and to_regclass('public.v_city_options') is null,
         coalesce((select string_agg(t, ', ') from unnest(array['public.provinces', 'public.districts',
                     'public.cities', 'public.city_districts', 'public.city_aliases', 'public.v_city_options']) t
                    where to_regclass(t) is not null), 'none present')
  union all
  select 3, 'location functions absent',
         not exists (select 1 from pg_proc p join pg_namespace s on s.oid = p.pronamespace
                      where s.nspname = 'public' and p.proname in ('location_search_key', 'search_cities')),
         coalesce((select string_agg(p.proname, ', ') from pg_proc p join pg_namespace s on s.oid = p.pronamespace
                    where s.nspname = 'public' and p.proname in ('location_search_key', 'search_cities')), 'none present')
  union all
  select 4, 'user_roles / app_role absent',
         to_regclass('public.user_roles') is null and to_regtype('public.app_role') is null,
         'user_roles=' || coalesce(to_regclass('public.user_roles')::text, 'absent')
           || ', app_role=' || coalesce(to_regtype('public.app_role')::text, 'absent')
  union all
  select 5, 'user_roles trigger functions absent',
         not exists (select 1 from pg_proc p join pg_namespace s on s.oid = p.pronamespace
                      where s.nspname = 'public' and p.proname in ('player_profiles_grant_role',
                            'player_profiles_revoke_role', 'clubs_grant_owner_role', 'clubs_revoke_owner_role')),
         coalesce((select string_agg(p.proname, ', ') from pg_proc p join pg_namespace s on s.oid = p.pronamespace
                    where s.nspname = 'public' and p.proname in ('player_profiles_grant_role',
                          'player_profiles_revoke_role', 'clubs_grant_owner_role', 'clubs_revoke_owner_role')),
                  'none present')
  union all
  select 6, 'pg_trgm available',
         exists (select 1 from pg_available_extensions where name = 'pg_trgm'),
         coalesce((select 'installed in schema ' || n.nspname || ' (v' || e.extversion || ')'
                     from pg_extension e join pg_namespace n on n.oid = e.extnamespace where e.extname = 'pg_trgm'),
                  'not installed (migration 6 installs it in schema extensions)')
  union all
  select 7, 'pg_trgm not installed outside schema extensions',
         not exists (select 1 from pg_extension e join pg_namespace n on n.oid = e.extnamespace
                      where e.extname = 'pg_trgm' and n.nspname <> 'extensions'),
         'migration 6 stops if this is STOP'
  union all
  select 8, 'schema extensions exists',
         exists (select 1 from pg_namespace where nspname = 'extensions'),
         'Supabase default'
  union all
  select 9, 'authenticated may use schema extensions',
         exists (select 1 from pg_namespace where nspname = 'extensions')
           and has_schema_privilege('authenticated', 'extensions', 'usage'),
         'search_cities() needs the pg_trgm operator in schema extensions'
  union all
  select 10, 'migration 1 helper set_last_updated_at() present',
         to_regprocedure('public.set_last_updated_at()') is not null, ''
  union all
  select 11, 'profiles / player_profiles / clubs present',
         to_regclass('public.profiles') is not null and to_regclass('public.player_profiles') is not null
           and to_regclass('public.clubs') is not null, ''
) checks
order by n;

-- 2. Row counts (aggregates only).
select (select count(*) from public.profiles)        as profiles,
       (select count(*) from public.player_profiles) as player_profiles,
       (select count(*) from public.clubs)           as clubs;

-- 3. City text values in use today, and whether each equals (trim / case
--    insensitive) one of the app's 20 featured cities (kPakistanCities).
with featured(name) as (
  values ('Karachi'), ('Lahore'), ('Islamabad'), ('Rawalpindi'), ('Faisalabad'), ('Multan'), ('Peshawar'),
         ('Quetta'), ('Sialkot'), ('Hyderabad'), ('Gujranwala'), ('Sargodha'), ('Bahawalpur'), ('Sukkur'),
         ('Larkana'), ('Abbottabad'), ('Mardan'), ('Sahiwal'), ('Gujrat'), ('Rahim Yar Khan')
), used as (
  select 'current_addresses' as source, city from public.current_addresses
  union all select 'permanent_addresses', city from public.permanent_addresses
  union all select 'clubs', city from public.clubs
)
select u.source, u.city, count(*) as rows,
       exists (select 1 from featured f where lower(f.name) = lower(btrim(u.city))) as featured_match
  from used u
 group by u.source, u.city
 order by u.source, u.city;

-- 4. profiles.role against the data rows (the user_roles backfill grants
--    roles from the rows only: player_profiles → player, clubs → club_owner).
select coalesce(p.role, 'NULL') as profiles_role,
       (pp.user_id is not null)  as has_player_profile,
       (c.owner_id is not null)  as owns_club,
       count(*)                  as accounts
  from public.profiles p
  left join public.player_profiles pp on pp.user_id = p.id
  left join public.clubs c on c.owner_id = p.id
 group by 1, 2, 3
 order by 1, 2, 3;
