-- CricEco · migration 33 · M8 Player Hunt / Playing Opportunities
--
-- NOT APPLIED. Requires migrations 1–31 (NOT migration 32: independent of
-- it). Review first; apply only with separate approval, after a fresh
-- backup, inside
--   begin; set local lock_timeout = '5s'; <this file> commit;
-- Rollback: supabase/rollback/20261126_rollback_m8_player_hunt.sql.
-- Read-only check: supabase/tests/33_m8_player_hunt_postcheck.sql.
-- Local test: supabase/tests/local/28_m8_player_hunt_local_check.sql.
-- Design and app contract: docs/M8_PLAYER_HUNT.md.
--
-- What changes (one transaction):
--   1. Four tables, RLS on with NO policy and NO grant to any API role
--      (written and read only through the functions below):
--        hunt_listings  — a player's "open to offers" listing (one per user);
--        hunt_posts     — a club's player requirement (Find Players);
--        hunt_interests — "I'm Interested" (one per post and player);
--        hunt_invites   — a club's invite to a player (one pending per club
--                         and player).
--      Deleting a profile deletes its listing, interests and invites;
--      deleting a club deletes its posts (with their interests) and invites.
--   2. Functions for signed-in users only (SECURITY DEFINER, empty
--      search_path, auth.uid(); club owner = clubs.owner_id = auth.uid()):
--        my_hunt_listing, set_my_hunt_listing,
--        publish_hunt_post, close_hunt_post, club_hunt_posts, hunt_open_posts,
--        express_hunt_interest, withdraw_hunt_interest, club_hunt_interests,
--        hunt_open_players,
--        invite_hunt_player, club_hunt_invites, my_hunt_invites,
--        respond_hunt_invite.
--      Plus three internal helpers no API role may call (hunt_role_of,
--      hunt_player_stats, hunt_post_list).
--   3. Notifications: three new types through the existing internal
--      notification_add (migration 26, unchanged):
--        hunt_invite_received   → the player   (inbox "player",     category membership: always on)
--        hunt_interest_received → club owner   (inbox "club_owner", category join_requests)
--        hunt_invite_accepted   → club owner   (inbox "club_owner", category join_requests)
--      notifications_type_check keeps every existing type and gains these
--      three; notification_category (migration 28's body) gains the two
--      join_requests mappings. Push text: push-dispatch/templates.ts.
-- Accepting an invite never makes anyone a club member: joining stays the
-- existing join-by-code flow. No existing row is changed or deleted;
-- delete_account_data is unchanged (the foreign keys cascade).

do $$
begin
  if to_regclass('public.hunt_listings') is not null or to_regclass('public.hunt_posts') is not null
     or to_regclass('public.hunt_interests') is not null or to_regclass('public.hunt_invites') is not null
     or exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public'
                   and p.proname in ('my_hunt_listing', 'set_my_hunt_listing', 'publish_hunt_post', 'close_hunt_post',
                                     'club_hunt_posts', 'hunt_open_posts', 'express_hunt_interest',
                                     'withdraw_hunt_interest', 'club_hunt_interests', 'hunt_open_players',
                                     'invite_hunt_player', 'club_hunt_invites', 'my_hunt_invites',
                                     'respond_hunt_invite', 'hunt_role_of', 'hunt_player_stats', 'hunt_post_list'))
     or exists (select 1 from pg_constraint k
                 where k.conrelid = 'public.notifications'::regclass and k.conname = 'notifications_type_check'
                   and pg_get_constraintdef(k.oid) like '%hunt_%') then
    raise exception 'migration 33: already applied (or a name is taken) — nothing changed';
  end if;
  if to_regprocedure('public.set_my_avatar(text)') is null
     or (select count(*) from information_schema.columns
          where table_schema = 'public' and table_name = 'profiles'
            and column_name in ('avatar_path', 'public_profile', 'show_stats', 'share_phone_with_clubs')) <> 4
     or (select count(*) from information_schema.columns
          where table_schema = 'public' and table_name = 'clubs' and column_name = 'logo_path') <> 1
     or to_regclass('public.push_token_moves') is null
     or to_regprocedure('public.member_stats(uuid[])') is null
     or to_regprocedure('public.notification_add(uuid, text, text, text, jsonb, uuid, uuid, uuid, uuid)') is null then
    raise exception 'migration 33: migrations 1–31 are required';
  end if;
  -- What this migration replaces or relies on must be exactly migrations
  -- 26 / 28's (the rollback restores the type list and category verbatim).
  -- Line endings ignored.
  if (select md5(pg_get_constraintdef(k.oid)) from pg_constraint k
       where k.conrelid = 'public.notifications'::regclass and k.conname = 'notifications_type_check')
       is distinct from '6e21473f70979b51955fa439baac82d0'
     or (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p
          where p.oid = 'public.notification_category(text)'::regprocedure) <> '7945e3ba106695803d3b2fe3c386c207'
     or (select md5(replace(p.prosrc, chr(13), '')) || p.prosecdef::text from pg_proc p
          where p.oid = 'public.notification_add(uuid, text, text, text, jsonb, uuid, uuid, uuid, uuid)'::regprocedure)
        <> 'a6fc6bc7e42b161bc56a5b1ef9f8aa68true'
     or (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p
          where p.oid = 'public.notification_muted(uuid, text)'::regprocedure) <> 'c436f7ccbcfeecd1cd5bc67771e3334e' then
    raise exception 'migration 33: the notification type list / notification_category / notification_add / notification_muted differs from migrations 26 / 28 — nothing changed';
  end if;
end $$;

-- Codes (shared by the tables and functions):
--   role    batsman | bowler | all_rounder | wicket_keeper
--   format  t20 | t10 | odi | test | custom
--   budget  any | under_2000 | from_2000_to_5000 | over_5000
-- Errors: prefix "hunt:"; 42501 not authenticated / not allowed, 22023
-- invalid input, P0002 not found, P0001 a rule (limits, state).

