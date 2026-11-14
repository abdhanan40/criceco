-- CricEco · migration 8 · city_id on the address tables (Stage 4.3.3, additive only)
-- current_addresses / permanent_addresses keep their text city (older app
-- builds and save_profile_setup v1 still write it); a nullable city_id now
-- points at public.cities (migration 6) and the two are kept in step:
--   * resolve_city_match() / resolve_city_id() — text → city, unique matches only
--   * a one-off backfill of existing rows (city text and last_updated_at untouched)
--   * address_city_sync_from_id() / _from_text() — a written id sets the text
--     (and always wins); text written alone keeps the id while it still names
--     that city, else re-resolves it (NULL when there is no unique match)
--   * save_profile_setup_v2() — Profile Setup with city ids; v1 is unchanged
-- Nothing existing is modified: no column, constraint, policy, grant or
-- function of migrations 1–7 changes. city_id stays nullable (expand phase);
-- making it required is a later, separate step once every row is resolved.
--
-- Depends on migrations 2 (address tables) and 6 (location tables); the
-- backfill needs the location data (D1) to find anything.
-- RUN INSIDE ONE TRANSACTION (begin; set local lock_timeout = '5s'; … commit;):
-- it locks both address tables and briefly disables their last_updated_at
-- trigger for the backfill (ALTER TABLE, re-enabled before the end).
-- NOT APPLIED. Run tests/00f_preflight_address_cities.sql first (see supabase/README.md).

lock table public.current_addresses, public.permanent_addresses in share row exclusive mode;

do $$
begin
  if to_regclass('public.cities') is null or to_regprocedure('public.location_search_key(text)') is null then
    raise exception 'migration 8: migration 6 (location tables) is required';
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and column_name = 'city_id'
                and table_name in ('current_addresses', 'permanent_addresses')) then
    raise exception 'migration 8: an address table already has city_id — nothing changed';
  end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname in ('resolve_city_match', 'resolve_city_id',
                                                         'address_city_sync_from_id', 'address_city_sync_from_text',
                                                         'save_profile_setup_v2')) then
    raise exception 'migration 8: a migration 8 function already exists — nothing changed';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Columns: nullable, RESTRICT (a city in use can be deactivated, never deleted).
-- ---------------------------------------------------------------------------
alter table public.current_addresses
  add column city_id integer
  constraint current_addresses_city_id_fkey references public.cities (id) on delete restrict;
alter table public.permanent_addresses
  add column city_id integer
  constraint permanent_addresses_city_id_fkey references public.cities (id) on delete restrict;

create index current_addresses_city_id_idx on public.current_addresses (city_id);
create index permanent_addresses_city_id_idx on public.permanent_addresses (city_id);

comment on column public.current_addresses.city_id is
  'The city (public.cities). Kept in step with city by the address_city_sync_* triggers; NULL when the text has no unique match.';
comment on column public.permanent_addresses.city_id is
  'The city (public.cities). Kept in step with city by the address_city_sync_* triggers; NULL when the text has no unique match.';

-- ---------------------------------------------------------------------------
-- Text → city. Active cities only; an id only for a UNIQUE match, in order:
--   1 featured   — a featured city of that name (the 20-city picker wrote these)
--   2 name       — exactly one city of that name (several → ambiguous, stop)
--   3 label      — exactly one "Name (Qualifier)", e.g. "Kamra (Attock)"
--   4 alias      — exactly one city with that searchable alias
-- rule: featured | name | label | alias | ambiguous | unmatched | empty.
-- Runs as the caller (signed-in users can read the location tables).
-- ---------------------------------------------------------------------------
create or replace function public.resolve_city_match(p_text text)
returns table (city_id integer, rule text)
language sql
stable
security invoker
set search_path = ''
as $$
  with k as (select public.location_search_key(p_text) as key),
  featured as (
    select c.id from public.cities c, k
     where c.is_active and c.featured_rank is not null and c.search_key = k.key),
  named as (
    select c.id from public.cities c, k
     where c.is_active and c.search_key = k.key),
  labelled as (
    select c.id from public.cities c, k
     where c.is_active and c.qualifier is not null
       and c.search_key || ' ' || public.location_search_key(c.qualifier) = k.key),
  aliased as (
    select distinct a.city_id as id
      from public.city_aliases a
      join public.cities c on c.id = a.city_id and c.is_active, k
     where a.is_searchable and a.search_key = k.key)
  select case
           when (select key from k) is null then null
           when (select count(*) from featured) = 1 then (select id from featured)
           when (select count(*) from named) > 1 then null
           when (select count(*) from named) = 1 then (select id from named)
           when (select count(*) from labelled) > 1 then null
           when (select count(*) from labelled) = 1 then (select id from labelled)
           when (select count(*) from aliased) = 1 then (select id from aliased)
         end,
         case
           when (select key from k) is null then 'empty'
           when (select count(*) from featured) = 1 then 'featured'
           when (select count(*) from named) > 1 then 'ambiguous'
           when (select count(*) from named) = 1 then 'name'
           when (select count(*) from labelled) > 1 then 'ambiguous'
           when (select count(*) from labelled) = 1 then 'label'
           when (select count(*) from aliased) > 1 then 'ambiguous'
           when (select count(*) from aliased) = 1 then 'alias'
           else 'unmatched'
         end
