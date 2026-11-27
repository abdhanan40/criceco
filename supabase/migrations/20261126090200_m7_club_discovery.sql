-- CricEco · migration 32 · M7 club discovery: public club profiles and the
-- club directory, availability slots (Find Opponent), player rankings and
-- join-request applicant statistics
--
-- NOT APPLIED. Requires migrations 1–31. Review first; apply only with
-- separate approval, after a fresh backup, inside
--   begin; set local lock_timeout = '5s'; <this file> commit;
-- Rollback: supabase/rollback/20261126_rollback_m7_club_discovery.sql.
-- Read-only check: supabase/tests/32_m7_club_discovery_postcheck.sql.
-- Local test: supabase/tests/local/27_m7_club_discovery_local_check.sql.
-- Design and the exact app contract: docs/M7_CLUB_DISCOVERY.md.
--
-- What changes (one transaction). Purely additive: no existing table,
-- column, function, policy, grant or row is changed.
--   1. club_public_profile(p_club_id) and club_directory(...): another club's
--      PUBLIC fields (name, short name, city, type, established year, home
--      ground id, logo path), its active member count and its official
--      record from confirmed results (played / won / lost / tied / no result
--      / abandoned, the last 5 results, the formats played). Any signed-in
--      user. Never the owner's id or name, phone, e-mail, address or join code.
--      The directory never lists a club the caller owns.
--   2. public.club_match_slots: a club's posted open date (Create
--      Availability Slot). RLS on with NO policy and no grant: read and
--      written only through post_match_slot / withdraw_match_slot /
--      my_club_slots / open_match_slots (club owners). A slot is a time
--      range on one Asia/Karachi day, from tomorrow up to 365 days ahead;
--      at most 10 open slots per club; a club's open slots never overlap.
--      A slot stops being open when it starts (expired, decided by time on
--      every read; marked lazily on the next post).
--   3. player_rankings(...): the leaderboard's inputs from official career
--      statistics (member_stats, migration 22) — only players who allow it
--      (profiles.show_stats AND profiles.public_profile, migration 31), who
--      have a player profile and are active members of some club (the
--      caller's own row is always included). No rating on the server
--      (M2 decision 10): rating is always NULL; the app ranks.
--   4. club_applicant_stats(p_request_id): a pending applicant's career
--      statistics for the owner of the club applied to; NULL figures when
--      the applicant set show_stats = false.

do $$
begin
  if to_regclass('public.club_match_slots') is not null
     or exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public'
                   and p.proname in ('club_public_stats', 'club_public_profile', 'club_directory',
                                     'post_match_slot', 'withdraw_match_slot', 'my_club_slots', 'open_match_slots',
                                     'player_recent_form', 'player_rankings', 'club_applicant_stats')) then
    raise exception 'migration 32: already applied (or a name is taken) — nothing changed';
  end if;
  if to_regclass('public.push_token_moves') is null                                   -- 30
     or to_regprocedure('public.set_my_avatar(text)') is null                          -- 31
     or (select count(*) from information_schema.columns
          where table_schema = 'public'
            and ((table_name = 'profiles' and column_name in ('show_stats', 'public_profile', 'avatar_path'))
                 or (table_name = 'clubs' and column_name = 'logo_path'))) <> 4
     or to_regclass('public.matches') is null or to_regclass('public.match_results') is null
     or to_regclass('public.match_batting') is null or to_regclass('public.match_bowling') is null
     or to_regclass('public.join_requests') is null or to_regclass('public.player_profiles') is null
     or to_regprocedure('public.member_stats(uuid[])') is null
     or to_regprocedure('public.is_club_owner(uuid)') is null
     or to_regprocedure('public.set_last_updated_at()') is null then
    raise exception 'migration 32: migrations 1–31 are required';
  end if;
  -- The functions used must be exactly those of migrations 11 and 22 (the
  -- figures and the owner check are theirs). Line endings ignored.
  if (select md5(replace(p.prosrc, chr(13), '')) || p.prosecdef::text from pg_proc p
       where p.oid = 'public.member_stats(uuid[])'::regprocedure) <> '8ca6dc8d797d94b255fbe871400bb212true'
     or (select md5(replace(p.prosrc, chr(13), '')) || p.prosecdef::text from pg_proc p
          where p.oid = 'public.is_club_owner(uuid)'::regprocedure) <> 'f9100b85bcfaa52aac0aa03f292b14fbtrue' then
    raise exception 'migration 32: a function it uses differs from its migration (11 / 22) — nothing changed';
  end if;
end $$;

-- Errors (message prefix · SQLSTATE):
--   club:      not authenticated (42501) · not found (P0002) · invalid (22023)
--   slot:      not authenticated / not allowed (42501) · club not found /
--              not found (P0002) · invalid / invalid date / invalid time /
--              invalid city / invalid ground / invalid venue / invalid notes
--              (22023) · overlaps (23P01) · too many open / not open (P0001)
--   ranking:   not authenticated (42501) · invalid (22023)
--   club_join: not authenticated / not allowed (42501) · not found (P0002) ·
--              not pending (P0001)   (as decide_join_request, migration 11)

