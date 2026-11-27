-- CricEco · migration 35 · M10 Tournaments
--
-- NOT APPLIED. Requires migrations 1–31 and 33 (independent of 32 and 34;
-- tested on top of 1–34). Review first; apply only with separate approval,
-- after a fresh backup, inside
--   begin; set local lock_timeout = '5s'; <this file> commit;
-- Rollback: supabase/rollback/20261126_rollback_m10_tournaments.sql.
-- Read-only check: supabase/tests/35_m10_tournaments_postcheck.sql.
-- Local test: supabase/tests/local/30_m10_tournaments_local_check.sql.
-- Design and app contract: docs/M10_TOURNAMENTS.md.
--
-- What changes (one transaction):
--   1. Four tables, RLS on with NO policy and NO grant to any API role
--      (written and read only through the functions below):
--        tournaments                      — a club's tournament (Create Tournament);
--        tournament_registrations         — a club's entry (one active per club
--                                           and tournament);
--        tournament_registration_players  — the entry's squad (11 + 4, captain,
--                                           vice-captain, wicket-keeper);
--        tournament_fixtures              — the draw (knockout bracket with BYEs,
--                                           or a single league round).
--      Deleting a club deletes its tournaments and entries; deleting an
--      account deletes that person's squad places (club_members cascade).
--   2. Functions for signed-in users only (SECURITY DEFINER, empty
--      search_path, auth.uid(); club owner = clubs.owner_id = auth.uid()):
--        create_tournament, my_hosted_tournaments, browse_tournaments,
--        tournament_detail, tournament_hub_stats, tournament_teams,
--        tournament_registration_squad, submit_tournament_registration,
--        decide_tournament_registration, remove_tournament_team,
--        my_tournament_registrations, generate_tournament_fixtures,
--        tournament_fixtures, tournament_points_table, tournament_awards.
--      One function for the future trusted scorer only (EXECUTE: service_role):
--        record_tournament_fixture_result — the ONLY way a fixture gets a
--        winner (results stay read-only in CricEco, as migration 24).
--      Internal helpers no API role may call: tournament_status_now,
--      tournament_list, tournament_registration_rows, tournament_fixture_decide,
--      tournament_advance_byes, tournament_standings and two trigger functions.
--   3. Notifications: five new types through the existing internal
--      notification_add (migration 26, unchanged), all in the "club_owner" inbox:
--        tournament_registration_received → organizer's owner   (join_requests)
--        tournament_registration_approved → entering club owner (challenges)
--        tournament_registration_rejected → entering club owner (challenges)
--        tournament_team_removed          → entering club owner (challenges)
--        tournament_fixtures_published    → every entered club's owner (matches)
--      notifications_type_check keeps all 29 existing types and gains these
--      five; notification_category (migration 33's body) gains the mappings.
--      Push text: push-dispatch/templates.ts.
-- No payments: entry fee and prize are display data only. No existing row is
-- changed or deleted; delete_account_data is unchanged.

do $$
begin
  if to_regclass('public.tournaments') is not null or to_regclass('public.tournament_registrations') is not null
     or to_regclass('public.tournament_registration_players') is not null
     or to_regclass('public.tournament_fixtures') is not null
     or exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public'
                   and p.proname in ('create_tournament', 'my_hosted_tournaments', 'browse_tournaments',
                                     'tournament_detail', 'tournament_hub_stats', 'tournament_teams',
                                     'tournament_registration_squad', 'submit_tournament_registration',
                                     'decide_tournament_registration', 'remove_tournament_team',
                                     'my_tournament_registrations', 'generate_tournament_fixtures',
                                     'tournament_fixtures', 'tournament_points_table', 'tournament_awards',
                                     'record_tournament_fixture_result', 'tournament_status_now', 'tournament_list',
                                     'tournament_registration_rows', 'tournament_fixture_decide',
                                     'tournament_advance_byes', 'tournament_standings',
                                     'tournament_registrations_validate', 'tournament_registration_players_validate'))
     or exists (select 1 from pg_constraint k
                 where k.conrelid = 'public.notifications'::regclass and k.conname = 'notifications_type_check'
                   and pg_get_constraintdef(k.oid) like '%tournament_%') then
    raise exception 'migration 35: already applied (or a name is taken) — nothing changed';
  end if;
  if to_regclass('public.teams') is null or to_regclass('public.club_members') is null
     or to_regclass('public.match_results') is null or to_regclass('public.match_batting') is null
     or to_regprocedure('public.availability_locks_on(text, date, date)') is null
     or to_regprocedure('public.set_my_avatar(text)') is null
     or (select count(*) from information_schema.columns
          where table_schema = 'public' and table_name = 'profiles' and column_name in ('avatar_path', 'show_stats')) <> 2
     or (select count(*) from information_schema.columns
          where table_schema = 'public' and table_name = 'clubs' and column_name = 'logo_path') <> 1
     or to_regclass('public.hunt_invites') is null
     or to_regprocedure('public.notification_add(uuid, text, text, text, jsonb, uuid, uuid, uuid, uuid)') is null then
    raise exception 'migration 35: migrations 1–31 and 33 are required';
  end if;
  -- What this migration replaces or relies on must be exactly migration 33's
  -- (type list, categories) and 26's (notification_add / notification_muted):
  -- the rollback restores the type list and category verbatim. Line endings ignored.
  if (select md5(pg_get_constraintdef(k.oid)) from pg_constraint k
       where k.conrelid = 'public.notifications'::regclass and k.conname = 'notifications_type_check')
       is distinct from 'd6c0cf7d4d7aab931ecd5010be1ea212'
     or (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p
          where p.oid = 'public.notification_category(text)'::regprocedure) <> '99866e275e10125352bb2e5acad0d5c0'
     or (select md5(replace(p.prosrc, chr(13), '')) || p.prosecdef::text from pg_proc p
          where p.oid = 'public.notification_add(uuid, text, text, text, jsonb, uuid, uuid, uuid, uuid)'::regprocedure)
        <> 'a6fc6bc7e42b161bc56a5b1ef9f8aa68true'
     or (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p
          where p.oid = 'public.notification_muted(uuid, text)'::regprocedure) <> 'c436f7ccbcfeecd1cd5bc67771e3334e' then
    raise exception 'migration 35: the notification type list / notification_category / notification_add / notification_muted differs from migrations 33 / 26 — nothing changed';
  end if;
end $$;

-- Codes (exactly the Dart enum names, snake_case):
--   format          test | t20 | odi | t10 | custom          (MatchFormat)
--   tournament_type knockout | league                         (TournamentType)
--   status          registration_open | registration_full |
--                   registration_closed | completed           (TournamentStatus)
--   registration    pending | approved | rejected | removed   (RegistrationStatus + removed)
-- "Today" is Asia/Karachi. Errors: prefix "tournament:"; 42501 not
-- authenticated / not allowed, 22023 invalid input, 23514 squad rules,
-- P0002 not found, P0001 a rule (state, limits).

-- ---------------------------------------------------------------------------
-- 1. Tables (closed: no policy, no grant; the functions below only)
-- ---------------------------------------------------------------------------
create table public.tournaments (
  id                     uuid primary key default gen_random_uuid(),
  organizer_club_id      uuid not null
                         constraint tournaments_organizer_club_id_fkey references public.clubs (id) on delete cascade,
  created_by             uuid
                         constraint tournaments_created_by_fkey references public.profiles (id) on delete set null,
  name                   text not null
                         constraint tournaments_name_check check (char_length(name) between 1 and 60 and name = btrim(name)),
  city                   text not null
                         constraint tournaments_city_check check (char_length(city) between 1 and 60 and city = btrim(city)),
  ground                 text not null
                         constraint tournaments_ground_check check (char_length(ground) between 1 and 60 and ground = btrim(ground)),
  format                 text not null
                         constraint tournaments_format_check check (format in ('test', 't20', 'odi', 't10', 'custom')),
  custom_overs           smallint
                         constraint tournaments_custom_overs_check check (custom_overs is null or custom_overs between 1 and 50),
  tournament_type        text not null
                         constraint tournaments_type_check check (tournament_type in ('knockout', 'league')),
  start_date             date not null,
  end_date               date not null,
  registration_deadline  date not null,
  -- Display only (no payments in CricEco). NULL = not set ("—").
  entry_fee              integer
                         constraint tournaments_entry_fee_check check (entry_fee is null or entry_fee between 0 and 9999999),
  prize                  integer
                         constraint tournaments_prize_check check (prize is null or prize between 0 and 99999999),
  max_teams              smallint not null
                         constraint tournaments_max_teams_check check (max_teams between 2 and 32),
  description            text not null default ''
                         constraint tournaments_description_check
                         check (char_length(description) <= 500 and description = btrim(description)),
  rules                  text[] not null default '{}'
                         constraint tournaments_rules_check
                         check (cardinality(rules) <= 20 and array_position(rules, null) is null
                                and octet_length(array_to_string(rules, '')) <= 8000),
  -- Stored status. "registration_closed" is also derived on read once the
  -- deadline day (Asia/Karachi) has passed (tournament_status_now).
  status                 text not null default 'registration_open'
                         constraint tournaments_status_check
                         check (status in ('registration_open', 'registration_full', 'registration_closed', 'completed')),
  winner_registration_id uuid,
  fixtures_generated_at  timestamptz,
  completed_at           timestamptz,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  constraint tournaments_overs_follow_format check ((format = 'custom') = (custom_overs is not null)),
  constraint tournaments_end_after_start check (end_date >= start_date),
  constraint tournaments_deadline_by_start check (registration_deadline <= start_date),
  constraint tournaments_deadline_not_past
    check (registration_deadline >= (created_at at time zone 'Asia/Karachi')::date),
  constraint tournaments_completed_follows_status check ((status = 'completed') = (completed_at is not null)),
  constraint tournaments_fixtures_close_registration
    check (fixtures_generated_at is null or status in ('registration_closed', 'completed')),
  constraint tournaments_completed_has_fixtures check (status <> 'completed' or fixtures_generated_at is not null)
);

create index tournaments_organizer_created_idx on public.tournaments (organizer_club_id, created_at desc);
create index tournaments_city_start_idx on public.tournaments (lower(city), start_date);
create index tournaments_created_by_idx on public.tournaments (created_by) where created_by is not null;

comment on table public.tournaments is
  'Migration 35 (M10): a club''s tournament. Closed table: create_tournament / generate_tournament_fixtures / record_tournament_fixture_result and the readers only.';

create table public.tournament_registrations (
  id              uuid primary key default gen_random_uuid(),
  tournament_id   uuid not null
                  constraint tournament_registrations_tournament_id_fkey references public.tournaments (id) on delete cascade,
  club_id         uuid not null
                  constraint tournament_registrations_club_id_fkey references public.clubs (id) on delete cascade,
  -- The club team the squad came from (NULL: a new match-day squad).
  team_id         uuid
                  constraint tournament_registrations_team_id_fkey references public.teams (id) on delete set null,
  -- Snapshot of the squad name (Lineup.name).
  team_name       text not null
                  constraint tournament_registrations_team_name_check
                  check (char_length(team_name) between 1 and 40 and team_name = btrim(team_name)),
  -- pending → approved | rejected; approved → removed (before fixtures).
  status          text not null default 'pending'
                  constraint tournament_registrations_status_check
                  check (status in ('pending', 'approved', 'rejected', 'removed')),
  -- "I agree to the tournament rules." (required to submit).
  rules_agreed_at timestamptz not null default now(),
  submitted_by    uuid
                  constraint tournament_registrations_submitted_by_fkey references public.profiles (id) on delete set null,
  submitted_at    timestamptz not null default now(),
  decided_by      uuid
                  constraint tournament_registrations_decided_by_fkey references public.profiles (id) on delete set null,
  decided_at      timestamptz,
  constraint tournament_registrations_decided_follows_status check ((status = 'pending') = (decided_at is null)),
  constraint tournament_registrations_id_tournament_key unique (id, tournament_id)
);

