-- CricEco · migration 12 · teams and squads (teams, team_players)
--
-- NOT APPLIED. Requires migration 11. Review first; apply only with separate
-- approval, after a fresh backup, inside
-- begin; set local lock_timeout = '5s'; … commit;
-- Rollback: rollback/20261116_rollback_teams.sql (before migration 11's).
--
-- Business rules (docs/TEAM_SQUAD_IMPLEMENTATION.md):
--   * A team belongs to one club. Only the club's owner reads or changes it.
--   * Name: 1–40 characters, unique per club among active teams (case and
--     repeated spaces ignored). Format test / t20 / odi / t10 / custom;
--     custom needs 1–50 overs, the others none.
--   * Squad: at most 11 Playing XI + 4 substitutes (15). A player appears
--     once per team; the same club member may be in several teams.
--   * Only ACTIVE members of the same club can be in a squad. Removing a
--     member from the club (migration 11) takes them out of every team and
--     clears captain / vice-captain.
--   * Captain and vice-captain are optional, must be in that team's squad and
--     must be two different people.
--   * Deleting a team archives it (status 'archived'): it disappears from My
--     Teams and frees its name; its rows stay. When matches exist they will
--     reference teams with ON DELETE RESTRICT, so an archived team is never
--     hard-deleted while a match uses it.
--   * Writes only through create_team / save_team / archive_team, which check
--     auth.uid() owns the club; RLS allows SELECT only.

do $$
begin
  if to_regclass('public.teams') is not null or to_regclass('public.team_players') is not null then
    raise exception 'migration 12: teams or team_players already exists — nothing changed';
  end if;
  if to_regclass('public.club_members') is null or to_regprocedure('public.is_club_owner(uuid)') is null then
    raise exception 'migration 12: migration 11 (club memberships) is required';
  end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public'
                and p.proname in ('create_team', 'save_team', 'archive_team', 'team_players_validate',
                                  'club_members_leave_teams', 'team_name_key')) then
    raise exception 'migration 12: a team function already exists — nothing changed';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
