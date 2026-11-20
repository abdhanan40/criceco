-- CricEco · migration 18 · match lineups (M1, P2)
--
-- NOT APPLIED. Requires migration 12 (teams) and migration 17 (matches).
-- Review first; apply only with separate approval, after a fresh backup, inside
--   begin; set local lock_timeout = '5s'; <this file> commit;
-- Rollback: supabase/rollback/20261120_rollback_match_lineups.sql (roll back
-- migration 19 first). Read-only check: supabase/tests/18_match_lineups_postcheck.sql.
-- Local test: supabase/tests/local/15_match_lineups_local_check.sql (+ 15b_…sh).
-- Design: docs/MATCHES_BACKEND.md.
--
-- Rules (approved M1 decisions):
--   * Each club of a match has at most one lineup for it: a name, an optional
--     source team (one of the club's ACTIVE teams), exactly 11 Playing XI + 4
--     substitutes in pick order (positions 1–15), and an optional captain and
--     vice-captain — two different players of the Playing XI.
--   * Only that club's OWNER saves it, and only while the match is CONFIRMED
--     and has not started. Saving replaces the whole lineup in one
--     transaction: it is validated completely first; any failure leaves the
--     previous lineup untouched.
--   * Only ACTIVE members of that club can be picked (never another club's).
--     Injured / unavailable players are refused by migration 19 (player
--     availability), which adds that check to match_lineup_players.
--   * Privacy: a lineup is readable by the owner and the active members of ITS
--     club only — never by the opponent club (RLS and match_lineup()).
--   * Removing a member from the club (migration 11) takes them out of the
--     lineups of that club's matches that are not completed (and clears
--     captain / vice-captain there). Completed matches keep their lineups.
--     Deleting an account removes that person's lineup rows everywhere
--     (account deletion deletes their memberships; results in M2 will keep
--     their own snapshot).
--   * Teams used by a lineup can't be hard-deleted (ON DELETE RESTRICT);
--     teams are only ever archived (migration 12).
--   * No direct writes for anyone: save_match_lineup only. RLS: SELECT only.
-- All API functions: SECURITY DEFINER, empty search_path, auth.uid() checks,
-- executable by authenticated only (never anon). Errors start with "lineup:".

do $$
begin
  if to_regclass('public.matches') is null or to_regprocedure('public.is_active_club_member(uuid)') is null then
    raise exception 'migration 18: migration 17 (matches) is required';
  end if;
  if to_regclass('public.teams') is null or to_regclass('public.club_members') is null then
    raise exception 'migration 18: migrations 11 and 12 (memberships, teams) are required';
  end if;
  if to_regclass('public.match_lineups') is not null or to_regclass('public.match_lineup_players') is not null
     or exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public'
                   and p.proname in ('match_lineups_validate', 'match_lineup_players_validate',
                                     'club_members_leave_match_lineups', 'save_match_lineup', 'match_lineup')) then
    raise exception 'migration 18: already applied (or a name is taken) — nothing changed';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
create table public.match_lineups (
  match_id               uuid not null
                         constraint match_lineups_match_id_fkey references public.matches (id) on delete cascade,
  club_id                uuid not null
                         constraint match_lineups_club_id_fkey references public.clubs (id) on delete cascade,
  name                   text not null
                         constraint match_lineups_name_check check (char_length(btrim(name)) between 1 and 40),
  source_team_id         uuid
                         constraint match_lineups_source_team_id_fkey references public.teams (id) on delete restrict,
  captain_member_id      uuid
                         constraint match_lineups_captain_member_id_fkey references public.club_members (id) on delete set null,
  vice_captain_member_id uuid
                         constraint match_lineups_vice_captain_member_id_fkey references public.club_members (id) on delete set null,
  saved_at               timestamptz not null default now(),
  saved_by               uuid
                         constraint match_lineups_saved_by_fkey references public.profiles (id) on delete set null,
  constraint match_lineups_pkey primary key (match_id, club_id),
  constraint match_lineups_leaders_distinct check (
    captain_member_id is null or vice_captain_member_id is null or captain_member_id <> vice_captain_member_id)
);

comment on table public.match_lineups is
  'A club''s lineup for one match (M1). Written only by save_match_lineup (migration 18). Private to that club.';

