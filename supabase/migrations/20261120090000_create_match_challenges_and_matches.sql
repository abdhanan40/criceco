-- CricEco · migration 17 · match challenges and matches (M1, P1)
--
-- NOT APPLIED. Requires migration 11 (club_members, is_club_owner) and the
-- profiles migration (set_last_updated_at). Review first; apply only with
-- separate approval, after a fresh backup, inside
--   begin; set local lock_timeout = '5s'; <this file> commit;
-- Rollback: supabase/rollback/20261120_rollback_match_challenges_and_matches.sql.
-- Read-only check: supabase/tests/17_matches_postcheck.sql.
-- Local test: supabase/tests/local/14_matches_local_check.sql (+ 14b_…sh).
-- Design: docs/MATCHES_BACKEND.md.
--
-- Approved rules (M1 decisions, 2026-11-20):
--   * Clubs find each other through match_club_directory: public fields only
--     (id, name, short name, city, type) — never owner, phone, email,
--     address or join code. The clubs table itself stays owner-only.
--   * Only club OWNERS manage challenges and matches (managers/coaches: no).
--   * A challenge (date + venue + format) goes from one club's owner to
--     another club. One pending challenge per club pair, in either direction;
--     at most 20 pending sent challenges per club. It expires 7 days after it
--     was sent, or when its proposed date starts if that is sooner (Asia/
--     Karachi), marked lazily.
--   * The receiving owner accepts or declines. Accepting creates EXACTLY ONE
--     pending match (matches.challenge_id is unique; the challenge row is
--     locked). The challenge's date and venue become the challenger's schedule
--     proposal on that match, at the default start time 10:00 Asia/Karachi.
--   * Schedule: either club's owner proposes a start time + venue (+ city);
--     the OTHER club's owner accepts (→ confirmed) or declines (proposal
--     cleared). Every proposal bumps proposal_version; a response must name
--     the version it answers. Confirming checks that neither club has another
--     confirmed match overlapping that time (per-club advisory locks, taken in
--     uuid order). A confirmed match may be rescheduled the same way before it
--     starts; it stays confirmed at the old time until the new one is accepted.
--   * Either owner cancels a pending or confirmed match before it starts,
--     with a reason. 'completed' is reserved for results (M2): nothing sets it
--     yet.
--   * RLS: SELECT only — challenges for the owners of both clubs; matches for
--     the owners and active members of both clubs. No direct INSERT / UPDATE /
--     DELETE for anyone: every change goes through the functions below, which
--     take the caller from auth.uid() and re-check ownership in the database.
--   * Ground booking and payments stay demo-only (M7). Lineups (P2), player
--     availability (P2), results and scorecards (M2) are not part of this.
-- All API functions: SECURITY DEFINER, empty search_path, executable by
-- authenticated only (never anon). Errors start with "challenge:" or "match:"
-- (see section 4).

do $$
begin
  if to_regclass('public.clubs') is null or to_regclass('public.club_members') is null
     or to_regprocedure('public.is_club_owner(uuid)') is null
     or to_regprocedure('public.set_last_updated_at()') is null then
    raise exception 'migration 17: migration 11 (club memberships) is required';
  end if;
  if to_regclass('public.match_challenges') is not null or to_regclass('public.matches') is not null
     or exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public'
                   and p.proname in ('is_active_club_member', 'match_duration', 'match_lock_clubs',
                                     'match_challenges_guard_update', 'matches_guard_update',
                                     'match_club_directory', 'send_challenge', 'respond_to_challenge',
                                     'club_challenges', 'propose_match_schedule', 'respond_to_match_schedule',
                                     'cancel_match', 'club_matches')) then
    raise exception 'migration 17: already applied (or a name is taken) — nothing changed';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
