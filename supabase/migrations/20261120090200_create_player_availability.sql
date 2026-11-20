-- CricEco · migration 19 · player availability (M1, P2)
--
-- NOT APPLIED. Requires migration 11 (club memberships) and migration 18
-- (match lineups: this migration adds the "no injured / unavailable player"
-- rule to them). Review first; apply only with separate approval, after a
-- fresh backup, inside
--   begin; set local lock_timeout = '5s'; <this file> commit;
-- Rollback: supabase/rollback/20261120_rollback_player_availability.sql.
-- Read-only check: supabase/tests/19_player_availability_postcheck.sql.
-- Local test: supabase/tests/local/16_player_availability_local_check.sql.
-- Design: docs/MATCHES_BACKEND.md.
--
-- Rules (mirrors the app's PlayerAvailabilityRecord):
--   * One record per person: status available / limited / unavailable /
--     injured / other; optional reason (injury, personal, work, travel,
--     family_emergency, rest_day, other) and "until" date; optional notes
--     (≤ 200 characters). "available" never carries a reason or a date (they
--     are cleared, as the app does). No record = available.
--   * Only the person themself writes it (set_my_availability, auth.uid()).
--   * Readable by the person, and by the OWNER of a club where the person is
--     an ACTIVE member — nobody else: not other members, not the opponent
--     club, not a club they were removed from, never anon.
--   * Injured / unavailable players can't be picked for a match lineup while
--     the status covers the match day (no until date, or until on/after the
--     match's date in Asia/Karachi): trigger on match_lineup_players. A later
--     status change does not change lineups already saved.
--   * No direct writes for anyone; RLS: SELECT only.
-- All API functions: SECURITY DEFINER, empty search_path, auth.uid() checks,
-- executable by authenticated only (never anon). Errors start with
-- "availability:" (and "lineup: player unavailable" for the lineup rule).

do $$
begin
  if to_regclass('public.club_members') is null or to_regprocedure('public.is_club_owner(uuid)') is null then
    raise exception 'migration 19: migration 11 (club memberships) is required';
  end if;
  if to_regclass('public.match_lineup_players') is null then
    raise exception 'migration 19: migration 18 (match lineups) is required';
  end if;
  if to_regclass('public.player_availability') is not null
     or exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public'
                   and p.proname in ('is_owner_of_active_member', 'set_my_availability', 'my_availability',
                                     'club_player_availability', 'availability_locks_on',
                                     'match_lineup_players_check_availability')) then
    raise exception 'migration 19: already applied (or a name is taken) — nothing changed';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Table
-- ---------------------------------------------------------------------------
create table public.player_availability (
  user_id     uuid primary key
              constraint player_availability_user_id_fkey references public.profiles (id) on delete cascade,
  status      text not null
              constraint player_availability_status_check
              check (status in ('available', 'limited', 'unavailable', 'injured', 'other')),
  reason      text
              constraint player_availability_reason_check
              check (reason is null or reason in ('injury', 'personal', 'work', 'travel', 'family_emergency',
                                                  'rest_day', 'other')),
  until_date  date,
  notes       text
              constraint player_availability_notes_check
              check (notes is null or char_length(btrim(notes)) between 1 and 200),
  updated_at  timestamptz not null default now(),
  constraint player_availability_available_is_plain
    check (status <> 'available' or (reason is null and until_date is null))
);

comment on table public.player_availability is
  'A person''s availability for selection (M1). Written only by set_my_availability (migration 19).';

-- ---------------------------------------------------------------------------
-- 2. Helpers
-- ---------------------------------------------------------------------------
-- Is the caller the owner of a club where [p_user_id] is an ACTIVE member?
-- SECURITY DEFINER so the policy doesn't depend on other tables' policies;
-- it reveals nothing but that boolean.
create or replace function public.is_owner_of_active_member(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.club_members m
                   join public.clubs c on c.id = m.club_id
                  where m.user_id = p_user_id and m.status = 'active' and c.owner_id = (select auth.uid()));
$$;

-- Does this status keep a person out of a lineup on [p_day]?
create or replace function public.availability_locks_on(p_status text, p_until date, p_day date)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select coalesce(p_status in ('injured', 'unavailable') and (p_until is null or p_until >= p_day), false);
$$;

-- ---------------------------------------------------------------------------
-- 3. Row level security (read only; writes through set_my_availability)
-- ---------------------------------------------------------------------------
alter table public.player_availability enable row level security;

create policy "player_availability: select own or owner of their club"
  on public.player_availability for select to authenticated
  using (user_id = (select auth.uid()) or public.is_owner_of_active_member(user_id));

revoke all on table public.player_availability from public, anon, authenticated;
grant select on table public.player_availability to authenticated;

-- ---------------------------------------------------------------------------
-- 4. The lineup rule: no injured / unavailable player on the match day
-- ---------------------------------------------------------------------------
create or replace function public.match_lineup_players_check_availability()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_day date;
begin
  select (m.starts_at at time zone 'Asia/Karachi')::date into v_day from public.matches m where m.id = new.match_id;
  if exists (select 1 from public.club_members cm
               join public.player_availability pa on pa.user_id = cm.user_id
              where cm.id = new.member_id
                and public.availability_locks_on(pa.status, pa.until_date,
                                                 coalesce(v_day, (now() at time zone 'Asia/Karachi')::date))) then
    raise exception 'lineup: player unavailable' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create trigger match_lineup_players_check_availability
  before insert or update of member_id, match_id on public.match_lineup_players
  for each row execute function public.match_lineup_players_check_availability();

-- ---------------------------------------------------------------------------
-- 5. Functions
-- ---------------------------------------------------------------------------
-- Errors (message prefix "availability:" · SQLSTATE):
--   not authenticated / not allowed (42501) · not found (P0002) ·
--   invalid status / invalid reason / invalid date / invalid notes (22023)

-- Sets the caller's own availability (creates or replaces the record).
-- "available" clears reason and date. Blank texts are NULL. until: from
-- today (Asia/Karachi) up to one year ahead.
create or replace function public.set_my_availability(
  p_status     text,
  p_reason     text default null,
  p_until_date date default null,
  p_notes      text default null
)
returns public.player_availability
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_today  date := (now() at time zone 'Asia/Karachi')::date;
  v_status text := lower(btrim(coalesce(p_status, '')));
  v_reason text := nullif(lower(btrim(coalesce(p_reason, ''))), '');
  v_until  date := p_until_date;
  v_notes  text := nullif(btrim(coalesce(p_notes, '')), '');
  v_row    public.player_availability;
begin
  if v_uid is null then
    raise exception 'availability: not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles p where p.id = v_uid) then
    raise exception 'availability: not found' using errcode = 'P0002';
  end if;
  if v_status not in ('available', 'limited', 'unavailable', 'injured', 'other') then
    raise exception 'availability: invalid status' using errcode = '22023';
  end if;
  if v_status = 'available' then
    v_reason := null;
    v_until := null;
  end if;
  if v_reason is not null
     and v_reason not in ('injury', 'personal', 'work', 'travel', 'family_emergency', 'rest_day', 'other') then
    raise exception 'availability: invalid reason' using errcode = '22023';
  end if;
  if v_until is not null and (v_until < v_today or v_until > v_today + 365) then
    raise exception 'availability: invalid date' using errcode = '22023';
  end if;
  if v_notes is not null and char_length(v_notes) > 200 then
    raise exception 'availability: invalid notes' using errcode = '22023';
  end if;

  insert into public.player_availability as a (user_id, status, reason, until_date, notes, updated_at)
  values (v_uid, v_status, v_reason, v_until, v_notes, now())
  on conflict (user_id) do update
     set status = excluded.status, reason = excluded.reason, until_date = excluded.until_date,
         notes = excluded.notes, updated_at = excluded.updated_at
  returning * into v_row;
  return v_row;
end;
$$;

-- The caller's own record (no row = available).
create or replace function public.my_availability()
returns setof public.player_availability
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'availability: not authenticated' using errcode = '42501';
  end if;
  return query select * from public.player_availability a where a.user_id = auth.uid();
end;
$$;

-- A club's ACTIVE members with their availability, for the club's owner
-- only (squad pool / lineup builder). No record = available.
-- locks_selection: injured / unavailable covering today (Asia/Karachi).
create or replace function public.club_player_availability(p_club_id uuid)
returns table (
  member_id       uuid,
  user_id         uuid,
  full_name       text,
  member_role     text,
  status          text,
  reason          text,
  until_date      date,
  notes           text,
  updated_at      timestamptz,
  locks_selection boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'availability: not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.clubs c where c.id = p_club_id and c.owner_id = v_uid) then
    raise exception 'availability: not allowed' using errcode = '42501';
  end if;
  return query
    select m.id, m.user_id, p.full_name, m.member_role,
           coalesce(a.status, 'available'), a.reason, a.until_date, a.notes, a.updated_at,
           public.availability_locks_on(a.status, a.until_date, (now() at time zone 'Asia/Karachi')::date)
      from public.club_members m
      left join public.profiles p on p.id = m.user_id
      left join public.player_availability a on a.user_id = m.user_id
     where m.club_id = p_club_id and m.status = 'active'
     order by (m.member_role = 'owner') desc, lower(coalesce(p.full_name, '')), m.id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Privileges
-- ---------------------------------------------------------------------------
revoke execute on function public.availability_locks_on(text, date, date) from public, anon, authenticated;
revoke execute on function public.match_lineup_players_check_availability() from public, anon, authenticated;
revoke execute on function public.is_owner_of_active_member(uuid) from public, anon;
revoke execute on function public.set_my_availability(text, text, date, text) from public, anon;
revoke execute on function public.my_availability() from public, anon;
revoke execute on function public.club_player_availability(uuid) from public, anon;

grant execute on function public.is_owner_of_active_member(uuid) to authenticated; -- used by the policy
grant execute on function public.set_my_availability(text, text, date, text) to authenticated;
grant execute on function public.my_availability() to authenticated;
grant execute on function public.club_player_availability(uuid) to authenticated;

notify pgrst, 'reload schema';