-- The name as compared for uniqueness: trimmed, single spaces, lower case.
create or replace function public.team_name_key(p_name text)
returns text
language sql
immutable
set search_path = ''
as $$
  select lower(regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g'));
$$;

create table public.teams (
  id                     uuid primary key default gen_random_uuid(),
  club_id                uuid not null
                         constraint teams_club_id_fkey references public.clubs (id) on delete cascade,
  name                   text not null
                         constraint teams_name_check check (char_length(btrim(name)) between 1 and 40),
  format                 text not null
                         constraint teams_format_check check (format in ('test', 't20', 'odi', 't10', 'custom')),
  custom_overs           smallint
                         constraint teams_custom_overs_check check (custom_overs is null or custom_overs between 1 and 50),
  captain_member_id      uuid
                         constraint teams_captain_member_id_fkey references public.club_members (id) on delete set null,
  vice_captain_member_id uuid
                         constraint teams_vice_captain_member_id_fkey references public.club_members (id) on delete set null,
  status                 text not null default 'active'
                         constraint teams_status_check check (status in ('active', 'archived')),
  archived_at            timestamptz,
  created_at             timestamptz not null default now(),
  last_updated_at        timestamptz not null default now(),
  constraint teams_overs_follow_format check ((format = 'custom') = (custom_overs is not null)),
  constraint teams_archived_consistency check ((status = 'archived') = (archived_at is not null)),
  constraint teams_leaders_distinct check (
    captain_member_id is null or vice_captain_member_id is null or captain_member_id <> vice_captain_member_id)
);

comment on table public.teams is 'A club''s teams (My Teams). Written only by create_team / save_team / archive_team.';

create unique index teams_club_name_active_key on public.teams (club_id, public.team_name_key(name))
  where status = 'active';
create index teams_club_status_idx on public.teams (club_id, status);
create index teams_captain_member_id_idx on public.teams (captain_member_id) where captain_member_id is not null;
create index teams_vice_captain_member_id_idx on public.teams (vice_captain_member_id)
  where vice_captain_member_id is not null;

create table public.team_players (
  team_id   uuid not null
            constraint team_players_team_id_fkey references public.teams (id) on delete cascade,
  member_id uuid not null
            constraint team_players_member_id_fkey references public.club_members (id) on delete cascade,
  selection text not null
            constraint team_players_selection_check check (selection in ('playing', 'sub')),
  position  smallint not null
            constraint team_players_position_check check (position between 1 and 15),
  added_at  timestamptz not null default now(),
  constraint team_players_pkey primary key (team_id, member_id),
  constraint team_players_team_position_key unique (team_id, position)
);

comment on table public.team_players is 'A team''s squad: Playing XI and substitutes, in pick order.';

create index team_players_member_id_idx on public.team_players (member_id);

create trigger teams_set_last_updated_at
  before update on public.teams
  for each row execute function public.set_last_updated_at();

-- A squad place needs an ACTIVE member of the team's own club, on an
-- active team. (Defence in depth: save_team checks the same.)
create or replace function public.team_players_validate()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists (
       select 1
         from public.teams t
         join public.club_members m on m.club_id = t.club_id
        where t.id = new.team_id and t.status = 'active'
          and m.id = new.member_id and m.status = 'active') then
    raise exception 'team: player not in club' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger team_players_validate
  before insert or update on public.team_players
  for each row execute function public.team_players_validate();

-- Removing a club member (status → removed) takes them out of every team of
-- that club and clears captain / vice-captain.
create or replace function public.club_members_leave_teams()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'removed' and old.status <> 'removed' then
    delete from public.team_players tp where tp.member_id = new.id;
    update public.teams t set captain_member_id = null where t.captain_member_id = new.id;
    update public.teams t set vice_captain_member_id = null where t.vice_captain_member_id = new.id;
  end if;
  return null;
end;
$$;

create trigger club_members_leave_teams
  after update of status on public.club_members
  for each row execute function public.club_members_leave_teams();

-- ---------------------------------------------------------------------------
-- 2. Row level security (read only; writes through the functions)
-- ---------------------------------------------------------------------------
alter table public.teams enable row level security;
alter table public.team_players enable row level security;

create policy "teams: select owned club"
  on public.teams for select to authenticated
  using (public.is_club_owner(club_id));

create policy "team_players: select owned club"
  on public.team_players for select to authenticated
  using (exists (select 1 from public.teams t where t.id = team_id and public.is_club_owner(t.club_id)));

revoke all on table public.teams, public.team_players from anon, authenticated;
grant select on table public.teams, public.team_players to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Functions
-- ---------------------------------------------------------------------------
-- Messages start with "team:" — team: not authenticated / not allowed (42501)
-- · not found (P0002) · duplicate name (23505) · invalid (22023) ·
-- squad full (23514) · player not in club (23514) · archived (P0001).

create or replace function public.create_team(
  p_club_id      uuid,
  p_name         text,
  p_format       text,
  p_custom_overs integer default null
)
returns public.teams
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid  uuid := auth.uid();
  v_team public.teams;
begin
  if v_uid is null then
    raise exception 'team: not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.clubs c where c.id = p_club_id and c.owner_id = v_uid) then
    raise exception 'team: not allowed' using errcode = '42501';
  end if;
  begin
    insert into public.teams (club_id, name, format, custom_overs)
    values (p_club_id, regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g'), lower(btrim(p_format)),
            case when lower(btrim(p_format)) = 'custom' then p_custom_overs end)
    returning * into v_team;
  exception
    when unique_violation then
      raise exception 'team: duplicate name' using errcode = '23505';
    when check_violation or not_null_violation or numeric_value_out_of_range then
      raise exception 'team: invalid' using errcode = '22023';
  end;
  return v_team;
end;
$$;

-- Saves a team's details and its whole squad in one transaction.
-- p_players: a JSON array in pick order, e.g.
--   [{"member_id": "…", "selection": "playing"}, {"member_id": "…", "selection": "sub"}]
create or replace function public.save_team(
  p_team_id           uuid,
  p_name              text,
  p_format            text,
  p_custom_overs      integer,
  p_captain_member_id uuid,
  p_vice_member_id    uuid,
  p_players           jsonb
)
returns public.teams
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_team    public.teams;
  v_format  text := lower(btrim(coalesce(p_format, '')));
  v_total   integer;
  v_count   integer;
  v_playing integer;
  v_subs    integer;
begin
  if v_uid is null then
    raise exception 'team: not authenticated' using errcode = '42501';
  end if;
  select * into v_team from public.teams t where t.id = p_team_id for update;
  if not found then
    raise exception 'team: not found' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.clubs c where c.id = v_team.club_id and c.owner_id = v_uid) then
    raise exception 'team: not allowed' using errcode = '42501';
  end if;
  if v_team.status <> 'active' then
    raise exception 'team: archived' using errcode = 'P0001';
  end if;

  -- The squad: an array of {member_id, selection}, no repeats, within 11 + 4,
  -- every player an active member of this club.
  if p_players is null or jsonb_typeof(p_players) <> 'array' then
    raise exception 'team: invalid' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(p_players) e
              where jsonb_typeof(e) <> 'object'
                 or coalesce(e ->> 'selection', '') not in ('playing', 'sub')
                 or coalesce(e ->> 'member_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') then
    raise exception 'team: invalid' using errcode = '22023';
  end if;
  select count(*), count(distinct e ->> 'member_id'),
         count(*) filter (where e ->> 'selection' = 'playing'),
         count(*) filter (where e ->> 'selection' = 'sub')
    into v_total, v_count, v_playing, v_subs
    from jsonb_array_elements(p_players) e;
  if v_count <> v_total then
    raise exception 'team: invalid' using errcode = '22023'; -- a player listed twice
  end if;
  if v_playing > 11 or v_subs > 4 then
    raise exception 'team: squad full' using errcode = '23514';
  end if;
  if exists (select 1 from jsonb_array_elements(p_players) e
              where not exists (select 1 from public.club_members m
                                 where m.id = (e ->> 'member_id')::uuid
                                   and m.club_id = v_team.club_id and m.status = 'active')) then
    raise exception 'team: player not in club' using errcode = '23514';
  end if;

  -- Captain / vice-captain: optional, in this squad, two different people.
  if p_captain_member_id is not null and p_captain_member_id = p_vice_member_id then
    raise exception 'team: invalid' using errcode = '22023';
  end if;
  if (p_captain_member_id is not null and not exists (
        select 1 from jsonb_array_elements(p_players) e where (e ->> 'member_id')::uuid = p_captain_member_id))
     or (p_vice_member_id is not null and not exists (
        select 1 from jsonb_array_elements(p_players) e where (e ->> 'member_id')::uuid = p_vice_member_id)) then
    raise exception 'team: invalid' using errcode = '22023';
  end if;

  begin
    update public.teams
       set name = regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g'),
           format = v_format,
           custom_overs = case when v_format = 'custom' then p_custom_overs end,
           captain_member_id = p_captain_member_id,
           vice_captain_member_id = p_vice_member_id
     where id = p_team_id
    returning * into v_team;
  exception
    when unique_violation then
      raise exception 'team: duplicate name' using errcode = '23505';
    when check_violation or not_null_violation or numeric_value_out_of_range then
      raise exception 'team: invalid' using errcode = '22023';
  end;

  delete from public.team_players where team_id = p_team_id;
  insert into public.team_players (team_id, member_id, selection, position)
  select p_team_id, (e.value ->> 'member_id')::uuid, e.value ->> 'selection', e.ordinality::smallint
    from jsonb_array_elements(p_players) with ordinality as e(value, ordinality);

  return v_team;
