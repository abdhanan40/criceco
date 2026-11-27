-- CricEco · ROLLBACK of migration 35 (M10 Tournaments).
--
-- NOT APPLIED. Run only with explicit approval, after a backup, inside
--   begin; set local lock_timeout = '5s'; <this file> commit;
-- FIRST roll back (or never ship) an app build that calls the tournament
-- functions, and stop the scorer integration (record_tournament_fixture_result):
-- after this file they are gone.
--
-- Reverses migration 35:
--   1. DELETES the notifications of the five tournament types
--      (tournament_registration_received / _approved / _rejected,
--      tournament_team_removed, tournament_fixtures_published) — with their
--      push records (ON DELETE CASCADE) — because the restored type list no
--      longer allows them; the number is reported (NOTICE);
--   2. drops the 16 tournament functions, the 6 internal helpers and the 2
--      trigger functions (their triggers go with the tables);
--   3. drops tournament_fixtures, tournament_registration_players,
--      tournament_registrations and tournaments (every tournament, entry,
--      squad and fixture is lost; the numbers are reported first);
--   4. restores notifications_type_check and notification_category exactly
--      as migration 33 left them (verbatim; notification_category keeps its
--      privileges: no API role).
-- No other row is changed or deleted (official matches and results of
-- migrations 17–24 are untouched). notification_add, notification_muted and
-- delete_account_data were never changed by migration 35.
-- Generated from migration 33 (20261126090300, lines 220–253).

do $$
begin
  if to_regclass('public.tournaments') is null or to_regclass('public.tournament_registrations') is null
     or to_regclass('public.tournament_registration_players') is null or to_regclass('public.tournament_fixtures') is null
     or to_regprocedure('public.record_tournament_fixture_result(uuid, uuid, uuid)') is null then
    raise exception 'rollback 35: migration 35 is not (fully) applied — nothing changed';
  end if;
  -- Restore only over migration 35's own definitions (line endings ignored).
  if (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p
       where p.oid = 'public.notification_category(text)'::regprocedure) <> '6a6386ac85255f30e53cd8f535cb306c'
     or (select md5(pg_get_constraintdef(k.oid)) from pg_constraint k
          where k.conrelid = 'public.notifications'::regclass and k.conname = 'notifications_type_check')
        is distinct from '2879e160a8fb571fd498935907be7beb' then
    raise exception 'rollback 35: notification_category / notifications_type_check differ from migration 35 (changed by a later migration?) — nothing changed';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. The tournament notifications (and their push records); what is lost
-- ---------------------------------------------------------------------------
do $$
declare
  v_count integer;
begin
  raise notice 'rollback 35: dropping % tournament(s), % entr(y/ies), % squad place(s), % fixture(s)',
    (select count(*) from public.tournaments), (select count(*) from public.tournament_registrations),
    (select count(*) from public.tournament_registration_players), (select count(*) from public.tournament_fixtures);
  delete from public.notifications n
   where n.type in ('tournament_registration_received', 'tournament_registration_approved',
                    'tournament_registration_rejected', 'tournament_team_removed', 'tournament_fixtures_published');
  get diagnostics v_count = row_count;
  raise notice 'rollback 35: % tournament notification(s) deleted', v_count;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Functions
-- ---------------------------------------------------------------------------
drop function public.record_tournament_fixture_result(uuid, uuid, uuid);
drop function public.tournament_awards(uuid);
drop function public.tournament_points_table(uuid);
drop function public.tournament_fixtures(uuid);
drop function public.generate_tournament_fixtures(uuid);
drop function public.my_tournament_registrations(uuid, text);
drop function public.remove_tournament_team(uuid);
drop function public.decide_tournament_registration(uuid, boolean);
drop function public.submit_tournament_registration(uuid, uuid, text, uuid, jsonb, uuid, uuid, uuid, boolean);
drop function public.tournament_registration_squad(uuid);
drop function public.tournament_teams(uuid);
drop function public.tournament_hub_stats(uuid);
drop function public.tournament_detail(uuid);
drop function public.browse_tournaments(text);
drop function public.my_hosted_tournaments(uuid);
drop function public.create_tournament(uuid, text, text, text, text, integer, text, date, date, date, integer,
                                       integer, integer, text, text[]);
drop function public.tournament_standings(uuid);
drop function public.tournament_advance_byes(uuid);
drop function public.tournament_fixture_decide(uuid, uuid, boolean);
drop function public.tournament_registration_rows(uuid, uuid, uuid);
drop function public.tournament_list(uuid, uuid, uuid, boolean, text);
drop function public.tournament_status_now(text, date);

-- ---------------------------------------------------------------------------
-- 3. Tables (one statement: they reference each other), then the trigger
--    functions
-- ---------------------------------------------------------------------------
drop table public.tournament_fixtures, public.tournament_registration_players, public.tournament_registrations,
  public.tournaments;
drop function public.tournament_registration_players_validate();
drop function public.tournament_registrations_validate();

-- ---------------------------------------------------------------------------
-- 4. Migration 33's type list and categories (verbatim)
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
-- 5. Self-check
-- ---------------------------------------------------------------------------
do $$
begin
  if (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p
       where p.oid = 'public.notification_category(text)'::regprocedure) <> '99866e275e10125352bb2e5acad0d5c0'
     or (select md5(pg_get_constraintdef(k.oid)) from pg_constraint k
          where k.conrelid = 'public.notifications'::regclass and k.conname = 'notifications_type_check')
        is distinct from 'd6c0cf7d4d7aab931ecd5010be1ea212'
     or has_function_privilege('authenticated', 'public.notification_category(text)', 'execute')
     or has_function_privilege('anon', 'public.notification_category(text)', 'execute') then
    raise exception 'rollback 35 self-check: the type list / notification_category is not migration 33''s';
  end if;
  if to_regclass('public.tournaments') is not null or to_regclass('public.tournament_registrations') is not null
     or to_regclass('public.tournament_registration_players') is not null or to_regclass('public.tournament_fixtures') is not null
     or exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public'
                   and (p.proname like '%tournament%')) then
    raise exception 'rollback 35 self-check: something of migration 35 is left';
  end if;
end $$;

notify pgrst, 'reload schema';