-- ---------------------------------------------------------------------------
-- 1. Public club profile and directory
-- ---------------------------------------------------------------------------
-- A club's public figures: active members and the official record from its
-- CONFIRMED results (as club_results / club_record of migration 20, which
-- stay members-only). recent_form: the last 5 results, newest first
-- ('won' | 'lost' | 'tied' | 'no_result' | 'abandoned'); played_formats:
-- the formats of those results, most played first. Internal: no access check.
create function public.club_public_stats(p_club_id uuid)
returns table (
  member_count   integer,
  played         integer,
  won            integer,
  lost           integer,
  tied           integer,
  no_result      integer,
  abandoned      integer,
  recent_form    text[],
  played_formats text[]
)
language sql
stable
security definer
set search_path = ''
as $$
  with res as (
    select m.id as match_id, m.starts_at, m.format,
           case r.outcome
             when 'tie' then 'tied'
             when 'no_result' then 'no_result'
             when 'abandoned' then 'abandoned'
             else case when (r.outcome = 'club_a_won') = (m.club_a_id = p_club_id) then 'won' else 'lost' end
           end as result
      from public.matches m
      join public.match_results r on r.match_id = m.id and r.status = 'confirmed'
     where m.club_a_id = p_club_id or m.club_b_id = p_club_id
  )
  select (select count(*) from public.club_members cm where cm.club_id = p_club_id and cm.status = 'active')::int,
         (select count(*) from res)::int,
         (select count(*) from res where res.result = 'won')::int,
         (select count(*) from res where res.result = 'lost')::int,
         (select count(*) from res where res.result = 'tied')::int,
         (select count(*) from res where res.result = 'no_result')::int,
         (select count(*) from res where res.result = 'abandoned')::int,
         coalesce((select array_agg(l.result order by l.starts_at desc, l.match_id)
                     from (select res.result, res.starts_at, res.match_id from res
                            order by res.starts_at desc, res.match_id limit 5) l), '{}'::text[]),
         coalesce((select array_agg(f.format order by f.n desc, f.format)
                     from (select res.format, count(*) as n from res group by res.format) f), '{}'::text[]);
$$;