end;
$$;

-- "Delete team": archive it (see the rules at the top).
create or replace function public.archive_team(p_team_id uuid)
returns public.teams
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid  uuid := auth.uid();
  v_team public.teams;
begin
  if v_uid is null then
    raise exception 'team: not authenticated' using errcode = '42501';
  end if;
  select * into v_team from public.teams t where t.id = p_team_id for update;
  if not found then
    raise exception 'team: not found' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.clubs c where c.id = v_team.club_id and c.owner_id = v_uid) then
    raise exception 'team: not allowed' using errcode = '42501';
  end if;
  if v_team.status = 'archived' then
    return v_team;
  end if;
  update public.teams set status = 'archived', archived_at = now() where id = p_team_id
  returning * into v_team;
  return v_team;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Privileges
-- ---------------------------------------------------------------------------
revoke execute on function public.team_name_key(text) from public, anon;
revoke execute on function public.team_players_validate() from public, anon, authenticated;
revoke execute on function public.club_members_leave_teams() from public, anon, authenticated;
revoke execute on function public.create_team(uuid, text, text, integer) from public, anon;
revoke execute on function public.save_team(uuid, text, text, integer, uuid, uuid, jsonb) from public, anon;
revoke execute on function public.archive_team(uuid) from public, anon;

grant execute on function public.team_name_key(text) to authenticated;
grant execute on function public.create_team(uuid, text, text, integer) to authenticated;
grant execute on function public.save_team(uuid, text, text, integer, uuid, uuid, jsonb) to authenticated;
grant execute on function public.archive_team(uuid) to authenticated;

notify pgrst, 'reload schema';