create table public.match_challenges (
  id             uuid primary key default gen_random_uuid(),
  from_club_id   uuid not null
                 constraint match_challenges_from_club_id_fkey references public.clubs (id) on delete cascade,
  to_club_id     uuid not null
                 constraint match_challenges_to_club_id_fkey references public.clubs (id) on delete cascade,
  format         text not null
                 constraint match_challenges_format_check check (format in ('test', 't20', 'odi', 't10', 'custom')),
  custom_overs   smallint
                 constraint match_challenges_custom_overs_check check (custom_overs is null or custom_overs between 1 and 50),
  proposed_date  date not null,
  venue_name     text not null
                 constraint match_challenges_venue_name_check check (char_length(btrim(venue_name)) between 1 and 100),
  message        text
                 constraint match_challenges_message_check
                 check (message is null or char_length(btrim(message)) between 1 and 280),
  status         text not null default 'pending'
                 constraint match_challenges_status_check
                 check (status in ('pending', 'accepted', 'declined', 'expired')),
  expires_at     timestamptz not null,
  decided_at     timestamptz,
  decided_by     uuid
                 constraint match_challenges_decided_by_fkey references public.profiles (id) on delete set null,
  match_id       uuid
                 constraint match_challenges_match_id_key unique,
  created_at     timestamptz not null default now(),
  constraint match_challenges_not_self check (from_club_id <> to_club_id),
  constraint match_challenges_overs_follow_format check ((format = 'custom') = (custom_overs is not null)),
  constraint match_challenges_decided_consistency check ((status = 'pending') = (decided_at is null)),
  constraint match_challenges_match_on_accept check (match_id is null or status = 'accepted'),
  constraint match_challenges_expiry_after_creation check (expires_at > created_at)
);

comment on table public.match_challenges is
  'Club-to-club match challenges (M1). Written only by send_challenge / respond_to_challenge (migration 17).';

-- One pending challenge per club pair, whichever club sent it.
create unique index match_challenges_one_pending_pair_key
  on public.match_challenges (least(from_club_id, to_club_id), greatest(from_club_id, to_club_id))
  where status = 'pending';
create index match_challenges_to_club_status_idx on public.match_challenges (to_club_id, status, created_at desc);
create index match_challenges_from_club_status_idx on public.match_challenges (from_club_id, status, created_at desc);
create index match_challenges_decided_by_idx on public.match_challenges (decided_by) where decided_by is not null;

create table public.matches (
  id                   uuid primary key default gen_random_uuid(),
  challenge_id         uuid
                       constraint matches_challenge_id_key unique
                       constraint matches_challenge_id_fkey references public.match_challenges (id) on delete set null,
  club_a_id            uuid not null
                       constraint matches_club_a_id_fkey references public.clubs (id) on delete cascade,
  club_b_id            uuid not null
                       constraint matches_club_b_id_fkey references public.clubs (id) on delete cascade,
  format               text not null
                       constraint matches_format_check check (format in ('test', 't20', 'odi', 't10', 'custom')),
  custom_overs         smallint
                       constraint matches_custom_overs_check check (custom_overs is null or custom_overs between 1 and 50),
  status               text not null default 'pending'
                       constraint matches_status_check check (status in ('pending', 'confirmed', 'completed', 'cancelled')),
  -- The agreed schedule (set when a proposal is accepted).
  starts_at            timestamptz,
  venue_name           text
                       constraint matches_venue_name_check
                       check (venue_name is null or char_length(btrim(venue_name)) between 1 and 100),
  city                 text
                       constraint matches_city_check check (city is null or char_length(btrim(city)) between 1 and 60),
  -- The open schedule proposal, if any (proposed_city is optional).
  proposed_starts_at   timestamptz,
  proposed_venue_name  text
                       constraint matches_proposed_venue_name_check
                       check (proposed_venue_name is null or char_length(btrim(proposed_venue_name)) between 1 and 100),
  proposed_city        text
                       constraint matches_proposed_city_check
                       check (proposed_city is null or char_length(btrim(proposed_city)) between 1 and 60),
  proposed_by_club_id  uuid,
  proposal_version     integer not null default 0
                       constraint matches_proposal_version_check check (proposal_version >= 0),
  cancelled_at         timestamptz,
  cancelled_by_club_id uuid,
  cancel_reason        text
                       constraint matches_cancel_reason_check
                       check (cancel_reason is null or char_length(btrim(cancel_reason)) between 1 and 200),
  created_at           timestamptz not null default now(),
  last_updated_at      timestamptz not null default now(),
  constraint matches_two_clubs check (club_a_id <> club_b_id),
  constraint matches_overs_follow_format check ((format = 'custom') = (custom_overs is not null)),
  constraint matches_scheduled_when_confirmed
    check (status not in ('confirmed', 'completed') or (starts_at is not null and venue_name is not null)),
  constraint matches_cancelled_consistency check (
    (status = 'cancelled') = (cancelled_at is not null)
    and (cancelled_at is null) = (cancelled_by_club_id is null)
    and (cancelled_at is null) = (cancel_reason is null)),
  constraint matches_proposal_complete check (
    (proposed_starts_at is null) = (proposed_venue_name is null)
    and (proposed_starts_at is null) = (proposed_by_club_id is null)
    and (proposed_city is null or proposed_starts_at is not null)),
  constraint matches_proposal_only_when_open check (proposed_starts_at is null or status in ('pending', 'confirmed')),
  constraint matches_proposed_by_participant
    check (proposed_by_club_id is null or proposed_by_club_id in (club_a_id, club_b_id)),
  constraint matches_cancelled_by_participant
    check (cancelled_by_club_id is null or cancelled_by_club_id in (club_a_id, club_b_id))
);

