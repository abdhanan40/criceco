-- CricEco · post-check for migration 34 (M9 fitness).
-- READ-ONLY: one SELECT, no DML/DDL, no personal data (counts only). Every row
-- must say PASS (rows marked INFO only report). Safe before the migration too
-- (the new objects then FAIL).
with
fn as (select to_regprocedure('public.log_workout(date, text, integer, text, text)') as log,
              to_regprocedure('public.my_workouts(date, date)') as mine,
              to_regprocedure('public.delete_workout(uuid)') as del,
              to_regprocedure('public.club_member_fitness(uuid, date, date)') as cmf,
              to_regprocedure('public.club_member_workouts(uuid, date, date)') as cmw,
              to_regprocedure('public.club_member_match_activity(uuid, date, date)') as cma,
              to_regprocedure('public.fitness_member_matches(uuid, date, date)') as helper),
rpcs as (select f.oid from fn, lateral unnest(array[fn.log, fn.mine, fn.del, fn.cmf, fn.cmw, fn.cma]) f(oid)
          where f.oid is not null),
tbl as (select to_regclass('public.player_workouts') as t),
checks(check_name, expected, actual) as (
  values
    ('01 player_workouts columns (name type nullable default)',
     'created_at timestamp with time zone NO now(); id uuid NO gen_random_uuid(); intensity text NO -; minutes integer NO -; notes text YES -; user_id uuid NO -; workout_date date NO -; workout_type text NO -',
       (select coalesce(string_agg(c.column_name || ' ' || c.data_type || ' ' || c.is_nullable || ' ' || coalesce(c.column_default, '-'),
                                   '; ' order by c.column_name), 'missing')
          from information_schema.columns c where c.table_schema = 'public' and c.table_name = 'player_workouts')),
    ('02 the five CHECKs exist and are validated; the date window is Asia/Karachi, 0–365 days before created_at', '5|true',
       (select count(*)::text || '|'
               || coalesce(bool_and(k.convalidated)
                           and bool_or(k.conname = 'player_workouts_date_window'
                                       and pg_get_constraintdef(k.oid) like '%workout_date <= ((created_at AT TIME ZONE ''Asia/Karachi''::text))::date%'
                                       and pg_get_constraintdef(k.oid) like '%::date - 365)%'), false)::text
          from pg_constraint k, tbl
         where k.conrelid = tbl.t
           and k.conname in ('player_workouts_type_check', 'player_workouts_minutes_check', 'player_workouts_intensity_check',
                             'player_workouts_notes_check', 'player_workouts_date_window'))),
    ('03 the enums and bounds match the app (types, intensities, minutes 1–600, notes 1–120 trimmed)', 'true',
       (select coalesce(bool_and(case k.conname
                 when 'player_workouts_type_check' then pg_get_constraintdef(k.oid) like '%''training''::text, ''gym''::text, ''running''::text, ''nets''::text, ''other''::text%'
                 when 'player_workouts_intensity_check' then pg_get_constraintdef(k.oid) like '%''light''::text, ''moderate''::text, ''high''::text%'
                 when 'player_workouts_minutes_check' then pg_get_constraintdef(k.oid) like '%minutes >= 1%minutes <= 600%'
                 else pg_get_constraintdef(k.oid) like '%notes = btrim(notes)%char_length(notes) <= 120%' end)
               and count(*) = 4, false)::text
          from pg_constraint k, tbl
         where k.conrelid = tbl.t
           and k.conname in ('player_workouts_type_check', 'player_workouts_minutes_check', 'player_workouts_intensity_check',
                             'player_workouts_notes_check'))),
    ('04 user_id → profiles ON DELETE CASCADE (account deletion removes the workouts)', 'true',
       (select coalesce((select (k.confrelid = 'public.profiles'::regclass and k.confdeltype = 'c')::text
                           from pg_constraint k, tbl
                          where k.conrelid = tbl.t and k.conname = 'player_workouts_user_id_fkey' and k.contype = 'f'), 'missing'))),
    ('05 RLS on; one policy: SELECT own rows, to authenticated', 'true|1|true',
       (select coalesce((select c.relrowsecurity::text from pg_class c, tbl where c.oid = tbl.t), 'missing') || '|'
               || (select count(*)::text from pg_policy p, tbl where p.polrelid = tbl.t) || '|'
               || coalesce((select (p.polcmd = 'r' and p.polpermissive
                                    and p.polroles = array[(select oid from pg_roles where rolname = 'authenticated')]::oid[]
                                    -- "auth." is left out when auth is on the session's search_path
                                    and pg_get_expr(p.polqual, p.polrelid) ~ '^\(user_id = \( SELECT (auth\.)?uid\(\) AS uid\)\)$')::text
                              from pg_policy p, tbl where p.polrelid = tbl.t and p.polname = 'player_workouts: select own'), 'missing'))),
    ('06 table grants: authenticated SELECT only; anon and service_role nothing', 'true|false|false|false',
       (select case when (select t from tbl) is null then 'missing' else
                 has_table_privilege('authenticated', 'public.player_workouts', 'SELECT')::text || '|'
                 || has_table_privilege('authenticated', 'public.player_workouts', 'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')::text || '|'
                 || has_table_privilege('anon', 'public.player_workouts', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')::text || '|'
                 || has_table_privilege('service_role', 'public.player_workouts', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')::text end)),
    ('07 indexes (user_id, workout_date) and (user_id, created_at)', '2',
       (select count(*)::text from pg_indexes i
         where i.schemaname = 'public' and i.tablename = 'player_workouts'
           and ((i.indexname = 'player_workouts_user_date_idx' and i.indexdef like '%(user_id, workout_date)')
                or (i.indexname = 'player_workouts_user_created_idx' and i.indexdef like '%(user_id, created_at)')))),
    ('08 the six RPCs: SECURITY DEFINER, search_path '''', authenticated may execute, anon not', '6',
       (select count(*)::text from rpcs r join pg_proc p on p.oid = r.oid
         where p.prosecdef and array_to_string(p.proconfig, ',') = 'search_path=""'
           and has_function_privilege('authenticated', p.oid, 'execute')
           and not has_function_privilege('anon', p.oid, 'execute'))),
    ('09 fitness_member_matches (internal): SECURITY DEFINER, closed to anon / authenticated', 'true|false',
       (select coalesce((select (p.prosecdef and array_to_string(p.proconfig, ',') = 'search_path=""')::text || '|'
                                || (has_function_privilege('authenticated', p.oid, 'execute')
                                    or has_function_privilege('anon', p.oid, 'execute'))::text
                           from pg_proc p, fn where p.oid = fn.helper), 'missing'))),
    ('10 log_workout / my_workouts result columns',
     'TABLE(id uuid, workout_date date, workout_type text, minutes integer, intensity text, notes text, created_at timestamp with time zone)|same|void',
       (select coalesce(pg_get_function_result(fn.log), 'missing') || '|'
               || case when pg_get_function_result(fn.mine) = pg_get_function_result(fn.log) then 'same'
                       else coalesce(pg_get_function_result(fn.mine), 'missing') end || '|'
               || coalesce(pg_get_function_result(fn.del), 'missing') from fn)),
    ('11 club_member_fitness result columns',
     'TABLE(member_id uuid, user_id uuid, member_role text, fitness_visible boolean, workout_sessions integer, workout_minutes integer, training_load numeric, last_workout_date date, matches integer, last_match_date date)',
       (select coalesce(pg_get_function_result(fn.cmf), 'missing') from fn)),
    ('12 club_member_workouts result columns (no notes)',
     'TABLE(member_id uuid, workout_id uuid, workout_date date, workout_type text, minutes integer, intensity text)',
       (select coalesce(pg_get_function_result(fn.cmw), 'missing') from fn)),
    ('13 club_member_match_activity result columns',
     'TABLE(member_id uuid, match_id uuid, starts_at timestamp with time zone, club_id uuid, club_name text, opponent_club_id uuid, opponent_name text, result text, bat_runs integer, bat_balls integer, bowl_balls integer, bowl_runs integer, bowl_wickets integer)',
       (select coalesce(pg_get_function_result(fn.cma), 'missing') from fn)),
    ('14 the owner views honour profiles.show_stats and active membership; limits 10 / day and 30 / 24 h in log_workout', 'true',
       (select coalesce((select bool_and(p.prosrc like '%p.show_stats or m.user_id = (select auth.uid())%'
                                         and p.prosrc like '%m.status = ''active''%'
                                         and p.prosrc like '%c.owner_id = (select auth.uid())%')
                           from pg_proc p, fn where p.oid in (fn.cmf, fn.cmw, fn.cma))
                        and (select p.prosrc like '%>= 10 then%' and p.prosrc like '%interval ''24 hours'') >= 30 then%'
                               from pg_proc p, fn where p.oid = fn.log), false)::text)),
    ('15 workouts / people with workouts (INFO)', 'info',
       (select case when (select t from tbl) is null then 'missing' else
                 (xpath('/row/c/text()', query_to_xml(
                    'select (select count(*) from public.player_workouts) || '' / ''
                            || (select count(distinct user_id) from public.player_workouts) as c',
                    false, true, '')))[1]::text end))
)
select check_name, expected, actual,
       case when expected = 'info' then 'INFO'
            when actual is not distinct from expected then 'PASS' else 'FAIL' end as result
  from checks
 order by check_name;
