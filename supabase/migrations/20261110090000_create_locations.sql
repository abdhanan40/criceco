-- CricEco · migration 6 · nationwide location lookup (Stage 4.2, additive only)
-- provinces → districts → cities (cities, towns and supported localities),
-- city_districts (a city may span several districts, e.g. Karachi) and
-- city_aliases (alternate spellings / Urdu names, for search).
--
-- Adds, and changes nothing that exists (no existing table, column, policy,
-- grant or row is touched):
--   * extension pg_trgm in schema extensions (similar-spelling search)
--   * location_search_key()  — the one normalisation used for matching/search
--   * 5 tables, their keys, checks and indexes; RLS: signed-in users read all
--     rows, nobody writes through the API (data is loaded by reviewed data
--     scripts: supabase/seed/locations/apply_locations.sql)
--   * v_city_options (security_invoker view) and search_cities()
-- The tables start EMPTY. Production data source: GeoNames (CC BY 4.0, see
-- ATTRIBUTION.md). HDX P-code columns stay NULL until HDX is approved.
-- Area / locality stays free text elsewhere; profiles, addresses and clubs
-- keep their text city columns (city_id columns arrive in later stages).
--
-- Depends on migration 1: public.set_last_updated_at().
-- NOT APPLIED. Run tests/00e_preflight_stage42.sql first (see supabase/README.md).

-- ---------------------------------------------------------------------------
-- Guards: stop loudly instead of guessing.
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regclass('public.provinces') is not null or to_regclass('public.districts') is not null
     or to_regclass('public.cities') is not null or to_regclass('public.city_districts') is not null
     or to_regclass('public.city_aliases') is not null or to_regclass('public.v_city_options') is not null then
    raise exception 'migration 6: a location table or view already exists — nothing changed';
  end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname in ('location_search_key', 'search_cities')) then
    raise exception 'migration 6: location_search_key() or search_cities() already exists — nothing changed';
  end if;
  if exists (select 1 from pg_extension e join pg_namespace n on n.oid = e.extnamespace
              where e.extname = 'pg_trgm' and n.nspname <> 'extensions') then
    raise exception 'migration 6: pg_trgm is installed outside schema extensions — resolve before applying';
  end if;
  if to_regprocedure('public.set_last_updated_at()') is null then
    raise exception 'migration 6: public.set_last_updated_at() (migration 1) is missing';
  end if;
end $$;

-- Supabase already has schema "extensions" (no-op there); a plain local
-- PostgreSQL needs it created.
create schema if not exists extensions;
create extension if not exists pg_trgm with schema extensions;

-- ---------------------------------------------------------------------------
-- The search key: lower case, common Latin diacritics folded (ā → a),
-- punctuation and spaces collapsed to one space. Non-Latin letters (Urdu)
-- are kept. IMMUTABLE, so it can feed generated columns and indexes.
-- Mirrored by searchKey() in tool/locations/locations_import.dart.
-- ---------------------------------------------------------------------------
create or replace function public.location_search_key(p_text text)
returns text
language sql
immutable
strict
parallel safe
set search_path = ''
as $$
  -- One translate() for case folding too (A–Z and the listed letters only),
  -- so the result never depends on the database locale and matches the
  -- Dart mirror exactly. Other characters are kept as they are.
  select nullif(btrim(regexp_replace(
           translate(p_text,
                     'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
                  || 'āáàâäãå' || 'īíìîï' || 'ūúùûü' || 'ēéèêë' || 'ōóòôöõ' || 'ñçṣṭḍẓḥṛś'
                  || 'ĀÁÀÂÄÃÅ' || 'ĪÍÌÎÏ' || 'ŪÚÙÛÜ' || 'ĒÉÈÊË' || 'ŌÓÒÔÖÕ' || 'ÑÇṢṬḌẒḤṚŚ',
                     'abcdefghijklmnopqrstuvwxyz'
                  || 'aaaaaaa' || 'iiiii' || 'uuuuu' || 'eeeee' || 'oooooo' || 'ncstdzhrs'
                  || 'aaaaaaa' || 'iiiii' || 'uuuuu' || 'eeeee' || 'oooooo' || 'ncstdzhrs'),
           '[\s!-/:-@\[-`{-~ -¿ -⁯،؛؟۔]+', ' ', 'g')), '')
$$;