$$;

create or replace function public.resolve_city_id(p_text text)
returns integer
language sql
stable
security invoker
set search_path = ''
as $$
  select m.city_id from public.resolve_city_match(p_text) m
$$;

-- ---------------------------------------------------------------------------
-- Backfill, BEFORE the sync trigger exists (so no city text is rewritten) and
-- with the last_updated_at trigger off (so no timestamp moves). Unmatched and
-- ambiguous rows keep city_id NULL. The NOTICEs are the backfill report.
-- ---------------------------------------------------------------------------
alter table public.current_addresses disable trigger current_addresses_set_last_updated_at;
alter table public.permanent_addresses disable trigger permanent_addresses_set_last_updated_at;

update public.current_addresses a
   set city_id = r.city_id
  from (select x.id, m.city_id from public.current_addresses x
          cross join lateral public.resolve_city_match(x.city) m) r
 where r.id = a.id and r.city_id is not null;

update public.permanent_addresses a
   set city_id = r.city_id
  from (select x.id, m.city_id from public.permanent_addresses x
          cross join lateral public.resolve_city_match(x.city) m) r
 where r.id = a.id and r.city_id is not null;

alter table public.current_addresses enable trigger current_addresses_set_last_updated_at;
alter table public.permanent_addresses enable trigger permanent_addresses_set_last_updated_at;

do $$
declare
  r record;
begin
  for r in
    select t.tbl, m.rule, count(*) as n
      from (select 'current_addresses' as tbl, city from public.current_addresses
            union all
            select 'permanent_addresses', city from public.permanent_addresses) t
      cross join lateral public.resolve_city_match(t.city) m
     group by t.tbl, m.rule
     order by t.tbl, m.rule
  loop
    raise notice 'migration 8 backfill: % — %: % row(s)', r.tbl, r.rule, r.n;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Keep text and id in step on every write. Two BEFORE triggers per table,
-- fired by the columns a statement WRITES (UPDATE OF: the column appears in
-- the SET list, even with an unchanged value) and always on INSERT; they run
-- in name order, the id step (…_1_from_id) before the text step (…_2_from_text):
--
--   1 from_id   (city_id written)
--       id given        → the text becomes that city's plain name (decision 8a);
--                         an explicitly supplied id is kept, even if unchanged
--       id NULL         → if the text changed (or on insert): resolve the text;
--                         otherwise the id stays NULL (cleared on purpose)
--   2 from_text (city written)
--       text unchanged  → nothing
--       id set and the text still names that city (its name, its
--         "Name (Qualifier)" label, or text that resolves to it)
--                       → the id is kept (an ambiguous text never drops it)
--       otherwise       → the id is resolved from the text (NULL without a
--                         unique match): the text names a different city
--       an unknown id   → left for the foreign key to refuse
-- When both columns are written, step 1 has already set the text from the
-- id, so step 2 keeps that id: the supplied id always wins.
-- Both run as the caller (signed-in users can read the location tables).
-- ---------------------------------------------------------------------------
create or replace function public.address_city_sync_from_id()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_name text;
begin
  if new.city_id is not null then
    select c.name into v_name from public.cities c where c.id = new.city_id;
    if v_name is not null then
      new.city := v_name;
    end if;
  elsif tg_op = 'INSERT' or new.city is distinct from old.city then
    new.city_id := public.resolve_city_id(new.city);
  end if;
  return new;
end;
$$;

create or replace function public.address_city_sync_from_text()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_key  text;
  c      record;
begin
  if tg_op = 'UPDATE' and new.city is not distinct from old.city then
    return new;
  end if;
  if new.city_id is not null then
    select x.id, x.search_key, x.qualifier into c from public.cities x where x.id = new.city_id;
    if not found then
      return new; -- unknown id: the foreign key refuses it
    end if;
    v_key := public.location_search_key(new.city);
    if v_key = c.search_key
       or v_key = c.search_key || ' ' || public.location_search_key(c.qualifier)
       or public.resolve_city_id(new.city) = c.id then
      return new; -- the text still names this city: keep its id
    end if;
  end if;
  new.city_id := public.resolve_city_id(new.city);
  return new;
end;
$$;

create trigger current_addresses_city_sync_1_from_id
  before insert or update of city_id on public.current_addresses
  for each row execute function public.address_city_sync_from_id();
create trigger current_addresses_city_sync_2_from_text
  before insert or update of city on public.current_addresses
  for each row execute function public.address_city_sync_from_text();
