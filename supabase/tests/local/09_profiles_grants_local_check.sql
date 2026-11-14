-- CricEco · LOCAL TEST ONLY — migration 10 (least-privilege grants on
-- public.profiles) by real attempts. Run after migration 10 on the local
-- PostgreSQL test database (00_auth_stub.sql, the legacy profiles fixture,
-- migrations 1–5; 6–9 optional — their steps run only when present).
-- Everything is one transaction, ROLLED BACK at the end.
--   D: what migration 10 removed is REFUSED (42501) — for authenticated:
--      TRUNCATE, DELETE, REFERENCES, TRIGGER, MAINTAIN (REINDEX); for anon:
--      every access; PUBLIC-granted access is gone too;
--   F: every flow the app relies on still works — sign-up (the trigger as
--      Supabase's auth role), the account read, Profile Setup v1 (and v2),
--      the direct role update, Edit Profile (update_profile_details, with
--      its row lock), club creation's role trigger, and the auth.users →
--      profiles cascade.
-- Refuses to run on a real Supabase project.

\set ON_ERROR_STOP on
begin;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'supabase_admin')
     or exists (select 1 from pg_attribute
                 where attrelid = to_regclass('auth.users') and attname = 'encrypted_password'
                   and not attisdropped) then
    raise exception 'LOCAL ONLY: this looks like a real Supabase project — stopping';
  end if;
  if has_table_privilege('authenticated', 'public.profiles', 'TRUNCATE') then
    raise exception 'LOCAL ONLY: migration 10 is not applied (authenticated still holds TRUNCATE) — stopping';
  end if;
end $$;

-- F1. Sign-up: Supabase Auth inserts the user (as its own role, which holds
-- no privilege on profiles); the SECURITY DEFINER trigger creates the row.
set local role supabase_auth_admin;
insert into auth.users (id, email)
values ('c0000000-0000-4000-8000-0000000000a1', 'grants-a@local.test');
reset role;
do $$
begin
  if has_table_privilege('supabase_auth_admin', 'public.profiles', 'INSERT') then
    raise exception 'FAIL F1: meaningless — supabase_auth_admin can insert profiles directly';
  end if;
  if not exists (select 1 from public.profiles where id = 'c0000000-0000-4000-8000-0000000000a1') then
    raise exception 'FAIL F1: the sign-up trigger did not create the profile';
  end if;
  raise notice 'PASS F1: sign-up creates the profile (definer trigger, no API privilege needed)';
end $$;

-- A city id for v2 / update_profile_details, when the location data is there.
do $$
declare
  v text := '';