create index match_lineups_club_id_idx on public.match_lineups (club_id);
create index match_lineups_source_team_id_idx on public.match_lineups (source_team_id) where source_team_id is not null;
create index match_lineups_captain_member_id_idx on public.match_lineups (captain_member_id)
  where captain_member_id is not null;
create index match_lineups_vice_captain_member_id_idx on public.match_lineups (vice_captain_member_id)
  where vice_captain_member_id is not null;
create index match_lineups_saved_by_idx on public.match_lineups (saved_by) where saved_by is not null;

create table public.match_lineup_players (
  match_id  uuid not null,
  club_id   uuid not null,
  member_id uuid not null
            constraint match_lineup_players_member_id_fkey references public.club_members (id) on delete cascade,
  selection text not null
            constraint match_lineup_players_selection_check check (selection in ('playing', 'sub')),
  position  smallint not null
            constraint match_lineup_players_position_check check (position between 1 and 15),
  constraint match_lineup_players_pkey primary key (match_id, club_id, member_id),
  constraint match_lineup_players_position_key unique (match_id, club_id, position),
  constraint match_lineup_players_lineup_fkey foreign key (match_id, club_id)
    references public.match_lineups (match_id, club_id) on delete cascade
);

comment on table public.match_lineup_players is
  'A match lineup''s players: Playing XI and substitutes, in pick order. Written only by save_match_lineup.';

create index match_lineup_players_member_id_idx on public.match_lineup_players (member_id);

-- ---------------------------------------------------------------------------
-- 2. Integrity triggers (defence in depth: save_match_lineup checks the same)
-- ---------------------------------------------------------------------------
-- A lineup belongs to one of the match's two clubs.
create or replace function public.match_lineups_validate()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists (select 1 from public.matches m
                  where m.id = new.match_id and new.club_id in (m.club_a_id, m.club_b_id)) then
    raise exception 'lineup: club not in match' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger match_lineups_validate
  before insert or update of match_id, club_id on public.match_lineups
  for each row execute function public.match_lineups_validate();

-- A lineup place needs an ACTIVE member of the lineup's own club.
create or replace function public.match_lineup_players_validate()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists (select 1 from public.club_members m
                  where m.id = new.member_id and m.club_id = new.club_id and m.status = 'active') then
    raise exception 'lineup: player not in club' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger match_lineup_players_validate
  before insert or update on public.match_lineup_players
  for each row execute function public.match_lineup_players_validate();

-- Removing a club member (status → removed) takes them out of that club's
-- lineups of matches that are not completed, and clears captain /
-- vice-captain there. Completed matches keep their lineups (history).
create or replace function public.club_members_leave_match_lineups()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'removed' and old.status <> 'removed' then
    delete from public.match_lineup_players lp
     using public.matches m
     where lp.member_id = new.id and m.id = lp.match_id and m.status <> 'completed';
    update public.match_lineups l set captain_member_id = null
      from public.matches m
     where l.captain_member_id = new.id and m.id = l.match_id and m.status <> 'completed';
    update public.match_lineups l set vice_captain_member_id = null
      from public.matches m
     where l.vice_captain_member_id = new.id and m.id = l.match_id and m.status <> 'completed';
  end if;
  return null;
end;
$$;

create trigger club_members_leave_match_lineups
  after update of status on public.club_members
  for each row execute function public.club_members_leave_match_lineups();

-- ---------------------------------------------------------------------------
-- 3. Row level security (read only; writes through save_match_lineup)
-- ---------------------------------------------------------------------------
alter table public.match_lineups enable row level security;
alter table public.match_lineup_players enable row level security;

create policy "match_lineups: select own club"
  on public.match_lineups for select to authenticated
  using (public.is_club_owner(club_id) or public.is_active_club_member(club_id));

create policy "match_lineup_players: select own club"
  on public.match_lineup_players for select to authenticated
  using (public.is_club_owner(club_id) or public.is_active_club_member(club_id));

revoke all on table public.match_lineups, public.match_lineup_players from public, anon, authenticated;
grant select on table public.match_lineups, public.match_lineup_players to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Functions
-- ---------------------------------------------------------------------------
-- Errors (message prefix "lineup:" · SQLSTATE):
--   not authenticated / not allowed (42501) · not found (P0002) ·
--   invalid / invalid name / invalid captain / invalid vice-captain /
--   invalid team (22023) · match not confirmed / match started /
--   team archived / player unavailable (migration 19) (P0001) ·
--   invalid squad / player not in club / club not in match (23514)

