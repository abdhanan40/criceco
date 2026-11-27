-- CricEco · ROLLBACK of migration 33 (M8 Player Hunt / Playing Opportunities).
--
-- NOT APPLIED. Run only with explicit approval, after a backup, inside
--   begin; set local lock_timeout = '5s'; <this file> commit;
-- FIRST roll back (or never ship) an app build that calls the hunt
-- functions: after this file they are gone.
--
-- Reverses migration 33:
--   1. DELETES the notifications of the three hunt types
--      (hunt_invite_received, hunt_interest_received, hunt_invite_accepted)
--      — with their push records (ON DELETE CASCADE) — because the restored
--      type list no longer allows them; the number is reported (NOTICE);
--   2. drops the 14 hunt functions and the 3 internal helpers;
--   3. drops hunt_invites, hunt_interests, hunt_posts and hunt_listings
--      (every listing, post, interest and invite is lost);
--   4. restores notifications_type_check and notification_category exactly
--      as migration 28 left them (verbatim; notification_category keeps its
--      privileges: no API role).
-- No other row is changed or deleted. notification_add, notification_muted
-- and delete_account_data were never changed by migration 33.
-- Generated from migration 28 (20261122090300, lines 51–82).

do $$
begin
  if to_regclass('public.hunt_listings') is null or to_regclass('public.hunt_posts') is null
     or to_regclass('public.hunt_interests') is null or to_regclass('public.hunt_invites') is null
     or to_regprocedure('public.respond_hunt_invite(uuid, boolean)') is null then
    raise exception 'rollback 33: migration 33 is not (fully) applied — nothing changed';
  end if;
  -- Restore only over migration 33's own definitions (line endings ignored).
  if (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p
       where p.oid = 'public.notification_category(text)'::regprocedure) <> '99866e275e10125352bb2e5acad0d5c0'
     or (select md5(pg_get_constraintdef(k.oid)) from pg_constraint k
          where k.conrelid = 'public.notifications'::regclass and k.conname = 'notifications_type_check')
        is distinct from 'd6c0cf7d4d7aab931ecd5010be1ea212' then
    raise exception 'rollback 33: notification_category / notifications_type_check differ from migration 33 (changed by a later migration?) — nothing changed';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. The hunt notifications (and their push records)
-- ---------------------------------------------------------------------------
do $$
declare
  v_count integer;
begin
  delete from public.notifications n
   where n.type in ('hunt_invite_received', 'hunt_interest_received', 'hunt_invite_accepted');
  get diagnostics v_count = row_count;
  raise notice 'rollback 33: % hunt notification(s) deleted', v_count;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Functions
-- ---------------------------------------------------------------------------
drop function public.respond_hunt_invite(uuid, boolean);
drop function public.my_hunt_invites();
drop function public.club_hunt_invites(uuid);
drop function public.invite_hunt_player(uuid, uuid, uuid);
drop function public.hunt_open_players(text, text);
drop function public.club_hunt_interests(uuid, uuid);
drop function public.withdraw_hunt_interest(uuid);
drop function public.express_hunt_interest(uuid);
drop function public.hunt_open_posts(text, text);
drop function public.club_hunt_posts(uuid);
drop function public.close_hunt_post(uuid);
drop function public.publish_hunt_post(uuid, text, text, integer, text, date, text, text, text);
drop function public.set_my_hunt_listing(boolean, text, text);
drop function public.my_hunt_listing();
drop function public.hunt_post_list(uuid, uuid, uuid, boolean, text, text);
drop function public.hunt_player_stats(uuid);
drop function public.hunt_role_of(uuid);

-- ---------------------------------------------------------------------------
-- 3. Tables
-- ---------------------------------------------------------------------------
drop table public.hunt_invites;
drop table public.hunt_interests;
drop table public.hunt_posts;
drop table public.hunt_listings;

-- ---------------------------------------------------------------------------
-- 4. Migration 28's type list and categories (verbatim)
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
    'match_reminder', 'challenge_expiring', 'ownership_expiring'));

create or replace function public.notification_category(p_type text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
           when p_type = 'join_request_received' then 'join_requests'
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
-- 5. Self-check
-- ---------------------------------------------------------------------------
do $$
begin
  if (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p
       where p.oid = 'public.notification_category(text)'::regprocedure) <> '7945e3ba106695803d3b2fe3c386c207'
     or (select md5(pg_get_constraintdef(k.oid)) from pg_constraint k
          where k.conrelid = 'public.notifications'::regclass and k.conname = 'notifications_type_check')
        is distinct from '6e21473f70979b51955fa439baac82d0'
     or has_function_privilege('authenticated', 'public.notification_category(text)', 'execute')
     or has_function_privilege('anon', 'public.notification_category(text)', 'execute') then
    raise exception 'rollback 33 self-check: the type list / notification_category is not migration 28''s';
  end if;
  if to_regclass('public.hunt_listings') is not null or to_regclass('public.hunt_posts') is not null
     or to_regclass('public.hunt_interests') is not null or to_regclass('public.hunt_invites') is not null
     or exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public'
                   and p.proname in ('my_hunt_listing', 'set_my_hunt_listing', 'publish_hunt_post', 'close_hunt_post',
                                     'club_hunt_posts', 'hunt_open_posts', 'express_hunt_interest',
                                     'withdraw_hunt_interest', 'club_hunt_interests', 'hunt_open_players',
                                     'invite_hunt_player', 'club_hunt_invites', 'my_hunt_invites',
                                     'respond_hunt_invite', 'hunt_role_of', 'hunt_player_stats', 'hunt_post_list')) then
    raise exception 'rollback 33 self-check: something of migration 33 is left';
  end if;
end $$;

notify pgrst, 'reload schema';