begin
  if to_regclass('public.cities') is not null then
    execute 'select coalesce((select id::text from public.cities
                               where name = ''Lahore'' and is_active order by id limit 1), '''')'
      into v;
  end if;
  perform set_config('s437.city', v, true);
end $$;

-- Helpers (created as the owner, temporary): a statement must be REFUSED
-- for lack of a privilege on profiles — not succeed, not fail otherwise.
create function pg_temp.s437_refused(stmt text, label text) returns void
language plpgsql as $f$
begin
  begin
    execute stmt;
  exception when insufficient_privilege then
    if sqlerrm not like '%profiles%' then
      raise exception 'FAIL %: refused, but not for profiles: %', label, sqlerrm;
    end if;
    return;
  end;
  raise exception 'FAIL %: allowed: %', label, stmt;
end $f$;
create function pg_temp.s437_noop() returns trigger language plpgsql as 'begin return new; end';
-- A scratch schema (rolled back) where authenticated may create a table, so
-- that only the REFERENCES privilege on profiles can refuse D3.
create schema s437_scratch;
grant usage, create on schema s437_scratch to authenticated;

-- ===================== As the signed-in user =====================
select set_config('request.jwt.claims',
  json_build_object('sub', 'c0000000-0000-4000-8000-0000000000a1', 'role', 'authenticated')::text, true);
set local role authenticated;
do $$
declare
  me constant uuid := 'c0000000-0000-4000-8000-0000000000a1';
  n int;
  v_city int := nullif(current_setting('s437.city', true), '')::int;
begin
  if current_user <> 'authenticated' or auth.uid() is distinct from me then
    raise exception 'UNSAFE: not running as the test user';
  end if;

  -- D1–D5. Refused (42501, for profiles): TRUNCATE (row level security
  -- would not stop it), DELETE (also of the own row), REFERENCES (a foreign
  -- key from a scratch table), TRIGGER, MAINTAIN (PostgreSQL 17: REINDEX).
  perform pg_temp.s437_refused('truncate public.profiles cascade', 'D1 TRUNCATE');
  perform pg_temp.s437_refused(format('delete from public.profiles where id = %L', me), 'D2 DELETE');
  perform pg_temp.s437_refused('create table s437_scratch.ref (id uuid references public.profiles (id))', 'D3 REFERENCES');
  perform pg_temp.s437_refused('create trigger s437_noop before update on public.profiles
                                for each row execute function pg_temp.s437_noop()', 'D4 TRIGGER');
  if current_setting('server_version_num')::int >= 170000 then
    perform pg_temp.s437_refused('reindex table public.profiles', 'D5 MAINTAIN');
  end if;
  raise notice 'PASS D1–D5: TRUNCATE, DELETE, REFERENCES, TRIGGER and MAINTAIN refused (42501)';

  -- F2. The account read: the own row only.
  select count(*) into n from public.profiles;
  if n <> 1 or not exists (select 1 from public.profiles where id = me) then
    raise exception 'FAIL F2: the account read sees % rows', n;
  end if;
  raise notice 'PASS F2: SELECT of the own row (and only it)';

  -- F3. Profile Setup v1: INSERT … ON CONFLICT DO UPDATE on profiles, both addresses.
  perform public.save_profile_setup(
    p_full_name => 'Grant Check', p_phone => '0300 1234567', p_date_of_birth => date '2000-05-01',
    p_current_city => 'Lahore', p_current_area => 'Gulberg', p_current_address => 'Street 1',
    p_permanent_same_as_current => true);
  if not exists (select 1 from public.profiles where id = me and profile_completed and phone = '+923001234567') then
    raise exception 'FAIL F3: save_profile_setup did not save';
  end if;
  raise notice 'PASS F3: save_profile_setup (v1)';

  -- F4. Profile Setup v2 (migration 8), when present.
  if to_regprocedure('public.save_profile_setup_v2(text, text, date, integer, text, text, boolean, integer, text, text)') is not null
     and v_city is not null then
    execute 'select public.save_profile_setup_v2(p_full_name => $1, p_phone => $2, p_date_of_birth => $3,
               p_current_city_id => $4, p_current_area => $5, p_current_address => $6,
               p_permanent_same_as_current => true)'
      using 'Grant Check', '03001234567', date '2000-05-01', v_city, 'DHA', 'Street 2';
    if not exists (select 1 from public.current_addresses where user_id = me and city_id = v_city and area = 'DHA') then
      raise exception 'FAIL F4: save_profile_setup_v2 did not save';
    end if;
    raise notice 'PASS F4: save_profile_setup_v2';
  else
    raise notice 'SKIPPED F4: save_profile_setup_v2 / location data not present';
  end if;

  -- F5. The app's direct role update (setRoleIfUnset).
  update public.profiles set role = 'player' where id = me and role is null;
  get diagnostics n = row_count;
  if n <> 1 then raise exception 'FAIL F5: the direct role update changed % rows', n; end if;
  raise notice 'PASS F5: UPDATE of the own row (role)';

  -- F6. Edit Profile (migration 9), when present — its FOR NO KEY UPDATE locks need UPDATE.
  perform 1 from public.profiles where id = me for no key update;
  if to_regprocedure('public.update_profile_details(text, text, date, text, integer, text, text, text, integer, text, text)') is not null then
    execute 'select public.update_profile_details(p_full_name => $1, p_phone => $2, p_date_of_birth => $3,
               p_current_city => $4, p_current_city_id => null, p_current_area => $5, p_current_address => $6)'
      using 'Grant Check Two', '03001234567', date '2000-05-01', 'Lahore', 'Cantt', 'Street 3';
    if not exists (select 1 from public.profiles where id = me and full_name = 'Grant Check Two')
       or not exists (select 1 from public.current_addresses where user_id = me and area = 'Cantt') then
      raise exception 'FAIL F6: update_profile_details did not save';
    end if;
    raise notice 'PASS F6: update_profile_details (and its row lock)';
  else
    raise notice 'PASS F6: the FOR NO KEY UPDATE row lock (update_profile_details not present)';
  end if;

  -- F7. Club creation: its trigger (running as the user) sets profiles.role.
  perform public.create_club('Grant Check XI', 'Lahore', 'corporate');
  if not exists (select 1 from public.profiles where id = me and role = 'club_owner') then
    raise exception 'FAIL F7: create_club did not make the user a club owner';
  end if;
  raise notice 'PASS F7: create_club''s role trigger updates profiles';
end $$;

-- ===================== Signed out =====================
reset role;
select set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
set local role anon;
do $$
declare
  stmt text;
begin
  if current_user <> 'anon' or auth.uid() is not null then
    raise exception 'UNSAFE: not running as anon';
  end if;
  foreach stmt in array array[
    'select 1 from public.profiles',
    'insert into public.profiles (id) values (gen_random_uuid())',
    'update public.profiles set full_name = full_name',
    'delete from public.profiles',
    'truncate public.profiles cascade'] loop
    perform pg_temp.s437_refused(stmt, 'D6 anon');
  end loop;
  raise notice 'PASS D6: anon — SELECT / INSERT / UPDATE / DELETE / TRUNCATE all refused (42501)';
end $$;

-- ===================== As the owner =====================
reset role;
do $$
begin
  -- D7. Nothing reaches profiles through PUBLIC (a role with no grant of its own).
  if has_table_privilege('public', 'public.profiles', 'SELECT')
     or has_table_privilege('public', 'public.profiles', 'TRUNCATE') then
    raise exception 'FAIL D7: PUBLIC holds a privilege on profiles';
  end if;
  raise notice 'PASS D7: PUBLIC holds nothing on profiles';
end $$;

-- F8. Deleting the auth user still removes the profile (the cascade needs no API privilege).
delete from auth.users where id = 'c0000000-0000-4000-8000-0000000000a1';
do $$
begin
  if exists (select 1 from public.profiles where id = 'c0000000-0000-4000-8000-0000000000a1') then
    raise exception 'FAIL F8: the profile survived its auth user';
  end if;
  raise notice 'PASS F8: the auth.users → profiles cascade';
  raise notice 'PASSED: local/09 profiles grants (everything rolled back)';
end $$;

rollback;