-- Saves the caller's club's lineup for a match: the whole lineup, in one
-- transaction. p_players: a JSON array in pick order (position = order), e.g.
--   [{"member_id": "…", "selection": "playing"}, … 11 playing, 4 sub]
create or replace function public.save_match_lineup(
  p_match_id          uuid,
  p_name              text,
  p_source_team_id    uuid,
  p_players           jsonb,
  p_captain_member_id uuid,
  p_vice_member_id    uuid
)
returns public.match_lineups
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_match   public.matches;
  v_club    uuid;
  v_name    text := regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g');
  v_team    public.teams;
  v_total   integer;
  v_count   integer;
  v_playing integer;
  v_subs    integer;
  v_row     public.match_lineups;
begin
  if v_uid is null then
    raise exception 'lineup: not authenticated' using errcode = '42501';
  end if;
  -- The match row is share-locked: a concurrent cancel / reschedule waits
  -- until this lineup is saved (both clubs may save at the same time).
  select * into v_match from public.matches m where m.id = p_match_id for share;
  if not found then
    raise exception 'lineup: not found' using errcode = 'P0002';
  end if;
  select c.id into v_club from public.clubs c
   where c.id in (v_match.club_a_id, v_match.club_b_id) and c.owner_id = v_uid;
  if v_club is null then
    raise exception 'lineup: not allowed' using errcode = '42501';
  end if;
  if v_match.status <> 'confirmed' then
    raise exception 'lineup: match not confirmed' using errcode = 'P0001';
  end if;
  if v_match.starts_at <= now() then
    raise exception 'lineup: match started' using errcode = 'P0001';
  end if;
  if char_length(v_name) not between 1 and 40 then
    raise exception 'lineup: invalid name' using errcode = '22023';
  end if;

  -- The squad: an array of {member_id, selection}, no repeats, exactly 11 + 4.
  if p_players is null or jsonb_typeof(p_players) <> 'array' then
    raise exception 'lineup: invalid' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(p_players) e
              where jsonb_typeof(e) <> 'object'
                 or coalesce(e ->> 'selection', '') not in ('playing', 'sub')
                 or coalesce(e ->> 'member_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') then
    raise exception 'lineup: invalid' using errcode = '22023';
  end if;
  select count(*), count(distinct (e ->> 'member_id')::uuid),
         count(*) filter (where e ->> 'selection' = 'playing'),
         count(*) filter (where e ->> 'selection' = 'sub')
    into v_total, v_count, v_playing, v_subs
    from jsonb_array_elements(p_players) e;
  if v_count <> v_total then
    raise exception 'lineup: invalid' using errcode = '22023'; -- a player listed twice
  end if;
  if v_playing <> 11 or v_subs <> 4 then
    raise exception 'lineup: invalid squad' using errcode = '23514';
  end if;

  -- Captain / vice-captain: optional, in the Playing XI, two different people.
  if p_captain_member_id is not null and p_captain_member_id = p_vice_member_id then
    raise exception 'lineup: invalid captain' using errcode = '22023';
  end if;
  if p_captain_member_id is not null and not exists (
       select 1 from jsonb_array_elements(p_players) e
        where (e ->> 'member_id')::uuid = p_captain_member_id and e ->> 'selection' = 'playing') then
    raise exception 'lineup: invalid captain' using errcode = '22023';
  end if;
  if p_vice_member_id is not null and not exists (
       select 1 from jsonb_array_elements(p_players) e
        where (e ->> 'member_id')::uuid = p_vice_member_id and e ->> 'selection' = 'playing') then
    raise exception 'lineup: invalid vice-captain' using errcode = '22023';
  end if;

  -- Source team: optional; one of this club's ACTIVE teams.
  if p_source_team_id is not null then
    select * into v_team from public.teams t where t.id = p_source_team_id;
    if not found or v_team.club_id <> v_club then
      raise exception 'lineup: invalid team' using errcode = '22023';
    end if;
    if v_team.status <> 'active' then
      raise exception 'lineup: team archived' using errcode = 'P0001';
    end if;
  end if;

  -- The players' memberships are share-locked (in id order) BEFORE any
  -- lineup row is touched: a concurrent removal waits for this save (and then
  -- takes the member out of it), or this save waits for the removal (and then
  -- refuses the removed member). Then: every one an active member of this club.
  perform 1 from public.club_members m
   where m.id in (select (e ->> 'member_id')::uuid from jsonb_array_elements(p_players) e)
   order by m.id
     for share;
  if exists (select 1 from jsonb_array_elements(p_players) e
              where not exists (select 1 from public.club_members m
                                 where m.id = (e ->> 'member_id')::uuid
                                   and m.club_id = v_club and m.status = 'active')) then
    raise exception 'lineup: player not in club' using errcode = '23514';
  end if;

  -- Write: header (captain / vice set last, once the players exist), players.
  insert into public.match_lineups as l (match_id, club_id, name, source_team_id, saved_at, saved_by)
  values (p_match_id, v_club, v_name, p_source_team_id, now(), v_uid)
  on conflict (match_id, club_id) do update
     set name = excluded.name, source_team_id = excluded.source_team_id,
         captain_member_id = null, vice_captain_member_id = null,
         saved_at = excluded.saved_at, saved_by = excluded.saved_by;

  delete from public.match_lineup_players where match_id = p_match_id and club_id = v_club;
  insert into public.match_lineup_players (match_id, club_id, member_id, selection, position)
  select p_match_id, v_club, (e.value ->> 'member_id')::uuid, e.value ->> 'selection', e.ordinality::smallint
    from jsonb_array_elements(p_players) with ordinality as e(value, ordinality);

  update public.match_lineups
     set captain_member_id = p_captain_member_id, vice_captain_member_id = p_vice_member_id
   where match_id = p_match_id and club_id = v_club
  returning * into v_row;
  return v_row;
