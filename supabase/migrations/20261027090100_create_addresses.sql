-- CricEco · migration 2/4 · current_addresses, permanent_addresses
-- ERD v8 CurrentAddress / PermanentAddress: 0..1 row each per user.
--
-- Rows are written at User Profile Setup with City, Area and Address all
-- filled in (the app requires them), so the columns are NOT NULL here.
-- City and Area are free text (the app's area list is demo data plus
-- "Other (type it)"), never enums.
-- When "same as current" is Yes (profiles.permanent_same_as_current) the
-- app stores a copy of the current address as the permanent one, so
-- permanent_addresses always holds the effective permanent address.
--
-- NOT APPLIED. Requires migration 1 (public.profiles, set_last_updated_at).

create table public.current_addresses (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null unique default auth.uid()
                    references public.profiles (id) on delete cascade,
  city            text not null,
  area            text not null,
  address         text not null,
  created_at      timestamptz not null default now(),
  last_updated_at timestamptz not null default now(),

  constraint current_addresses_city_check    check (char_length(btrim(city)) between 1 and 100),
  constraint current_addresses_area_check    check (char_length(btrim(area)) between 1 and 150),
  constraint current_addresses_address_check check (char_length(btrim(address)) between 1 and 500)
);

create table public.permanent_addresses (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null unique default auth.uid()
                    references public.profiles (id) on delete cascade,
  city            text not null,
  area            text not null,
  address         text not null,
  created_at      timestamptz not null default now(),
  last_updated_at timestamptz not null default now(),

  constraint permanent_addresses_city_check    check (char_length(btrim(city)) between 1 and 100),
  constraint permanent_addresses_area_check    check (char_length(btrim(area)) between 1 and 150),
  constraint permanent_addresses_address_check check (char_length(btrim(address)) between 1 and 500)
);

comment on table public.current_addresses is 'ERD v8 CurrentAddress: 0..1 per user.';
comment on table public.permanent_addresses is
  'ERD v8 PermanentAddress: 0..1 per user; a copy of the current address when "same as current".';

-- The UNIQUE (user_id) constraints are the indexes for user lookups / upserts.

-- ---------------------------------------------------------------------------
-- profiles_validate (from migration 1), extended now that the address tables
-- exist: a profile can only BECOME completed (insert as completed, or
-- false / NULL → true) once name, phone, date of birth and both addresses are
-- saved — also when profile_completed is set directly through the API rather
-- than by save_profile_setup(). Rows that were already completed before this
-- migration are not re-checked, so their other columns stay editable. Runs
-- as the caller, so RLS limits the address lookup to their own rows.
-- ---------------------------------------------------------------------------
create or replace function public.profiles_validate()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.date_of_birth is not null and new.date_of_birth > current_date then
    raise exception 'date_of_birth cannot be in the future' using errcode = '23514';
  end if;
  if new.profile_completed and (tg_op = 'INSERT' or old.profile_completed is not true) then
    if new.full_name is null or new.phone is null or new.date_of_birth is null then
      raise exception 'profile_completed requires full_name, phone and date_of_birth' using errcode = '23514';
    end if;
    if not exists (select 1 from public.current_addresses where user_id = new.id)
       or not exists (select 1 from public.permanent_addresses where user_id = new.id) then
      raise exception 'profile_completed requires a current and a permanent address' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;

create trigger current_addresses_set_last_updated_at
  before update on public.current_addresses
  for each row execute function public.set_last_updated_at();

create trigger permanent_addresses_set_last_updated_at
  before update on public.permanent_addresses
  for each row execute function public.set_last_updated_at();

-- ---------------------------------------------------------------------------
-- Row Level Security: own rows only. No DELETE policy (rows go with the user).
-- ---------------------------------------------------------------------------
alter table public.current_addresses enable row level security;
alter table public.permanent_addresses enable row level security;

create policy "current_addresses: select own"
  on public.current_addresses for select to authenticated
  using ((select auth.uid()) = user_id);
create policy "current_addresses: insert own"
  on public.current_addresses for insert to authenticated
  with check ((select auth.uid()) = user_id);
create policy "current_addresses: update own"
  on public.current_addresses for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create policy "permanent_addresses: select own"
  on public.permanent_addresses for select to authenticated
  using ((select auth.uid()) = user_id);
create policy "permanent_addresses: insert own"
  on public.permanent_addresses for insert to authenticated
  with check ((select auth.uid()) = user_id);
create policy "permanent_addresses: update own"
  on public.permanent_addresses for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

revoke all on table public.current_addresses, public.permanent_addresses from anon, authenticated;
grant select, insert, update on table public.current_addresses, public.permanent_addresses to authenticated;