-- One live (pending / approved) entry per club and tournament.
create unique index tournament_registrations_one_active_idx on public.tournament_registrations (tournament_id, club_id)
  where status in ('pending', 'approved');
create index tournament_registrations_tournament_status_idx
  on public.tournament_registrations (tournament_id, status, submitted_at);
create index tournament_registrations_club_submitted_idx on public.tournament_registrations (club_id, submitted_at desc);
create index tournament_registrations_team_id_idx on public.tournament_registrations (team_id) where team_id is not null;
create index tournament_registrations_submitted_by_idx on public.tournament_registrations (submitted_by)
  where submitted_by is not null;
create index tournament_registrations_decided_by_idx on public.tournament_registrations (decided_by)
  where decided_by is not null;

comment on table public.tournament_registrations is
  'Migration 35 (M10): a club''s tournament entry. Closed table: submit / decide_tournament_registration, remove_tournament_team and the readers only.';

-- The tournament's champion is one of its own entries.
alter table public.tournaments
  add constraint tournaments_winner_registration_fkey
  foreign key (winner_registration_id, id) references public.tournament_registrations (id, tournament_id)
  on delete set null (winner_registration_id);

create table public.tournament_registration_players (
  registration_id  uuid not null
                   constraint tournament_registration_players_registration_id_fkey
                   references public.tournament_registrations (id) on delete cascade,
  member_id        uuid not null
                   constraint tournament_registration_players_member_id_fkey
                   references public.club_members (id) on delete cascade,
  selection        text not null
                   constraint tournament_registration_players_selection_check check (selection in ('playing', 'sub')),
  position         smallint not null
                   constraint tournament_registration_players_position_check check (position between 1 and 15),
  is_captain       boolean not null default false,
  is_vice_captain  boolean not null default false,
  is_wicket_keeper boolean not null default false,
  constraint tournament_registration_players_pkey primary key (registration_id, member_id),
  constraint tournament_registration_players_position_key unique (registration_id, position),
  constraint tournament_registration_players_leaders_distinct check (not (is_captain and is_vice_captain)),
  constraint tournament_registration_players_leaders_play
    check (selection = 'playing' or not (is_captain or is_vice_captain or is_wicket_keeper))
);

create unique index tournament_registration_players_one_captain_idx
  on public.tournament_registration_players (registration_id) where is_captain;
create unique index tournament_registration_players_one_vice_idx
  on public.tournament_registration_players (registration_id) where is_vice_captain;
create unique index tournament_registration_players_one_keeper_idx
  on public.tournament_registration_players (registration_id) where is_wicket_keeper;
create index tournament_registration_players_member_id_idx on public.tournament_registration_players (member_id);

comment on table public.tournament_registration_players is
  'Migration 35 (M10): a tournament entry''s squad (Playing XI and substitutes, in pick order). Closed table: submit_tournament_registration only.';

create table public.tournament_fixtures (
  id                     uuid primary key default gen_random_uuid(),
  tournament_id          uuid not null
                         constraint tournament_fixtures_tournament_id_fkey references public.tournaments (id) on delete cascade,
  -- 1 = first round. Knockout: Final is the last round; league: one round.
  round_no               smallint not null
                         constraint tournament_fixtures_round_no_check check (round_no between 1 and 10),
  round_name             text not null
                         constraint tournament_fixtures_round_name_check check (char_length(round_name) between 1 and 40),
  match_no               smallint not null
                         constraint tournament_fixtures_match_no_check check (match_no between 1 and 496),
  -- A side: an entry, a BYE, or neither (TBD: the winner of an earlier fixture).
  home_registration_id   uuid,
  home_bye               boolean not null default false,
  away_registration_id   uuid,
  away_bye               boolean not null default false,
  -- Set ONLY by record_tournament_fixture_result (service_role) or, for a
  -- BYE, by the draw itself. winner_bye: a BYE-vs-BYE slot (no team).
  winner_registration_id uuid,
  winner_bye             boolean not null default false,
  -- Knockout: where the winner goes.
  next_fixture_id        uuid
                         constraint tournament_fixtures_next_fixture_id_fkey
                         references public.tournament_fixtures (id) on delete cascade,
  next_slot              text
                         constraint tournament_fixtures_next_slot_check check (next_slot in ('home', 'away')),
  -- The official match (migrations 17 / 20–24) this fixture was played as.
  match_id               uuid
                         constraint tournament_fixtures_match_id_fkey references public.matches (id) on delete set null,
  decided_at             timestamptz,
  created_at             timestamptz not null default now(),
  constraint tournament_fixtures_round_match_key unique (tournament_id, round_no, match_no),
  constraint tournament_fixtures_home_fkey foreign key (home_registration_id, tournament_id)
    references public.tournament_registrations (id, tournament_id) on delete set null (home_registration_id),
  constraint tournament_fixtures_away_fkey foreign key (away_registration_id, tournament_id)
    references public.tournament_registrations (id, tournament_id) on delete set null (away_registration_id),
  constraint tournament_fixtures_winner_fkey foreign key (winner_registration_id, tournament_id)
    references public.tournament_registrations (id, tournament_id) on delete set null (winner_registration_id),
  constraint tournament_fixtures_home_side check (not (home_bye and home_registration_id is not null)),
  constraint tournament_fixtures_away_side check (not (away_bye and away_registration_id is not null)),
  constraint tournament_fixtures_two_sides
    check (home_registration_id is null or away_registration_id is null or home_registration_id <> away_registration_id),
  constraint tournament_fixtures_winner_side
    check (not winner_bye or (winner_registration_id is null and home_bye and away_bye)),
  constraint tournament_fixtures_next_follows_slot check ((next_fixture_id is null) = (next_slot is null))
);

create index tournament_fixtures_next_fixture_id_idx on public.tournament_fixtures (next_fixture_id)
  where next_fixture_id is not null;
create unique index tournament_fixtures_match_id_key on public.tournament_fixtures (match_id) where match_id is not null;
create index tournament_fixtures_home_idx on public.tournament_fixtures (home_registration_id)
  where home_registration_id is not null;
create index tournament_fixtures_away_idx on public.tournament_fixtures (away_registration_id)
  where away_registration_id is not null;
create index tournament_fixtures_winner_idx on public.tournament_fixtures (winner_registration_id)
  where winner_registration_id is not null;
create index tournaments_winner_registration_idx on public.tournaments (winner_registration_id)
  where winner_registration_id is not null;

comment on table public.tournament_fixtures is
  'Migration 35 (M10): a tournament''s draw. Closed table: generate_tournament_fixtures writes it; only record_tournament_fixture_result (service_role) sets a played fixture''s winner.';

alter table public.tournaments enable row level security;
alter table public.tournament_registrations enable row level security;
alter table public.tournament_registration_players enable row level security;
alter table public.tournament_fixtures enable row level security;

revoke all on table public.tournaments, public.tournament_registrations, public.tournament_registration_players,
  public.tournament_fixtures
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. Integrity triggers (defence in depth: the functions check the same)
-- ---------------------------------------------------------------------------
-- An entry is never the organizer's own club; its team is one of its club's.
create function public.tournament_registrations_validate()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if exists (select 1 from public.tournaments t where t.id = new.tournament_id and t.organizer_club_id = new.club_id) then
    raise exception 'tournament: own tournament' using errcode = '23514';
  end if;
  if new.team_id is not null
     and not exists (select 1 from public.teams tm where tm.id = new.team_id and tm.club_id = new.club_id) then
    raise exception 'tournament: invalid team' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger tournament_registrations_validate
  before insert or update of tournament_id, club_id, team_id on public.tournament_registrations
  for each row execute function public.tournament_registrations_validate();

-- A squad place needs an ACTIVE member of the entry's own club.
create function public.tournament_registration_players_validate()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists (select 1 from public.club_members m
                   join public.tournament_registrations r on r.id = new.registration_id
                  where m.id = new.member_id and m.club_id = r.club_id and m.status = 'active') then
    raise exception 'tournament: player not in club' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger tournament_registration_players_validate
  before insert or update of registration_id, member_id on public.tournament_registration_players
  for each row execute function public.tournament_registration_players_validate();

-- ---------------------------------------------------------------------------
-- 3. Notifications: five types
-- ---------------------------------------------------------------------------
alter table public.notifications
  drop constraint notifications_type_check,
  add constraint notifications_type_check check (type in (
    'join_request_received', 'join_request_approved', 'join_request_declined', 'removed_from_club',
    'ownership_offered', 'ownership_accepted', 'ownership_rejected', 'ownership_withdrawn',
    'challenge_received', 'challenge_accepted', 'challenge_declined',
    'schedule_proposed', 'schedule_accepted', 'schedule_declined', 'match_rescheduled', 'match_cancelled',
    'lineup_selected', 'lineup_changed', 'lineup_dropped',
    'result_published', 'result_corrected', 'player_of_match',
    'announcement',
    'match_reminder', 'challenge_expiring', 'ownership_expiring',
    'hunt_invite_received', 'hunt_interest_received', 'hunt_invite_accepted',
    'tournament_registration_received', 'tournament_registration_approved', 'tournament_registration_rejected',
    'tournament_team_removed', 'tournament_fixtures_published'));