-- ---------------------------------------------------------------------------
-- 1. Tables (closed: no policy, no grant; the functions below only)
-- ---------------------------------------------------------------------------
create table public.hunt_listings (
  user_id    uuid
             constraint hunt_listings_pkey primary key
             constraint hunt_listings_user_id_fkey references public.profiles (id) on delete cascade,
  listed     boolean not null default false,
  role       text not null
             constraint hunt_listings_role_check
             check (role in ('batsman', 'bowler', 'all_rounder', 'wicket_keeper')),
  city       text not null
             constraint hunt_listings_city_check check (char_length(btrim(city)) between 1 and 100),
  -- When the player last turned the listing on (NULL: never listed).
  listed_at  timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index hunt_listings_listed_idx on public.hunt_listings (role, lower(city)) where listed;

comment on table public.hunt_listings is
  'Migration 33 (M8): a player''s "open to offers" listing. Closed table: set_my_hunt_listing / my_hunt_listing / hunt_open_players only.';

create table public.hunt_posts (
  id             uuid primary key default gen_random_uuid(),
  club_id        uuid not null
                 constraint hunt_posts_club_id_fkey references public.clubs (id) on delete cascade,
  created_by     uuid
                 constraint hunt_posts_created_by_fkey references public.profiles (id) on delete set null,
  role           text not null
                 constraint hunt_posts_role_check
                 check (role in ('batsman', 'bowler', 'all_rounder', 'wicket_keeper')),
  format         text not null
                 constraint hunt_posts_format_check check (format in ('t20', 't10', 'odi', 'test', 'custom')),
  players_needed smallint not null
                 constraint hunt_posts_players_needed_check check (players_needed between 1 and 11),
  -- NULL = any location ("All").
  city           text
                 constraint hunt_posts_city_check check (city is null or char_length(btrim(city)) between 1 and 100),
  -- NULL = flexible / anytime.
  match_date     date,
  match_time     time without time zone,
  budget         text not null default 'any'
                 constraint hunt_posts_budget_check
                 check (budget in ('any', 'under_2000', 'from_2000_to_5000', 'over_5000')),
  notes          text not null default ''
                 constraint hunt_posts_notes_check check (char_length(notes) <= 280),
  -- Stored: open | closed. "expired" is derived on read (open and past expires_at).
  status         text not null default 'open'
                 constraint hunt_posts_status_check check (status in ('open', 'closed')),
  expires_at     timestamptz not null,
  closed_at      timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint hunt_posts_closed_follows_status check ((status = 'closed') = (closed_at is not null)),
  constraint hunt_posts_expiry_after_creation check (expires_at > created_at)
);

create index hunt_posts_club_created_idx on public.hunt_posts (club_id, created_at desc);
create index hunt_posts_open_idx on public.hunt_posts (role, expires_at) where status = 'open';
create index hunt_posts_created_by_idx on public.hunt_posts (created_by) where created_by is not null;

comment on table public.hunt_posts is
  'Migration 33 (M8): a club''s player requirement. Closed table: publish_hunt_post / close_hunt_post / club_hunt_posts / hunt_open_posts only.';

create table public.hunt_interests (
  id         uuid primary key default gen_random_uuid(),
  post_id    uuid not null
             constraint hunt_interests_post_id_fkey references public.hunt_posts (id) on delete cascade,
  user_id    uuid not null
             constraint hunt_interests_user_id_fkey references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint hunt_interests_post_user_key unique (post_id, user_id)
);

create index hunt_interests_user_created_idx on public.hunt_interests (user_id, created_at desc);

comment on table public.hunt_interests is
  'Migration 33 (M8): "I''m Interested" on a hunt post, one per post and player. Closed table: express / withdraw_hunt_interest, club_hunt_interests only.';

create table public.hunt_invites (
  id           uuid primary key default gen_random_uuid(),
  club_id      uuid not null
               constraint hunt_invites_club_id_fkey references public.clubs (id) on delete cascade,
  user_id      uuid not null
               constraint hunt_invites_user_id_fkey references public.profiles (id) on delete cascade,
  invited_by   uuid
               constraint hunt_invites_invited_by_fkey references public.profiles (id) on delete set null,
  -- The requirement it is about, if any (the invite stays when it goes).
  post_id      uuid
               constraint hunt_invites_post_id_fkey references public.hunt_posts (id) on delete set null,
  -- pending → accepted | declined; a pending invite past expires_at is
  -- expired (stored as such when the club invites the player again).
  status       text not null default 'pending'
               constraint hunt_invites_status_check check (status in ('pending', 'accepted', 'declined', 'expired')),
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null default (now() + interval '14 days'),
  responded_at timestamptz,
  constraint hunt_invites_responded_follows_status
    check ((status in ('accepted', 'declined')) = (responded_at is not null)),
  constraint hunt_invites_expiry_after_creation check (expires_at > created_at),
  constraint hunt_invites_not_self check (invited_by is null or invited_by <> user_id)
);

create unique index hunt_invites_one_pending_idx on public.hunt_invites (club_id, user_id) where status = 'pending';
create index hunt_invites_club_created_idx on public.hunt_invites (club_id, created_at desc);
create index hunt_invites_user_created_idx on public.hunt_invites (user_id, created_at desc);
create index hunt_invites_invited_by_idx on public.hunt_invites (invited_by) where invited_by is not null;
create index hunt_invites_post_id_idx on public.hunt_invites (post_id) where post_id is not null;

comment on table public.hunt_invites is
  'Migration 33 (M8): a club''s invite to a player. Accepting never joins the club. Closed table: invite_hunt_player / club_hunt_invites / my_hunt_invites / respond_hunt_invite only.';

alter table public.hunt_listings enable row level security;
alter table public.hunt_posts enable row level security;
alter table public.hunt_interests enable row level security;
alter table public.hunt_invites enable row level security;

revoke all on table public.hunt_listings, public.hunt_posts, public.hunt_interests, public.hunt_invites
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. Notifications: three types, two of them in "join_requests"
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
    'hunt_invite_received', 'hunt_interest_received', 'hunt_invite_accepted'));