end;
$$;

-- The lineup(s) of a match the caller may see: their OWN club's — as its
-- owner or an active member. Never the opponent's. One row per player in pick
-- order (a saved lineup without players returns one row with player columns
-- NULL); no rows when nothing is saved yet. Readable in any match status.
create or replace function public.match_lineup(p_match_id uuid)
returns table (
  club_id                uuid,
  lineup_name            text,
  source_team_id         uuid,
  captain_member_id      uuid,
  vice_captain_member_id uuid,
  saved_at               timestamptz,
  member_id              uuid,
  full_name              text,
  member_role            text,
  selection              text,
  "position"             smallint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_match public.matches;
begin
  if v_uid is null then
    raise exception 'lineup: not authenticated' using errcode = '42501';
  end if;
  select * into v_match from public.matches m where m.id = p_match_id;
  if not found then
    raise exception 'lineup: not found' using errcode = 'P0002';
  end if;
  if not (public.is_club_owner(v_match.club_a_id) or public.is_club_owner(v_match.club_b_id)
          or public.is_active_club_member(v_match.club_a_id) or public.is_active_club_member(v_match.club_b_id)) then
    raise exception 'lineup: not allowed' using errcode = '42501';
  end if;
  return query
    select l.club_id, l.name, l.source_team_id, l.captain_member_id, l.vice_captain_member_id, l.saved_at,
           lp.member_id, p.full_name, cm.member_role, lp.selection, lp.position
      from public.match_lineups l
      left join public.match_lineup_players lp on lp.match_id = l.match_id and lp.club_id = l.club_id
      left join public.club_members cm on cm.id = lp.member_id
      left join public.profiles p on p.id = cm.user_id
     where l.match_id = p_match_id
       and (public.is_club_owner(l.club_id) or public.is_active_club_member(l.club_id))
     order by l.club_id, lp.position;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Privileges
-- ---------------------------------------------------------------------------
revoke execute on function public.match_lineups_validate() from public, anon, authenticated;
revoke execute on function public.match_lineup_players_validate() from public, anon, authenticated;
revoke execute on function public.club_members_leave_match_lineups() from public, anon, authenticated;
revoke execute on function public.save_match_lineup(uuid, text, uuid, jsonb, uuid, uuid) from public, anon;
revoke execute on function public.match_lineup(uuid) from public, anon;

grant execute on function public.save_match_lineup(uuid, text, uuid, jsonb, uuid, uuid) to authenticated;
grant execute on function public.match_lineup(uuid) to authenticated;

notify pgrst, 'reload schema';
