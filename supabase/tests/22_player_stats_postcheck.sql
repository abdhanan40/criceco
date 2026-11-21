-- CricEco · post-check for migration 22 (player statistics).
-- READ-ONLY: one SELECT, no DML/DDL, no personal data. Every row must say PASS.
-- Safe before the migration too (the new objects then FAIL).
with checks(check_name, expected, actual) as (
  values
    ('01 the 5 functions exist: SECURITY DEFINER, empty search_path', '5/5',
       (select count(*)::text || '/' ||
               count(*) filter (where p.prosecdef and array_to_string(p.proconfig, ',') like '%search_path=""%')::text
          from pg_proc p where p.pronamespace = 'public'::regnamespace
           and p.proname in ('member_stats', 'can_view_player_stats', 'player_stats', 'club_member_stats',
                             'player_match_log'))),
    ('02 the 3 API functions: authenticated yes, anon no', '3/0',
       (select count(*) filter (where has_function_privilege('authenticated', p.oid, 'execute'))::text || '/'
               || count(*) filter (where has_function_privilege('anon', p.oid, 'execute'))::text
          from pg_proc p where p.pronamespace = 'public'::regnamespace
           and p.proname in ('player_stats', 'club_member_stats', 'player_match_log'))),
    ('03 internal helpers: not callable by app roles', '2/0/0',
       (select count(*)::text || '/'
               || count(*) filter (where has_function_privilege('authenticated', p.oid, 'execute'))::text || '/'
               || count(*) filter (where has_function_privilege('anon', p.oid, 'execute'))::text
          from pg_proc p where p.pronamespace = 'public'::regnamespace
           and p.proname in ('member_stats', 'can_view_player_stats'))),
    ('04 signatures: player_stats(uuid), club_member_stats(uuid), player_match_log(uuid, integer)', 'true',
       (to_regprocedure('public.player_stats(uuid)') is not null
        and to_regprocedure('public.club_member_stats(uuid)') is not null
        and to_regprocedure('public.player_match_log(uuid, integer)') is not null)::text),
    ('05 no rating / skill / verified output (decision 10)', '0',
       (select count(*)::text from pg_proc p, unnest(p.proargnames) a
         where p.pronamespace = 'public'::regnamespace
           and p.proname in ('member_stats', 'player_stats', 'club_member_stats', 'player_match_log')
           and a in ('rating', 'skill', 'verified'))),
    ('06 migration 21 (scorecards) present', 'true',
       (to_regclass('public.match_batting') is not null and to_regclass('public.match_bowling') is not null)::text)
)
select check_name, expected, actual,
       case when actual is not distinct from expected then 'PASS' else 'FAIL' end as result
  from checks
 order by check_name;
