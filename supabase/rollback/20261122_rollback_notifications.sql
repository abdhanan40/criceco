-- CricEco · ROLLBACK of migration 25 (notifications: the server inbox, M3 P1).
--
-- NOT APPLIED. Run only with explicit approval, after a backup, inside
--   begin; set local lock_timeout = '5s'; <this file> commit;
--
-- DESTRUCTIVE TO M3 DATA: every notification (and its read state) and every
-- club announcement is deleted. It REFUSES while any exists, unless you
-- confirm that they were exported (or may go), in the same transaction:
--   set local criceco.rollback_notifications_exported = 'yes';
-- Export first, e.g.:
--   supabase db dump --data-only -t public.notifications -t public.club_announcements
-- Nothing else is touched: requests, offers, challenges, matches, line-ups,
-- results, clubs, members and profiles stay exactly as they are; only the
-- notification triggers on their tables are removed.
-- An app built with CRICECO_NOTIFICATIONS=true then gets errors in the
-- inbox — ship a build without it first.

do $$
begin
  if to_regclass('public.notifications') is null then
    raise exception 'rollback 25: migration 25 is not applied — nothing changed';
  end if;
  if (exists (select 1 from public.notifications) or exists (select 1 from public.club_announcements))
     and coalesce(current_setting('criceco.rollback_notifications_exported', true), '') <> 'yes' then
    raise exception 'rollback 25: notifications or announcements exist — export them first, then set criceco.rollback_notifications_exported = ''yes'' (nothing changed)';
  end if;
end $$;

-- The event triggers on the existing tables.
drop trigger if exists join_requests_notify on public.join_requests;
drop trigger if exists club_members_notify_removed on public.club_members;
drop trigger if exists club_ownership_transfers_notify on public.club_ownership_transfers;
drop trigger if exists match_challenges_notify on public.match_challenges;
drop trigger if exists matches_notify on public.matches;
drop trigger if exists match_lineup_players_notify on public.match_lineup_players;
drop trigger if exists match_results_notify on public.match_results;

-- The API.
drop function if exists public.my_notifications(text, timestamptz, uuid, integer);
drop function if exists public.notification_unread_count(text);
drop function if exists public.mark_notifications_read(uuid[]);
drop function if exists public.mark_all_notifications_read(text, timestamptz);
drop function if exists public.publish_club_announcement(uuid, text, text, text);
drop function if exists public.club_announcement(uuid);
drop function if exists public.club_announcement_list(uuid, integer);

-- The trigger functions and helpers.
drop function if exists public.join_requests_notify();
drop function if exists public.club_members_notify_removed();
drop function if exists public.club_ownership_transfers_notify();
drop function if exists public.match_challenges_notify();
drop function if exists public.matches_notify();
drop function if exists public.match_lineup_players_notify();
drop function if exists public.match_results_notify();
drop function if exists public.notification_lineup_fanout(public.matches, text, text, jsonb);
drop function if exists public.notification_result_for(text, uuid, uuid);
drop function if exists public.notification_person_name(uuid);
drop function if exists public.notification_add(uuid, text, text, text, jsonb, uuid, uuid, uuid, uuid);

-- The tables (their policy, guard trigger and indexes go with them).
drop table if exists public.notification_lineup_state;
drop table if exists public.notifications;
drop table if exists public.club_announcements;
drop function if exists public.notifications_guard_update();

notify pgrst, 'reload schema';
