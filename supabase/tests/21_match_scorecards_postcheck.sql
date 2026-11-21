-- CricEco · post-check for migration 21 (match scorecards).
-- READ-ONLY: one SELECT, no DML/DDL, no personal data. Every row must say PASS.
-- Safe before the migration too (the new objects then FAIL / ABSENT).
with checks(check_name, expected, actual) as (
  values
    ('01 tables match_batting / match_bowling exist, RLS on', 'true/true',
       coalesce((select relrowsecurity::text from pg_class where oid = to_regclass('public.match_batting')), 'ABSENT')
       || '/' ||
       coalesce((select relrowsecurity::text from pg_class where oid = to_regclass('public.match_bowling')), 'ABSENT')),
    ('02 one SELECT policy per table; no other policy', '1/1|1/1',
       (select count(*) filter (where cmd = 'SELECT' and tablename = 'match_batting')::text || '/'
               || count(*) filter (where tablename = 'match_batting')::text || '|'
               || count(*) filter (where cmd = 'SELECT' and tablename = 'match_bowling')::text || '/'
               || count(*) filter (where tablename = 'match_bowling')::text
          from pg_policies where schemaname = 'public' and tablename in ('match_batting', 'match_bowling'))),
    ('03 authenticated: SELECT only; anon / PUBLIC: nothing (both tables)', 'true',
       (to_regclass('public.match_batting') is not null and to_regclass('public.match_bowling') is not null
        and not exists (select 1 from information_schema.role_table_grants
                         where table_schema = 'public' and table_name in ('match_batting', 'match_bowling')
                           and ((grantee = 'authenticated' and privilege_type <> 'SELECT')
                                or grantee in ('anon', 'PUBLIC')))
        and (select count(*) from information_schema.role_table_grants
              where table_schema = 'public' and table_name in ('match_batting', 'match_bowling')
                and grantee = 'authenticated' and privilege_type = 'SELECT') = 2)::text),
    ('04 primary keys and one-row-per-player keys', '2/2',
       (select count(*) filter (where contype = 'p')::text || '/' || count(*) filter (where contype = 'u')::text
          from pg_constraint where connamespace = 'public'::regnamespace
           and conname in ('match_batting_pkey', 'match_bowling_pkey',
                           'match_batting_one_row_per_player', 'match_bowling_one_row_per_player'))),
    ('05 check constraints on the two tables', '28',
       (select count(*)::text from pg_constraint
         where contype = 'c' and conrelid in (coalesce(to_regclass('public.match_batting'), 0::regclass),
                                              coalesce(to_regclass('public.match_bowling'), 0::regclass)))),
    ('06 FK delete rules: innings CASCADE, bowler row CASCADE, people SET NULL', 'c/n/c/c/n/n',
       (select coalesce(max(confdeltype::text) filter (where conname = 'match_bowling_innings_fkey'), '-') || '/'
               || coalesce(max(confdeltype::text) filter (where conname = 'match_bowling_member_id_fkey'), '-') || '/'
               || coalesce(max(confdeltype::text) filter (where conname = 'match_batting_innings_fkey'), '-') || '/'
               || coalesce(max(confdeltype::text) filter (where conname = 'match_batting_bowler_fkey'), '-') || '/'
               || coalesce(max(confdeltype::text) filter (where conname = 'match_batting_member_id_fkey'), '-') || '/'
               || coalesce(max(confdeltype::text) filter (where conname = 'match_batting_fielder_member_id_fkey'), '-')
          from pg_constraint where connamespace = 'public'::regnamespace and contype = 'f')),
    ('07 member look-up indexes', '3',
       (select count(*)::text from pg_indexes where schemaname = 'public'
           and indexname in ('match_batting_member_idx', 'match_batting_fielder_idx', 'match_bowling_member_idx'))),
    ('08 triggers: two card guards, forget-on-account-deletion', '3',
       (select count(*)::text from pg_trigger
         where not tgisinternal
           and ((tgrelid = to_regclass('public.match_batting') and tgname = 'match_batting_guard')
             or (tgrelid = to_regclass('public.match_bowling') and tgname = 'match_bowling_guard')
             or (tgrelid = to_regclass('public.club_members') and tgname = 'club_members_forget_match_scorecards')))),
    ('09 the 5 privileged functions: SECURITY DEFINER, empty search_path', '5/5',
       (select count(*)::text || '/' ||
               count(*) filter (where p.prosecdef and array_to_string(p.proconfig, ',') like '%search_path=""%')::text
          from pg_proc p where p.pronamespace = 'public'::regnamespace
           and p.proname in ('club_members_forget_match_scorecards', 'match_club_player_pool', 'match_player_pool',
                             'submit_match_result_with_scorecard', 'match_scorecard'))),
    ('10 the 3 API functions: authenticated yes, anon no', '3/0',
       (select count(*) filter (where has_function_privilege('authenticated', p.oid, 'execute'))::text || '/'
               || count(*) filter (where has_function_privilege('anon', p.oid, 'execute'))::text
          from pg_proc p where p.pronamespace = 'public'::regnamespace
           and p.proname in ('match_player_pool', 'submit_match_result_with_scorecard', 'match_scorecard'))),
    ('11 helpers and trigger functions: not callable by app roles', '5/0/0',
       (select count(*)::text || '/'
               || count(*) filter (where has_function_privilege('authenticated', p.oid, 'execute'))::text || '/'
               || count(*) filter (where has_function_privilege('anon', p.oid, 'execute'))::text
          from pg_proc p where p.pronamespace = 'public'::regnamespace
           and p.proname in ('match_scorecards_guard', 'club_members_forget_match_scorecards', 'match_bowler_max_balls',
                             'match_dismissal_text', 'match_club_player_pool'))),
    ('12 row counts (batting / bowling)', '0/0',
       case when to_regclass('public.match_batting') is null or to_regclass('public.match_bowling') is null then 'ABSENT'
            else (xpath('/row/v/text()', query_to_xml(
              'select (select count(*) from public.match_batting)::text || ''/'' || (select count(*) from public.match_bowling)::text as v',
              false, true, '')))[1]::text end)
)
select check_name, expected, actual,
       case when actual is not distinct from expected then 'PASS' else 'FAIL' end as result
  from checks
 order by check_name;