comment on table public.matches is
  'Matches between two clubs (M1). club_a = the challenger. Written only by the match functions (migration 17).';

alter table public.match_challenges
  add constraint match_challenges_match_id_fkey foreign key (match_id) references public.matches (id) on delete set null;

create index matches_club_a_status_starts_idx on public.matches (club_a_id, status, starts_at);
create index matches_club_b_status_starts_idx on public.matches (club_b_id, status, starts_at);

create trigger matches_set_last_updated_at
  before update on public.matches
  for each row execute function public.set_last_updated_at();

-- ---------------------------------------------------------------------------
-- 2. Status transitions (defence in depth; the functions check the same)
-- ---------------------------------------------------------------------------
-- A challenge is decided once: pending → accepted | declined | expired. Its
-- terms never change. After the decision only the foreign keys' own
-- ON DELETE SET NULL (decider's profile, the match) may touch it.
create or replace function public.match_challenges_guard_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.status = 'pending' then
    if new.status not in ('accepted', 'declined', 'expired')
       or (to_jsonb(new) - array['status', 'decided_at', 'decided_by', 'match_id'])
          is distinct from (to_jsonb(old) - array['status', 'decided_at', 'decided_by', 'match_id']) then
      raise exception 'challenge: invalid transition' using errcode = '23514';
    end if;
    return new;
  end if;
  if (to_jsonb(new) - array['decided_by', 'match_id']) is distinct from (to_jsonb(old) - array['decided_by', 'match_id'])
     or (new.decided_by is not null and new.decided_by is distinct from old.decided_by)
     or (new.match_id is not null and new.match_id is distinct from old.match_id) then
    raise exception 'challenge: not pending' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create trigger match_challenges_guard_update
  before update on public.match_challenges
  for each row execute function public.match_challenges_guard_update();

-- A match: pending → pending (proposals) | confirmed | cancelled;
-- confirmed → confirmed (reschedule) | cancelled | completed (M2).
-- cancelled / completed are final. Clubs, format and challenge never change
-- (except the challenge link's own ON DELETE SET NULL).
create or replace function public.matches_guard_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (new.club_a_id, new.club_b_id, new.format, new.custom_overs, new.created_at)
       is distinct from (old.club_a_id, old.club_b_id, old.format, old.custom_overs, old.created_at)
     or (new.challenge_id is not null and new.challenge_id is distinct from old.challenge_id) then
    raise exception 'match: invalid transition' using errcode = '23514';
  end if;
  if old.status in ('cancelled', 'completed') then
    if (to_jsonb(new) - array['challenge_id', 'last_updated_at'])
       is distinct from (to_jsonb(old) - array['challenge_id', 'last_updated_at']) then
      raise exception 'match: not open' using errcode = 'P0001';
    end if;
  elsif not ((old.status = 'pending' and new.status in ('pending', 'confirmed', 'cancelled'))
          or (old.status = 'confirmed' and new.status in ('confirmed', 'cancelled', 'completed'))) then
    raise exception 'match: invalid transition' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger matches_guard_update
  before update on public.matches
  for each row execute function public.matches_guard_update();

-- ---------------------------------------------------------------------------
-- 3. Row level security (read only; writes through the functions)
-- ---------------------------------------------------------------------------
-- Is the caller an ACTIVE member (any role, owner included) of [p_club_id]?
-- SECURITY DEFINER so the policy doesn't depend on club_members' own policy;
-- it reveals nothing but that boolean, and only about the caller.
create or replace function public.is_active_club_member(p_club_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.club_members m
                  where m.club_id = p_club_id and m.user_id = (select auth.uid()) and m.status = 'active');
$$;

alter table public.match_challenges enable row level security;
alter table public.matches enable row level security;

create policy "match_challenges: select owner of either club"
  on public.match_challenges for select to authenticated
  using (public.is_club_owner(from_club_id) or public.is_club_owner(to_club_id));

create policy "matches: select owner or member of either club"
  on public.matches for select to authenticated
  using (public.is_club_owner(club_a_id) or public.is_club_owner(club_b_id)
         or public.is_active_club_member(club_a_id) or public.is_active_club_member(club_b_id));

revoke all on table public.match_challenges, public.matches from public, anon, authenticated;
grant select on table public.match_challenges, public.matches to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Functions
-- ---------------------------------------------------------------------------
-- Errors (message prefix · SQLSTATE):
--   challenge: not authenticated / not allowed (42501) · club not found /
--     not found (P0002) · own club (P0001) · invalid / invalid date /
--     invalid venue / invalid message (22023) · already pending (23505) ·
--     too many pending (P0001) · not pending (P0001) · invalid transition (23514)
--   match: not authenticated / not allowed (42501) · not found (P0002) ·
--     invalid / invalid time / invalid venue / invalid city / invalid reason
--     (22023) · not open (P0001) · already started (P0001) · no proposal
--     (P0001) · proposal changed (P0001) · schedule clash (23P01) ·
--     invalid transition (23514)
-- An expired challenge is NOT an error when answered: respond_to_challenge
-- marks it 'expired' and returns it (raising would roll the mark back).

-- How long a match occupies its clubs, for the clash check.
create or replace function public.match_duration(p_format text, p_custom_overs integer)
returns interval
language sql
immutable
set search_path = ''
as $$
  select case p_format
           when 't10'  then interval '3 hours'
           when 't20'  then interval '4 hours'
           when 'odi'  then interval '8 hours'
           when 'test' then interval '5 days'
           else greatest(interval '1 hour', coalesce(p_custom_overs, 50) * interval '8 minutes')
         end;
$$;

-- Serialises work on the given clubs: transaction advisory locks, always
-- taken in uuid order (so two callers can't deadlock), released at commit.
create or replace function public.match_lock_clubs(p_club_a uuid, p_club_b uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_club uuid;
begin
  for v_club in select x from unnest(array[p_club_a, p_club_b]) as x where x is not null group by x order by x loop
    perform pg_advisory_xact_lock(hashtextextended('criceco.match.club:' || v_club::text, 0));
  end loop;
end;
$$;

-- Find Opponent / challenge sheet: other clubs' PUBLIC fields only.
-- Signed-in club owners only; never the caller's own club; at most 50 rows.
-- p_search matches name or short name (case-insensitive substring);
-- p_city matches the city exactly (case and outer spaces ignored).
create or replace function public.match_club_directory(p_search text default null, p_city text default null)
returns table (
  club_id     uuid,
  name        text,
  short_name  text,
  city        text,
  club_type   text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_search text := lower(nullif(regexp_replace(btrim(coalesce(p_search, '')), '\s+', ' ', 'g'), ''));
  v_city   text := lower(nullif(btrim(coalesce(p_city, '')), ''));
begin
  if v_uid is null then
    raise exception 'match: not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.clubs c where c.owner_id = v_uid) then
    raise exception 'match: not allowed' using errcode = '42501';
  end if;
  if char_length(coalesce(v_search, '')) > 100 or char_length(coalesce(v_city, '')) > 60 then
    raise exception 'match: invalid' using errcode = '22023';
  end if;
  return query
    select c.id, c.name, c.short_name, c.city, c.club_type
      from public.clubs c
     where c.owner_id <> v_uid
       and (v_search is null
            or strpos(lower(c.name), v_search) > 0
            or strpos(lower(coalesce(c.short_name, '')), v_search) > 0)
       and (v_city is null or lower(btrim(c.city)) = v_city)
     order by lower(c.name), c.id
     limit 50;
end;
$$;

-- Send a challenge from a club the caller owns. Returns the new challenge.
create or replace function public.send_challenge(
  p_from_club_id  uuid,
  p_to_club_id    uuid,
  p_format        text,
  p_custom_overs  integer,
  p_proposed_date date,
  p_venue_name    text,
  p_message       text default null
)
returns public.match_challenges
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid      uuid := auth.uid();
  v_today    date := (now() at time zone 'Asia/Karachi')::date;
  v_format   text := lower(btrim(coalesce(p_format, '')));
  v_venue    text := regexp_replace(btrim(coalesce(p_venue_name, '')), '\s+', ' ', 'g');
  v_message  text := nullif(btrim(coalesce(p_message, '')), '');
  v_pending  integer;
  v_row      public.match_challenges;
begin
  if v_uid is null then
    raise exception 'challenge: not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.clubs c where c.id = p_from_club_id) then
    raise exception 'challenge: club not found' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.clubs c where c.id = p_from_club_id and c.owner_id = v_uid) then
    raise exception 'challenge: not allowed' using errcode = '42501';
  end if;
  if not exists (select 1 from public.clubs c where c.id = p_to_club_id) then
    raise exception 'challenge: club not found' using errcode = 'P0002';
  end if;
  if p_to_club_id = p_from_club_id then
    raise exception 'challenge: own club' using errcode = 'P0001';
  end if;
  if v_format not in ('test', 't20', 'odi', 't10', 'custom')
     or (v_format = 'custom' and (p_custom_overs is null or p_custom_overs not between 1 and 50)) then
    raise exception 'challenge: invalid' using errcode = '22023';
  end if;
  if p_proposed_date is null or p_proposed_date < v_today + 1 or p_proposed_date > v_today + 365 then
    raise exception 'challenge: invalid date' using errcode = '22023';
  end if;
  if char_length(v_venue) not between 1 and 100 then
    raise exception 'challenge: invalid venue' using errcode = '22023';
  end if;
  if v_message is not null and char_length(v_message) > 280 then
    raise exception 'challenge: invalid message' using errcode = '22023';
  end if;

  -- Both clubs, in uuid order: crossed challenges and the pending cap are
  -- decided one at a time.
  perform public.match_lock_clubs(p_from_club_id, p_to_club_id);

  -- Pending challenges past their expiry no longer count (marked lazily).
  update public.match_challenges
     set status = 'expired', decided_at = now()
   where status = 'pending' and expires_at <= now()
     and (from_club_id = p_from_club_id
          or (least(from_club_id, to_club_id) = least(p_from_club_id, p_to_club_id)
              and greatest(from_club_id, to_club_id) = greatest(p_from_club_id, p_to_club_id)));

  if exists (select 1 from public.match_challenges m
              where m.status = 'pending'
                and least(m.from_club_id, m.to_club_id) = least(p_from_club_id, p_to_club_id)
                and greatest(m.from_club_id, m.to_club_id) = greatest(p_from_club_id, p_to_club_id)) then
    raise exception 'challenge: already pending' using errcode = '23505';
  end if;
  select count(*) into v_pending from public.match_challenges m
   where m.from_club_id = p_from_club_id and m.status = 'pending';
  if v_pending >= 20 then
    raise exception 'challenge: too many pending' using errcode = 'P0001';
  end if;

  begin
    insert into public.match_challenges (from_club_id, to_club_id, format, custom_overs, proposed_date,
                                         venue_name, message, expires_at)
    values (p_from_club_id, p_to_club_id, v_format, case when v_format = 'custom' then p_custom_overs end,
            p_proposed_date, v_venue, v_message,
            least(now() + interval '7 days', p_proposed_date::timestamp at time zone 'Asia/Karachi'))
    returning * into v_row;
  exception
    when unique_violation then
      raise exception 'challenge: already pending' using errcode = '23505';
    when check_violation or not_null_violation or numeric_value_out_of_range then
      raise exception 'challenge: invalid' using errcode = '22023';
  end;
  return v_row;
end;
$$;

-- The receiving club's owner accepts or declines. Returns the challenge:
-- 'accepted' (with match_id), 'declined', or 'expired' when it ran out
-- (then nothing else changes).
create or replace function public.respond_to_challenge(p_challenge_id uuid, p_accept boolean)
returns public.match_challenges
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_row   public.match_challenges;
  v_match uuid;
begin
  if v_uid is null then
    raise exception 'challenge: not authenticated' using errcode = '42501';
  end if;
  if p_accept is null then
    raise exception 'challenge: invalid' using errcode = '22023';
  end if;
  -- The row lock makes a second, concurrent answer wait — and then see
  -- the challenge is no longer pending.
  select * into v_row from public.match_challenges c where c.id = p_challenge_id for update;
  if not found then
    raise exception 'challenge: not found' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.clubs c where c.id = v_row.to_club_id and c.owner_id = v_uid) then
    raise exception 'challenge: not allowed' using errcode = '42501';
  end if;
  if v_row.status <> 'pending' then
    raise exception 'challenge: not pending' using errcode = 'P0001';
  end if;
  if v_row.expires_at <= now() then
    update public.match_challenges set status = 'expired', decided_at = now()
     where id = p_challenge_id returning * into v_row;
    return v_row;
  end if;

  if not p_accept then
    update public.match_challenges set status = 'declined', decided_at = now(), decided_by = v_uid
     where id = p_challenge_id returning * into v_row;
    return v_row;
  end if;

  -- Accept: one pending match; the challenge's date and venue are the
  -- challenger's (club A's) schedule proposal, version 1.
  begin
    insert into public.matches (challenge_id, club_a_id, club_b_id, format, custom_overs, status,
                                proposed_starts_at, proposed_venue_name, proposed_by_club_id, proposal_version)
    values (v_row.id, v_row.from_club_id, v_row.to_club_id, v_row.format, v_row.custom_overs, 'pending',
            (v_row.proposed_date + time '10:00') at time zone 'Asia/Karachi', v_row.venue_name,
            v_row.from_club_id, 1)
    returning id into v_match;
  exception
    when unique_violation then
      raise exception 'challenge: not pending' using errcode = 'P0001';
  end;
  update public.match_challenges
     set status = 'accepted', decided_at = now(), decided_by = v_uid, match_id = v_match
   where id = p_challenge_id
  returning * into v_row;
  return v_row;
end;
$$;

-- A club's challenges (sent and received), newest first, for its owner.
-- status is the effective one ('expired' once a pending challenge ran out).
create or replace function public.club_challenges(p_club_id uuid)
returns table (
  challenge_id        uuid,
  direction           text,
  opponent_club_id    uuid,
  opponent_name       text,
  opponent_short_name text,
  opponent_city       text,
  format              text,
  custom_overs        smallint,
  proposed_date       date,
  venue_name          text,
  message             text,
  status              text,
  created_at          timestamptz,
  expires_at          timestamptz,
  decided_at          timestamptz,
  match_id            uuid
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
    raise exception 'challenge: not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.clubs c where c.id = p_club_id and c.owner_id = v_uid) then
    raise exception 'challenge: not allowed' using errcode = '42501';
  end if;
  return query
    select m.id,
           case when m.from_club_id = p_club_id then 'sent' else 'received' end,
           o.id, o.name, o.short_name, o.city,
           m.format, m.custom_overs, m.proposed_date, m.venue_name, m.message,
           case when m.status = 'pending' and m.expires_at <= now() then 'expired' else m.status end,
           m.created_at, m.expires_at, m.decided_at, m.match_id
      from public.match_challenges m
      join public.clubs o on o.id = case when m.from_club_id = p_club_id then m.to_club_id else m.from_club_id end
     where m.from_club_id = p_club_id or m.to_club_id = p_club_id
     order by m.created_at desc, m.id;
end;
$$;

-- Either club's owner proposes (or re-proposes) the schedule of a pending or
-- not-yet-started confirmed match. Replaces any open proposal.
create or replace function public.propose_match_schedule(
  p_match_id   uuid,
  p_starts_at  timestamptz,
  p_venue_name text,
  p_city       text default null
)
returns public.matches
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_row   public.matches;
  v_club  uuid;
  v_venue text := regexp_replace(btrim(coalesce(p_venue_name, '')), '\s+', ' ', 'g');
  v_city  text := nullif(regexp_replace(btrim(coalesce(p_city, '')), '\s+', ' ', 'g'), '');
begin
  if v_uid is null then
    raise exception 'match: not authenticated' using errcode = '42501';
  end if;
  select * into v_row from public.matches m where m.id = p_match_id for update;
  if not found then
    raise exception 'match: not found' using errcode = 'P0002';
  end if;
  select c.id into v_club from public.clubs c
   where c.id in (v_row.club_a_id, v_row.club_b_id) and c.owner_id = v_uid;
  if v_club is null then
    raise exception 'match: not allowed' using errcode = '42501';
  end if;
  if v_row.status not in ('pending', 'confirmed') then
    raise exception 'match: not open' using errcode = 'P0001';
  end if;
  if v_row.status = 'confirmed' and v_row.starts_at <= now() then
    raise exception 'match: already started' using errcode = 'P0001';
  end if;
  if p_starts_at is null or p_starts_at <= now() or p_starts_at > now() + interval '365 days' then
    raise exception 'match: invalid time' using errcode = '22023';
  end if;
  if char_length(v_venue) not between 1 and 100 then
    raise exception 'match: invalid venue' using errcode = '22023';
  end if;
  if v_city is not null and char_length(v_city) > 60 then
    raise exception 'match: invalid city' using errcode = '22023';
  end if;
  update public.matches
     set proposed_starts_at = p_starts_at, proposed_venue_name = v_venue, proposed_city = v_city,
         proposed_by_club_id = v_club, proposal_version = v_row.proposal_version + 1
   where id = p_match_id
  returning * into v_row;
  return v_row;
end;
$$;

-- The OTHER club's owner answers the open proposal [p_proposal_version].
-- Accept → confirmed at the proposed time (after the clash check); decline →
-- the proposal is cleared (the match keeps its status and agreed schedule).
create or replace function public.respond_to_match_schedule(
  p_match_id         uuid,
  p_proposal_version integer,
  p_accept           boolean
)
returns public.matches
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_row   public.matches;
  v_club  uuid;
  v_start timestamptz;
  v_end   timestamptz;
begin
  if v_uid is null then
    raise exception 'match: not authenticated' using errcode = '42501';
  end if;
  if p_accept is null or p_proposal_version is null then
    raise exception 'match: invalid' using errcode = '22023';
  end if;
  select * into v_row from public.matches m where m.id = p_match_id;
  if not found then
    raise exception 'match: not found' using errcode = 'P0002';
  end if;
  -- Locks: both clubs (uuid order) before the row, the same order every
  -- clash-checking call uses; then the match row.
  perform public.match_lock_clubs(v_row.club_a_id, v_row.club_b_id);
  select * into v_row from public.matches m where m.id = p_match_id for update;

  select c.id into v_club from public.clubs c
   where c.id in (v_row.club_a_id, v_row.club_b_id) and c.owner_id = v_uid;
  if v_club is null then
    raise exception 'match: not allowed' using errcode = '42501';
  end if;
  if v_row.status not in ('pending', 'confirmed') then
    raise exception 'match: not open' using errcode = 'P0001';
  end if;
  if v_row.proposed_starts_at is null then
    raise exception 'match: no proposal' using errcode = 'P0001';
  end if;
  if v_row.proposed_by_club_id = v_club then
    raise exception 'match: not allowed' using errcode = '42501'; -- the proposer can't confirm their own proposal
  end if;
  if v_row.proposal_version <> p_proposal_version then
    raise exception 'match: proposal changed' using errcode = 'P0001';
  end if;

  if not p_accept then
    update public.matches
       set proposed_starts_at = null, proposed_venue_name = null, proposed_city = null, proposed_by_club_id = null
     where id = p_match_id
    returning * into v_row;
    return v_row;
  end if;

  if v_row.status = 'confirmed' and v_row.starts_at <= now() then
    raise exception 'match: already started' using errcode = 'P0001';
  end if;
  v_start := v_row.proposed_starts_at;
  if v_start <= now() then
    raise exception 'match: invalid time' using errcode = '22023';
  end if;
  v_end := v_start + public.match_duration(v_row.format, v_row.custom_overs);
  if exists (select 1 from public.matches o
              where o.id <> v_row.id and o.status = 'confirmed'
                and (o.club_a_id in (v_row.club_a_id, v_row.club_b_id) or o.club_b_id in (v_row.club_a_id, v_row.club_b_id))
                and o.starts_at < v_end
                and o.starts_at + public.match_duration(o.format, o.custom_overs) > v_start) then
    raise exception 'match: schedule clash' using errcode = '23P01';
  end if;

  update public.matches
     set status = 'confirmed', starts_at = v_start, venue_name = v_row.proposed_venue_name, city = v_row.proposed_city,
         proposed_starts_at = null, proposed_venue_name = null, proposed_city = null, proposed_by_club_id = null
   where id = p_match_id
  returning * into v_row;
  return v_row;
end;
$$;

-- Either club's owner cancels a pending match, or a confirmed one before it
-- starts. A reason (1–200 characters) is required.
create or replace function public.cancel_match(p_match_id uuid, p_reason text)
returns public.matches
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_row    public.matches;
  v_club   uuid;
  v_reason text := regexp_replace(btrim(coalesce(p_reason, '')), '\s+', ' ', 'g');
begin
  if v_uid is null then
    raise exception 'match: not authenticated' using errcode = '42501';
  end if;
  select * into v_row from public.matches m where m.id = p_match_id for update;
  if not found then
    raise exception 'match: not found' using errcode = 'P0002';
  end if;
  select c.id into v_club from public.clubs c
   where c.id in (v_row.club_a_id, v_row.club_b_id) and c.owner_id = v_uid;
  if v_club is null then
    raise exception 'match: not allowed' using errcode = '42501';
  end if;
  if v_row.status not in ('pending', 'confirmed') then
    raise exception 'match: not open' using errcode = 'P0001';
  end if;
  if v_row.status = 'confirmed' and v_row.starts_at <= now() then
    raise exception 'match: already started' using errcode = 'P0001';
  end if;
  if char_length(v_reason) not between 1 and 200 then
    raise exception 'match: invalid reason' using errcode = '22023';
  end if;
  update public.matches
     set status = 'cancelled', cancelled_at = now(), cancelled_by_club_id = v_club, cancel_reason = v_reason,
         proposed_starts_at = null, proposed_venue_name = null, proposed_city = null, proposed_by_club_id = null
   where id = p_match_id
  returning * into v_row;
  return v_row;
end;
$$;

-- A club's matches, one-sided, for its owner: the opponent's public fields,
-- who challenged whom, the agreed schedule and the open proposal.
-- Upcoming first (by agreed or proposed start), then the rest, newest first.
create or replace function public.club_matches(p_club_id uuid)
returns table (
  match_id            uuid,
  challenge_id        uuid,
  opponent_club_id    uuid,
  opponent_name       text,
  opponent_short_name text,
  opponent_city       text,
  challenged_by_me    boolean,
  format              text,
  custom_overs        smallint,
  status              text,
  starts_at           timestamptz,
  venue_name          text,
  city                text,
  proposed_starts_at  timestamptz,
  proposed_venue_name text,
  proposed_city       text,
  proposed_by_me      boolean,
  proposal_version    integer,
  cancelled_at        timestamptz,
  cancelled_by_me     boolean,
  cancel_reason       text,
  created_at          timestamptz,
  last_updated_at     timestamptz
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
    raise exception 'match: not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.clubs c where c.id = p_club_id and c.owner_id = v_uid) then
    raise exception 'match: not allowed' using errcode = '42501';
  end if;
  return query
    select m.id, m.challenge_id, o.id, o.name, o.short_name, o.city,
           m.club_a_id = p_club_id,
           m.format, m.custom_overs, m.status, m.starts_at, m.venue_name, m.city,
           m.proposed_starts_at, m.proposed_venue_name, m.proposed_city,
           case when m.proposed_by_club_id is null then null else m.proposed_by_club_id = p_club_id end,
           m.proposal_version, m.cancelled_at,
           case when m.cancelled_by_club_id is null then null else m.cancelled_by_club_id = p_club_id end,
           m.cancel_reason, m.created_at, m.last_updated_at
      from public.matches m
      join public.clubs o on o.id = case when m.club_a_id = p_club_id then m.club_b_id else m.club_a_id end
     where m.club_a_id = p_club_id or m.club_b_id = p_club_id
     order by (m.status in ('pending', 'confirmed')) desc,
              case when m.status in ('pending', 'confirmed') then coalesce(m.starts_at, m.proposed_starts_at) end
                nulls last,
              coalesce(m.starts_at, m.created_at) desc, m.id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Privileges
-- ---------------------------------------------------------------------------
revoke execute on function public.match_challenges_guard_update() from public, anon, authenticated;
revoke execute on function public.matches_guard_update() from public, anon, authenticated;
revoke execute on function public.match_duration(text, integer) from public, anon, authenticated;
revoke execute on function public.match_lock_clubs(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.is_active_club_member(uuid) from public, anon;
revoke execute on function public.match_club_directory(text, text) from public, anon;
revoke execute on function public.send_challenge(uuid, uuid, text, integer, date, text, text) from public, anon;
revoke execute on function public.respond_to_challenge(uuid, boolean) from public, anon;
revoke execute on function public.club_challenges(uuid) from public, anon;
revoke execute on function public.propose_match_schedule(uuid, timestamptz, text, text) from public, anon;
revoke execute on function public.respond_to_match_schedule(uuid, integer, boolean) from public, anon;
revoke execute on function public.cancel_match(uuid, text) from public, anon;
revoke execute on function public.club_matches(uuid) from public, anon;

grant execute on function public.is_active_club_member(uuid) to authenticated; -- used by the matches policy
grant execute on function public.match_club_directory(text, text) to authenticated;
grant execute on function public.send_challenge(uuid, uuid, text, integer, date, text, text) to authenticated;
grant execute on function public.respond_to_challenge(uuid, boolean) to authenticated;
grant execute on function public.club_challenges(uuid) to authenticated;
grant execute on function public.propose_match_schedule(uuid, timestamptz, text, text) to authenticated;
grant execute on function public.respond_to_match_schedule(uuid, integer, boolean) to authenticated;
grant execute on function public.cancel_match(uuid, text) to authenticated;
grant execute on function public.club_matches(uuid) to authenticated;

notify pgrst, 'reload schema';
