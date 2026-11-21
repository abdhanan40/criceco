-- CricEco · post-check for migration 24 (result write lockdown and the
-- trusted scorer foundation). READ-ONLY: one SELECT, no DML/DDL, no personal
-- data. Every row must say PASS. Safe before the migration too (it then FAILs).
-- After migration 24 this check replaces post-checks 20 and 21 (which
-- describe the owner write functions that 24 removes).
with checks(check_name, expected, actual) as (
  values
    ('01 owner write functions and match_player_pool are gone', '0',
       (select count(*)::text from pg_proc p where p.pronamespace = 'public'::regnamespace
           and p.proname in ('submit_match_result', 'submit_match_result_with_scorecard', 'confirm_match_result',
                             'dispute_match_result', 'match_player_pool'))),
    ('02 scorer tables exist, RLS on, no policy', '4/4/0',
       (select count(*)::text || '/' || count(*) filter (where c.relrowsecurity)::text || '/'
               || (select count(*) from pg_policies where schemaname = 'public'
                     and tablename in ('scorer_clients', 'match_officials', 'result_submission_log',
                                       'result_change_log'))::text
          from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
           and c.relname in ('scorer_clients', 'match_officials', 'result_submission_log', 'result_change_log'))),
    ('03 scorer tables: no table privilege for anon / authenticated / service_role', 'true',
       (to_regclass('public.scorer_clients') is not null
        and not exists (select 1 from information_schema.role_table_grants
                         where table_schema = 'public'
                           and table_name in ('scorer_clients', 'match_officials', 'result_submission_log',
                                              'result_change_log')
                           and grantee in ('anon', 'authenticated', 'service_role', 'PUBLIC')))::text),
    ('04 result tables: SELECT only for authenticated / service_role; nothing for anon', 'true',
       (to_regclass('public.match_results') is not null
        and not exists (select 1 from information_schema.role_table_grants
                         where table_schema = 'public'
                           and table_name in ('match_results', 'match_innings', 'match_batting', 'match_bowling')
                           and ((grantee in ('authenticated', 'service_role') and privilege_type <> 'SELECT')
                                or grantee in ('anon', 'PUBLIC'))))::text),
    ('05 read rules: one per result table, all for the official (confirmed) version', '4/4',
       (select count(*)::text || '/' || count(*) filter (where qual like '%confirmed%' and qual not like '%OR (%status%')::text
          from pg_policies where schemaname = 'public'
           and tablename in ('match_results', 'match_innings', 'match_batting', 'match_bowling'))),
    ('06 the 6 scorer functions: SECURITY DEFINER, empty search_path; service_role only', '6/6|6/0/0',
       (select count(*)::text || '/'
               || count(*) filter (where p.prosecdef and array_to_string(p.proconfig, ',') like '%search_path=""%')::text
               || '|' || count(*) filter (where has_function_privilege('service_role', p.oid, 'execute'))::text
               || '/' || count(*) filter (where has_function_privilege('authenticated', p.oid, 'execute'))::text
               || '/' || count(*) filter (where has_function_privilege('anon', p.oid, 'execute'))::text
          from pg_proc p where p.pronamespace = 'public'::regnamespace
           and p.proname in ('ingest_official_result', 'verify_official_result', 'correct_official_result',
                             'assign_match_official', 'unassign_match_official', 'official_match_roster'))),
    ('07 the 8 read API functions: authenticated yes, anon no', '8/0',
       (select count(*) filter (where has_function_privilege('authenticated', p.oid, 'execute'))::text || '/'
               || count(*) filter (where has_function_privilege('anon', p.oid, 'execute'))::text
          from pg_proc p where p.pronamespace = 'public'::regnamespace
           and p.proname in ('match_result', 'match_scorecard', 'club_results', 'club_record', 'player_stats',
                             'club_member_stats', 'player_match_log', 'my_matches'))),
    ('08 internal functions: nobody may call them (anon / authenticated / service_role)', '17/0/0/0',
       (select count(*)::text || '/'
               || count(*) filter (where has_function_privilege('anon', p.oid, 'execute'))::text || '/'
               || count(*) filter (where has_function_privilege('authenticated', p.oid, 'execute'))::text || '/'
               || count(*) filter (where has_function_privilege('service_role', p.oid, 'execute'))::text
          from pg_proc p where p.pronamespace = 'public'::regnamespace
           and p.proname in ('official_result_store', 'official_result_decide', 'official_result_submit',
                             'result_tables_audit', 'audit_log_append_only', 'match_format_max_balls',
                             'match_result_summary', 'match_results_guard_update', 'match_innings_guard',
                             'club_members_forget_match_results', 'match_scorecards_guard',
                             'club_members_forget_match_scorecards', 'match_bowler_max_balls',
                             'match_dismissal_text', 'match_club_player_pool', 'member_stats',
                             'can_view_player_stats'))),
    ('09 audit triggers: 4 append-only on the logs, 5 change records, guard on insert and update', '4/5/true',
       (select count(*) filter (where tgname in ('result_submission_log_append_only', 'result_submission_log_no_truncate',
                                                 'result_change_log_append_only', 'result_change_log_no_truncate'))::text
               || '/' || count(*) filter (where tgname in ('match_results_audit', 'match_innings_audit',
                                                           'match_batting_audit', 'match_bowling_audit',
                                                           'match_officials_audit'))::text
               || '/' || coalesce(bool_or(tgname = 'match_results_guard_update'
                                          and pg_get_triggerdef(oid) like '%BEFORE INSERT OR UPDATE%'), false)::text
          from pg_trigger where not tgisinternal
           and tgrelid in (select oid from pg_class where relnamespace = 'public'::regnamespace))),
    ('10 match_results: no owner / dispute columns; official provenance columns present', '0/7',
       (select count(*) filter (where attname in ('submitted_by_club_id', 'submitted_by', 'decided_by_club_id',
                                                  'decided_by', 'dispute_reason'))::text || '/'
               || count(*) filter (where attname in ('source', 'scorer_client_id', 'submission_id',
                                                     'decided_by_client_id', 'decision_note', 'corrects_version',
                                                     'correction_reason'))::text
          from pg_attribute where attrelid = to_regclass('public.match_results') and attnum > 0 and not attisdropped)),
    ('11 statuses: submitted / confirmed / rejected / superseded (no disputed)', 'true',
       (exists (select 1 from pg_constraint where conname = 'match_results_status_check'
                  and pg_get_constraintdef(oid) like '%rejected%' and pg_get_constraintdef(oid) not like '%disputed%'))::text),
    ('12 row counts (results / clients / assignments / submission log / change log)', '0/0/0/0/0',
       case when to_regclass('public.scorer_clients') is null then 'ABSENT'
            else (xpath('/row/v/text()', query_to_xml(
              'select (select count(*) from public.match_results)::text || ''/'' || (select count(*) from public.scorer_clients)::text
                      || ''/'' || (select count(*) from public.match_officials)::text
                      || ''/'' || (select count(*) from public.result_submission_log)::text
                      || ''/'' || (select count(*) from public.result_change_log)::text as v',
              false, true, '')))[1]::text end)
)
select check_name, expected, actual,
       case when actual is not distinct from expected then 'PASS' else 'FAIL' end as result
  from checks
 order by check_name;
