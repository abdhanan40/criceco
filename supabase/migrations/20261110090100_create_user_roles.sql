-- CricEco · migration 7 · user_roles — the roles an account holds (Stage 4.2, additive only)
-- One account may hold several roles (Player and Club Owner). Roles are
-- granted ONLY by the database, from the data rows that prove them:
--   player_profiles row → 'player' · clubs row (owner) → 'club_owner'
-- and removed when that row is deleted. Clients can read their own roles
-- and nothing else; they can never write a role.
--
-- Adds, and changes nothing that exists (no existing table, column, policy,
-- grant or row is touched):
--   * type app_role ('player', 'club_owner', 'ground_owner', 'admin' — the
--     last two are reserved: nothing grants them yet)
--   * table user_roles (+ RLS: read own) and four SECURITY DEFINER trigger
--     functions on player_profiles / clubs
--   * a backfill from the existing rows (profiles.role is NOT used as a source)
-- profiles.role stays exactly as it is and is still written by the app and
-- by clubs_set_owner_role() (backward compatibility, approved Stage 4.1).
-- create_club() is unchanged; its insert now also grants club_owner.
--
-- Depends on migrations 1–3 and 5 (profiles, player_profiles, clubs).
-- RUN INSIDE ONE TRANSACTION. Its first statement is LOCK TABLE, which
-- PostgreSQL only allows in a transaction block. In the SQL Editor, wrap
-- the whole file:
--   begin; set local lock_timeout = '5s'; … this file … commit;
-- The lock is held until commit, so no player profile or club write can
-- slip between the backfill and the new triggers.
-- NOT APPLIED. Run tests/00e_preflight_stage42.sql first (see supabase/README.md).

-- No player profile / club can be written while this runs, so the backfill
-- and the new triggers can't miss a row.
lock table public.player_profiles, public.clubs in share row exclusive mode;

do $$
begin
  if to_regtype('public.app_role') is not null or to_regclass('public.user_roles') is not null then
    raise exception 'migration 7: app_role or user_roles already exists — nothing changed';
  end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname in ('player_profiles_grant_role', 'player_profiles_revoke_role',
                                                         'clubs_grant_owner_role', 'clubs_revoke_owner_role')) then
    raise exception 'migration 7: a user_roles trigger function already exists — nothing changed';
  end if;
  if to_regclass('public.player_profiles') is null or to_regclass('public.clubs') is null then
    raise exception 'migration 7: player_profiles (migration 3) and clubs (migration 5) are required';
  end if;
end $$;

create type public.app_role as enum ('player', 'club_owner', 'ground_owner', 'admin');

create table public.user_roles (
  user_id    uuid not null
             constraint user_roles_user_id_fkey references public.profiles (id) on delete cascade,
  role       public.app_role not null,
  granted_at timestamptz not null default now(),
  -- An administrator who granted it; NULL = granted by the system (triggers / backfill).
  granted_by uuid
             constraint user_roles_granted_by_fkey references public.profiles (id) on delete set null,
  constraint user_roles_pkey primary key (user_id, role)
);
create index user_roles_granted_by_idx on public.user_roles (granted_by) where granted_by is not null;

comment on table public.user_roles is
  'Roles an account holds. Written only by database triggers (player_profiles → player, clubs → club_owner).';

-- ---------------------------------------------------------------------------
-- Grant / revoke from the data rows. SECURITY DEFINER (clients have no write
-- access to user_roles); each function uses only the row that fired it.
-- Trigger functions (RETURNS trigger) can't be called through the API.
-- ---------------------------------------------------------------------------
create or replace function public.player_profiles_grant_role()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.user_roles (user_id, role) values (new.user_id, 'player')
  on conflict (user_id, role) do nothing;
  return null;
end;
$$;

create or replace function public.player_profiles_revoke_role()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.user_roles where user_id = old.user_id and role = 'player';
  return null;
end;
$$;

create or replace function public.clubs_grant_owner_role()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.user_roles (user_id, role) values (new.owner_id, 'club_owner')
  on conflict (user_id, role) do nothing;
  return null;
end;
$$;

-- One club per owner (clubs.owner_id is unique), so deleting it ends the role.
create or replace function public.clubs_revoke_owner_role()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.user_roles where user_id = old.owner_id and role = 'club_owner';
  return null;
end;
$$;

create trigger player_profiles_grant_role
  after insert on public.player_profiles
  for each row execute function public.player_profiles_grant_role();
create trigger player_profiles_revoke_role
  after delete on public.player_profiles
  for each row execute function public.player_profiles_revoke_role();
create trigger clubs_grant_owner_role
  after insert on public.clubs
  for each row execute function public.clubs_grant_owner_role();
create trigger clubs_revoke_owner_role
  after delete on public.clubs
  for each row execute function public.clubs_revoke_owner_role();

-- ---------------------------------------------------------------------------
-- Backfill from the rows only (an account whose profiles.role says club_owner
-- but which has no club gets no club_owner role — the app agrees: it sends
-- that account to Club Setup).
-- ---------------------------------------------------------------------------
insert into public.user_roles (user_id, role, granted_at)
select pp.user_id, 'player', pp.created_at from public.player_profiles pp
on conflict (user_id, role) do nothing;

insert into public.user_roles (user_id, role, granted_at)
select c.owner_id, 'club_owner', c.created_at from public.clubs c
on conflict (user_id, role) do nothing;

-- ---------------------------------------------------------------------------
-- Row Level Security: read own roles only; no client writes.
-- ---------------------------------------------------------------------------
alter table public.user_roles enable row level security;

create policy "user_roles: select own"
  on public.user_roles for select to authenticated
  using ((select auth.uid()) = user_id);

revoke all on table public.user_roles from anon, authenticated;
grant select on table public.user_roles to authenticated;

-- Let the API see the new table (and its foreign key for embedding) straight away.
notify pgrst, 'reload schema';