-- One club's public profile, for any signed-in user (own club included:
-- is_own tells). Unknown club: 'club: not found'.
create function public.club_public_profile(p_club_id uuid)
returns table (
  club_id          uuid,
  name             text,
  short_name       text,
  city             text,
  club_type        text,
  established_year integer,
  home_ground_id   text,
  logo_path        text,
  member_count     integer,
  played           integer,
  won              integer,
  lost             integer,
  tied             integer,
  no_result        integer,
  abandoned        integer,
  recent_form      text[],
  played_formats   text[],
  is_own           boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'club: not authenticated' using errcode = '42501';
  end if;
  return query
    select c.id, c.name, c.short_name, c.city, c.club_type, c.established_year::int, c.home_ground_id, c.logo_path,
           s.member_count, s.played, s.won, s.lost, s.tied, s.no_result, s.abandoned, s.recent_form, s.played_formats,
           c.owner_id = v_uid
      from public.clubs c
     cross join lateral public.club_public_stats(c.id) s
     where c.id = p_club_id;
  if not found then
    raise exception 'club: not found' using errcode = 'P0002';
  end if;
end;
$$;

-- The club directory (Challenges / Find Opponent / Club Profile): other
-- clubs' public profiles, for any signed-in user; never a club the caller
-- owns. p_search: name or short name, case-insensitive substring (≤ 100);
-- p_city: the city exactly, case and outer spaces ignored (≤ 60). By name,
-- p_limit 1–100 (default 50) rows from p_offset (0–10000).
create function public.club_directory(
  p_search text default null,
  p_city   text default null,
  p_limit  integer default 50,
  p_offset integer default 0
)
returns table (
  club_id          uuid,
  name             text,
  short_name       text,
  city             text,
  club_type        text,
  established_year integer,
  home_ground_id   text,
  logo_path        text,
  member_count     integer,
  played           integer,
  won              integer,
  lost             integer,
  tied             integer,
  no_result        integer,
  abandoned        integer,
  recent_form      text[],
  played_formats   text[]
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid    uuid := auth.uid();
  v_search text := lower(nullif(regexp_replace(btrim(coalesce(p_search, '')), '\s+', ' ', 'g'), ''));
  v_city   text := lower(nullif(btrim(coalesce(p_city, '')), ''));
begin
  if v_uid is null then
    raise exception 'club: not authenticated' using errcode = '42501';
  end if;
  if char_length(coalesce(v_search, '')) > 100 or char_length(coalesce(v_city, '')) > 60 then
    raise exception 'club: invalid' using errcode = '22023';
  end if;
  return query
    select c.id, c.name, c.short_name, c.city, c.club_type, c.established_year::int, c.home_ground_id, c.logo_path,
           s.member_count, s.played, s.won, s.lost, s.tied, s.no_result, s.abandoned, s.recent_form, s.played_formats
      from (select c0.* from public.clubs c0
             where c0.owner_id <> v_uid
               and (v_search is null
                    or strpos(lower(c0.name), v_search) > 0
                    or strpos(lower(coalesce(c0.short_name, '')), v_search) > 0)
               and (v_city is null or lower(btrim(c0.city)) = v_city)
             order by lower(c0.name), c0.id
             limit greatest(1, least(coalesce(p_limit, 50), 100))
             offset greatest(0, least(coalesce(p_offset, 0), 10000))) c
     cross join lateral public.club_public_stats(c.id) s
     order by lower(c.name), c.id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Availability slots
-- ---------------------------------------------------------------------------
create table public.club_match_slots (
  id              uuid primary key default gen_random_uuid(),
  club_id         uuid not null
                  constraint club_match_slots_club_id_fkey references public.clubs (id) on delete cascade,
  format          text not null
                  constraint club_match_slots_format_check check (format in ('test', 't20', 'odi', 't10', 'custom')),
  custom_overs    smallint
                  constraint club_match_slots_custom_overs_check check (custom_overs is null or custom_overs between 1 and 50),
  city            text not null
                  constraint club_match_slots_city_check check (char_length(btrim(city)) between 1 and 60),
  -- The app's preferred ground (its ground directory id), NULL = any ground.
  ground_id       text
                  constraint club_match_slots_ground_id_check check (ground_id is null or char_length(ground_id) between 1 and 64),
  venue_name      text
                  constraint club_match_slots_venue_name_check
                  check (venue_name is null or char_length(btrim(venue_name)) between 1 and 100),
  -- The time range (one Asia/Karachi day; checked by post_match_slot).
  starts_at       timestamptz not null,
  ends_at         timestamptz not null,
  notes           text
                  constraint club_match_slots_notes_check check (notes is null or char_length(btrim(notes)) between 1 and 200),
  -- 'taken' is reserved: nothing sets it yet.
  status          text not null default 'open'
                  constraint club_match_slots_status_check check (status in ('open', 'withdrawn', 'expired', 'taken')),
  closed_at       timestamptz,
  created_by      uuid
                  constraint club_match_slots_created_by_fkey references public.profiles (id) on delete set null,
  created_at      timestamptz not null default now(),
  last_updated_at timestamptz not null default now(),
  constraint club_match_slots_overs_follow_format check ((format = 'custom') = (custom_overs is not null)),
  constraint club_match_slots_time_range check (ends_at > starts_at and ends_at <= starts_at + interval '24 hours'),
  constraint club_match_slots_closed_consistency check ((status = 'open') = (closed_at is null))
);

comment on table public.club_match_slots is
  'Availability slots (M7, migration 32): a club''s posted open date. Read and written only through post_match_slot, withdraw_match_slot, my_club_slots and open_match_slots.';
comment on column public.club_match_slots.status is
  'open | withdrawn | expired | taken (reserved). An open slot whose starts_at has passed is expired (decided by time on every read).';

create index club_match_slots_open_club_idx on public.club_match_slots (club_id, starts_at) where status = 'open';
create index club_match_slots_open_starts_idx on public.club_match_slots (starts_at) where status = 'open';
create index club_match_slots_club_idx on public.club_match_slots (club_id, starts_at);
create index club_match_slots_created_by_idx on public.club_match_slots (created_by) where created_by is not null;

create trigger club_match_slots_set_last_updated_at
  before update on public.club_match_slots
  for each row execute function public.set_last_updated_at();

-- Closed: no policy, no grant (the functions below are SECURITY DEFINER).
alter table public.club_match_slots enable row level security;
revoke all on table public.club_match_slots from public, anon, authenticated, service_role;

-- Post an open slot for a club the caller owns. p_slot_date from tomorrow
-- (Asia/Karachi) to 365 days ahead; p_start_time < p_end_time on that day
-- (whole minutes, ending by 23:59). Returns the new slot (as my_club_slots).
create function public.post_match_slot(
  p_club_id      uuid,
  p_format       text,
  p_custom_overs integer,
  p_city         text,
  p_slot_date    date,
  p_start_time   time,
  p_end_time     time,
  p_ground_id    text default null,
  p_venue_name   text default null,
  p_notes        text default null
)
returns table (
  slot_id      uuid,
  club_id      uuid,
  format       text,
  custom_overs smallint,
  city         text,
  ground_id    text,
  venue_name   text,
  slot_date    date,
  start_time   time,
  end_time     time,
  starts_at    timestamptz,
  ends_at      timestamptz,
  notes        text,
  status       text,
  created_at   timestamptz,
  closed_at    timestamptz
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid    uuid := auth.uid();
  v_today  date := (now() at time zone 'Asia/Karachi')::date;
  v_format text := lower(btrim(coalesce(p_format, '')));
  v_city   text := regexp_replace(btrim(coalesce(p_city, '')), '\s+', ' ', 'g');
  v_ground text := nullif(btrim(coalesce(p_ground_id, '')), '');
  v_venue  text := nullif(regexp_replace(btrim(coalesce(p_venue_name, '')), '\s+', ' ', 'g'), '');
  v_notes  text := nullif(btrim(coalesce(p_notes, '')), '');
  v_start  timestamptz;
  v_end    timestamptz;
  v_open   integer;
  v_id     uuid;
begin
  if v_uid is null then
    raise exception 'slot: not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.clubs c where c.id = p_club_id) then
    raise exception 'slot: club not found' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.clubs c where c.id = p_club_id and c.owner_id = v_uid) then
    raise exception 'slot: not allowed' using errcode = '42501';
  end if;
  if v_format not in ('test', 't20', 'odi', 't10', 'custom')
     or (v_format = 'custom' and (p_custom_overs is null or p_custom_overs not between 1 and 50)) then
    raise exception 'slot: invalid' using errcode = '22023';
  end if;
  if char_length(v_city) not between 1 and 60 then
    raise exception 'slot: invalid city' using errcode = '22023';
  end if;
  if p_slot_date is null or p_slot_date < v_today + 1 or p_slot_date > v_today + 365 then
    raise exception 'slot: invalid date' using errcode = '22023';
  end if;
  if p_start_time is null or p_end_time is null or p_end_time <= p_start_time or p_end_time > time '23:59'
     or date_trunc('minute', p_start_time::interval) <> p_start_time::interval
     or date_trunc('minute', p_end_time::interval) <> p_end_time::interval then
    raise exception 'slot: invalid time' using errcode = '22023';
  end if;
  if v_ground is not null and char_length(v_ground) > 64 then
    raise exception 'slot: invalid ground' using errcode = '22023';
  end if;
  if v_venue is not null and char_length(v_venue) > 100 then
    raise exception 'slot: invalid venue' using errcode = '22023';
  end if;
  if v_notes is not null and char_length(v_notes) > 200 then
    raise exception 'slot: invalid notes' using errcode = '22023';
  end if;
  v_start := (p_slot_date + p_start_time) at time zone 'Asia/Karachi';
  v_end := (p_slot_date + p_end_time) at time zone 'Asia/Karachi';

  -- One post per club at a time: the cap and the overlap are decided in turn.
  perform pg_advisory_xact_lock(hashtextextended('criceco.slot.club:' || p_club_id::text, 0));

  -- Open slots that have started are expired (marked lazily).
  update public.club_match_slots s
     set status = 'expired', closed_at = now()
   where s.club_id = p_club_id and s.status = 'open' and s.starts_at <= now();

  if exists (select 1 from public.club_match_slots s
              where s.club_id = p_club_id and s.status = 'open'
                and tstzrange(s.starts_at, s.ends_at) && tstzrange(v_start, v_end)) then
    raise exception 'slot: overlaps' using errcode = '23P01';
  end if;
  select count(*) into v_open from public.club_match_slots s where s.club_id = p_club_id and s.status = 'open';
  if v_open >= 10 then
    raise exception 'slot: too many open' using errcode = 'P0001';
  end if;

  begin
    insert into public.club_match_slots (club_id, format, custom_overs, city, ground_id, venue_name,
                                         starts_at, ends_at, notes, created_by)
    values (p_club_id, v_format, case when v_format = 'custom' then p_custom_overs end, v_city, v_ground, v_venue,
            v_start, v_end, v_notes, v_uid)
    returning id into v_id;
  exception
    when check_violation or not_null_violation or numeric_value_out_of_range then
      raise exception 'slot: invalid' using errcode = '22023';
  end;

  return query
    select s.id, s.club_id, s.format, s.custom_overs, s.city, s.ground_id, s.venue_name,
           (s.starts_at at time zone 'Asia/Karachi')::date, (s.starts_at at time zone 'Asia/Karachi')::time,
           (s.ends_at at time zone 'Asia/Karachi')::time, s.starts_at, s.ends_at, s.notes, s.status,
           s.created_at, s.closed_at
      from public.club_match_slots s
     where s.id = v_id;
end;
$$;

-- Withdraw an open slot of a club the caller owns. An already withdrawn
-- slot is returned unchanged; an expired (started) or taken one cannot be
-- withdrawn ('slot: not open').
create function public.withdraw_match_slot(p_slot_id uuid)
returns table (
  slot_id      uuid,
  club_id      uuid,
  format       text,
  custom_overs smallint,
  city         text,
  ground_id    text,
  venue_name   text,
  slot_date    date,
  start_time   time,
  end_time     time,
  starts_at    timestamptz,
  ends_at      timestamptz,
  notes        text,
  status       text,
  created_at   timestamptz,
  closed_at    timestamptz
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid uuid := auth.uid();
  v_row public.club_match_slots;
begin
  if v_uid is null then
    raise exception 'slot: not authenticated' using errcode = '42501';
  end if;
  select * into v_row from public.club_match_slots s where s.id = p_slot_id for update;
  if not found then
    raise exception 'slot: not found' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.clubs c where c.id = v_row.club_id and c.owner_id = v_uid) then
    raise exception 'slot: not allowed' using errcode = '42501';
  end if;
  if v_row.status <> 'withdrawn' then
    if v_row.status <> 'open' or v_row.starts_at <= now() then
      raise exception 'slot: not open' using errcode = 'P0001';
    end if;
    update public.club_match_slots s set status = 'withdrawn', closed_at = now() where s.id = p_slot_id;
  end if;
  return query
    select s.id, s.club_id, s.format, s.custom_overs, s.city, s.ground_id, s.venue_name,
           (s.starts_at at time zone 'Asia/Karachi')::date, (s.starts_at at time zone 'Asia/Karachi')::time,
           (s.ends_at at time zone 'Asia/Karachi')::time, s.starts_at, s.ends_at, s.notes, s.status,
           s.created_at, s.closed_at
      from public.club_match_slots s
     where s.id = p_slot_id;
end;
$$;

-- The slots of a club the caller owns, by start: its open, not yet started
-- slots; with p_include_closed also those withdrawn, or started, in the
-- last 30 days (status 'expired' for an open slot that has started).
create function public.my_club_slots(p_club_id uuid, p_include_closed boolean default false)
returns table (
  slot_id      uuid,
  club_id      uuid,
  format       text,
  custom_overs smallint,
  city         text,
  ground_id    text,
  venue_name   text,
  slot_date    date,
  start_time   time,
  end_time     time,
  starts_at    timestamptz,
  ends_at      timestamptz,
  notes        text,
  status       text,
  created_at   timestamptz,
  closed_at    timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
begin
  if auth.uid() is null then
    raise exception 'slot: not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.clubs c where c.id = p_club_id and c.owner_id = auth.uid()) then
    raise exception 'slot: not allowed' using errcode = '42501';
  end if;
  return query
    select s.id, s.club_id, s.format, s.custom_overs, s.city, s.ground_id, s.venue_name,
           (s.starts_at at time zone 'Asia/Karachi')::date, (s.starts_at at time zone 'Asia/Karachi')::time,
           (s.ends_at at time zone 'Asia/Karachi')::time, s.starts_at, s.ends_at, s.notes,
           case when s.status = 'open' and s.starts_at <= now() then 'expired' else s.status end,
           s.created_at, s.closed_at
      from public.club_match_slots s
     where s.club_id = p_club_id
       and ((s.status = 'open' and s.starts_at > now())
            or (coalesce(p_include_closed, false)
                and case when s.status = 'withdrawn' then s.closed_at else s.starts_at end > now() - interval '30 days'))
     order by s.starts_at, s.id;
end;
$$;

-- Find Opponent ("Teams Looking for Opponents"): OTHER clubs' open, not yet
-- started slots, soonest first, with the club's public name and record.
-- Signed-in club owners only (as match_club_directory); never the caller's
-- own clubs. Filters: p_city exactly (case and outer spaces ignored, ≤ 60),
-- p_format, p_from_date / p_to_date (inclusive, Asia/Karachi). p_limit 1–100
-- (default 50) rows from p_offset (0–10000).
create function public.open_match_slots(
  p_city      text default null,
  p_format    text default null,
  p_from_date date default null,
  p_to_date   date default null,
  p_limit     integer default 50,
  p_offset    integer default 0
)
returns table (
  slot_id         uuid,
  club_id         uuid,
  club_name       text,
  club_short_name text,
  club_city       text,
  club_type       text,
  club_logo_path  text,
  club_played     integer,
  club_won        integer,
  club_lost       integer,
  format          text,
  custom_overs    smallint,
  city            text,
  ground_id       text,
  venue_name      text,
  slot_date       date,
  start_time      time,
  end_time        time,
  starts_at       timestamptz,
  ends_at         timestamptz,
  notes           text,
  created_at      timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid    uuid := auth.uid();
  v_city   text := lower(nullif(btrim(coalesce(p_city, '')), ''));
  v_format text := lower(nullif(btrim(coalesce(p_format, '')), ''));
begin
  if v_uid is null then
    raise exception 'slot: not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.clubs c where c.owner_id = v_uid) then
    raise exception 'slot: not allowed' using errcode = '42501';
  end if;
  if char_length(coalesce(v_city, '')) > 60
     or (v_format is not null and v_format not in ('test', 't20', 'odi', 't10', 'custom'))
     or (p_from_date is not null and p_to_date is not null and p_to_date < p_from_date) then
    raise exception 'slot: invalid' using errcode = '22023';
  end if;
  return query
    select s.id, c.id, c.name, c.short_name, c.city, c.club_type, c.logo_path, st.played, st.won, st.lost,
           s.format, s.custom_overs, s.city, s.ground_id, s.venue_name,
           (s.starts_at at time zone 'Asia/Karachi')::date, (s.starts_at at time zone 'Asia/Karachi')::time,
           (s.ends_at at time zone 'Asia/Karachi')::time, s.starts_at, s.ends_at, s.notes, s.created_at
      from (select s0.* from public.club_match_slots s0
              join public.clubs c0 on c0.id = s0.club_id
             where s0.status = 'open' and s0.starts_at > now()
               and c0.owner_id <> v_uid
               and (v_city is null or lower(btrim(s0.city)) = v_city)
               and (v_format is null or s0.format = v_format)
               and (p_from_date is null or (s0.starts_at at time zone 'Asia/Karachi')::date >= p_from_date)
               and (p_to_date is null or (s0.starts_at at time zone 'Asia/Karachi')::date <= p_to_date)
             order by s0.starts_at, s0.id
             limit greatest(1, least(coalesce(p_limit, 50), 100))
             offset greatest(0, least(coalesce(p_offset, 0), 10000))) s
      join public.clubs c on c.id = s.club_id
     cross join lateral public.club_public_stats(c.id) st
     order by s.starts_at, s.id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Player rankings
-- ---------------------------------------------------------------------------
-- The last (up to) 5 confirmed matches the given memberships appeared in
-- (batting, bowling, fielding or Player of the Match, as member_stats), and
-- how many of them the player's club won. Internal: no access check.
create function public.player_recent_form(p_member_ids uuid[])
returns table (recent_played integer, recent_wins integer)
language sql
stable
security definer
set search_path = ''
as $$
  with apps as (
    select b.match_id, b.version, b.member_id from public.match_batting b where b.member_id = any (p_member_ids)
    union
    select b.match_id, b.version, b.fielder_member_id from public.match_batting b where b.fielder_member_id = any (p_member_ids)
    union
    select w.match_id, w.version, w.member_id from public.match_bowling w where w.member_id = any (p_member_ids)
    union
    select r.match_id, r.version, r.player_of_match_member_id from public.match_results r
     where r.player_of_match_member_id = any (p_member_ids)
  ), conf as (
    select distinct on (a.match_id) a.match_id, mt.starts_at,
           r.outcome in ('club_a_won', 'club_b_won') and (r.outcome = 'club_a_won') = (mt.club_a_id = cm.club_id) as won
      from apps a
      join public.match_results r on r.match_id = a.match_id and r.version = a.version and r.status = 'confirmed'
      join public.matches mt on mt.id = a.match_id
      join public.club_members cm on cm.id = a.member_id
     order by a.match_id, cm.id
  ), last5 as (
    select conf.won from conf order by conf.starts_at desc, conf.match_id limit 5
  )
  select count(*)::int, count(*) filter (where last5.won)::int from last5;
$$;

-- The leaderboard's inputs: one row per ranked player, career figures over
-- every membership (as player_stats). Listed: players with a player profile
-- and a name who are active members of some club (of p_club_id when given)
-- and allow it (show_stats AND public_profile); the caller is always listed
-- when they qualify otherwise (is_own row). club_*: p_club_id, else the
-- player's earliest active membership. p_role: batsman | bowler |
-- all_rounder; p_search: name, case-insensitive substring (≤ 100). Order:
-- matches, runs, wickets (all descending), then name; p_limit 1–200
-- (default 100). rating is always NULL (no rating on the server).
create function public.player_rankings(
  p_role    text default null,
  p_club_id uuid default null,
  p_search  text default null,
  p_limit   integer default 100
)
returns table (
  user_id          uuid,
  full_name        text,
  avatar_path      text,
  club_id          uuid,
  club_name        text,
  club_short_name  text,
  player_role      text,
  is_wicketkeeper  boolean,
  matches          integer,
  bat_innings      integer,
  not_outs         integer,
  runs             integer,
  balls_faced      integer,
  batting_average  numeric,
  strike_rate      numeric,
  highest          integer,
  highest_not_out  boolean,
  fifties          integer,
  hundreds         integer,
  wickets          integer,
  balls_bowled     integer,
  runs_conceded    integer,
  bowling_average  numeric,
  economy          numeric,
  best_wickets     integer,
  best_runs        integer,
  catches          integer,
  stumpings        integer,
  player_of_match  integer,
  recent_played    integer,
  recent_wins      integer,
  rating           numeric,
  is_me            boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid    uuid := auth.uid();
  v_role   text := lower(nullif(btrim(coalesce(p_role, '')), ''));
  v_search text := lower(nullif(regexp_replace(btrim(coalesce(p_search, '')), '\s+', ' ', 'g'), ''));
begin
  if v_uid is null then
    raise exception 'ranking: not authenticated' using errcode = '42501';
  end if;
  if (v_role is not null and v_role not in ('batsman', 'bowler', 'all_rounder'))
     or char_length(coalesce(v_search, '')) > 100 then
    raise exception 'ranking: invalid' using errcode = '22023';
  end if;
  return query
    with cand as (
      select p.id as uid, btrim(p.full_name) as pname, p.avatar_path as avatar, pp.player_role as prole,
             coalesce(pp.is_wicketkeeper, false) as wk, home.cid, home.cname, home.cshort,
             array(select m2.id from public.club_members m2 where m2.user_id = p.id) as member_ids
        from public.profiles p
        join public.player_profiles pp on pp.user_id = p.id
       cross join lateral (
         select c.id as cid, c.name as cname, c.short_name as cshort
           from public.club_members m
           join public.clubs c on c.id = m.club_id
          where m.user_id = p.id and m.status = 'active' and (p_club_id is null or m.club_id = p_club_id)
          order by m.joined_at, m.club_id
          limit 1) home
       where (p.id = v_uid or (p.show_stats and p.public_profile))
         and char_length(btrim(coalesce(p.full_name, ''))) > 0
         and (v_role is null or pp.player_role = v_role)
         and (v_search is null or strpos(lower(p.full_name), v_search) > 0)
    )
    select cand.uid, cand.pname, cand.avatar, cand.cid, cand.cname, cand.cshort, cand.prole, cand.wk,
           s.matches, s.bat_innings, s.not_outs, s.runs, s.balls_faced, s.batting_average, s.strike_rate,
           s.highest, s.highest_not_out, s.fifties, s.hundreds, s.wickets, s.balls_bowled, s.runs_conceded,
           s.bowling_average, s.economy, s.best_wickets, s.best_runs, s.catches, s.stumpings, s.player_of_match,
           f.recent_played, f.recent_wins, null::numeric, cand.uid = v_uid
      from cand
     cross join lateral public.member_stats(cand.member_ids) s
     cross join lateral public.player_recent_form(cand.member_ids) f
     order by s.matches desc, s.runs desc, s.wickets desc, lower(cand.pname), cand.uid
     limit greatest(1, least(coalesce(p_limit, 100), 200));
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Join-request applicant statistics
-- ---------------------------------------------------------------------------
-- A PENDING request to a club the caller owns: the applicant's career
-- figures (every membership, as player_stats). One row; when the applicant
-- set show_stats = false, stats_visible is false and every figure is NULL.
create function public.club_applicant_stats(p_request_id uuid)
returns table (
  request_id       uuid,
  stats_visible    boolean,
  matches          integer,
  bat_innings      integer,
  not_outs         integer,
  runs             integer,
  balls_faced      integer,
  batting_average  numeric,
  strike_rate      numeric,
  highest          integer,
  highest_not_out  boolean,
  fifties          integer,
  hundreds         integer,
  wickets          integer,
  balls_bowled     integer,
  runs_conceded    integer,
  bowling_average  numeric,
  economy          numeric,
  best_wickets     integer,
  best_runs        integer,
  catches          integer,
  run_outs         integer,
  stumpings        integer,
  player_of_match  integer
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid     uuid := auth.uid();
  v_request public.join_requests;
  v_show    boolean;
begin
  if v_uid is null then
    raise exception 'club_join: not authenticated' using errcode = '42501';
  end if;
  select * into v_request from public.join_requests r where r.id = p_request_id;
  if not found then
    raise exception 'club_join: not found' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.clubs c where c.id = v_request.club_id and c.owner_id = v_uid) then
    raise exception 'club_join: not allowed' using errcode = '42501';
  end if;
  if v_request.status <> 'pending' then
    raise exception 'club_join: not pending' using errcode = 'P0001';
  end if;
  select p.show_stats into v_show from public.profiles p where p.id = v_request.user_id;
  if v_show is not true then
    return query
      select v_request.id, false, null::int, null::int, null::int, null::int, null::int, null::numeric, null::numeric,
             null::int, null::boolean, null::int, null::int, null::int, null::int, null::int, null::numeric,
             null::numeric, null::int, null::int, null::int, null::int, null::int, null::int;
    return;
  end if;
  return query
    select v_request.id, true, s.matches, s.bat_innings, s.not_outs, s.runs, s.balls_faced, s.batting_average,
           s.strike_rate, s.highest, s.highest_not_out, s.fifties, s.hundreds, s.wickets, s.balls_bowled,
           s.runs_conceded, s.bowling_average, s.economy, s.best_wickets, s.best_runs, s.catches, s.run_outs,
           s.stumpings, s.player_of_match
      from public.member_stats(array(select m.id from public.club_members m where m.user_id = v_request.user_id)) s;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Privileges: the API functions to signed-in users only; the internal
--    helpers to nobody
-- ---------------------------------------------------------------------------
revoke execute on function public.club_public_stats(uuid) from public, anon, authenticated;
revoke execute on function public.player_recent_form(uuid[]) from public, anon, authenticated;

revoke execute on function public.club_public_profile(uuid) from public, anon;
revoke execute on function public.club_directory(text, text, integer, integer) from public, anon;
revoke execute on function public.post_match_slot(uuid, text, integer, text, date, time, time, text, text, text) from public, anon;
revoke execute on function public.withdraw_match_slot(uuid) from public, anon;
revoke execute on function public.my_club_slots(uuid, boolean) from public, anon;
revoke execute on function public.open_match_slots(text, text, date, date, integer, integer) from public, anon;
revoke execute on function public.player_rankings(text, uuid, text, integer) from public, anon;
revoke execute on function public.club_applicant_stats(uuid) from public, anon;

grant execute on function public.club_public_profile(uuid) to authenticated;
grant execute on function public.club_directory(text, text, integer, integer) to authenticated;
grant execute on function public.post_match_slot(uuid, text, integer, text, date, time, time, text, text, text) to authenticated;
grant execute on function public.withdraw_match_slot(uuid) to authenticated;
grant execute on function public.my_club_slots(uuid, boolean) to authenticated;
grant execute on function public.open_match_slots(text, text, date, date, integer, integer) to authenticated;
grant execute on function public.player_rankings(text, uuid, text, integer) to authenticated;
grant execute on function public.club_applicant_stats(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Self-check (raises — rolling everything back — on any mismatch)
-- ---------------------------------------------------------------------------
do $$
declare
  v_fn regprocedure;
  v_role text;
begin
  if not (select c.relrowsecurity from pg_class c where c.oid = 'public.club_match_slots'::regclass)
     or exists (select 1 from pg_policy pol where pol.polrelid = 'public.club_match_slots'::regclass) then
    raise exception 'migration 32 self-check: club_match_slots must have RLS on and no policy';
  end if;
  foreach v_role in array array['anon', 'authenticated', 'service_role'] loop
    if exists (select 1 from pg_roles where rolname = v_role)
       and has_table_privilege(v_role, 'public.club_match_slots', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') then
      raise exception 'migration 32 self-check: % has a privilege on club_match_slots', v_role;
    end if;
  end loop;
  if (select count(*) from pg_constraint k
       where k.conrelid = 'public.club_match_slots'::regclass and k.convalidated
         and k.conname in ('club_match_slots_format_check', 'club_match_slots_custom_overs_check',
                           'club_match_slots_city_check', 'club_match_slots_ground_id_check',
                           'club_match_slots_venue_name_check', 'club_match_slots_notes_check',
                           'club_match_slots_status_check', 'club_match_slots_overs_follow_format',
                           'club_match_slots_time_range', 'club_match_slots_closed_consistency',
                           'club_match_slots_club_id_fkey', 'club_match_slots_created_by_fkey')) <> 12 then
    raise exception 'migration 32 self-check: club_match_slots constraints';
  end if;
  foreach v_fn in array array['public.club_public_profile(uuid)', 'public.club_directory(text, text, integer, integer)',
                              'public.post_match_slot(uuid, text, integer, text, date, time, time, text, text, text)',
                              'public.withdraw_match_slot(uuid)', 'public.my_club_slots(uuid, boolean)',
                              'public.open_match_slots(text, text, date, date, integer, integer)',
                              'public.player_rankings(text, uuid, text, integer)',
                              'public.club_applicant_stats(uuid)']::regprocedure[] loop
    if not has_function_privilege('authenticated', v_fn, 'execute') or has_function_privilege('anon', v_fn, 'execute')
       or (select not p.prosecdef or array_to_string(p.proconfig, ',') <> 'search_path=""' from pg_proc p where p.oid = v_fn) then
      raise exception 'migration 32 self-check: % privileges / properties', v_fn;
    end if;
  end loop;
  foreach v_fn in array array['public.club_public_stats(uuid)', 'public.player_recent_form(uuid[])']::regprocedure[] loop
    if has_function_privilege('authenticated', v_fn, 'execute') or has_function_privilege('anon', v_fn, 'execute')
       or (select not p.prosecdef or array_to_string(p.proconfig, ',') <> 'search_path=""' from pg_proc p where p.oid = v_fn) then
      raise exception 'migration 32 self-check: % must be internal', v_fn;
    end if;
  end loop;
  -- The public club shapes carry no owner, phone, e-mail, address or code.
  if exists (select 1 from unnest(array['public.club_public_profile(uuid)', 'public.club_directory(text, text, integer, integer)',
                                        'public.open_match_slots(text, text, date, date, integer, integer)',
                                        'public.player_rankings(text, uuid, text, integer)']::regprocedure[]) f
              where pg_get_function_result(f) ~ '(owner|phone|email|address|code|date_of_birth)') then
    raise exception 'migration 32 self-check: a public result carries a private column';
  end if;
  if pg_get_function_result('public.my_club_slots(uuid, boolean)'::regprocedure)
       <> pg_get_function_result('public.post_match_slot(uuid, text, integer, text, date, time, time, text, text, text)'::regprocedure)
     or pg_get_function_result('public.my_club_slots(uuid, boolean)'::regprocedure)
       <> pg_get_function_result('public.withdraw_match_slot(uuid)'::regprocedure)
     or pg_get_function_result('public.club_public_profile(uuid)'::regprocedure)
       <> replace(pg_get_function_result('public.club_directory(text, text, integer, integer)'::regprocedure),
                  'played_formats text[])', 'played_formats text[], is_own boolean)') then
    raise exception 'migration 32 self-check: a result type is not the intended one';
  end if;
end $$;

notify pgrst, 'reload schema';