-- ---------------------------------------------------------------------------
-- Tables. Database-generated identity keys (never reused or renumbered; rows
-- are deactivated, never deleted). Source keys are separate unique columns;
-- data scripts match on them, never on ids.
-- ---------------------------------------------------------------------------
create table public.provinces (
  id               smallint generated always as identity primary key,
  name             text not null
                   constraint provinces_name_check
                   check (name = btrim(name) and char_length(name) between 2 and 80),
  display_name     text
                   constraint provinces_display_name_check
                   check (display_name is null or (display_name = btrim(display_name)
                                                  and char_length(display_name) between 2 and 80)),
  kind             text not null
                   constraint provinces_kind_check
                   check (kind in ('province', 'federal_territory', 'administrative_territory')),
  alt_names        text[] not null default '{}',
  geonames_id      integer constraint provinces_geonames_id_key unique,
  geonames_admin1  text constraint provinces_geonames_admin1_key unique
                   constraint provinces_geonames_admin1_check check (geonames_admin1 ~ '^[0-9]{2}$'),
  hdx_pcode        text constraint provinces_hdx_pcode_key unique
                   constraint provinces_hdx_pcode_check check (hdx_pcode ~ '^PK[0-9]$'),
  sort_order       smallint not null default 0,
  is_active        boolean not null default true,
  source           text not null
                   constraint provinces_source_check check (source in ('geonames', 'hdx_cod_ab', 'manual')),
  source_version   text,
  created_at       timestamptz not null default now(),
  last_updated_at  timestamptz not null default now(),
  search_key       text generated always as (public.location_search_key(name)) stored,
  constraint provinces_source_key_check
    check (geonames_id is not null or hdx_pcode is not null or source = 'manual')
);
create unique index provinces_search_key_key on public.provinces (search_key);

create table public.districts (
  id               integer generated always as identity primary key,
  province_id      smallint not null
                   constraint districts_province_id_fkey references public.provinces (id) on delete restrict,
  name             text not null
                   constraint districts_name_check
                   check (name = btrim(name) and char_length(name) between 2 and 80),
  alt_names        text[] not null default '{}',
  geonames_id      integer constraint districts_geonames_id_key unique,
  hdx_pcode        text constraint districts_hdx_pcode_key unique
                   constraint districts_hdx_pcode_check check (hdx_pcode ~ '^PK[0-9]{3}$'),
  is_active        boolean not null default true,
  source           text not null
                   constraint districts_source_check check (source in ('geonames', 'hdx_cod_ab', 'manual')),
  source_ref       text,
  source_version   text,
  created_at       timestamptz not null default now(),
  last_updated_at  timestamptz not null default now(),
  search_key       text generated always as (public.location_search_key(name)) stored,
  constraint districts_id_province_key unique (id, province_id),
  constraint districts_source_key_check
    check (geonames_id is not null or hdx_pcode is not null or (source = 'manual' and source_ref is not null))
);
create index districts_province_id_idx on public.districts (province_id);
create unique index districts_province_search_key_key on public.districts (province_id, search_key);

create table public.cities (
  id                  integer generated always as identity primary key,
  province_id         smallint not null
                      constraint cities_province_id_fkey references public.provinces (id) on delete restrict,
  name                text not null
                      constraint cities_name_check
                      check (name = btrim(name) and char_length(name) between 2 and 80),
  -- Curated tie-breaker, required only when two cities of one province share a name.
  qualifier           text
                      constraint cities_qualifier_check
                      check (qualifier is null or (qualifier = btrim(qualifier)
                                                  and char_length(qualifier) between 2 and 80)),
  kind                text not null default 'city'
                      constraint cities_kind_check check (kind in ('city', 'town', 'cantonment', 'locality')),
  geonames_id         integer constraint cities_geonames_id_key unique,
  geonames_fcode      text,
  featured_rank       smallint constraint cities_featured_rank_check check (featured_rank between 1 and 100),
  latitude            numeric(8, 5) constraint cities_latitude_check check (latitude between -90 and 90),
  longitude           numeric(8, 5) constraint cities_longitude_check check (longitude between -180 and 180),
  is_active           boolean not null default true,
  replaced_by_city_id integer
                      constraint cities_replaced_by_city_id_fkey references public.cities (id) on delete restrict,
  source              text not null
                      constraint cities_source_check check (source in ('geonames', 'manual')),
  source_ref          text,
  source_version      text,
  created_at          timestamptz not null default now(),
  last_updated_at     timestamptz not null default now(),
  search_key          text generated always as (public.location_search_key(name)) stored,
  constraint cities_id_province_key unique (id, province_id),
  constraint cities_source_key_check
    check (geonames_id is not null or (source = 'manual' and source_ref is not null)),
  constraint cities_replaced_check
    check (replaced_by_city_id is null or (not is_active and replaced_by_city_id <> id))
);
create index cities_province_id_idx on public.cities (province_id);
create unique index cities_province_name_key
  on public.cities (province_id, search_key, coalesce(public.location_search_key(qualifier), ''));
