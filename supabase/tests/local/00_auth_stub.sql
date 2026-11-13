-- CricEco · LOCAL TEST ONLY — minimal stand-in for the Supabase auth pieces
-- the migrations use, on a plain PostgreSQL 16 container.
-- NEVER run this on a Supabase project (it refuses: a real project already
-- has the auth schema).

do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'auth') then
    raise exception 'LOCAL ONLY: an auth schema already exists — this is not a fresh local test database';
  end if;
end $$;

-- Supabase API roles, plus the role Supabase Auth uses to create users.
-- (Roles are cluster-wide: reused when a second local database is set up.)
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'supabase_auth_admin') then
    create role supabase_auth_admin nologin noinherit;
  end if;
end $$;

grant usage on schema public to anon, authenticated, service_role;

-- Supabase's default: new public tables / functions are granted to the API
-- roles — so the migrations' REVOKEs are tested against the real starting point.
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;

-- auth.users: only the columns these tests touch.
create schema auth;
create table auth.users (
  id         uuid primary key default gen_random_uuid(),
  email      text unique,
  created_at timestamptz not null default now()
);

-- auth.uid(): same lookup as Supabase (claim "sub" from the request JWT).
create function auth.uid()
returns uuid
language sql
stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
$$;

grant usage on schema auth to anon, authenticated, service_role, supabase_auth_admin;
grant execute on function auth.uid() to anon, authenticated, service_role;
grant select, insert, update, delete on auth.users to supabase_auth_admin;