-- An entry to decide is a request (join_requests); the organizer's answers
-- are club-vs-club competition (challenges); the draw is about matches.
create or replace function public.notification_category(p_type text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
           when p_type in ('join_request_received', 'hunt_interest_received', 'hunt_invite_accepted',
                           'tournament_registration_received') then 'join_requests'
           when p_type in ('challenge_received', 'challenge_accepted', 'challenge_declined',
                           'schedule_proposed', 'schedule_accepted', 'schedule_declined',
                           'challenge_expiring', 'tournament_registration_approved',
                           'tournament_registration_rejected', 'tournament_team_removed') then 'challenges'
           when p_type in ('lineup_selected', 'lineup_changed', 'lineup_dropped',
                           'match_rescheduled', 'match_cancelled', 'match_reminder',
                           'tournament_fixtures_published') then 'matches'
           when p_type in ('result_published', 'result_corrected', 'player_of_match') then 'results'
           when p_type = 'announcement' then 'announcements'
           else 'membership'
         end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Internal helpers (no API role may call them)
-- ---------------------------------------------------------------------------
-- The status as of now (Tournament.statusAt): an open tournament whose
-- deadline day (Asia/Karachi) has passed is closed; the row is not rewritten.
create function public.tournament_status_now(p_status text, p_deadline date)
returns text
language sql
stable
set search_path = ''
as $$
  select case when p_status = 'registration_open' and (now() at time zone 'Asia/Karachi')::date > p_deadline
              then 'registration_closed' else p_status end;
$$;

-- Tournaments as the app shows them, for [p_viewer]. Filters: one
-- tournament, one organizer club, browse (not the viewer's own clubs), city
-- (case and outer spaces ignored).
create function public.tournament_list(
  p_viewer            uuid,
  p_tournament_id     uuid,
  p_organizer_club_id uuid,
  p_browse            boolean,
  p_city              text
)
returns table (
  tournament_id          uuid,
  organizer_club_id      uuid,
  organizer_name         text,
  organizer_short_name   text,
  organizer_city         text,
  organizer_logo_path    text,
  name                   text,
  city                   text,
  ground                 text,
  format                 text,
  custom_overs           integer,
  tournament_type        text,
  start_date             date,
  end_date               date,
  registration_deadline  date,
  entry_fee              integer,
  prize                  integer,
  max_teams              integer,
  description            text,
  rules                  text[],
  status                 text,
  approved_count         integer,
  pending_count          integer,
  available_slots        integer,
  accepts_registrations  boolean,
  fixtures_generated     boolean,
  fixtures_generated_at  timestamptz,
  winner_registration_id uuid,
  winner_name            text,
  is_organizer           boolean,
  my_registration_id     uuid,
  my_registration_status text,
  created_at             timestamptz
)
language sql
stable
set search_path = ''
as $$
  select t.id, c.id, c.name, c.short_name, c.city, c.logo_path,
         t.name, t.city, t.ground, t.format, t.custom_overs::integer, t.tournament_type,
         t.start_date, t.end_date, t.registration_deadline, t.entry_fee, t.prize, t.max_teams::integer,
         t.description, t.rules,
         public.tournament_status_now(t.status, t.registration_deadline),
         s.approved,
         case when c.owner_id = p_viewer then s.pending end,
         greatest(t.max_teams - s.approved, 0),
         public.tournament_status_now(t.status, t.registration_deadline) = 'registration_open'
           and s.approved < t.max_teams and t.fixtures_generated_at is null,
         t.fixtures_generated_at is not null, t.fixtures_generated_at,
         t.winner_registration_id, wc.name,
         c.owner_id = p_viewer,
         mine.id, mine.status,
         t.created_at
    from public.tournaments t
    join public.clubs c on c.id = t.organizer_club_id
    cross join lateral (select count(*) filter (where r.status = 'approved')::integer as approved,
                               count(*) filter (where r.status = 'pending')::integer as pending
                          from public.tournament_registrations r where r.tournament_id = t.id) s
    left join public.tournament_registrations w on w.id = t.winner_registration_id
    left join public.clubs wc on wc.id = w.club_id
    left join lateral (select r.id, r.status
                         from public.tournament_registrations r
                         join public.clubs rc on rc.id = r.club_id
                        where r.tournament_id = t.id and rc.owner_id = p_viewer
                          and r.status in ('pending', 'approved')
                        order by r.submitted_at desc, r.id
                        limit 1) mine on true
   where (p_tournament_id is null or t.id = p_tournament_id)
     and (p_organizer_club_id is null or t.organizer_club_id = p_organizer_club_id)
     and (not p_browse or c.owner_id <> p_viewer)
     and (p_city is null or lower(t.city) = lower(p_city))
   order by case when p_browse then t.start_date end, t.created_at desc, t.id
   limit 200;
$$;

-- Entries as the app shows them, for [p_viewer]: approved ones for every
-- signed-in user; every status for the organizer's owner; the viewer's own
-- club's entries in every status. One tournament, or one entry.
create function public.tournament_registration_rows(p_viewer uuid, p_tournament_id uuid, p_registration_id uuid)
returns table (
  registration_id uuid,
  tournament_id   uuid,
  club_id         uuid,
  club_name       text,
  club_short_name text,
  club_city       text,
  club_logo_path  text,
  team_id         uuid,
  team_name       text,
  status          text,
  submitted_at    timestamptz,
  decided_at      timestamptz,
  player_count    integer,
  is_my_club      boolean
)
language sql
stable
set search_path = ''
as $$
  select r.id, r.tournament_id, c.id, c.name, c.short_name, c.city, c.logo_path,
         r.team_id, r.team_name, r.status, r.submitted_at, r.decided_at,
         (select count(*)::integer from public.tournament_registration_players rp where rp.registration_id = r.id),
         c.owner_id = p_viewer
    from public.tournament_registrations r
    join public.tournaments t on t.id = r.tournament_id
    join public.clubs c on c.id = r.club_id
    join public.clubs oc on oc.id = t.organizer_club_id
   where (p_tournament_id is null or r.tournament_id = p_tournament_id)
     and (p_registration_id is null or r.id = p_registration_id)
     and (r.status = 'approved' or oc.owner_id = p_viewer or c.owner_id = p_viewer)
   order by case r.status when 'approved' then 0 when 'pending' then 1 else 2 end,
            case when r.status = 'pending' then r.submitted_at end,
            case when r.status = 'approved' then r.decided_at end,
            r.decided_at desc, r.id;
$$;

-- Sets a fixture's winner (an entry, or a BYE for BYE vs BYE) and moves it
-- into the next fixture's slot (FixtureEngine._setWinner).
create function public.tournament_fixture_decide(p_fixture_id uuid, p_winner uuid, p_winner_bye boolean)
returns void
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_next uuid;
  v_slot text;
begin
  update public.tournament_fixtures f
     set winner_registration_id = p_winner, winner_bye = p_winner_bye, decided_at = now()
   where f.id = p_fixture_id
  returning f.next_fixture_id, f.next_slot into v_next, v_slot;
  if v_next is not null then
    update public.tournament_fixtures f
       set home_registration_id = case when v_slot = 'home' then p_winner else f.home_registration_id end,
           home_bye = case when v_slot = 'home' then p_winner_bye else f.home_bye end,
           away_registration_id = case when v_slot = 'away' then p_winner else f.away_registration_id end,
           away_bye = case when v_slot = 'away' then p_winner_bye else f.away_bye end
     where f.id = v_next;
  end if;
end;
$$;

-- Resolves every undecided fixture with a BYE on one side and both sides
-- known (FixtureEngine._autoAdvanceByes): the team advances, no points.
create function public.tournament_advance_byes(p_tournament_id uuid)
returns void
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_row     public.tournament_fixtures;
  v_changed boolean;
begin
  loop
    v_changed := false;
    for v_row in
      select * from public.tournament_fixtures f
       where f.tournament_id = p_tournament_id and f.decided_at is null
         and (f.home_bye or f.away_bye)
         and (f.home_bye or f.home_registration_id is not null)
         and (f.away_bye or f.away_registration_id is not null)
       order by f.round_no, f.match_no
    loop
      perform public.tournament_fixture_decide(
                v_row.id,
                case when v_row.home_bye then v_row.away_registration_id else v_row.home_registration_id end,
                v_row.home_bye and v_row.away_bye);
      v_changed := true;
    end loop;
    exit when not v_changed;
  end loop;
end;
$$;

-- The points table (standingsTable): every approved entry; 2 points a win;
-- played fixtures only (BYEs never count). Points, then club name.
create function public.tournament_standings(p_tournament_id uuid)
returns table (
  "position"      integer,
  registration_id uuid,
  club_id         uuid,
  club_name       text,
  team_name       text,
  played          integer,
  won             integer,
  lost            integer,
  points          integer
)
language sql
stable
set search_path = ''
as $$
  with res as (
    select f.winner_registration_id as w,
           case when f.winner_registration_id = f.home_registration_id then f.away_registration_id
                else f.home_registration_id end as l
      from public.tournament_fixtures f
     where f.tournament_id = p_tournament_id and f.winner_registration_id is not null
       and not f.home_bye and not f.away_bye
  ), tally as (
    select r.id, r.club_id, c.name as club_name, r.team_name,
           (select count(*) from res where res.w = r.id)::integer as won,
           (select count(*) from res where res.l = r.id)::integer as lost
      from public.tournament_registrations r
      join public.clubs c on c.id = r.club_id
     where r.tournament_id = p_tournament_id and r.status = 'approved'
  )
  select (row_number() over (order by tally.won * 2 desc, tally.club_name, tally.id))::integer,
         tally.id, tally.club_id, tally.club_name, tally.team_name,
         tally.won + tally.lost, tally.won, tally.lost, tally.won * 2
    from tally
   order by 1;
$$;

-- ---------------------------------------------------------------------------
-- 5. Hosting (Create Tournament, My Tournaments, Tournament Center)
-- ---------------------------------------------------------------------------
-- Publish a tournament for the caller's club (validateTournamentInput). Text
-- is trimmed (inner runs of spaces become one; the description keeps its
-- line breaks). custom_overs only with format "custom" (ignored otherwise).
-- At most 20 not-completed tournaments and 5 new ones per 24 hours per club.
-- Returns the tournament (tournament_detail's columns).
create function public.create_tournament(
  p_club_id               uuid,
  p_name                  text,
  p_city                  text,
  p_ground                text,
  p_format                text,
  p_custom_overs          integer,
  p_tournament_type       text,
  p_start_date            date,
  p_end_date              date,
  p_registration_deadline date,
  p_max_teams             integer,
  p_entry_fee             integer default null,
  p_prize                 integer default null,
  p_description           text default null,
  p_rules                 text[] default null
)
returns table (
  tournament_id          uuid,
  organizer_club_id      uuid,
  organizer_name         text,
  organizer_short_name   text,
  organizer_city         text,
  organizer_logo_path    text,
  name                   text,
  city                   text,
  ground                 text,
  format                 text,
  custom_overs           integer,
  tournament_type        text,
  start_date             date,
  end_date               date,
  registration_deadline  date,
  entry_fee              integer,
  prize                  integer,
  max_teams              integer,
  description            text,
  rules                  text[],
  status                 text,
  approved_count         integer,
  pending_count          integer,
  available_slots        integer,
  accepts_registrations  boolean,
  fixtures_generated     boolean,
  fixtures_generated_at  timestamptz,
  winner_registration_id uuid,
  winner_name            text,
  is_organizer           boolean,
  my_registration_id     uuid,
  my_registration_status text,
  created_at             timestamptz
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_club   public.clubs;
  v_name   text := regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g');
  v_city   text := regexp_replace(btrim(coalesce(p_city, '')), '\s+', ' ', 'g');
  v_ground text := regexp_replace(btrim(coalesce(p_ground, '')), '\s+', ' ', 'g');
  v_desc   text := btrim(coalesce(p_description, ''));
  v_rules  text[];
  v_today  date := (now() at time zone 'Asia/Karachi')::date;
  v_id     uuid;
begin
  if v_uid is null then
    raise exception 'tournament: not authenticated' using errcode = '42501';
  end if;
  -- The club row lock serializes the owner's publishes (the limits).
  select * into v_club from public.clubs c where c.id = p_club_id for no key update;
  if not found or v_club.owner_id is distinct from v_uid then
    raise exception 'tournament: not allowed' using errcode = '42501';
  end if;
  if char_length(v_name) not between 1 and 60 then
    raise exception 'tournament: invalid name' using errcode = '22023';
  end if;
  if char_length(v_city) not between 1 and 60 then
    raise exception 'tournament: invalid city' using errcode = '22023';
  end if;
  if char_length(v_ground) not between 1 and 60 then
    raise exception 'tournament: invalid ground' using errcode = '22023';
  end if;
  if p_format is null or p_format not in ('test', 't20', 'odi', 't10', 'custom') then
    raise exception 'tournament: invalid format' using errcode = '22023';
  end if;
  if p_format = 'custom' and (p_custom_overs is null or p_custom_overs not between 1 and 50) then
    raise exception 'tournament: invalid overs' using errcode = '22023';
  end if;
  if p_tournament_type is null or p_tournament_type not in ('knockout', 'league') then
    raise exception 'tournament: invalid type' using errcode = '22023';
  end if;
  if p_start_date is null then
    raise exception 'tournament: invalid start date' using errcode = '22023';
  end if;
  if p_start_date < v_today then
    raise exception 'tournament: start date in the past' using errcode = '22023';
  end if;
  if p_start_date > v_today + 365 then
    raise exception 'tournament: start date too far ahead' using errcode = '22023';
  end if;
  if p_end_date is null then
    raise exception 'tournament: invalid end date' using errcode = '22023';
  end if;
  if p_end_date < p_start_date then
    raise exception 'tournament: end date before start date' using errcode = '22023';
  end if;
  if p_end_date > p_start_date + 180 then
    raise exception 'tournament: tournament too long' using errcode = '22023';
  end if;
  if p_registration_deadline is null then
    raise exception 'tournament: invalid deadline' using errcode = '22023';
  end if;
  if p_registration_deadline < v_today then
    raise exception 'tournament: deadline in the past' using errcode = '22023';
  end if;
  if p_registration_deadline > p_start_date then
    raise exception 'tournament: deadline after start date' using errcode = '22023';
  end if;
  if p_max_teams is null or p_max_teams not between 2 and 32 then
    raise exception 'tournament: invalid max teams' using errcode = '22023';
  end if;
  if p_entry_fee is not null and p_entry_fee not between 0 and 9999999 then
    raise exception 'tournament: invalid entry fee' using errcode = '22023';
  end if;
  if p_prize is not null and p_prize not between 0 and 99999999 then
    raise exception 'tournament: invalid prize' using errcode = '22023';
  end if;
  if char_length(v_desc) > 500 then
    raise exception 'tournament: invalid description' using errcode = '22023';
  end if;
  v_rules := coalesce((select array_agg(regexp_replace(btrim(x.r), '\s+', ' ', 'g') order by x.o)
                         from unnest(coalesce(p_rules, '{}'::text[])) with ordinality as x(r, o)
                        where nullif(btrim(coalesce(x.r, '')), '') is not null), '{}'::text[]);
  if cardinality(v_rules) > 20 or exists (select 1 from unnest(v_rules) r where char_length(r) > 200) then
    raise exception 'tournament: invalid rules' using errcode = '22023';
  end if;
  if (select count(*) from public.tournaments t where t.organizer_club_id = p_club_id and t.status <> 'completed') >= 20 then
    raise exception 'tournament: too many tournaments' using errcode = 'P0001';
  end if;
  if (select count(*) from public.tournaments t
       where t.organizer_club_id = p_club_id and t.created_at > now() - interval '24 hours') >= 5 then
    raise exception 'tournament: too many tournaments, try later' using errcode = 'P0001';
  end if;

  insert into public.tournaments (organizer_club_id, created_by, name, city, ground, format, custom_overs,
                                  tournament_type, start_date, end_date, registration_deadline, entry_fee, prize,
                                  max_teams, description, rules)
  values (p_club_id, v_uid, v_name, v_city, v_ground, p_format,
          case when p_format = 'custom' then p_custom_overs::smallint end,
          p_tournament_type, p_start_date, p_end_date, p_registration_deadline, p_entry_fee, p_prize,
          p_max_teams::smallint, v_desc, v_rules)
  returning id into v_id;

  return query select * from public.tournament_list(v_uid, v_id, null, false, null);
end;
$$;

-- My Tournaments: the club's tournaments, newest first (its owner only).
create function public.my_hosted_tournaments(p_club_id uuid)
returns table (
  tournament_id          uuid,
  organizer_club_id      uuid,
  organizer_name         text,
  organizer_short_name   text,
  organizer_city         text,
  organizer_logo_path    text,
  name                   text,
  city                   text,
  ground                 text,
  format                 text,
  custom_overs           integer,
  tournament_type        text,
  start_date             date,
  end_date               date,
  registration_deadline  date,
  entry_fee              integer,
  prize                  integer,
  max_teams              integer,
  description            text,
  rules                  text[],
  status                 text,
  approved_count         integer,
  pending_count          integer,
  available_slots        integer,
  accepts_registrations  boolean,
  fixtures_generated     boolean,
  fixtures_generated_at  timestamptz,
  winner_registration_id uuid,
  winner_name            text,
  is_organizer           boolean,
  my_registration_id     uuid,
  my_registration_status text,
  created_at             timestamptz
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
    raise exception 'tournament: not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.clubs c where c.id = p_club_id and c.owner_id = v_uid) then
    raise exception 'tournament: not allowed' using errcode = '42501';
  end if;
  return query select * from public.tournament_list(v_uid, null, p_club_id, false, null);
end;
$$;

-- Browse Tournaments: other clubs' tournaments (never one of the caller's
-- own clubs), soonest start first, at most 200. p_city optional (case and
-- outer spaces ignored); NULL = every city (the app builds its city list
-- from these rows).
create function public.browse_tournaments(p_city text default null)
returns table (
  tournament_id          uuid,
  organizer_club_id      uuid,
  organizer_name         text,
  organizer_short_name   text,
  organizer_city         text,
  organizer_logo_path    text,
  name                   text,
  city                   text,
  ground                 text,
  format                 text,
  custom_overs           integer,
  tournament_type        text,
  start_date             date,
  end_date               date,
  registration_deadline  date,
  entry_fee              integer,
  prize                  integer,
  max_teams              integer,
  description            text,
  rules                  text[],
  status                 text,
  approved_count         integer,
  pending_count          integer,
  available_slots        integer,
  accepts_registrations  boolean,
  fixtures_generated     boolean,
  fixtures_generated_at  timestamptz,
  winner_registration_id uuid,
  winner_name            text,
  is_organizer           boolean,
  my_registration_id     uuid,
  my_registration_status text,
  created_at             timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid  uuid := auth.uid();
  v_city text := nullif(regexp_replace(btrim(coalesce(p_city, '')), '\s+', ' ', 'g'), '');
begin
  if v_uid is null then
    raise exception 'tournament: not authenticated' using errcode = '42501';
  end if;
  if char_length(coalesce(v_city, '')) > 60 then
    raise exception 'tournament: invalid city' using errcode = '22023';
  end if;
  return query select * from public.tournament_list(v_uid, null, null, true, v_city);
end;
$$;

-- Tournament Details / Dashboard: one tournament, for any signed-in user.
create function public.tournament_detail(p_tournament_id uuid)
returns table (
  tournament_id          uuid,
  organizer_club_id      uuid,
  organizer_name         text,
  organizer_short_name   text,
  organizer_city         text,
  organizer_logo_path    text,
  name                   text,
  city                   text,
  ground                 text,
  format                 text,
  custom_overs           integer,
  tournament_type        text,
  start_date             date,
  end_date               date,
  registration_deadline  date,
  entry_fee              integer,
  prize                  integer,
  max_teams              integer,
  description            text,
  rules                  text[],
  status                 text,
  approved_count         integer,
  pending_count          integer,
  available_slots        integer,
  accepts_registrations  boolean,
  fixtures_generated     boolean,
  fixtures_generated_at  timestamptz,
  winner_registration_id uuid,
  winner_name            text,
  is_organizer           boolean,
  my_registration_id     uuid,
  my_registration_status text,
  created_at             timestamptz
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
    raise exception 'tournament: not authenticated' using errcode = '42501';
  end if;
  return query select * from public.tournament_list(v_uid, p_tournament_id, null, false, null);
  if not found then
    raise exception 'tournament: not found' using errcode = 'P0002';
  end if;
end;
$$;

-- Tournament Center stats (TournamentHubStats) for the caller's club.
create function public.tournament_hub_stats(p_club_id uuid)
returns table (
  hosted     integer,
  open       integer,
  registered integer,
  approved   integer,
  pending    integer
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
    raise exception 'tournament: not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.clubs c where c.id = p_club_id and c.owner_id = v_uid) then
    raise exception 'tournament: not allowed' using errcode = '42501';
  end if;
  return query
    select (select count(*)::integer from public.tournaments t where t.organizer_club_id = p_club_id),
           (select count(*)::integer from public.tournament_list(v_uid, null, null, true, null) b
             where b.accepts_registrations),
           (select count(*)::integer from public.tournament_registrations r where r.club_id = p_club_id),
           (select count(*)::integer from public.tournament_registrations r
             where r.club_id = p_club_id and r.status = 'approved'),
           (select count(*)::integer from public.tournament_registrations r
             where r.club_id = p_club_id and r.status = 'pending');
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Entries (registration flow, requests, Teams tab)
-- ---------------------------------------------------------------------------
-- Teams tab / Team Requests: the tournament's entries the caller may see
-- (approved for everyone; all for the organizer's owner; the caller's own).
-- Approved first (in approval order = the draw's seeding), then pending
-- (oldest first), then rejected / removed (newest decision first).
create function public.tournament_teams(p_tournament_id uuid)
returns table (
  registration_id uuid,
  tournament_id   uuid,
  club_id         uuid,
  club_name       text,
  club_short_name text,
  club_city       text,
  club_logo_path  text,
  team_id         uuid,
  team_name       text,
  status          text,
  submitted_at    timestamptz,
  decided_at      timestamptz,
  player_count    integer,
  is_my_club      boolean
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
    raise exception 'tournament: not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.tournaments t where t.id = p_tournament_id) then
    raise exception 'tournament: not found' using errcode = 'P0002';
  end if;
  return query select * from public.tournament_registration_rows(v_uid, p_tournament_id, null);
end;
$$;

-- An entry's squad, in pick order: for the entering club's owner and the
-- organizer's owner only. member_active = still an active member.
create function public.tournament_registration_squad(p_registration_id uuid)
returns table (
  registration_id  uuid,
  "position"       integer,
  member_id        uuid,
  user_id          uuid,
  full_name        text,
  avatar_path      text,
  member_role      text,
  selection        text,
  is_captain       boolean,
  is_vice_captain  boolean,
  is_wicket_keeper boolean,
  member_active    boolean
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
    raise exception 'tournament: not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.tournament_registrations r
                   join public.tournaments t on t.id = r.tournament_id
                   join public.clubs c on c.id = r.club_id
                   join public.clubs oc on oc.id = t.organizer_club_id
                  where r.id = p_registration_id and (c.owner_id = v_uid or oc.owner_id = v_uid)) then
    raise exception 'tournament: not allowed' using errcode = '42501';
  end if;
  return query
    select rp.registration_id, rp.position::integer, rp.member_id, m.user_id, p.full_name, p.avatar_path,
           m.member_role, rp.selection, rp.is_captain, rp.is_vice_captain, rp.is_wicket_keeper,
           m.status = 'active'
      from public.tournament_registration_players rp
      join public.club_members m on m.id = rp.member_id
      join public.profiles p on p.id = m.user_id
     where rp.registration_id = p_registration_id
     order by rp.position;
end;
$$;

-- "Submit Registration": the caller's club enters the squad confirmed in the
-- registration draft. p_players: a JSON array in pick order (position =
-- order), exactly 11 {"member_id": "…", "selection": "playing"} and 4
-- "sub" — active members of the club, none injured / unavailable on the
-- start date. Captain, vice-captain and wicket-keeper: optional, in the
-- Playing XI (captain ≠ vice-captain). p_team_id: one of the club's ACTIVE
-- teams, or NULL (a new squad); p_team_name NULL = that team's name.
-- p_agree_rules must be true. Registration must be open (deadline day in
-- Asia/Karachi, not full, no fixtures). One live entry per club; a person
-- plays for one entry per tournament; at most 64 pending per tournament and
-- 20 submissions per club per 24 hours. The organizer's owner is told.
-- Returns the entry (tournament_teams' columns).
create function public.submit_tournament_registration(
  p_tournament_id     uuid,
  p_club_id           uuid,
  p_team_name         text,
  p_team_id           uuid,
  p_players           jsonb,
  p_captain_member_id uuid,
  p_vice_member_id    uuid,
  p_keeper_member_id  uuid,
  p_agree_rules       boolean
)
returns table (
  registration_id uuid,
  tournament_id   uuid,
  club_id         uuid,
  club_name       text,
  club_short_name text,
  club_city       text,
  club_logo_path  text,
  team_id         uuid,
  team_name       text,
  status          text,
  submitted_at    timestamptz,
  decided_at      timestamptz,
  player_count    integer,
  is_my_club      boolean
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_club    public.clubs;
  v_t       public.tournaments;
  v_org     public.clubs;
  v_team    public.teams;
  v_name    text := regexp_replace(btrim(coalesce(p_team_name, '')), '\s+', ' ', 'g');
  v_total   integer;
  v_count   integer;
  v_playing integer;
  v_subs    integer;
  v_status  text;
  v_id      uuid;
begin
  if v_uid is null then
    raise exception 'tournament: not authenticated' using errcode = '42501';
  end if;
  -- The club row lock serializes this club's submissions (the daily limit).
  select * into v_club from public.clubs c where c.id = p_club_id for no key update;
  if not found or v_club.owner_id is distinct from v_uid then
    raise exception 'tournament: not allowed' using errcode = '42501';
  end if;
  -- The tournament row lock orders this entry against the organizer's
  -- decisions and the draw (generate_tournament_fixtures closes registration).
  select * into v_t from public.tournaments t where t.id = p_tournament_id for update;
  if not found then
    raise exception 'tournament: not found' using errcode = 'P0002';
  end if;
  if v_t.organizer_club_id = p_club_id then
    raise exception 'tournament: own tournament' using errcode = 'P0001';
  end if;
  if p_agree_rules is distinct from true then
    raise exception 'tournament: rules not agreed' using errcode = '22023';
  end if;

  -- The squad: an array of {member_id, selection}, no repeats, exactly 11 + 4.
  if p_players is null or jsonb_typeof(p_players) <> 'array' then
    raise exception 'tournament: invalid squad' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(p_players) e
              where jsonb_typeof(e) <> 'object'
                 or coalesce(e ->> 'selection', '') not in ('playing', 'sub')
                 or coalesce(e ->> 'member_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') then
    raise exception 'tournament: invalid squad' using errcode = '22023';
  end if;
  select count(*), count(distinct (e ->> 'member_id')::uuid),
         count(*) filter (where e ->> 'selection' = 'playing'),
         count(*) filter (where e ->> 'selection' = 'sub')
    into v_total, v_count, v_playing, v_subs
    from jsonb_array_elements(p_players) e;
  if v_count <> v_total then
    raise exception 'tournament: invalid squad' using errcode = '22023'; -- a player listed twice
  end if;
  if v_playing <> 11 or v_subs <> 4 then
    raise exception 'tournament: squad must be 11 + 4' using errcode = '23514';
  end if;
  if p_captain_member_id is not null and p_captain_member_id = p_vice_member_id then
    raise exception 'tournament: invalid captain' using errcode = '22023';
  end if;
  if p_captain_member_id is not null and not exists (
       select 1 from jsonb_array_elements(p_players) e
        where (e ->> 'member_id')::uuid = p_captain_member_id and e ->> 'selection' = 'playing') then
    raise exception 'tournament: invalid captain' using errcode = '22023';
  end if;
  if p_vice_member_id is not null and not exists (
       select 1 from jsonb_array_elements(p_players) e
        where (e ->> 'member_id')::uuid = p_vice_member_id and e ->> 'selection' = 'playing') then
    raise exception 'tournament: invalid vice-captain' using errcode = '22023';
  end if;
  if p_keeper_member_id is not null and not exists (
       select 1 from jsonb_array_elements(p_players) e
        where (e ->> 'member_id')::uuid = p_keeper_member_id and e ->> 'selection' = 'playing') then
    raise exception 'tournament: invalid wicket-keeper' using errcode = '22023';
  end if;

  -- Source team: optional; one of this club's ACTIVE teams.
  if p_team_id is not null then
    select * into v_team from public.teams tm where tm.id = p_team_id;
    if not found or v_team.club_id <> p_club_id then
      raise exception 'tournament: invalid team' using errcode = '22023';
    end if;
    if v_team.status <> 'active' then
      raise exception 'tournament: team archived' using errcode = 'P0001';
    end if;
    if v_name = '' then
      v_name := v_team.name;
    end if;
  end if;
  if char_length(v_name) not between 1 and 40 then
    raise exception 'tournament: invalid team name' using errcode = '22023';
  end if;

  -- Registration open now (server time, Asia/Karachi deadline day).
  v_status := public.tournament_status_now(v_t.status, v_t.registration_deadline);
  if v_t.fixtures_generated_at is not null or v_status in ('registration_closed', 'completed') then
    raise exception 'tournament: registration closed' using errcode = 'P0001';
  end if;
  if v_status = 'registration_full'
     or (select count(*) from public.tournament_registrations r
          where r.tournament_id = p_tournament_id and r.status = 'approved') >= v_t.max_teams then
    raise exception 'tournament: registration full' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.tournament_registrations r
              where r.tournament_id = p_tournament_id and r.club_id = p_club_id
                and r.status in ('pending', 'approved')) then
    raise exception 'tournament: already registered' using errcode = 'P0001';
  end if;

  -- The players' memberships are share-locked (in id order): a concurrent
  -- removal waits for this entry, or this entry sees the removal. Then:
  -- every one an active member of this club, none locked on the start date.
  perform 1 from public.club_members m
   where m.id in (select (e ->> 'member_id')::uuid from jsonb_array_elements(p_players) e)
   order by m.id
     for share;
  if exists (select 1 from jsonb_array_elements(p_players) e
              where not exists (select 1 from public.club_members m
                                 where m.id = (e ->> 'member_id')::uuid
                                   and m.club_id = p_club_id and m.status = 'active')) then
    raise exception 'tournament: player not in club' using errcode = '23514';
  end if;
  if exists (select 1 from jsonb_array_elements(p_players) e
               join public.club_members m on m.id = (e ->> 'member_id')::uuid
               join public.player_availability a on a.user_id = m.user_id
              where public.availability_locks_on(a.status, a.until_date, v_t.start_date)) then
    raise exception 'tournament: player unavailable' using errcode = 'P0001';
  end if;
  if exists (select 1 from jsonb_array_elements(p_players) e
               join public.club_members m on m.id = (e ->> 'member_id')::uuid
               join public.club_members m2 on m2.user_id = m.user_id
               join public.tournament_registration_players rp on rp.member_id = m2.id
               join public.tournament_registrations r on r.id = rp.registration_id
              where r.tournament_id = p_tournament_id and r.status in ('pending', 'approved')) then
    raise exception 'tournament: player already registered' using errcode = 'P0001';
  end if;
  if (select count(*) from public.tournament_registrations r
       where r.tournament_id = p_tournament_id and r.status = 'pending') >= 64 then
    raise exception 'tournament: too many requests' using errcode = 'P0001';
  end if;
  if (select count(*) from public.tournament_registrations r
       where r.club_id = p_club_id and r.submitted_at > now() - interval '24 hours') >= 20 then
    raise exception 'tournament: too many registrations, try later' using errcode = 'P0001';
  end if;

  insert into public.tournament_registrations (tournament_id, club_id, team_id, team_name, submitted_by)
  values (p_tournament_id, p_club_id, p_team_id, v_name, v_uid)
  returning id into v_id;
  insert into public.tournament_registration_players (registration_id, member_id, selection, position,
                                                      is_captain, is_vice_captain, is_wicket_keeper)
  select v_id, (e.value ->> 'member_id')::uuid, e.value ->> 'selection', e.ordinality::smallint,
         (e.value ->> 'member_id')::uuid = p_captain_member_id is true,
         (e.value ->> 'member_id')::uuid = p_vice_member_id is true,
         (e.value ->> 'member_id')::uuid = p_keeper_member_id is true
    from jsonb_array_elements(p_players) with ordinality as e(value, ordinality);

  select * into v_org from public.clubs c where c.id = v_t.organizer_club_id;
  perform public.notification_add(
            v_org.owner_id, 'club_owner', 'tournament_registration_received',
            'tournament:registration:' || v_id,
            jsonb_build_object('tournament_id', v_t.id, 'tournament_name', v_t.name, 'applicant_name', v_club.name,
                               'team_name', v_name, 'start_date', v_t.start_date),
            v_org.id, null, v_id, null);

  return query select * from public.tournament_registration_rows(v_uid, null, v_id);
end;
$$;

-- Organizer's owner: approve or reject a pending entry. Approval moves it to
-- the confirmed teams (refused once fixtures exist, or when max_teams are
-- confirmed; the last one marks the tournament registration_full).
-- Rejection is always possible while pending. The entering club's owner is
-- told. Returns the entry.
create function public.decide_tournament_registration(p_registration_id uuid, p_approve boolean)
returns table (
  registration_id uuid,
  tournament_id   uuid,
  club_id         uuid,
  club_name       text,
  club_short_name text,
  club_city       text,
  club_logo_path  text,
  team_id         uuid,
  team_name       text,
  status          text,
  submitted_at    timestamptz,
  decided_at      timestamptz,
  player_count    integer,
  is_my_club      boolean
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid      uuid := auth.uid();
  v_tid      uuid;
  v_t        public.tournaments;
  v_org      public.clubs;
  v_reg      public.tournament_registrations;
  v_approved integer;
  v_owner    uuid;
begin
  if v_uid is null then
    raise exception 'tournament: not authenticated' using errcode = '42501';
  end if;
  if p_approve is null then
    raise exception 'tournament: invalid decision' using errcode = '22023';
  end if;
  select r.tournament_id into v_tid from public.tournament_registrations r where r.id = p_registration_id;
  if v_tid is null then
    raise exception 'tournament: registration not found' using errcode = 'P0002';
  end if;
  -- The tournament row lock serializes decisions (the last slot).
  select * into v_t from public.tournaments t where t.id = v_tid for update;
  select * into v_org from public.clubs c where c.id = v_t.organizer_club_id;
  if v_org.owner_id is distinct from v_uid then
    raise exception 'tournament: not allowed' using errcode = '42501';
  end if;
  select * into v_reg from public.tournament_registrations r where r.id = p_registration_id for update;
  if v_reg.status <> 'pending' then
    raise exception 'tournament: not pending' using errcode = 'P0001';
  end if;
  if p_approve then
    if v_t.fixtures_generated_at is not null then
      raise exception 'tournament: fixtures generated' using errcode = 'P0001';
    end if;
    select count(*) into v_approved from public.tournament_registrations r
     where r.tournament_id = v_tid and r.status = 'approved';
    if v_approved >= v_t.max_teams then
      raise exception 'tournament: registration full' using errcode = 'P0001';
    end if;
    update public.tournament_registrations r
       set status = 'approved', decided_at = now(), decided_by = v_uid
     where r.id = p_registration_id;
    if v_approved + 1 >= v_t.max_teams and v_t.status = 'registration_open' then
      update public.tournaments t set status = 'registration_full', updated_at = now() where t.id = v_tid;
    end if;
  else
    update public.tournament_registrations r
       set status = 'rejected', decided_at = now(), decided_by = v_uid
     where r.id = p_registration_id;
  end if;

  select c.owner_id into v_owner from public.clubs c where c.id = v_reg.club_id;
  perform public.notification_add(
            v_owner, 'club_owner',
            case when p_approve then 'tournament_registration_approved' else 'tournament_registration_rejected' end,
            'tournament:decision:' || p_registration_id,
            jsonb_build_object('tournament_id', v_t.id, 'tournament_name', v_t.name, 'organizer_name', v_org.name,
                               'team_name', v_reg.team_name, 'start_date', v_t.start_date),
            v_reg.club_id, null, p_registration_id, null);

  return query select * from public.tournament_registration_rows(v_uid, null, p_registration_id);
end;
$$;

-- Organizer's owner: "Remove" a confirmed team — only before fixtures exist
-- (the draw would otherwise break). A full tournament opens again. The
-- removed club may enter again while registration is open. Its owner is told.
-- Returns the entry (status removed).
create function public.remove_tournament_team(p_registration_id uuid)
returns table (
  registration_id uuid,
  tournament_id   uuid,
  club_id         uuid,
  club_name       text,
  club_short_name text,
  club_city       text,
  club_logo_path  text,
  team_id         uuid,
  team_name       text,
  status          text,
  submitted_at    timestamptz,
  decided_at      timestamptz,
  player_count    integer,
  is_my_club      boolean
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_tid   uuid;
  v_t     public.tournaments;
  v_org   public.clubs;
  v_reg   public.tournament_registrations;
  v_owner uuid;
begin
  if v_uid is null then
    raise exception 'tournament: not authenticated' using errcode = '42501';
  end if;
  select r.tournament_id into v_tid from public.tournament_registrations r where r.id = p_registration_id;
  if v_tid is null then
    raise exception 'tournament: registration not found' using errcode = 'P0002';
  end if;
  select * into v_t from public.tournaments t where t.id = v_tid for update;
  select * into v_org from public.clubs c where c.id = v_t.organizer_club_id;
  if v_org.owner_id is distinct from v_uid then
    raise exception 'tournament: not allowed' using errcode = '42501';
  end if;
  select * into v_reg from public.tournament_registrations r where r.id = p_registration_id for update;
  if v_reg.status <> 'approved' then
    raise exception 'tournament: not approved' using errcode = 'P0001';
  end if;
  if v_t.fixtures_generated_at is not null then
    raise exception 'tournament: fixtures generated' using errcode = 'P0001';
  end if;
  update public.tournament_registrations r
     set status = 'removed', decided_at = now(), decided_by = v_uid
   where r.id = p_registration_id;
  if v_t.status = 'registration_full' then
    update public.tournaments t set status = 'registration_open', updated_at = now() where t.id = v_tid;
  end if;

  select c.owner_id into v_owner from public.clubs c where c.id = v_reg.club_id;
  perform public.notification_add(
            v_owner, 'club_owner', 'tournament_team_removed',
            'tournament:removed:' || p_registration_id,
            jsonb_build_object('tournament_id', v_t.id, 'tournament_name', v_t.name, 'organizer_name', v_org.name,
                               'team_name', v_reg.team_name, 'start_date', v_t.start_date),
            v_reg.club_id, null, p_registration_id, null);

  return query select * from public.tournament_registration_rows(v_uid, null, p_registration_id);
end;
$$;

-- My Registrations: the caller's club's entries, newest first; p_status
-- optional (pending | approved | rejected | removed).
create function public.my_tournament_registrations(p_club_id uuid, p_status text default null)
returns table (
  registration_id   uuid,
  tournament_id     uuid,
  tournament_name   text,
  organizer_club_id uuid,
  organizer_name    text,
  tournament_city   text,
  ground            text,
  start_date        date,
  end_date          date,
  tournament_status text,
  team_id           uuid,
  team_name         text,
  status            text,
  submitted_at      timestamptz,
  decided_at        timestamptz,
  player_count      integer
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
    raise exception 'tournament: not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.clubs c where c.id = p_club_id and c.owner_id = v_uid) then
    raise exception 'tournament: not allowed' using errcode = '42501';
  end if;
  if p_status is not null and p_status not in ('pending', 'approved', 'rejected', 'removed') then
    raise exception 'tournament: invalid status' using errcode = '22023';
  end if;
  return query
    select r.id, t.id, t.name, oc.id, oc.name, t.city, t.ground, t.start_date, t.end_date,
           public.tournament_status_now(t.status, t.registration_deadline),
           r.team_id, r.team_name, r.status, r.submitted_at, r.decided_at,
           (select count(*)::integer from public.tournament_registration_players rp where rp.registration_id = r.id)
      from public.tournament_registrations r
      join public.tournaments t on t.id = r.tournament_id
      join public.clubs oc on oc.id = t.organizer_club_id
     where r.club_id = p_club_id and (p_status is null or r.status = p_status)
     order by r.submitted_at desc, r.id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. The draw (FixtureEngine), fixtures, points table, awards
-- ---------------------------------------------------------------------------
-- Organizer's owner: build the bracket / league from the confirmed teams
-- (at least 2), seeded in approval order. Knockout: next power of two with
-- BYEs at the end, BYE walkovers resolved at once; league: one round, every
-- pair once. Registration closes (status registration_closed); still-pending
-- entries are rejected (their owners are told) and every confirmed club's
-- owner is told the draw is out. Idempotent: once generated, nothing changes
-- and outcome = 'already_generated'.
create function public.generate_tournament_fixtures(p_tournament_id uuid)
returns table (outcome text, fixture_count integer)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_t      public.tournaments;
  v_org    public.clubs;
  v_ids    uuid[];
  v_n      integer;
  v_size   integer := 2;
  v_rounds integer := 0;
  v_count  integer;
  v_round  text;
  v_names  text[] := array['Final', 'Semifinal', 'Quarterfinal', 'Round of 16', 'Round of 32'];
  v_reg    record;
  r        integer;
  m        integer;
begin
  if v_uid is null then
    raise exception 'tournament: not authenticated' using errcode = '42501';
  end if;
  select * into v_t from public.tournaments t where t.id = p_tournament_id for update;
  if not found then
    raise exception 'tournament: not found' using errcode = 'P0002';
  end if;
  select * into v_org from public.clubs c where c.id = v_t.organizer_club_id;
  if v_org.owner_id is distinct from v_uid then
    raise exception 'tournament: not allowed' using errcode = '42501';
  end if;
  if v_t.fixtures_generated_at is not null then
    return query select 'already_generated'::text,
                        (select count(*)::integer from public.tournament_fixtures f where f.tournament_id = p_tournament_id);
    return;
  end if;
  v_ids := array(select r0.id from public.tournament_registrations r0
                  where r0.tournament_id = p_tournament_id and r0.status = 'approved'
                  order by r0.decided_at, r0.submitted_at, r0.id);
  v_n := coalesce(cardinality(v_ids), 0);
  if v_n < 2 then
    raise exception 'tournament: not enough teams' using errcode = 'P0001';
  end if;

  if v_t.tournament_type = 'league' then
    insert into public.tournament_fixtures (tournament_id, round_no, round_name, match_no,
                                            home_registration_id, away_registration_id)
    select p_tournament_id, 1, 'League Stage', (row_number() over (order by i, j))::smallint, v_ids[i], v_ids[j]
      from generate_series(1, v_n) i, generate_series(1, v_n) j
     where i < j;
  else
    while v_size < v_n loop
      v_size := v_size * 2;
    end loop;
    v_count := v_size;
    while v_count > 1 loop
      v_rounds := v_rounds + 1;
      v_count := v_count / 2;
    end loop;
    -- Last round first, so every fixture knows where its winner goes.
    for r in reverse v_rounds .. 1 loop
      v_round := case when v_rounds - r < 5 then v_names[v_rounds - r + 1] else 'Round ' || r end;
      v_count := v_size / (2 ^ r)::integer;
      for m in 1 .. v_count loop
        insert into public.tournament_fixtures (tournament_id, round_no, round_name, match_no,
                                                home_registration_id, home_bye, away_registration_id, away_bye,
                                                next_fixture_id, next_slot)
        values (p_tournament_id, r, v_round, m,
                case when r = 1 and 2 * m - 1 <= v_n then v_ids[2 * m - 1] end,
                r = 1 and 2 * m - 1 > v_n,
                case when r = 1 and 2 * m <= v_n then v_ids[2 * m] end,
                r = 1 and 2 * m > v_n,
                (select f.id from public.tournament_fixtures f
                  where f.tournament_id = p_tournament_id and f.round_no = r + 1 and f.match_no = (m + 1) / 2),
                case when r < v_rounds then case when m % 2 = 1 then 'home' else 'away' end end);
      end loop;
    end loop;
    perform public.tournament_advance_byes(p_tournament_id);
  end if;

  update public.tournaments t
     set status = 'registration_closed', fixtures_generated_at = now(), updated_at = now()
   where t.id = p_tournament_id;

  -- The draw is fixed: entries still waiting are turned down.
  for v_reg in
    update public.tournament_registrations r0
       set status = 'rejected', decided_at = now(), decided_by = v_uid
     where r0.tournament_id = p_tournament_id and r0.status = 'pending'
    returning r0.id, r0.club_id, r0.team_name
  loop
    perform public.notification_add(
              (select c.owner_id from public.clubs c where c.id = v_reg.club_id), 'club_owner',
              'tournament_registration_rejected', 'tournament:decision:' || v_reg.id,
              jsonb_build_object('tournament_id', v_t.id, 'tournament_name', v_t.name, 'organizer_name', v_org.name,
                                 'team_name', v_reg.team_name, 'start_date', v_t.start_date),
              v_reg.club_id, null, v_reg.id, null);
  end loop;
  for v_reg in
    select r0.id, r0.club_id, r0.team_name from public.tournament_registrations r0
     where r0.tournament_id = p_tournament_id and r0.status = 'approved'
  loop
    perform public.notification_add(
              (select c.owner_id from public.clubs c where c.id = v_reg.club_id), 'club_owner',
              'tournament_fixtures_published', 'tournament:fixtures:' || p_tournament_id || ':' || v_reg.id,
              jsonb_build_object('tournament_id', v_t.id, 'tournament_name', v_t.name, 'organizer_name', v_org.name,
                                 'team_name', v_reg.team_name, 'start_date', v_t.start_date,
                                 'round_name', (select f.round_name from public.tournament_fixtures f
                                                 where f.tournament_id = p_tournament_id and f.round_no = 1 limit 1)),
              v_reg.club_id, null, p_tournament_id, null);
  end loop;

  return query select 'generated'::text,
                      (select count(*)::integer from public.tournament_fixtures f where f.tournament_id = p_tournament_id);
end;
$$;

-- Fixtures tab: every fixture in draw order, for any signed-in user (BYE
-- walkovers included: state 'walkover'; the app hides them). A side is an
-- entry (…_registration_id + …_name = the club's name), a BYE (…_bye) or
-- TBD (both NULL / false). state: tbd | ready | walkover | completed.
create function public.tournament_fixtures(p_tournament_id uuid)
returns table (
  fixture_id             uuid,
  round_no               integer,
  round_name             text,
  match_no               integer,
  home_registration_id   uuid,
  home_club_id           uuid,
  home_name              text,
  home_bye               boolean,
  away_registration_id   uuid,
  away_club_id           uuid,
  away_name              text,
  away_bye               boolean,
  winner_registration_id uuid,
  winner_bye             boolean,
  state                  text,
  next_fixture_id        uuid,
  next_slot              text,
  match_id               uuid,
  decided_at             timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'tournament: not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.tournaments t where t.id = p_tournament_id) then
    raise exception 'tournament: not found' using errcode = 'P0002';
  end if;
  return query
    select f.id, f.round_no::integer, f.round_name, f.match_no::integer,
           f.home_registration_id, hr.club_id, hc.name, f.home_bye,
           f.away_registration_id, ar.club_id, ac.name, f.away_bye,
           f.winner_registration_id, f.winner_bye,
           case when f.decided_at is not null and (f.home_bye or f.away_bye) then 'walkover'
                when f.decided_at is not null then 'completed'
                when f.home_registration_id is not null and f.away_registration_id is not null then 'ready'
                else 'tbd' end,
           f.next_fixture_id, f.next_slot, f.match_id, f.decided_at
      from public.tournament_fixtures f
      left join public.tournament_registrations hr on hr.id = f.home_registration_id
      left join public.clubs hc on hc.id = hr.club_id
      left join public.tournament_registrations ar on ar.id = f.away_registration_id
      left join public.clubs ac on ac.id = ar.club_id
     where f.tournament_id = p_tournament_id
     order by f.round_no, f.match_no;
end;
$$;

-- Points Table: every confirmed team (zeros before any result), for any
-- signed-in user. Points (2 a win), then club name.
create function public.tournament_points_table(p_tournament_id uuid)
returns table (
  "position"      integer,
  registration_id uuid,
  club_id         uuid,
  club_name       text,
  team_name       text,
  played          integer,
  won             integer,
  lost            integer,
  points          integer
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'tournament: not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.tournaments t where t.id = p_tournament_id) then
    raise exception 'tournament: not found' using errcode = 'P0002';
  end if;
  return query select * from public.tournament_standings(p_tournament_id);
end;
$$;

-- Tournament Awards, from OFFICIAL scorecards only: the confirmed result
-- version (migrations 20–24) of every fixture linked to a match. No linked
-- official result = no rows (never invented figures). One row per award with
-- a value above 0: top_run_scorer (runs), top_wicket_taker (wickets),
-- best_keeper (catches + stumpings, by a squad wicket-keeper or anyone with a
-- stumping), best_fielder (catches). Players who hide their statistics
-- (profiles.show_stats = false) are left out. For the organizer's and the
-- confirmed clubs' owners and active members.
create function public.tournament_awards(p_tournament_id uuid)
returns table (
  award           text,
  registration_id uuid,
  club_id         uuid,
  club_name       text,
  member_id       uuid,
  player_name     text,
  value           integer,
  matches_counted integer
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_t   public.tournaments;
begin
  if v_uid is null then
    raise exception 'tournament: not authenticated' using errcode = '42501';
  end if;
  select * into v_t from public.tournaments t where t.id = p_tournament_id;
  if not found then
    raise exception 'tournament: not found' using errcode = 'P0002';
  end if;
  if not (public.is_club_owner(v_t.organizer_club_id) or public.is_active_club_member(v_t.organizer_club_id)
          or exists (select 1 from public.tournament_registrations r
                      where r.tournament_id = p_tournament_id and r.status = 'approved'
                        and (public.is_club_owner(r.club_id) or public.is_active_club_member(r.club_id)))) then
    raise exception 'tournament: not allowed' using errcode = '42501';
  end if;
  return query
    with official as (
      select f.match_id, mr.version
        from public.tournament_fixtures f
        join public.match_results mr on mr.match_id = f.match_id and mr.status = 'confirmed'
       where f.tournament_id = p_tournament_id and f.match_id is not null
    ), bat as (
      select b.member_id, sum(b.runs)::integer as v
        from official o
        join public.match_batting b on b.match_id = o.match_id and b.version = o.version
       where b.member_id is not null
       group by b.member_id
    ), bowl as (
      select w.member_id, sum(w.wickets)::integer as v
        from official o
        join public.match_bowling w on w.match_id = o.match_id and w.version = o.version
       where w.member_id is not null
       group by w.member_id
    ), fld as (
      select b.fielder_member_id as member_id,
             count(*) filter (where b.dismissal = 'caught')::integer as catches,
             count(*) filter (where b.dismissal = 'stumped')::integer as stumpings
        from official o
        join public.match_batting b on b.match_id = o.match_id and b.version = o.version
       where b.fielder_member_id is not null
       group by b.fielder_member_id
    ), keepers as (
      select rp.member_id
        from public.tournament_registration_players rp
        join public.tournament_registrations r on r.id = rp.registration_id
       where r.tournament_id = p_tournament_id and r.status = 'approved' and rp.is_wicket_keeper
    ), cand as (
      select 1 as o, 'top_run_scorer' as award, bat.member_id, bat.v from bat
      union all
      select 2, 'top_wicket_taker', bowl.member_id, bowl.v from bowl
      union all
      select 3, 'best_keeper', fld.member_id, fld.catches + fld.stumpings from fld
       where fld.stumpings > 0 or fld.member_id in (select keepers.member_id from keepers)
      union all
      select 4, 'best_fielder', fld.member_id, fld.catches from fld
    ), ranked as (
      select distinct on (cand.o) cand.o, cand.award, r.id as registration_id, c.id as club_id, c.name as club_name,
             cand.member_id, p.full_name, cand.v
        from cand
        join public.club_members m on m.id = cand.member_id
        join public.profiles p on p.id = m.user_id
        join public.tournament_registrations r
          on r.tournament_id = p_tournament_id and r.club_id = m.club_id and r.status = 'approved'
        join public.clubs c on c.id = r.club_id
       where cand.v > 0 and p.show_stats
       order by cand.o, cand.v desc, p.full_name, cand.member_id
    )
    select ranked.award, ranked.registration_id, ranked.club_id, ranked.club_name, ranked.member_id,
           ranked.full_name, ranked.v, (select count(*)::integer from official)
      from ranked
     order by ranked.o;
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. The trusted scorer's write (service_role only; never the app)
-- ---------------------------------------------------------------------------
-- Records the winner of a READY fixture (both sides known, not yet decided):
-- one of its two entries. p_match_id (optional) links the official match it
-- was played as: a match between exactly these two clubs, not linked to
-- another fixture, with a CONFIRMED result whose winner (if it has one) is
-- the same club. The winner moves on (knockout: BYEs resolved again); the
-- tournament completes with its champion (knockout: the Final's winner;
-- league: the top of the points table once every fixture is decided).
-- Repeating the same call changes nothing; a different winner for a decided
-- fixture is refused. Called by the scorer Edge Function (not built yet)
-- with the service key; EXECUTE is granted to service_role only.
create function public.record_tournament_fixture_result(
  p_fixture_id             uuid,
  p_winner_registration_id uuid,
  p_match_id               uuid default null
)
returns table (fixture_id uuid, tournament_status text, champion_registration_id uuid)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_tid      uuid;
  v_t        public.tournaments;
  v_f        public.tournament_fixtures;
  v_match    public.matches;
  v_outcome  text;
  v_winclub  uuid;
  v_homeclub uuid;
  v_awayclub uuid;
  v_champion uuid;
begin
  select f.tournament_id into v_tid from public.tournament_fixtures f where f.id = p_fixture_id;
  if v_tid is null then
    raise exception 'tournament: fixture not found' using errcode = 'P0002';
  end if;
  select * into v_t from public.tournaments t where t.id = v_tid for update;
  select * into v_f from public.tournament_fixtures f where f.id = p_fixture_id for update;
  if v_f.decided_at is not null then
    if v_f.winner_registration_id is not distinct from p_winner_registration_id and not v_f.winner_bye
       and (p_match_id is null or p_match_id is not distinct from v_f.match_id) then
      return query select v_f.id, v_t.status, v_t.winner_registration_id;
      return;
    end if;
    raise exception 'tournament: fixture already decided' using errcode = 'P0001';
  end if;
  if v_f.home_registration_id is null or v_f.away_registration_id is null then
    raise exception 'tournament: fixture not ready' using errcode = 'P0001';
  end if;
  if p_winner_registration_id is null
     or p_winner_registration_id not in (v_f.home_registration_id, v_f.away_registration_id) then
    raise exception 'tournament: invalid winner' using errcode = '22023';
  end if;
  if p_match_id is not null then
    select r.club_id into v_homeclub from public.tournament_registrations r where r.id = v_f.home_registration_id;
    select r.club_id into v_awayclub from public.tournament_registrations r where r.id = v_f.away_registration_id;
    select * into v_match from public.matches mt where mt.id = p_match_id;
    if not found
       or not ((v_match.club_a_id = v_homeclub and v_match.club_b_id = v_awayclub)
               or (v_match.club_a_id = v_awayclub and v_match.club_b_id = v_homeclub)) then
      raise exception 'tournament: invalid match' using errcode = '22023';
    end if;
    if exists (select 1 from public.tournament_fixtures f where f.match_id = p_match_id) then
      raise exception 'tournament: match already linked' using errcode = 'P0001';
    end if;
    select mr.outcome into v_outcome from public.match_results mr
     where mr.match_id = p_match_id and mr.status = 'confirmed';
    if v_outcome is null then
      raise exception 'tournament: no official result' using errcode = 'P0001';
    end if;
    select r.club_id into v_winclub from public.tournament_registrations r where r.id = p_winner_registration_id;
    if (v_outcome = 'club_a_won' and v_winclub <> v_match.club_a_id)
       or (v_outcome = 'club_b_won' and v_winclub <> v_match.club_b_id) then
      raise exception 'tournament: winner differs from the official result' using errcode = 'P0001';
    end if;
    update public.tournament_fixtures f set match_id = p_match_id where f.id = p_fixture_id;
  end if;

  perform public.tournament_fixture_decide(p_fixture_id, p_winner_registration_id, false);
  if v_t.tournament_type = 'knockout' then
    perform public.tournament_advance_byes(v_tid);
    select f.winner_registration_id into v_champion from public.tournament_fixtures f
     where f.tournament_id = v_tid and f.decided_at is not null
       and f.round_no = (select max(f2.round_no) from public.tournament_fixtures f2 where f2.tournament_id = v_tid);
  elsif not exists (select 1 from public.tournament_fixtures f where f.tournament_id = v_tid and f.decided_at is null) then
    select s.registration_id into v_champion from public.tournament_standings(v_tid) s where s.position = 1;
  end if;
  if v_champion is not null then
    update public.tournaments t
       set status = 'completed', winner_registration_id = v_champion, completed_at = now(), updated_at = now()
     where t.id = v_tid;
  end if;

  return query select p_fixture_id, t.status, t.winner_registration_id from public.tournaments t where t.id = v_tid;
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. Privileges: signed-in users only; the scorer write to service_role; the
--    helpers to nobody
-- ---------------------------------------------------------------------------
revoke execute on function public.tournament_registrations_validate() from public, anon, authenticated, service_role;
revoke execute on function public.tournament_registration_players_validate() from public, anon, authenticated, service_role;
revoke execute on function public.tournament_status_now(text, date) from public, anon, authenticated, service_role;
revoke execute on function public.tournament_list(uuid, uuid, uuid, boolean, text) from public, anon, authenticated, service_role;
revoke execute on function public.tournament_registration_rows(uuid, uuid, uuid) from public, anon, authenticated, service_role;
revoke execute on function public.tournament_fixture_decide(uuid, uuid, boolean) from public, anon, authenticated, service_role;
revoke execute on function public.tournament_advance_byes(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.tournament_standings(uuid) from public, anon, authenticated, service_role;

revoke execute on function public.create_tournament(uuid, text, text, text, text, integer, text, date, date, date, integer,
                                                    integer, integer, text, text[]) from public, anon;
revoke execute on function public.my_hosted_tournaments(uuid) from public, anon;
revoke execute on function public.browse_tournaments(text) from public, anon;
revoke execute on function public.tournament_detail(uuid) from public, anon;
revoke execute on function public.tournament_hub_stats(uuid) from public, anon;
revoke execute on function public.tournament_teams(uuid) from public, anon;
revoke execute on function public.tournament_registration_squad(uuid) from public, anon;
revoke execute on function public.submit_tournament_registration(uuid, uuid, text, uuid, jsonb, uuid, uuid, uuid, boolean)
  from public, anon;
revoke execute on function public.decide_tournament_registration(uuid, boolean) from public, anon;
revoke execute on function public.remove_tournament_team(uuid) from public, anon;
revoke execute on function public.my_tournament_registrations(uuid, text) from public, anon;
revoke execute on function public.generate_tournament_fixtures(uuid) from public, anon;
revoke execute on function public.tournament_fixtures(uuid) from public, anon;
revoke execute on function public.tournament_points_table(uuid) from public, anon;
revoke execute on function public.tournament_awards(uuid) from public, anon;
revoke execute on function public.record_tournament_fixture_result(uuid, uuid, uuid) from public, anon, authenticated;

grant execute on function public.create_tournament(uuid, text, text, text, text, integer, text, date, date, date, integer,
                                                   integer, integer, text, text[]) to authenticated;
grant execute on function public.my_hosted_tournaments(uuid) to authenticated;
grant execute on function public.browse_tournaments(text) to authenticated;
grant execute on function public.tournament_detail(uuid) to authenticated;
grant execute on function public.tournament_hub_stats(uuid) to authenticated;
grant execute on function public.tournament_teams(uuid) to authenticated;
grant execute on function public.tournament_registration_squad(uuid) to authenticated;
grant execute on function public.submit_tournament_registration(uuid, uuid, text, uuid, jsonb, uuid, uuid, uuid, boolean)
  to authenticated;
grant execute on function public.decide_tournament_registration(uuid, boolean) to authenticated;
grant execute on function public.remove_tournament_team(uuid) to authenticated;
grant execute on function public.my_tournament_registrations(uuid, text) to authenticated;
grant execute on function public.generate_tournament_fixtures(uuid) to authenticated;
grant execute on function public.tournament_fixtures(uuid) to authenticated;
grant execute on function public.tournament_points_table(uuid) to authenticated;
grant execute on function public.tournament_awards(uuid) to authenticated;
grant execute on function public.record_tournament_fixture_result(uuid, uuid, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 10. Self-check (raises — rolling everything back — on any mismatch)
-- ---------------------------------------------------------------------------
do $$
declare
  v_fn  regprocedure;
  v_tbl regclass;
begin
  foreach v_tbl in array array['public.tournaments', 'public.tournament_registrations',
                               'public.tournament_registration_players', 'public.tournament_fixtures']::regclass[] loop
    if not (select c.relrowsecurity from pg_class c where c.oid = v_tbl)
       or exists (select 1 from pg_policy pol where pol.polrelid = v_tbl)
       or has_table_privilege('anon', v_tbl, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
       or has_table_privilege('authenticated', v_tbl, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
       or has_table_privilege('service_role', v_tbl, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') then
      raise exception 'migration 35 self-check: % is not closed (RLS on, no policy, no grant)', v_tbl;
    end if;
  end loop;
  foreach v_fn in array array[
      'public.create_tournament(uuid, text, text, text, text, integer, text, date, date, date, integer, integer, integer, text, text[])',
      'public.my_hosted_tournaments(uuid)', 'public.browse_tournaments(text)', 'public.tournament_detail(uuid)',
      'public.tournament_hub_stats(uuid)', 'public.tournament_teams(uuid)', 'public.tournament_registration_squad(uuid)',
      'public.submit_tournament_registration(uuid, uuid, text, uuid, jsonb, uuid, uuid, uuid, boolean)',
      'public.decide_tournament_registration(uuid, boolean)', 'public.remove_tournament_team(uuid)',
      'public.my_tournament_registrations(uuid, text)', 'public.generate_tournament_fixtures(uuid)',
      'public.tournament_fixtures(uuid)', 'public.tournament_points_table(uuid)',
      'public.tournament_awards(uuid)']::regprocedure[] loop
    if not has_function_privilege('authenticated', v_fn, 'execute') or has_function_privilege('anon', v_fn, 'execute')
       or (select not p.prosecdef or array_to_string(p.proconfig, ',') <> 'search_path=""' from pg_proc p where p.oid = v_fn) then
      raise exception 'migration 35 self-check: % privileges / properties', v_fn;
    end if;
  end loop;
  v_fn := 'public.record_tournament_fixture_result(uuid, uuid, uuid)'::regprocedure;
  if not has_function_privilege('service_role', v_fn, 'execute') or has_function_privilege('authenticated', v_fn, 'execute')
     or has_function_privilege('anon', v_fn, 'execute')
     or (select not p.prosecdef or array_to_string(p.proconfig, ',') <> 'search_path=""' from pg_proc p where p.oid = v_fn) then
    raise exception 'migration 35 self-check: record_tournament_fixture_result must be service_role only';
  end if;
  foreach v_fn in array array['public.tournament_registrations_validate()', 'public.tournament_registration_players_validate()',
                              'public.tournament_status_now(text, date)',
                              'public.tournament_list(uuid, uuid, uuid, boolean, text)',
                              'public.tournament_registration_rows(uuid, uuid, uuid)',
                              'public.tournament_fixture_decide(uuid, uuid, boolean)',
                              'public.tournament_advance_byes(uuid)', 'public.tournament_standings(uuid)']::regprocedure[] loop
    if has_function_privilege('authenticated', v_fn, 'execute') or has_function_privilege('anon', v_fn, 'execute')
       or has_function_privilege('service_role', v_fn, 'execute')
       or (select p.prosecdef or array_to_string(p.proconfig, ',') <> 'search_path=""' from pg_proc p where p.oid = v_fn) then
      raise exception 'migration 35 self-check: helper % is callable by an API role', v_fn;
    end if;
  end loop;
  if public.notification_category('tournament_registration_received') <> 'join_requests'
     or public.notification_category('tournament_registration_approved') <> 'challenges'
     or public.notification_category('tournament_registration_rejected') <> 'challenges'
     or public.notification_category('tournament_team_removed') <> 'challenges'
     or public.notification_category('tournament_fixtures_published') <> 'matches'
     or public.notification_category('hunt_interest_received') <> 'join_requests'
     or public.notification_category('hunt_invite_received') <> 'membership'
     or public.notification_category('join_request_received') <> 'join_requests'
     or public.notification_category('match_reminder') <> 'matches'
     or public.notification_category('challenge_expiring') <> 'challenges'
     or public.notification_category('announcement') <> 'announcements'
     or public.notification_category('result_published') <> 'results'
     or public.notification_category('ownership_expiring') <> 'membership'
     or has_function_privilege('authenticated', 'public.notification_category(text)', 'execute')
     or has_function_privilege('anon', 'public.notification_category(text)', 'execute') then
    raise exception 'migration 35 self-check: notification_category';
  end if;
  if (select array_length(regexp_split_to_array(pg_get_constraintdef(k.oid), '::text'), 1) - 1
        from pg_constraint k
       where k.conrelid = 'public.notifications'::regclass and k.conname = 'notifications_type_check') <> 34
     or not exists (select 1 from pg_constraint k
                     where k.conrelid = 'public.notifications'::regclass and k.conname = 'notifications_type_check'
                       and k.convalidated
                       and pg_get_constraintdef(k.oid) like '%''announcement''%''hunt_invite_accepted''%''tournament_registration_received''%''tournament_registration_approved''%''tournament_registration_rejected''%''tournament_team_removed''%''tournament_fixtures_published''%') then
    raise exception 'migration 35 self-check: notifications_type_check (34 types)';
  end if;
  if (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p
       where p.oid = 'public.notification_add(uuid, text, text, text, jsonb, uuid, uuid, uuid, uuid)'::regprocedure)
       <> 'a6fc6bc7e42b161bc56a5b1ef9f8aa68' then
    raise exception 'migration 35 self-check: notification_add changed';
  end if;
  if pg_get_function_result('public.my_hosted_tournaments(uuid)'::regprocedure)
       <> pg_get_function_result('public.tournament_detail(uuid)'::regprocedure)
     or pg_get_function_result('public.browse_tournaments(text)'::regprocedure)
       <> pg_get_function_result('public.tournament_detail(uuid)'::regprocedure)
     or pg_get_function_result('public.create_tournament(uuid, text, text, text, text, integer, text, date, date, date, integer, integer, integer, text, text[])'::regprocedure)
       <> pg_get_function_result('public.tournament_detail(uuid)'::regprocedure)
     or pg_get_function_result('public.submit_tournament_registration(uuid, uuid, text, uuid, jsonb, uuid, uuid, uuid, boolean)'::regprocedure)
       <> pg_get_function_result('public.tournament_teams(uuid)'::regprocedure)
     or pg_get_function_result('public.decide_tournament_registration(uuid, boolean)'::regprocedure)
       <> pg_get_function_result('public.tournament_teams(uuid)'::regprocedure)
     or pg_get_function_result('public.remove_tournament_team(uuid)'::regprocedure)
       <> pg_get_function_result('public.tournament_teams(uuid)'::regprocedure) then
    raise exception 'migration 35 self-check: result types differ';
  end if;
end $$;

notify pgrst, 'reload schema';