create unique index cities_featured_rank_key on public.cities (featured_rank) where featured_rank is not null;
create index cities_search_prefix_idx on public.cities (search_key text_pattern_ops) where is_active;
create index cities_search_trgm_idx on public.cities using gin (search_key extensions.gin_trgm_ops);
create index cities_replaced_by_city_id_idx on public.cities (replaced_by_city_id)
  where replaced_by_city_id is not null;

-- A city ↔ district link. province_id is repeated so the composite foreign
-- keys guarantee a city and its districts are in the same province.
create table public.city_districts (
  city_id      integer  not null,
  district_id  integer  not null,
  province_id  smallint not null,
  is_primary   boolean  not null default false,
  source       text not null
               constraint city_districts_source_check check (source in ('geonames', 'hdx_cod_ab', 'manual')),
  created_at   timestamptz not null default now(),
  constraint city_districts_pkey primary key (city_id, district_id),
  constraint city_districts_city_fkey foreign key (city_id, province_id)
    references public.cities (id, province_id) on delete restrict,
  constraint city_districts_district_fkey foreign key (district_id, province_id)
    references public.districts (id, province_id) on delete restrict
);
create index city_districts_district_id_idx on public.city_districts (district_id);
create unique index city_districts_one_primary_key on public.city_districts (city_id) where is_primary;

create table public.city_aliases (
  id            bigint generated always as identity primary key,
  city_id       integer not null
                constraint city_aliases_city_id_fkey references public.cities (id) on delete cascade,
  alias         text not null
                constraint city_aliases_alias_check
                check (alias = btrim(alias) and char_length(alias) between 2 and 80),
  language      text constraint city_aliases_language_check check (language ~ '^[a-z]{2,3}$'),
  kind          text not null default 'alternate'
                constraint city_aliases_kind_check
                check (kind in ('alternate', 'official', 'historic', 'colloquial', 'transliteration')),
  is_searchable boolean not null default true,
  source        text not null constraint city_aliases_source_check check (source in ('geonames', 'manual')),
  geonames_alternatename_id integer constraint city_aliases_geonames_alternatename_id_key unique,
  created_at    timestamptz not null default now(),
  search_key    text generated always as (public.location_search_key(alias)) stored
);
create unique index city_aliases_city_search_key_key on public.city_aliases (city_id, search_key);
create index city_aliases_search_prefix_idx on public.city_aliases (search_key text_pattern_ops)
  where is_searchable;
create index city_aliases_search_trgm_idx on public.city_aliases using gin (search_key extensions.gin_trgm_ops);

-- created_at can't change; last_updated_at follows every update (migration 1).
create trigger provinces_set_last_updated_at
  before update on public.provinces
  for each row execute function public.set_last_updated_at();
create trigger districts_set_last_updated_at
  before update on public.districts
  for each row execute function public.set_last_updated_at();
create trigger cities_set_last_updated_at
  before update on public.cities
  for each row execute function public.set_last_updated_at();

-- ---------------------------------------------------------------------------
-- Picker read model. security_invoker: the caller's table rights apply.
-- An active city of an active province, with no district link yet or at
-- least one active district.
-- ---------------------------------------------------------------------------
create view public.v_city_options
with (security_invoker = true)
as
select c.id,
       c.name,
       c.qualifier,
       c.kind,
       c.featured_rank,
       c.search_key,
       c.province_id,
       coalesce(p.display_name, p.name) as province_name,
       pd.district_id                   as primary_district_id,
       pd.district_name                 as primary_district_name,
       (select count(*)::integer
          from public.city_districts cd
          join public.districts d on d.id = cd.district_id and d.is_active
         where cd.city_id = c.id)       as district_count,
       c.latitude,
       c.longitude
  from public.cities c
  join public.provinces p on p.id = c.province_id and p.is_active
  left join lateral (
         select d.id as district_id, d.name as district_name
           from public.city_districts cd
           join public.districts d on d.id = cd.district_id and d.is_active
          where cd.city_id = c.id and cd.is_primary
       ) pd on true
 where c.is_active
   and (not exists (select 1 from public.city_districts cd where cd.city_id = c.id)
        or exists (select 1
                     from public.city_districts cd
                     join public.districts d on d.id = cd.district_id and d.is_active
                    where cd.city_id = c.id));

