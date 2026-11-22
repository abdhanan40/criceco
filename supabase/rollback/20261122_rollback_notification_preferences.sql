-- CricEco · ROLLBACK of migration 26 (notification preferences, M3 P4).
--
-- NOT APPLIED. Run only with explicit approval, after a backup, inside
--   begin; set local lock_timeout = '5s'; <this file> commit;
--
-- Removes the preferences: everyone gets every notification again. People's
-- choices are deleted — it REFUSES while any preference row exists, unless
-- you confirm in the same transaction:
--   set local criceco.rollback_preferences_discarded = 'yes';
-- Nothing else changes: notifications, announcements and every other table
-- stay; migration 25's notification_add and publish_club_announcement are
-- restored exactly as migration 25 created them (copied verbatim below).
-- An app built with CRICECO_NOTIFICATIONS=true then gets an error on the
-- Notification settings screen — ship a build without it first.
-- Generated from migration 25 (commit 45d06ca) by the M3 P4 build script.

do $$
begin
  if to_regclass('public.notification_preferences') is null then
    raise exception 'rollback 26: migration 26 is not applied — nothing changed';
  end if;
  if exists (select 1 from public.notification_preferences)
     and coalesce(current_setting('criceco.rollback_preferences_discarded', true), '') <> 'yes' then
    raise exception 'rollback 26: people have saved preferences — set criceco.rollback_preferences_discarded = ''yes'' to discard them (nothing changed)';
  end if;
end $$;

-- Migration 25's writers, verbatim.
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
  insert into public.notifications (recipient_id, inbox, type, params, club_id, match_id, subject_id, person_id, dedupe_key)
  values (p_recipient, p_inbox, p_type, jsonb_strip_nulls(coalesce(p_params, '{}'::jsonb)),
          p_club_id, p_match_id, p_subject_id, p_person_id, p_key)
  on conflict (recipient_id, dedupe_key) do nothing;
end;
$$;

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
  on conflict (recipient_id, dedupe_key) do nothing;
  get diagnostics v_count = row_count;

  update public.club_announcements a set recipient_count = v_count where a.id = v_id;
  return query select v_id, v_count;
end;
$$;

-- The API, the helpers and the table.
drop function if exists public.my_notification_preferences();
drop function if exists public.set_notification_preferences(boolean, boolean, boolean, boolean, boolean);
drop function if exists public.notification_muted(uuid, text);
drop function if exists public.notification_category(text);
drop table if exists public.notification_preferences;
drop function if exists public.notification_preferences_touch();

notify pgrst, 'reload schema';
