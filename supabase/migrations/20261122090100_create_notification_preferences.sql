-- CricEco · migration 26 · notification preferences (M3 P4)
--
-- NOT APPLIED. Requires migration 25 (the server inbox).
-- Rollback: supabase/rollback/20261122_rollback_notification_preferences.sql.
-- Read-only check: supabase/tests/26_notification_preferences_postcheck.sql.
-- Local tests: supabase/tests/local/21_notification_preferences_local_check.sql
-- (+ 21b_notification_preferences_concurrency.sh).
-- Design: docs/NOTIFICATIONS_BACKEND.md ("P4").
--
-- Approved 2026-11-22 (M3 P4):
--   * enforced ON THE SERVER: a category a person turned off is never created
--     for them (push, P5, will read the same rows);
--   * six categories; "membership" (join decisions, removal, ownership) is
--     ALWAYS ON; join_requests, challenges, matches, results and
--     announcements can be turned off;
--   * turning one off keeps what is already in the inbox (only new ones stop);
--   * one setting per account (a category belongs to one kind of event,
--     whichever inbox it lands in); everything on until changed.
-- Changes to migration 25: notification_add and publish_club_announcement
-- skip muted recipients (create or replace; everything else unchanged).

do $$
begin
  if to_regclass('public.notifications') is null
     or to_regprocedure('public.notification_add(uuid, text, text, text, jsonb, uuid, uuid, uuid, uuid)') is null
     or to_regprocedure('public.publish_club_announcement(uuid, text, text, text)') is null then
    raise exception 'migration 26: migration 25 is required';
  end if;
  if to_regclass('public.notification_preferences') is not null
     or exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public'
                   and p.proname in ('notification_category', 'notification_muted', 'my_notification_preferences',
                                     'set_notification_preferences', 'notification_preferences_touch')) then
    raise exception 'migration 26: already applied (or a name is taken) — nothing changed';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. The table: one row per person who changed something (no row = all on)
-- ---------------------------------------------------------------------------
create table public.notification_preferences (
  user_id       uuid primary key
                constraint notification_preferences_user_id_fkey references public.profiles (id) on delete cascade,
  join_requests boolean not null default true,
  challenges    boolean not null default true,
  matches       boolean not null default true,
  results       boolean not null default true,
  announcements boolean not null default true,
  updated_at    timestamptz not null default now()
);

comment on table public.notification_preferences is
  'Notification categories a person turned off (M3 P4). Written only by set_notification_preferences.';

create or replace function public.notification_preferences_touch()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger notification_preferences_touch
  before update on public.notification_preferences
  for each row execute function public.notification_preferences_touch();

-- ---------------------------------------------------------------------------
-- 2. Which category a notification type belongs to (unknown → membership:
--    always on, so a new type is never silently dropped)
-- ---------------------------------------------------------------------------
create or replace function public.notification_category(p_type text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
           when p_type = 'join_request_received' then 'join_requests'
           when p_type in ('challenge_received', 'challenge_accepted', 'challenge_declined',
                           'schedule_proposed', 'schedule_accepted', 'schedule_declined') then 'challenges'
           when p_type in ('lineup_selected', 'lineup_changed', 'lineup_dropped',
                           'match_rescheduled', 'match_cancelled') then 'matches'
           when p_type in ('result_published', 'result_corrected', 'player_of_match') then 'results'
           when p_type = 'announcement' then 'announcements'
           else 'membership'
         end;
$$;

-- Has [p_user_id] turned [p_type]'s category off? Membership never.
create or replace function public.notification_muted(p_user_id uuid, p_type text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select case public.notification_category(p_type)
             when 'join_requests' then not p.join_requests
             when 'challenges' then not p.challenges
             when 'matches' then not p.matches
             when 'results' then not p.results
             when 'announcements' then not p.announcements
             else false
           end
      from public.notification_preferences p
     where p.user_id = p_user_id), false);
$$;