-- ---------------------------------------------------------------------------
-- search_cities(): empty / 1-character query → featured cities (no filter)
-- or the filtered cities alphabetically; otherwise ranked
-- exact name → name prefix → alias prefix → similar name → similar alias,
-- then featured rank, then name. One row per city; limit 1–50.
-- SECURITY INVOKER: runs with the caller's read rights.
-- ---------------------------------------------------------------------------
create or replace function public.search_cities(
  p_query    text     default null,
  p_province smallint default null,
  p_district integer  default null,
  p_limit    integer  default 20
)
returns setof public.v_city_options
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_key text    := public.location_search_key(p_query);
  v_lim integer := least(greatest(coalesce(p_limit, 20), 1), 50);
begin
  if v_key is null or char_length(v_key) < 2 then
    if p_province is null and p_district is null then
      return query
        select o.* from public.v_city_options o
         where o.featured_rank is not null
         order by o.featured_rank
         limit v_lim;
    else
      return query
        select o.* from public.v_city_options o
         where (p_province is null or o.province_id = p_province)
           and (p_district is null or exists (
                  select 1 from public.city_districts cd
                   where cd.city_id = o.id and cd.district_id = p_district))
         order by o.featured_rank nulls last, o.name, o.id
         limit v_lim;
    end if;
    return;
  end if;

  return query
    with hits (city_id, r) as (
      select c.id, 0 from public.cities c where c.is_active and c.search_key = v_key
      union all
      select c.id, 1 from public.cities c where c.is_active and c.search_key like v_key || '%'
      union all
      select a.city_id, 2 from public.city_aliases a where a.is_searchable and a.search_key like v_key || '%'
      union all
      select c.id, 3 from public.cities c where c.is_active and c.search_key operator(extensions.%) v_key
      union all
      select a.city_id, 4 from public.city_aliases a
       where a.is_searchable and a.search_key operator(extensions.%) v_key
    ), best as (
      select h.city_id, min(h.r) as r from hits h group by h.city_id
    )
    select o.*
      from best b
      join public.v_city_options o on o.id = b.city_id
     where (p_province is null or o.province_id = p_province)
       and (p_district is null or exists (
              select 1 from public.city_districts cd
               where cd.city_id = o.id and cd.district_id = p_district))
     order by b.r, o.featured_rank nulls last, o.name, o.id
     limit v_lim;
end;
$$;

-- ---------------------------------------------------------------------------
-- Row Level Security and least privilege. Signed-in users read every row
-- (inactive ones too, so a saved place still displays); nothing for anon;
-- no client writes. Data scripts run as the database owner / service role.
-- ---------------------------------------------------------------------------
alter table public.provinces      enable row level security;
alter table public.districts      enable row level security;
alter table public.cities         enable row level security;
alter table public.city_districts enable row level security;
alter table public.city_aliases   enable row level security;

create policy "provinces: read"      on public.provinces      for select to authenticated using (true);
create policy "districts: read"      on public.districts      for select to authenticated using (true);
create policy "cities: read"         on public.cities         for select to authenticated using (true);
create policy "city_districts: read" on public.city_districts for select to authenticated using (true);
create policy "city_aliases: read"   on public.city_aliases   for select to authenticated using (true);

revoke all on table public.provinces, public.districts, public.cities, public.city_districts,
                    public.city_aliases, public.v_city_options
  from anon, authenticated;
grant select on table public.provinces, public.districts, public.cities, public.city_districts,
                      public.city_aliases, public.v_city_options
  to authenticated;

revoke execute on function public.location_search_key(text) from public, anon;
grant execute on function public.location_search_key(text) to authenticated;
revoke execute on function public.search_cities(text, smallint, integer, integer) from public, anon;
grant execute on function public.search_cities(text, smallint, integer, integer) to authenticated;

-- Let the API see the new objects straight away.
notify pgrst, 'reload schema';