-- hunt_invite_received stays in the else branch (membership, always on):
-- only players who listed themselves (or showed interest in that club's
-- post) can be invited, and unlisting stops new invites.
create or replace function public.notification_category(p_type text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
           when p_type in ('join_request_received', 'hunt_interest_received', 'hunt_invite_accepted') then 'join_requests'
           when p_type in ('challenge_received', 'challenge_accepted', 'challenge_declined',
                           'schedule_proposed', 'schedule_accepted', 'schedule_declined',
                           'challenge_expiring') then 'challenges'
           when p_type in ('lineup_selected', 'lineup_changed', 'lineup_dropped',
                           'match_rescheduled', 'match_cancelled', 'match_reminder') then 'matches'
           when p_type in ('result_published', 'result_corrected', 'player_of_match') then 'results'
           when p_type = 'announcement' then 'announcements'
           else 'membership'
         end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Internal helpers (no API role may call them)
-- ---------------------------------------------------------------------------
-- A player's hunt role from their cricket profile (NULL without one).
create function public.hunt_role_of(p_user_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  select case when pp.is_wicketkeeper then 'wicket_keeper' else pp.player_role end
    from public.player_profiles pp
   where pp.user_id = p_user_id;
$$;

-- A player's official career figures (migration 22: confirmed results,
-- every membership). The callers show them only when show_stats is on.
create function public.hunt_player_stats(p_user_id uuid)
returns table (
  matches         integer,
  runs            integer,
  batting_average numeric,
  strike_rate     numeric,
  wickets         integer,
  economy         numeric
)
language sql
stable
set search_path = ''
as $$
  select s.matches, s.runs, s.batting_average, s.strike_rate, s.wickets, s.economy
    from public.member_stats(coalesce((select array_agg(m.id) from public.club_members m
                                        where m.user_id = p_user_id), '{}'::uuid[])) s;
$$;

-- Hunt posts as the app shows them, for [p_viewer]. Filters: one club, one
-- post, open only (else: open ones and the last 90 days), role, city (a
-- post for any location always matches a city).
create function public.hunt_post_list(
  p_viewer    uuid,
  p_club_id   uuid,
  p_post_id   uuid,
  p_open_only boolean,
  p_role      text,
  p_city      text
)
returns table (
  post_id         uuid,
  club_id         uuid,
  club_name       text,
  club_short_name text,
  club_city       text,
  club_logo_path  text,
  role            text,
  format          text,
  players_needed  integer,
  city            text,
  match_date      date,
  match_time      text,
  budget          text,
  notes           text,
  status          text,
  created_at      timestamptz,
  expires_at      timestamptz,
  is_my_club      boolean,
  interested      boolean,
  interest_count  integer
)
language sql
stable
set search_path = ''
as $$
  select h.id, c.id, c.name, c.short_name, c.city, c.logo_path,
         h.role, h.format, h.players_needed::integer, h.city, h.match_date, to_char(h.match_time, 'HH24:MI'),
         h.budget, h.notes,
         case when h.status = 'open' and h.expires_at <= now() then 'expired' else h.status end,
         h.created_at, h.expires_at,
         c.owner_id = p_viewer,
         exists (select 1 from public.hunt_interests i where i.post_id = h.id and i.user_id = p_viewer),
         case when c.owner_id = p_viewer
              then (select count(*)::integer from public.hunt_interests i where i.post_id = h.id) end
    from public.hunt_posts h
    join public.clubs c on c.id = h.club_id
   where (p_club_id is null or h.club_id = p_club_id)
     and (p_post_id is null or h.id = p_post_id)
     and (case when p_open_only then h.status = 'open' and h.expires_at > now()
               else p_post_id is not null or (h.status = 'open' and h.expires_at > now())
                    or h.created_at > now() - interval '90 days' end)
     and (p_role is null or h.role = p_role)
     and (p_city is null or h.city is null or lower(h.city) = lower(p_city))
   order by h.created_at desc, h.id
   limit 200;
$$;

-- ---------------------------------------------------------------------------
-- 4. The player's listing ("Available for Playing Opportunities" /
--    "Open for Matches" / "List me as available to other clubs")
-- ---------------------------------------------------------------------------
-- One row, also before anything was saved (listed = false; role and city
-- then come from the cricket profile and current address). visible = clubs
-- can see the player now (listed and Privacy → public profile on).
create function public.my_hunt_listing()
returns table (
  listed     boolean,
  role       text,
  city       text,
  listed_at  timestamptz,
  updated_at timestamptz,
  visible    boolean
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
    raise exception 'hunt: not authenticated' using errcode = '42501';
  end if;
  return query
    select coalesce(l.listed, false), coalesce(l.role, public.hunt_role_of(p.id)), coalesce(l.city, a.city),
           l.listed_at, l.updated_at, coalesce(l.listed, false) and p.public_profile
      from public.profiles p
      left join public.hunt_listings l on l.user_id = p.id
      left join public.current_addresses a on a.user_id = p.id
     where p.id = v_uid;
  if not found then
    raise exception 'hunt: profile not found' using errcode = 'P0002';
  end if;
end;
$$;

-- Turn the listing on / off. Role and city: NULL = keep the saved one, or
-- (first time) take the cricket profile's role and the current address's
-- city. Listing on needs a cricket profile and a city. Returns
-- my_hunt_listing().
create function public.set_my_hunt_listing(p_listed boolean, p_role text default null, p_city text default null)
returns table (
  listed     boolean,
  role       text,
  city       text,
  listed_at  timestamptz,
  updated_at timestamptz,
  visible    boolean
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid  uuid := auth.uid();
  v_city text := nullif(regexp_replace(btrim(coalesce(p_city, '')), '\s+', ' ', 'g'), '');
  v_role text;
  v_old  public.hunt_listings;
begin
  if v_uid is null then
    raise exception 'hunt: not authenticated' using errcode = '42501';
  end if;
  if p_listed is null then
    raise exception 'hunt: invalid listing' using errcode = '22023';
  end if;
  if p_role is not null and p_role not in ('batsman', 'bowler', 'all_rounder', 'wicket_keeper') then
    raise exception 'hunt: invalid role' using errcode = '22023';
  end if;
  if v_city is not null and char_length(v_city) > 100 then
    raise exception 'hunt: invalid city' using errcode = '22023';
  end if;
  perform 1 from public.profiles p where p.id = v_uid for update;
  if not found then
    raise exception 'hunt: profile not found' using errcode = 'P0002';
  end if;
  if p_listed and not exists (select 1 from public.player_profiles pp where pp.user_id = v_uid) then
    raise exception 'hunt: player profile required' using errcode = 'P0001';
  end if;

  select * into v_old from public.hunt_listings l where l.user_id = v_uid;
  v_role := coalesce(p_role, v_old.role, public.hunt_role_of(v_uid));
  v_city := coalesce(v_city, v_old.city, (select a.city from public.current_addresses a where a.user_id = v_uid));
  if v_city is null then
    if p_listed then
      raise exception 'hunt: city required' using errcode = '22023';
    end if;
  elsif v_role is not null then
    insert into public.hunt_listings as l (user_id, listed, role, city, listed_at)
    values (v_uid, p_listed, v_role, v_city, case when p_listed then now() end)
    on conflict on constraint hunt_listings_pkey do update
       set listed = excluded.listed,
           role = excluded.role,
           city = excluded.city,
           listed_at = case when excluded.listed and not l.listed then now() else l.listed_at end,
           updated_at = now();
  end if;
  return query select * from public.my_hunt_listing();
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Club posts (Find Players → "Post Player Requirement")
-- ---------------------------------------------------------------------------
-- By the club's owner. p_match_time "HH:MM" (24 h). A dated post expires at
-- the end of that day (Pakistan time); an undated one after 30 days. At most
-- 10 open posts and 20 new ones per 24 hours per club; the same open
-- requirement twice is refused. Returns the post (club_hunt_posts' columns).
create function public.publish_hunt_post(
  p_club_id        uuid,
  p_role           text,
  p_format         text,
  p_players_needed integer,
  p_city           text default null,
  p_match_date     date default null,
  p_match_time     text default null,
  p_budget         text default 'any',
  p_notes          text default null
)
returns table (
  post_id         uuid,
  club_id         uuid,
  club_name       text,
  club_short_name text,
  club_city       text,
  club_logo_path  text,
  role            text,
  format          text,
  players_needed  integer,
  city            text,
  match_date      date,
  match_time      text,
  budget          text,
  notes           text,
  status          text,
  created_at      timestamptz,
  expires_at      timestamptz,
  is_my_club      boolean,
  interested      boolean,
  interest_count  integer
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_club  public.clubs;
  v_city  text := nullif(regexp_replace(btrim(coalesce(p_city, '')), '\s+', ' ', 'g'), '');
  v_notes text := btrim(coalesce(p_notes, ''));
  v_today date := (now() at time zone 'Asia/Karachi')::date;
  v_time  time;
  v_id    uuid;
begin
  if v_uid is null then
    raise exception 'hunt: not authenticated' using errcode = '42501';
  end if;
  -- The club row lock serializes the owner's publishes (the limits).
  select * into v_club from public.clubs c where c.id = p_club_id for update;
  if not found or v_club.owner_id is distinct from v_uid then
    raise exception 'hunt: not allowed' using errcode = '42501';
  end if;
  if p_role is null or p_role not in ('batsman', 'bowler', 'all_rounder', 'wicket_keeper') then
    raise exception 'hunt: invalid role' using errcode = '22023';
  end if;
  if p_format is null or p_format not in ('t20', 't10', 'odi', 'test', 'custom') then
    raise exception 'hunt: invalid format' using errcode = '22023';
  end if;
  if p_players_needed is null or p_players_needed not between 1 and 11 then
    raise exception 'hunt: invalid players needed' using errcode = '22023';
  end if;
  if v_city is not null and char_length(v_city) > 100 then
    raise exception 'hunt: invalid city' using errcode = '22023';
  end if;
  if p_match_date is not null and (p_match_date < v_today or p_match_date > v_today + 180) then
    raise exception 'hunt: invalid date' using errcode = '22023';
  end if;
  if p_match_time is not null then
    if p_match_time !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
      raise exception 'hunt: invalid time' using errcode = '22023';
    end if;
    v_time := p_match_time::time;
  end if;
  if p_budget is null or p_budget not in ('any', 'under_2000', 'from_2000_to_5000', 'over_5000') then
    raise exception 'hunt: invalid budget' using errcode = '22023';
  end if;
  if char_length(v_notes) > 280 then
    raise exception 'hunt: invalid notes' using errcode = '22023';
  end if;
  if exists (select 1 from public.hunt_posts h
              where h.club_id = p_club_id and h.status = 'open' and h.expires_at > now()
                and h.role = p_role and h.format = p_format and h.players_needed = p_players_needed
                and h.city is not distinct from v_city and h.match_date is not distinct from p_match_date
                and h.match_time is not distinct from v_time and h.budget = p_budget) then
    raise exception 'hunt: duplicate post' using errcode = 'P0001';
  end if;
  if (select count(*) from public.hunt_posts h
       where h.club_id = p_club_id and h.status = 'open' and h.expires_at > now()) >= 10 then
    raise exception 'hunt: too many open posts' using errcode = 'P0001';
  end if;
  if (select count(*) from public.hunt_posts h
       where h.club_id = p_club_id and h.created_at > now() - interval '24 hours') >= 20 then
    raise exception 'hunt: too many posts' using errcode = 'P0001';
  end if;

  insert into public.hunt_posts (club_id, created_by, role, format, players_needed, city, match_date, match_time,
                                 budget, notes, expires_at)
  values (p_club_id, v_uid, p_role, p_format, p_players_needed::smallint, v_city, p_match_date, v_time,
          p_budget, v_notes,
          case when p_match_date is null then now() + interval '30 days'
               else greatest(((p_match_date + 1)::timestamp at time zone 'Asia/Karachi'), now() + interval '1 minute') end)
  returning id into v_id;

  return query select * from public.hunt_post_list(v_uid, null, v_id, false, null, null);
end;
$$;

-- "Remove Slot": the club's owner closes a post (players no longer see it;
-- interests stay for the owner). Closing a closed post does nothing.
create function public.close_hunt_post(p_post_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'hunt: not authenticated' using errcode = '42501';
  end if;
  perform 1 from public.hunt_posts h join public.clubs c on c.id = h.club_id
   where h.id = p_post_id and c.owner_id = v_uid
     for update of h;
  if not found then
    raise exception 'hunt: not allowed' using errcode = '42501';
  end if;
  update public.hunt_posts h
     set status = 'closed', closed_at = now(), updated_at = now()
   where h.id = p_post_id and h.status = 'open';
end;
$$;

-- "Your Published Slots": the owner's posts (open ones, and all of the
-- last 90 days), newest first, with interest_count.
create function public.club_hunt_posts(p_club_id uuid)
returns table (
  post_id         uuid,
  club_id         uuid,
  club_name       text,
  club_short_name text,
  club_city       text,
  club_logo_path  text,
  role            text,
  format          text,
  players_needed  integer,
  city            text,
  match_date      date,
  match_time      text,
  budget          text,
  notes           text,
  status          text,
  created_at      timestamptz,
  expires_at      timestamptz,
  is_my_club      boolean,
  interested      boolean,
  interest_count  integer
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
    raise exception 'hunt: not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.clubs c where c.id = p_club_id and c.owner_id = v_uid) then
    raise exception 'hunt: not allowed' using errcode = '42501';
  end if;
  return query select * from public.hunt_post_list(v_uid, p_club_id, null, false, null, null);
end;
$$;

-- Playing Opportunities: every club's open posts (the caller's own club's
-- included, is_my_club = true), newest first, at most 200. p_role / p_city
-- optional (a post for any location matches every city).
create function public.hunt_open_posts(p_role text default null, p_city text default null)
returns table (
  post_id         uuid,
  club_id         uuid,
  club_name       text,
  club_short_name text,
  club_city       text,
  club_logo_path  text,
  role            text,
  format          text,
  players_needed  integer,
  city            text,
  match_date      date,
  match_time      text,
  budget          text,
  notes           text,
  status          text,
  created_at      timestamptz,
  expires_at      timestamptz,
  is_my_club      boolean,
  interested      boolean,
  interest_count  integer
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
    raise exception 'hunt: not authenticated' using errcode = '42501';
  end if;
  if p_role is not null and p_role not in ('batsman', 'bowler', 'all_rounder', 'wicket_keeper') then
    raise exception 'hunt: invalid role' using errcode = '22023';
  end if;
  return query
    select * from public.hunt_post_list(v_uid, null, null, true, p_role,
                                        nullif(regexp_replace(btrim(coalesce(p_city, '')), '\s+', ' ', 'g'), ''));
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Interest ("I'm Interested")
-- ---------------------------------------------------------------------------
-- A player (with a cricket profile) tells the club; not on their own club's
-- post. Already interested: nothing happens. At most 30 per player per 24
-- hours. The owner is told once per post and player (hunt_interest_received).
create function public.express_hunt_interest(p_post_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid  uuid := auth.uid();
  v_post public.hunt_posts;
  v_club public.clubs;
  v_name text;
  v_id   uuid;
begin
  if v_uid is null then
    raise exception 'hunt: not authenticated' using errcode = '42501';
  end if;
  -- Serializes this player's interests (the daily limit).
  perform pg_advisory_xact_lock(hashtextextended('criceco.hunt.interest:' || v_uid::text, 0));
  select * into v_post from public.hunt_posts h where h.id = p_post_id for share;
  if not found then
    raise exception 'hunt: post not found' using errcode = 'P0002';
  end if;
  select * into v_club from public.clubs c where c.id = v_post.club_id;
  if v_club.owner_id = v_uid then
    raise exception 'hunt: own club' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.hunt_interests i where i.post_id = p_post_id and i.user_id = v_uid) then
    return;
  end if;
  if v_post.status <> 'open' or v_post.expires_at <= now() then
    raise exception 'hunt: post closed' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.player_profiles pp where pp.user_id = v_uid) then
    raise exception 'hunt: player profile required' using errcode = 'P0001';
  end if;
  if (select count(*) from public.hunt_interests i
       where i.user_id = v_uid and i.created_at > now() - interval '24 hours') >= 30 then
    raise exception 'hunt: too many interests' using errcode = 'P0001';
  end if;

  insert into public.hunt_interests (post_id, user_id) values (p_post_id, v_uid)
  on conflict on constraint hunt_interests_post_user_key do nothing
  returning id into v_id;
  if v_id is null then
    return;
  end if;
  select p.full_name into v_name from public.profiles p where p.id = v_uid;
  perform public.notification_add(
            v_club.owner_id, 'club_owner', 'hunt_interest_received',
            'hunt:interest:' || p_post_id || ':' || v_uid,
            jsonb_build_object('club_name', v_club.name, 'person_name', v_name, 'hunt_role', v_post.role,
                               'format', v_post.format, 'players_needed', v_post.players_needed,
                               'match_date', v_post.match_date),
            v_club.id, null, p_post_id, v_uid);
end;
$$;

-- The player takes their interest back (nothing when there is none). The
-- owner's notification stays; expressing interest again tells nobody again.
create function public.withdraw_hunt_interest(p_post_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'hunt: not authenticated' using errcode = '42501';
  end if;
  delete from public.hunt_interests i where i.post_id = p_post_id and i.user_id = auth.uid();
end;
$$;

-- The owner's view of the players interested in the club's posts (one post
-- or all). The phone only with the player's consent; the official figures
-- only when the player shows statistics (stats_visible).
create function public.club_hunt_interests(p_club_id uuid, p_post_id uuid default null)
returns table (
  interest_id     uuid,
  post_id         uuid,
  user_id         uuid,
  full_name       text,
  avatar_path     text,
  role            text,
  city            text,
  phone           text,
  created_at      timestamptz,
  stats_visible   boolean,
  matches         integer,
  runs            integer,
  batting_average numeric,
  strike_rate     numeric,
  wickets         integer,
  economy         numeric
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
    raise exception 'hunt: not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.clubs c where c.id = p_club_id and c.owner_id = v_uid) then
    raise exception 'hunt: not allowed' using errcode = '42501';
  end if;
  return query
    select i.id, i.post_id, i.user_id, p.full_name, p.avatar_path,
           coalesce(l.role, public.hunt_role_of(p.id)), coalesce(l.city, a.city),
           case when p.share_phone_with_clubs then p.phone end,
           i.created_at, p.show_stats,
           s.matches, s.runs, s.batting_average, s.strike_rate, s.wickets, s.economy
      from public.hunt_interests i
      join public.hunt_posts h on h.id = i.post_id
      join public.profiles p on p.id = i.user_id
      left join public.hunt_listings l on l.user_id = i.user_id
      left join public.current_addresses a on a.user_id = i.user_id
      left join lateral public.hunt_player_stats(i.user_id) s on p.show_stats
     where h.club_id = p_club_id
       and (p_post_id is null or i.post_id = p_post_id)
     order by i.created_at desc, i.id
     limit 500;
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Available Players (club owners)
-- ---------------------------------------------------------------------------
-- Listed players whose profile is public: name, avatar, listing role and
-- city; official figures only with show_stats; NEVER a phone. is_member:
-- already in the caller's club; invite_id / invite_status: the caller's
-- club's latest invite to them. Newest listing first, at most 200.
create function public.hunt_open_players(p_city text default null, p_role text default null)
returns table (
  user_id         uuid,
  full_name       text,
  avatar_path     text,
  role            text,
  city            text,
  listed_at       timestamptz,
  is_me           boolean,
  is_member       boolean,
  invite_id       uuid,
  invite_status   text,
  stats_visible   boolean,
  matches         integer,
  runs            integer,
  batting_average numeric,
  strike_rate     numeric,
  wickets         integer,
  economy         numeric
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid  uuid := auth.uid();
  v_club uuid;
  v_city text := nullif(regexp_replace(btrim(coalesce(p_city, '')), '\s+', ' ', 'g'), '');
begin
  if v_uid is null then
    raise exception 'hunt: not authenticated' using errcode = '42501';
  end if;
  select c.id into v_club from public.clubs c where c.owner_id = v_uid;
  if v_club is null then
    raise exception 'hunt: not allowed' using errcode = '42501';
  end if;
  if p_role is not null and p_role not in ('batsman', 'bowler', 'all_rounder', 'wicket_keeper') then
    raise exception 'hunt: invalid role' using errcode = '22023';
  end if;
  return query
    select p.id, p.full_name, p.avatar_path, l.role, l.city, l.listed_at, p.id = v_uid,
           exists (select 1 from public.club_members m
                    where m.club_id = v_club and m.user_id = p.id and m.status = 'active'),
           iv.id, iv.eff_status,
           p.show_stats, s.matches, s.runs, s.batting_average, s.strike_rate, s.wickets, s.economy
      from public.hunt_listings l
      join public.profiles p on p.id = l.user_id
      left join lateral (select i.id,
                                case when i.status = 'pending' and i.expires_at <= now() then 'expired'
                                     else i.status end as eff_status
                           from public.hunt_invites i
                          where i.club_id = v_club and i.user_id = l.user_id
                          order by i.created_at desc
                          limit 1) iv on true
      left join lateral public.hunt_player_stats(l.user_id) s on p.show_stats
     where l.listed
       and p.public_profile
       and p.full_name is not null
       and (p_role is null or l.role = p_role)
       and (v_city is null or lower(l.city) = lower(v_city))
     order by l.listed_at desc nulls last, p.id
     limit 200;
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. Invites
-- ---------------------------------------------------------------------------
-- The owner invites a player who is listed (public profile) or who showed
-- interest in one of the club's posts; not themself, not an active member.
-- One pending invite per club and player; after an answer, not again for
-- 30 days. At most 20 invites per club per 24 hours. An invite waits 14
-- days. The player is told (hunt_invite_received). p_post_id: optional, one
-- of the club's posts.
create function public.invite_hunt_player(p_club_id uuid, p_user_id uuid, p_post_id uuid default null)
returns table (
  invite_id  uuid,
  status     text,
  created_at timestamptz,
  expires_at timestamptz
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid  uuid := auth.uid();
  v_club public.clubs;
  v_post public.hunt_posts;
  v_inv  public.hunt_invites;
begin
  if v_uid is null then
    raise exception 'hunt: not authenticated' using errcode = '42501';
  end if;
  -- The club row lock serializes the owner's invites (one pending, limit).
  select * into v_club from public.clubs c where c.id = p_club_id for update;
  if not found or v_club.owner_id is distinct from v_uid then
    raise exception 'hunt: not allowed' using errcode = '42501';
  end if;
  if p_user_id is null then
    raise exception 'hunt: invalid player' using errcode = '22023';
  end if;
  if p_user_id = v_uid then
    raise exception 'hunt: cannot invite yourself' using errcode = '22023';
  end if;
  if p_post_id is not null then
    select * into v_post from public.hunt_posts h where h.id = p_post_id and h.club_id = p_club_id;
    if not found then
      raise exception 'hunt: invalid post' using errcode = '22023';
    end if;
  end if;
  if exists (select 1 from public.club_members m
              where m.club_id = p_club_id and m.user_id = p_user_id and m.status = 'active') then
    raise exception 'hunt: already a member' using errcode = 'P0001';
  end if;
  -- An unknown user looks the same as one who is not available.
  if not exists (select 1 from public.hunt_listings l join public.profiles p on p.id = l.user_id
                  where l.user_id = p_user_id and l.listed and p.public_profile)
     and not exists (select 1 from public.hunt_interests i join public.hunt_posts h on h.id = i.post_id
                      where i.user_id = p_user_id and h.club_id = p_club_id) then
    raise exception 'hunt: player not available' using errcode = 'P0001';
  end if;
  update public.hunt_invites i
     set status = 'expired'
   where i.club_id = p_club_id and i.user_id = p_user_id and i.status = 'pending' and i.expires_at <= now();
  if exists (select 1 from public.hunt_invites i
              where i.club_id = p_club_id and i.user_id = p_user_id
                and (i.status = 'pending' or (i.status = 'accepted' and i.responded_at > now() - interval '30 days'))) then
    raise exception 'hunt: already invited' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.hunt_invites i
              where i.club_id = p_club_id and i.user_id = p_user_id
                and i.status = 'declined' and i.responded_at > now() - interval '30 days') then
    raise exception 'hunt: invite declined recently' using errcode = 'P0001';
  end if;
  if (select count(*) from public.hunt_invites i
       where i.club_id = p_club_id and i.created_at > now() - interval '24 hours') >= 20 then
    raise exception 'hunt: too many invites' using errcode = 'P0001';
  end if;

  insert into public.hunt_invites (club_id, user_id, invited_by, post_id)
  values (p_club_id, p_user_id, v_uid, p_post_id)
  returning * into v_inv;

  perform public.notification_add(
            p_user_id, 'player', 'hunt_invite_received', 'hunt:invite:' || v_inv.id,
            jsonb_build_object('club_name', v_club.name, 'city', v_club.city, 'hunt_role', v_post.role,
                               'format', v_post.format, 'match_date', v_post.match_date,
                               'expires_at', v_inv.expires_at),
            p_club_id, null, v_inv.id, null);

  return query select v_inv.id, v_inv.status, v_inv.created_at, v_inv.expires_at;
end;
$$;

-- The owner's invites (pending ones, and all of the last 90 days), newest
-- first. The phone only once the player accepted, and with their consent.
create function public.club_hunt_invites(p_club_id uuid)
returns table (
  invite_id    uuid,
  user_id      uuid,
  full_name    text,
  avatar_path  text,
  role         text,
  city         text,
  post_id      uuid,
  status       text,
  created_at   timestamptz,
  expires_at   timestamptz,
  responded_at timestamptz,
  phone        text
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
    raise exception 'hunt: not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.clubs c where c.id = p_club_id and c.owner_id = v_uid) then
    raise exception 'hunt: not allowed' using errcode = '42501';
  end if;
  return query
    select i.id, i.user_id, p.full_name, p.avatar_path,
           coalesce(l.role, public.hunt_role_of(p.id)), coalesce(l.city, a.city), i.post_id,
           case when i.status = 'pending' and i.expires_at <= now() then 'expired' else i.status end,
           i.created_at, i.expires_at, i.responded_at,
           case when i.status = 'accepted' and p.share_phone_with_clubs then p.phone end
      from public.hunt_invites i
      join public.profiles p on p.id = i.user_id
      left join public.hunt_listings l on l.user_id = i.user_id
      left join public.current_addresses a on a.user_id = i.user_id
     where i.club_id = p_club_id
       and (i.status = 'pending' or i.created_at > now() - interval '90 days')
     order by i.created_at desc, i.id
     limit 500;
end;
$$;

-- The player's invites (pending ones, and all of the last 90 days), newest
-- first, with the club and (when linked) the requirement.
create function public.my_hunt_invites()
returns table (
  invite_id       uuid,
  club_id         uuid,
  club_name       text,
  club_short_name text,
  club_city       text,
  club_logo_path  text,
  post_id         uuid,
  post_role       text,
  post_format     text,
  post_match_date date,
  status          text,
  created_at      timestamptz,
  expires_at      timestamptz,
  responded_at    timestamptz
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
    raise exception 'hunt: not authenticated' using errcode = '42501';
  end if;
  return query
    select i.id, c.id, c.name, c.short_name, c.city, c.logo_path, h.id, h.role, h.format, h.match_date,
           case when i.status = 'pending' and i.expires_at <= now() then 'expired' else i.status end,
           i.created_at, i.expires_at, i.responded_at
      from public.hunt_invites i
      join public.clubs c on c.id = i.club_id
      left join public.hunt_posts h on h.id = i.post_id
     where i.user_id = v_uid
       and (i.status = 'pending' or i.created_at > now() - interval '90 days')
     order by i.created_at desc, i.id
     limit 200;
end;
$$;

-- The player answers a pending invite. Accept = "I'm interested, contact me"
-- (the club then sees the phone if the player shares it with clubs, and its
-- owner is told: hunt_invite_accepted); it NEVER joins the club — joining
-- stays the join-by-code flow. Decline tells nobody.
create function public.respond_hunt_invite(p_invite_id uuid, p_accept boolean)
returns table (
  invite_id    uuid,
  status       text,
  responded_at timestamptz
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid  uuid := auth.uid();
  v_inv  public.hunt_invites;
  v_club public.clubs;
  v_name text;
begin
  if v_uid is null then
    raise exception 'hunt: not authenticated' using errcode = '42501';
  end if;
  if p_accept is null then
    raise exception 'hunt: invalid answer' using errcode = '22023';
  end if;
  select * into v_inv from public.hunt_invites i where i.id = p_invite_id and i.user_id = v_uid for update;
  if not found then
    raise exception 'hunt: invite not found' using errcode = 'P0002';
  end if;
  if v_inv.status <> 'pending' or v_inv.expires_at <= now() then
    raise exception 'hunt: invite not pending' using errcode = 'P0001';
  end if;
  update public.hunt_invites i
     set status = case when p_accept then 'accepted' else 'declined' end, responded_at = now()
   where i.id = p_invite_id
  returning * into v_inv;
  if p_accept then
    select * into v_club from public.clubs c where c.id = v_inv.club_id;
    select p.full_name into v_name from public.profiles p where p.id = v_uid;
    perform public.notification_add(
              v_club.owner_id, 'club_owner', 'hunt_invite_accepted', 'hunt:invite_accepted:' || v_inv.id,
              jsonb_build_object('club_name', v_club.name, 'person_name', v_name),
              v_club.id, null, v_inv.id, v_uid);
  end if;
  return query select v_inv.id, v_inv.status, v_inv.responded_at;
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. Privileges: signed-in users only; the helpers to nobody
-- ---------------------------------------------------------------------------
revoke execute on function public.hunt_role_of(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.hunt_player_stats(uuid) from public, anon, authenticated, service_role;
revoke execute on function public.hunt_post_list(uuid, uuid, uuid, boolean, text, text)
  from public, anon, authenticated, service_role;

revoke execute on function public.my_hunt_listing() from public, anon;
revoke execute on function public.set_my_hunt_listing(boolean, text, text) from public, anon;
revoke execute on function public.publish_hunt_post(uuid, text, text, integer, text, date, text, text, text) from public, anon;
revoke execute on function public.close_hunt_post(uuid) from public, anon;
revoke execute on function public.club_hunt_posts(uuid) from public, anon;
revoke execute on function public.hunt_open_posts(text, text) from public, anon;
revoke execute on function public.express_hunt_interest(uuid) from public, anon;
revoke execute on function public.withdraw_hunt_interest(uuid) from public, anon;
revoke execute on function public.club_hunt_interests(uuid, uuid) from public, anon;
revoke execute on function public.hunt_open_players(text, text) from public, anon;
revoke execute on function public.invite_hunt_player(uuid, uuid, uuid) from public, anon;
revoke execute on function public.club_hunt_invites(uuid) from public, anon;
revoke execute on function public.my_hunt_invites() from public, anon;
revoke execute on function public.respond_hunt_invite(uuid, boolean) from public, anon;

grant execute on function public.my_hunt_listing() to authenticated;
grant execute on function public.set_my_hunt_listing(boolean, text, text) to authenticated;
grant execute on function public.publish_hunt_post(uuid, text, text, integer, text, date, text, text, text) to authenticated;
grant execute on function public.close_hunt_post(uuid) to authenticated;
grant execute on function public.club_hunt_posts(uuid) to authenticated;
grant execute on function public.hunt_open_posts(text, text) to authenticated;
grant execute on function public.express_hunt_interest(uuid) to authenticated;
grant execute on function public.withdraw_hunt_interest(uuid) to authenticated;
grant execute on function public.club_hunt_interests(uuid, uuid) to authenticated;
grant execute on function public.hunt_open_players(text, text) to authenticated;
grant execute on function public.invite_hunt_player(uuid, uuid, uuid) to authenticated;
grant execute on function public.club_hunt_invites(uuid) to authenticated;
grant execute on function public.my_hunt_invites() to authenticated;
grant execute on function public.respond_hunt_invite(uuid, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- 10. Self-check (raises — rolling everything back — on any mismatch)
-- ---------------------------------------------------------------------------
do $$
declare
  v_fn  regprocedure;
  v_tbl regclass;
begin
  foreach v_tbl in array array['public.hunt_listings', 'public.hunt_posts', 'public.hunt_interests',
                               'public.hunt_invites']::regclass[] loop
    if not (select c.relrowsecurity from pg_class c where c.oid = v_tbl)
       or exists (select 1 from pg_policy pol where pol.polrelid = v_tbl)
       or has_table_privilege('anon', v_tbl, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
       or has_table_privilege('authenticated', v_tbl, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
       or has_table_privilege('service_role', v_tbl, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') then
      raise exception 'migration 33 self-check: % is not closed (RLS on, no policy, no grant)', v_tbl;
    end if;
  end loop;
  if (select count(*) from pg_constraint k
       where k.contype = 'f' and k.confdeltype = 'c'
         and k.conname in ('hunt_listings_user_id_fkey', 'hunt_posts_club_id_fkey', 'hunt_interests_post_id_fkey',
                           'hunt_interests_user_id_fkey', 'hunt_invites_club_id_fkey', 'hunt_invites_user_id_fkey')) <> 6
     or (select count(*) from pg_constraint k
          where k.contype = 'f' and k.confdeltype = 'n'
            and k.conname in ('hunt_posts_created_by_fkey', 'hunt_invites_invited_by_fkey', 'hunt_invites_post_id_fkey')) <> 3 then
    raise exception 'migration 33 self-check: the foreign keys (6 cascade, 3 set null)';
  end if;
  foreach v_fn in array array['public.my_hunt_listing()', 'public.set_my_hunt_listing(boolean, text, text)',
                              'public.publish_hunt_post(uuid, text, text, integer, text, date, text, text, text)',
                              'public.close_hunt_post(uuid)', 'public.club_hunt_posts(uuid)',
                              'public.hunt_open_posts(text, text)', 'public.express_hunt_interest(uuid)',
                              'public.withdraw_hunt_interest(uuid)', 'public.club_hunt_interests(uuid, uuid)',
                              'public.hunt_open_players(text, text)', 'public.invite_hunt_player(uuid, uuid, uuid)',
                              'public.club_hunt_invites(uuid)', 'public.my_hunt_invites()',
                              'public.respond_hunt_invite(uuid, boolean)']::regprocedure[] loop
    if not has_function_privilege('authenticated', v_fn, 'execute') or has_function_privilege('anon', v_fn, 'execute')
       or (select not p.prosecdef or array_to_string(p.proconfig, ',') <> 'search_path=""' from pg_proc p where p.oid = v_fn) then
      raise exception 'migration 33 self-check: % privileges / properties', v_fn;
    end if;
  end loop;
  foreach v_fn in array array['public.hunt_role_of(uuid)', 'public.hunt_player_stats(uuid)',
                              'public.hunt_post_list(uuid, uuid, uuid, boolean, text, text)']::regprocedure[] loop
    if has_function_privilege('authenticated', v_fn, 'execute') or has_function_privilege('anon', v_fn, 'execute')
       or has_function_privilege('service_role', v_fn, 'execute')
       or (select p.prosecdef or array_to_string(p.proconfig, ',') <> 'search_path=""' from pg_proc p where p.oid = v_fn) then
      raise exception 'migration 33 self-check: helper % is callable by an API role', v_fn;
    end if;
  end loop;
  if public.notification_category('hunt_interest_received') <> 'join_requests'
     or public.notification_category('hunt_invite_accepted') <> 'join_requests'
     or public.notification_category('hunt_invite_received') <> 'membership'
     or public.notification_category('join_request_received') <> 'join_requests'
     or public.notification_category('match_reminder') <> 'matches'
     or public.notification_category('challenge_expiring') <> 'challenges'
     or public.notification_category('announcement') <> 'announcements'
     or public.notification_category('ownership_expiring') <> 'membership'
     or has_function_privilege('authenticated', 'public.notification_category(text)', 'execute')
     or has_function_privilege('anon', 'public.notification_category(text)', 'execute') then
    raise exception 'migration 33 self-check: notification_category';
  end if;
  if (select array_length(regexp_split_to_array(pg_get_constraintdef(k.oid), '::text'), 1) - 1
        from pg_constraint k
       where k.conrelid = 'public.notifications'::regclass and k.conname = 'notifications_type_check') <> 29
     or not exists (select 1 from pg_constraint k
                     where k.conrelid = 'public.notifications'::regclass and k.conname = 'notifications_type_check'
                       and k.convalidated
                       and pg_get_constraintdef(k.oid) like '%''announcement''%''ownership_expiring''%''hunt_invite_received''%''hunt_interest_received''%''hunt_invite_accepted''%') then
    raise exception 'migration 33 self-check: notifications_type_check (29 types)';
  end if;
  if (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p
       where p.oid = 'public.notification_add(uuid, text, text, text, jsonb, uuid, uuid, uuid, uuid)'::regprocedure)
       <> 'a6fc6bc7e42b161bc56a5b1ef9f8aa68' then
    raise exception 'migration 33 self-check: notification_add changed';
  end if;
  if pg_get_function_result('public.hunt_open_posts(text, text)'::regprocedure)
       <> pg_get_function_result('public.club_hunt_posts(uuid)'::regprocedure)
     or pg_get_function_result('public.publish_hunt_post(uuid, text, text, integer, text, date, text, text, text)'::regprocedure)
       <> pg_get_function_result('public.club_hunt_posts(uuid)'::regprocedure)
     or pg_get_function_result('public.set_my_hunt_listing(boolean, text, text)'::regprocedure)
       <> pg_get_function_result('public.my_hunt_listing()'::regprocedure) then
    raise exception 'migration 33 self-check: result types differ';
  end if;
end $$;

notify pgrst, 'reload schema';
