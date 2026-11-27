-- CricEco · ROLLBACK of migration 32 (M7 club discovery:
-- supabase/migrations/20261126090200_m7_club_discovery.sql)
--
-- Run only with separate approval, after a fresh backup, inside
--   begin; set local lock_timeout = '5s'; <this file> commit;
-- First roll back any app build that calls the functions below.
--
-- Drops everything migration 32 added: the ten functions and the table
-- public.club_match_slots WITH ITS ROWS (every posted availability slot is
-- lost). Nothing else is touched: migration 32 changed no existing object.
-- A rolled-back database has the same catalogue as after migration 31.

do $$
begin
  if to_regclass('public.club_match_slots') is null
     or to_regprocedure('public.player_rankings(text, uuid, text, integer)') is null then
    raise exception 'rollback 32: migration 32 is not applied — nothing changed';
  end if;
end $$;

do $$
declare
  v_slots bigint;
begin
  select count(*) into v_slots from public.club_match_slots;
  raise notice 'rollback 32: dropping public.club_match_slots with % row(s)', v_slots;
end $$;

drop function public.club_applicant_stats(uuid);
drop function public.player_rankings(text, uuid, text, integer);
drop function public.player_recent_form(uuid[]);
drop function public.open_match_slots(text, text, date, date, integer, integer);
drop function public.my_club_slots(uuid, boolean);
drop function public.withdraw_match_slot(uuid);
drop function public.post_match_slot(uuid, text, integer, text, date, time, time, text, text, text);
drop function public.club_directory(text, text, integer, integer);
drop function public.club_public_profile(uuid);
drop function public.club_public_stats(uuid);

drop table public.club_match_slots;

do $$
begin
  if to_regclass('public.club_match_slots') is not null
     or exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public'
                   and p.proname in ('club_public_stats', 'club_public_profile', 'club_directory',
                                     'post_match_slot', 'withdraw_match_slot', 'my_club_slots', 'open_match_slots',
                                     'player_recent_form', 'player_rankings', 'club_applicant_stats')) then
    raise exception 'rollback 32 self-check: an object of migration 32 is still there';
  end if;
end $$;

notify pgrst, 'reload schema';