create trigger permanent_addresses_city_sync_1_from_id
  before insert or update of city_id on public.permanent_addresses
  for each row execute function public.address_city_sync_from_id();
create trigger permanent_addresses_city_sync_2_from_text
  before insert or update of city on public.permanent_addresses
  for each row execute function public.address_city_sync_from_text();

-- ---------------------------------------------------------------------------
-- save_profile_setup_v2: User Profile Setup in one transaction, with city ids
-- (active cities only). The same rules as v1 (migration 4, unchanged); the
-- city text is stored from the id. SECURITY INVOKER: the caller's own rows
-- only (RLS).
-- ---------------------------------------------------------------------------
create or replace function public.save_profile_setup_v2(
  p_full_name                 text,
  p_phone                     text,
  p_date_of_birth             date,
  p_current_city_id           integer,
  p_current_area              text,
  p_current_address           text,
  p_permanent_same_as_current boolean,
  p_permanent_city_id         integer default null,
  p_permanent_area            text    default null,
  p_permanent_address         text    default null
)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_same  boolean := coalesce(p_permanent_same_as_current, true);
  v_digits text := regexp_replace(coalesce(p_phone, ''), '[\s-]', '', 'g');
  v_phone  text := case
    when v_digits ~ '^03[0-9]{9}$'  then '+92' || substr(v_digits, 2)
    when v_digits ~ '^923[0-9]{9}$' then '+' || v_digits
    else nullif(v_digits, '')
  end;
  v_current_city   text;
  v_permanent_id   integer := case when v_same then p_current_city_id else p_permanent_city_id end;
  v_permanent_city text;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if p_full_name is null or char_length(btrim(p_full_name)) not between 2 and 100 then
    raise exception 'full_name must be 2–100 characters' using errcode = '23514';
  end if;
  if v_phone is null or v_phone !~ '^\+923[0-9]{9}$' then
    raise exception 'phone must be a Pakistani mobile number' using errcode = '23514';
  end if;
  if p_date_of_birth is null or p_date_of_birth < date '1900-01-01' then
    raise exception 'date_of_birth is required (1900 or later)' using errcode = '23514';
  end if;
  select c.name into v_current_city from public.cities c where c.id = p_current_city_id and c.is_active;
  if v_current_city is null then
    raise exception 'current_city_id must be an active city' using errcode = '23514';
  end if;
  select c.name into v_permanent_city from public.cities c where c.id = v_permanent_id and c.is_active;
  if v_permanent_city is null then
    raise exception 'permanent_city_id must be an active city' using errcode = '23514';
  end if;

  -- 1. Profile details (profile_completed last, step 4 — as v1).
  insert into public.profiles (id, full_name, phone, date_of_birth, permanent_same_as_current)
  values (v_uid, btrim(p_full_name), v_phone, p_date_of_birth, v_same)
  on conflict (id) do update set
    full_name                 = excluded.full_name,
    phone                     = excluded.phone,
    date_of_birth             = excluded.date_of_birth,
    permanent_same_as_current = excluded.permanent_same_as_current;

  -- 2. Current address.
  insert into public.current_addresses (user_id, city_id, city, area, address)
  values (v_uid, p_current_city_id, v_current_city, btrim(p_current_area), btrim(p_current_address))
  on conflict (user_id) do update set
    city_id = excluded.city_id, city = excluded.city, area = excluded.area, address = excluded.address;

  -- 3. Permanent address — "same as current" stores a copy of the current one.
  insert into public.permanent_addresses (user_id, city_id, city, area, address)
  values (
    v_uid,
    v_permanent_id,
    v_permanent_city,
    btrim(case when v_same then p_current_area    else p_permanent_area    end),
    btrim(case when v_same then p_current_address else p_permanent_address end)
  )
  on conflict (user_id) do update set
    city_id = excluded.city_id, city = excluded.city, area = excluded.area, address = excluded.address;

  -- 4. Done: profiles_validate now finds both addresses.
  update public.profiles set profile_completed = true where id = v_uid;
end;
$$;

-- ---------------------------------------------------------------------------
-- Privileges: signed-in users only (the trigger and v1 call the resolver as
-- the caller). Table grants and RLS are unchanged: users write city_id on
-- their own rows exactly like the other address columns.
-- ---------------------------------------------------------------------------
revoke execute on function public.resolve_city_match(text) from public, anon;
grant execute on function public.resolve_city_match(text) to authenticated;
revoke execute on function public.resolve_city_id(text) from public, anon;
grant execute on function public.resolve_city_id(text) to authenticated;
revoke execute on function public.save_profile_setup_v2(text, text, date, integer, text, text, boolean, integer, text, text)
  from public, anon;
grant execute on function public.save_profile_setup_v2(text, text, date, integer, text, text, boolean, integer, text, text)
  to authenticated;

notify pgrst, 'reload schema';