-- ---------------------------------------------------------------------------
-- 3. Migration 25's two writers skip muted recipients
-- ---------------------------------------------------------------------------
-- Adds one notification, once per (recipient, key). Nobody is told of their
-- own action, a missing recipient is skipped, and so is one who turned the
-- category off (migration 26).
create or replace function public.notification_add(
  p_recipient  uuid,
  p_inbox      text,
  p_type       text,
  p_key        text,
  p_params     jsonb,
  p_club_id    uuid default null,
  p_match_id   uuid default null,
  p_subject_id uuid default null,
  p_person_id  uuid default null
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if p_recipient is null or p_recipient = (select auth.uid()) then
    return;
  end if;
  if public.notification_muted(p_recipient, p_type) then
    return;
  end if;
  insert into public.notifications (recipient_id, inbox, type, params, club_id, match_id, subject_id, person_id, dedupe_key)
  values (p_recipient, p_inbox, p_type, jsonb_strip_nulls(coalesce(p_params, '{}'::jsonb)),
          p_club_id, p_match_id, p_subject_id, p_person_id, p_key)
  on conflict (recipient_id, dedupe_key) do nothing;
end;
$$;

-- The owner publishes; the server picks the recipients (active members in
-- the audience — players: with a cricket profile; staff: without — except
-- the owner and anyone who turned announcements off) and notifies them.
-- At most 20 per club per 24 hours. recipient_count = who was told.
create or replace function public.publish_club_announcement(
  p_club_id  uuid,
  p_title    text,
  p_message  text,
  p_audience text
)
returns table (announcement_id uuid, recipient_count integer)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_club    public.clubs;
  v_title   text := regexp_replace(btrim(coalesce(p_title, '')), '\s+', ' ', 'g');
  v_message text := btrim(coalesce(p_message, ''));
  v_id      uuid;
  v_count   integer;
begin
  if v_uid is null then
    raise exception 'announcement: not authenticated' using errcode = '42501';
  end if;
  -- The club row lock serializes the owner's publishes (the daily limit).
  select * into v_club from public.clubs c where c.id = p_club_id for update;
  if not found or v_club.owner_id is distinct from v_uid then
    raise exception 'announcement: not allowed' using errcode = '42501';
  end if;
  if char_length(v_title) not between 1 and 60 then
    raise exception 'announcement: invalid title' using errcode = '22023';
  end if;
  if char_length(v_message) not between 1 and 280 then
    raise exception 'announcement: invalid message' using errcode = '22023';
  end if;
  if p_audience is null or p_audience not in ('all', 'players', 'staff') then
    raise exception 'announcement: invalid audience' using errcode = '22023';
  end if;
  if (select count(*) from public.club_announcements a
       where a.club_id = p_club_id and a.created_at > now() - interval '24 hours') >= 20 then
    raise exception 'announcement: too many' using errcode = 'P0001';
  end if;

  insert into public.club_announcements (club_id, title, message, audience, created_by)
  values (p_club_id, v_title, v_message, p_audience, v_uid)
  returning id into v_id;

  insert into public.notifications (recipient_id, inbox, type, params, club_id, subject_id, dedupe_key)
  select m.user_id, 'player', 'announcement', jsonb_build_object('club_name', v_club.name, 'title', v_title),
         p_club_id, v_id, 'announcement:' || v_id
    from public.club_members m
   where m.club_id = p_club_id and m.status = 'active' and m.user_id <> v_uid
     and (p_audience = 'all'
          or (p_audience = 'players') = exists (select 1 from public.player_profiles pp where pp.user_id = m.user_id))
     and not public.notification_muted(m.user_id, 'announcement')
  on conflict (recipient_id, dedupe_key) do nothing;
  get diagnostics v_count = row_count;

  update public.club_announcements a set recipient_count = v_count where a.id = v_id;
  return query select v_id, v_count;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. The API (signed in; own row only)
-- ---------------------------------------------------------------------------
-- The caller's preferences (all on, updated_at null, when never changed).
create or replace function public.my_notification_preferences()
returns table (
  join_requests boolean,
  challenges    boolean,
  matches       boolean,
  results       boolean,
  announcements boolean,
  updated_at    timestamptz
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
    raise exception 'notification: not authenticated' using errcode = '42501';
  end if;
  return query
    select coalesce(p.join_requests, true), coalesce(p.challenges, true), coalesce(p.matches, true),
           coalesce(p.results, true), coalesce(p.announcements, true), p.updated_at
      from (select 1) one
      left join public.notification_preferences p on p.user_id = v_uid;
end;
$$;

-- Saves all five optional categories at once (membership is always on and
-- not a setting). Returns the saved row.
create or replace function public.set_notification_preferences(
  p_join_requests boolean,
  p_challenges    boolean,
  p_matches       boolean,
  p_results       boolean,
  p_announcements boolean
)
returns table (
  join_requests boolean,
  challenges    boolean,
  matches       boolean,
  results       boolean,
  announcements boolean,
  updated_at    timestamptz
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'notification: not authenticated' using errcode = '42501';
  end if;
  if p_join_requests is null or p_challenges is null or p_matches is null
     or p_results is null or p_announcements is null then
    raise exception 'notification: invalid' using errcode = '22023';
  end if;
  if not exists (select 1 from public.profiles p where p.id = v_uid) then
    raise exception 'notification: not found' using errcode = 'P0002';
  end if;
  return query
    insert into public.notification_preferences as p
           (user_id, join_requests, challenges, matches, results, announcements)
    values (v_uid, p_join_requests, p_challenges, p_matches, p_results, p_announcements)
    on conflict (user_id) do update
       set join_requests = excluded.join_requests, challenges = excluded.challenges, matches = excluded.matches,
           results = excluded.results, announcements = excluded.announcements
    returning p.join_requests, p.challenges, p.matches, p.results, p.announcements, p.updated_at;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Privileges (Supabase grants everything by default — take it back)
-- ---------------------------------------------------------------------------
revoke all on table public.notification_preferences from public, anon, authenticated, service_role;
alter table public.notification_preferences enable row level security;

revoke execute on function public.notification_preferences_touch() from public, anon, authenticated, service_role;
revoke execute on function public.notification_category(text) from public, anon, authenticated, service_role;
revoke execute on function public.notification_muted(uuid, text) from public, anon, authenticated, service_role;
revoke execute on function public.my_notification_preferences() from public, anon, service_role;
revoke execute on function public.set_notification_preferences(boolean, boolean, boolean, boolean, boolean)
  from public, anon, service_role;
grant execute on function public.my_notification_preferences() to authenticated;
grant execute on function public.set_notification_preferences(boolean, boolean, boolean, boolean, boolean)
  to authenticated;
