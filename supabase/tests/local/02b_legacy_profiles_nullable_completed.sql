-- CricEco · LOCAL TEST ONLY — variant of 02_legacy_profiles_fixture.sql for
-- the other possible live shape of profiles.profile_completed: nullable with
-- NO default, and the incomplete legacy row holding NULL instead of false.
-- (00b query 1 on live decides which shape is real; the rehearsal runs both.)
-- Run right after 02_legacy_profiles_fixture.sql, before migration 1.
-- Refuses to run on a real Supabase project or after the migrations.

do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password') then
    raise exception 'LOCAL ONLY: this looks like a real Supabase auth schema';
  end if;
  if not exists (select 1 from public.profiles where id = 'a0000000-0000-4000-8000-000000000005') then
    raise exception 'LOCAL ONLY: run 02_legacy_profiles_fixture.sql first';
  end if;
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'profiles' and column_name = 'date_of_birth') then
    raise exception 'LOCAL ONLY: migrations already applied — use a fresh local database';
  end if;
end $$;

alter table public.profiles
  alter column profile_completed drop not null,
  alter column profile_completed drop default;

-- "Not Done": incomplete legacy row, NULL instead of false.
update public.profiles set profile_completed = null
 where id = 'a0000000-0000-4000-8000-000000000005';
