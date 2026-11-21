-- CricEco · post-check for migration 20 (match results and innings totals).
-- READ-ONLY: one SELECT, no DML/DDL, no personal data. Every row must say PASS.
-- Safe before the migration too (the new objects then FAIL / ABSENT).
with checks(check_name, expected, actual) as (
  values
    ('01 tables match_results / match_innings exist, RLS on', 'true/true',
       coalesce((select relrowsecurity::text from pg_class where oid = to_regclass('public.match_results')), 'ABSENT')
       || '/' ||
       coalesce((select relrowsecurity::text from pg_class where oid = to_regclass('public.match_innings')), 'ABSENT')),
    ('02 one SELECT policy per table; no other policy', '1/1|1/1',
       (select count(*) filter (where cmd = 'SELECT' and tablename = 'match_results')::text || '/'
               || count(*) filter (where tablename = 'match_results')::text || '|'
               || count(*) filter (where cmd = 'SELECT' and tablename = 'match_innings')::text || '/'
               || count(*) filter (where tablename = 'match_innings')::text
          from pg_policies where schemaname = 'public' and tablename in ('match_results', 'match_innings'))),
    ('03 authenticated: SELECT only; anon / PUBLIC: nothing (both tables)', 'true',
       (to_regclass('public.match_results') is not null and to_regclass('public.match_innings') is not null
        and not exists (select 1 from information_schema.role_table_grants
                         where table_schema = 'public' and table_name in ('match_results', 'match_innings')
                           and ((grantee = 'authenticated' and privilege_type <> 'SELECT')
                                or grantee in ('anon', 'PUBLIC')))
        and (select count(*) from information_schema.role_table_grants
              where table_schema = 'public' and table_name in ('match_results', 'match_innings')
                and grantee = 'authenticated' and privilege_type = 'SELECT') = 2)::text),
    ('04 keys: (match, version) results; (match, version, innings) innings', '2',
       (select count(*)::text from pg_constraint where connamespace = 'public'::regnamespace and contype = 'p'
          and conname in ('match_results_pkey', 'match_innings_pkey'))),
    ('05 one waiting and one confirmed version per match (unique partial indexes)', 'true',
       (exists (select 1 from pg_indexes where schemaname = 'public' and indexname = 'match_results_one_submitted_key'
                  and indexdef like 'CREATE UNIQUE INDEX%' and indexdef like '%submitted%')
        and exists (select 1 from pg_indexes where schemaname = 'public' and indexname = 'match_results_one_confirmed_key'
                  and indexdef like 'CREATE UNIQUE INDEX%' and indexdef like '%confirmed%'))::text),
    ('06 named check constraints present', '28',
       (select count(*)::text from pg_constraint where connamespace = 'public'::regnamespace and contype = 'c'
          and conname in ('match_results_version_check', 'match_results_status_check', 'match_results_outcome_check',
                          'match_results_margin_runs_check', 'match_results_margin_wickets_check',
                          'match_results_player_of_match_name_check', 'match_results_dispute_reason_check',
                          'match_results_one_margin', 'match_results_margin_only_for_wins',
                          'match_results_decided_consistency', 'match_results_dispute_reason_only_when_disputed',
                          'match_results_player_of_match_consistency', 'match_results_deleted_player_has_no_name',
                          'match_innings_innings_no_check', 'match_innings_runs_check', 'match_innings_wickets_check',
                          'match_innings_balls_check', 'match_innings_byes_check', 'match_innings_leg_byes_check',
                          'match_innings_wides_check', 'match_innings_no_balls_check', 'match_innings_penalty_check',
                          'match_innings_two_clubs', 'match_innings_extras_within_runs',
                          'match_innings_declared_not_all_out',
                          'matches_status_check', 'matches_scheduled_when_confirmed', 'matches_two_clubs'))),
    ('07 FK delete rules: match CASCADE, people SET NULL, innings CASCADE', 'c/n/n/n/c',
       (select coalesce(max(confdeltype::text) filter (where conname = 'match_results_match_id_fkey'), '-') || '/'
               || coalesce(max(confdeltype::text) filter (where conname = 'match_results_player_of_match_member_id_fkey'), '-') || '/'
               || coalesce(max(confdeltype::text) filter (where conname = 'match_results_submitted_by_fkey'), '-') || '/'
               || coalesce(max(confdeltype::text) filter (where conname = 'match_results_decided_by_fkey'), '-') || '/'
               || coalesce(max(confdeltype::text) filter (where conname = 'match_innings_result_fkey'), '-')
          from pg_constraint where connamespace = 'public'::regnamespace and contype = 'f')),
    ('08 triggers: result guard, innings guard, forget-on-account-deletion', '3',
       (select count(*)::text from pg_trigger
         where not tgisinternal
           and ((tgrelid = to_regclass('public.match_results') and tgname = 'match_results_guard_update')
             or (tgrelid = to_regclass('public.match_innings') and tgname = 'match_innings_guard')
             or (tgrelid = to_regclass('public.club_members') and tgname = 'club_members_forget_match_results')))),
    ('09 the 8 privileged functions: SECURITY DEFINER, empty search_path', '8/8',
       (select count(*)::text || '/' ||
               count(*) filter (where p.prosecdef and array_to_string(p.proconfig, ',') like '%search_path=""%')::text
          from pg_proc p where p.pronamespace = 'public'::regnamespace
           and p.proname in ('club_members_forget_match_results', 'match_result_summary', 'submit_match_result',
                             'confirm_match_result', 'dispute_match_result', 'match_result', 'club_results',
                             'club_record'))),
    ('10 the 6 API functions: authenticated yes, anon no', '6/0',
       (select count(*) filter (where has_function_privilege('authenticated', p.oid, 'execute'))::text || '/'
               || count(*) filter (where has_function_privilege('anon', p.oid, 'execute'))::text
          from pg_proc p where p.pronamespace = 'public'::regnamespace
           and p.proname in ('submit_match_result', 'confirm_match_result', 'dispute_match_result', 'match_result',
                             'club_results', 'club_record'))),
    ('11 helpers and trigger functions: not callable by app roles', '5/0/0',
       (select count(*)::text || '/'
               || count(*) filter (where has_function_privilege('authenticated', p.oid, 'execute'))::text || '/'
               || count(*) filter (where has_function_privilege('anon', p.oid, 'execute'))::text
          from pg_proc p where p.pronamespace = 'public'::regnamespace
           and p.proname in ('match_format_max_balls', 'match_result_summary', 'match_results_guard_update',
                             'match_innings_guard', 'club_members_forget_match_results'))),
    ('12 row counts (results / innings); matches completed', '0/0/0',
       case when to_regclass('public.match_results') is null or to_regclass('public.match_innings') is null then 'ABSENT'
            else (xpath('/row/v/text()', query_to_xml(
              'select (select count(*) from public.match_results)::text || ''/'' || (select count(*) from public.match_innings)::text
                      || ''/'' || (select count(*) from public.matches where status = ''completed'')::text as v',
              false, true, '')))[1]::text end)
)
select check_name, expected, actual,
       case when actual is not distinct from expected then 'PASS' else 'FAIL' end as result
  from checks
 order by check_name;
