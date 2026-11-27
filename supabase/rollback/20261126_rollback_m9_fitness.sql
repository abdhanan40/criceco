-- CricEco · ROLLBACK of migration 34 (M9 fitness).
--
-- NOT APPLIED. Run only with explicit approval, after a backup, inside
--   begin; set local lock_timeout = '5s'; <this file> commit;
-- FIRST roll back (or never ship) an app build that calls log_workout,
-- my_workouts, delete_workout, club_member_fitness, club_member_workouts or
-- club_member_match_activity, or reads player_workouts: after this file they
-- are gone.
--
-- Reverses migration 34: drops the seven functions and the table
-- player_workouts with its policy, constraints and indexes. Every logged
-- workout is LOST (take a backup / export first if they matter). Nothing
-- else is changed: migration 34 replaced no existing object.

do $$
begin
  if to_regclass('public.player_workouts') is null
     or to_regprocedure('public.log_workout(date, text, integer, text, text)') is null
     or to_regprocedure('public.my_workouts(date, date)') is null
     or to_regprocedure('public.delete_workout(uuid)') is null
     or to_regprocedure('public.club_member_fitness(uuid, date, date)') is null
     or to_regprocedure('public.club_member_workouts(uuid, date, date)') is null
     or to_regprocedure('public.club_member_match_activity(uuid, date, date)') is null
     or to_regprocedure('public.fitness_member_matches(uuid, date, date)') is null then
    raise exception 'rollback 34: migration 34 is not (fully) applied — nothing changed';
  end if;
end $$;

do $$
declare
  v_rows bigint;
begin
  select count(*) into v_rows from public.player_workouts;
  raise notice 'rollback 34: dropping player_workouts with % logged workout(s)', v_rows;
end $$;

drop function public.club_member_match_activity(uuid, date, date);
drop function public.club_member_workouts(uuid, date, date);
drop function public.club_member_fitness(uuid, date, date);
drop function public.fitness_member_matches(uuid, date, date);
drop function public.delete_workout(uuid);
drop function public.my_workouts(date, date);
drop function public.log_workout(date, text, integer, text, text);

drop table public.player_workouts;

do $$
begin
  if to_regclass('public.player_workouts') is not null
     or exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace
                   and p.proname in ('log_workout', 'my_workouts', 'delete_workout', 'club_member_fitness',
                                     'club_member_workouts', 'club_member_match_activity',
                                     'fitness_member_matches')) then
    raise exception 'rollback 34 self-check: an object of migration 34 is still there';
  end if;
end $$;

notify pgrst, 'reload schema';
