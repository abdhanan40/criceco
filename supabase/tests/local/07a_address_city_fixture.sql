-- CricEco · LOCAL TEST ONLY — address rows as they exist BEFORE migration 8,
-- for its backfill check (local/07b). COMMITTED (the backfill must see them).
-- Run after migrations 1–7 and the location data (D1), BEFORE migration 8,
-- as the database owner. Refuses on a real Supabase project or when
-- migration 8 is already applied.
--
-- One account per city text (emails *@s43.local.test); current and
-- permanent addresses differ so both tables are exercised:
--   lahore-a "Lahore" · lahore-b "  lahore  " · lahore-c "LAHORE"  → featured
--   karachi "Karachi" → featured · kamra "Kamra" → ambiguous (two towns)
--   kamra-label "Kamra (Attock)" → label · lyallpur "Lyallpur" → alias (Faisalabad)
--   other "Other" → unmatched · atlantis "Atlantis" → unmatched
--   jhelum "Jhelum" → name (one city of that name, not featured)
--   "Attock" (atlantis' permanent) → alias of Attock City

do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password') then
    raise exception 'LOCAL ONLY: this looks like a real Supabase auth schema';
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'current_addresses' and column_name = 'city_id') then
    raise exception 'LOCAL ONLY: run before migration 8';
  end if;
  if (select count(*) from public.cities) = 0 then
    raise exception 'LOCAL ONLY: load the location data (D1) first';
  end if;
end $$;

begin;

create temporary table fx (account text, cur text, perm text) on commit drop;
insert into fx values
  ('lahore-a', 'Lahore', 'Karachi'),
  ('lahore-b', '  lahore  ', 'Lahore'),
  ('lahore-c', 'LAHORE', 'Lahore'),
  ('karachi', 'Karachi', 'Lyallpur'),
  ('kamra', 'Kamra', 'Other'),
  ('kamra-label', 'Kamra (Attock)', 'Kamra'),
  ('lyallpur', 'Lyallpur', 'Atlantis'),
  ('other', 'Other', 'Karachi'),
  ('atlantis', 'Atlantis', 'Attock'),
  ('jhelum', 'Jhelum', 'Kamra (Attock)');

insert into auth.users (email) select account || '@s43.local.test' from fx;
insert into public.current_addresses (user_id, city, area, address)
select u.id, fx.cur, 'Area', 'House 1' from fx join auth.users u on u.email = fx.account || '@s43.local.test';
insert into public.permanent_addresses (user_id, city, area, address)
select u.id, fx.perm, 'Area', 'House 2' from fx join auth.users u on u.email = fx.account || '@s43.local.test';
-- Older timestamps, to prove migration 8 leaves them alone (the trigger that
-- sets last_updated_at is switched off for this one update).
alter table public.current_addresses disable trigger current_addresses_set_last_updated_at;
alter table public.permanent_addresses disable trigger permanent_addresses_set_last_updated_at;
update public.current_addresses set last_updated_at = timestamptz '2026-01-02 03:04:05+00'
 where user_id in (select id from auth.users where email like '%@s43.local.test');
update public.permanent_addresses set last_updated_at = timestamptz '2026-01-02 03:04:05+00'
 where user_id in (select id from auth.users where email like '%@s43.local.test');
alter table public.current_addresses enable trigger current_addresses_set_last_updated_at;
alter table public.permanent_addresses enable trigger permanent_addresses_set_last_updated_at;

-- Snapshot of every address row before migration 8.
create schema if not exists s43_fixture;
create table s43_fixture.addresses_before as
  select 'current_addresses' as tbl, user_id, city, area, address, created_at, last_updated_at
    from public.current_addresses
  union all
  select 'permanent_addresses', user_id, city, area, address, created_at, last_updated_at
    from public.permanent_addresses;

commit;

select (select count(*) from s43_fixture.addresses_before) as address_rows,
       (select count(*) from auth.users where email like '%@s43.local.test') as fixture_accounts;
