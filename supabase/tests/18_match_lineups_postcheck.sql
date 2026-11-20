-- CricEco · post-check for migration 18 (match lineups).
-- READ-ONLY: one SELECT, no DML/DDL, no personal data. Every row must say PASS.
-- Safe before the migration too (the new objects then FAIL / ABSENT).
with checks(check_name, expected, actual) as (
  values
    ('01 tables match_lineups / match_lineup_players exist, RLS on', 'true/true',
       coalesce((select relrowsecurity::text from pg_class where oid = to_regclass('public.match_lineups')), 'ABSENT')
       || '/' ||
       coalesce((select relrowsecurity::text from pg_class where oid = to_regclass('public.match_lineup_players')), 'ABSENT')),
    ('02 one SELECT policy per table; no other policy', '1/1|1/1',
       (select count(*) filter (where cmd = 'SELECT' and tablename = 'match_lineups')::text || '/'
               || count(*) filter (where tablename = 'match_lineups')::text || '|'
               || count(*) filter (where cmd = 'SELECT' and tablename = 'match_lineup_players')::text || '/'
               || count(*) filter (where tablename = 'match_lineup_players')::text
          from pg_policies where schemaname = 'public' and tablename in ('match_lineups', 'match_lineup_players'))),
    ('03 authenticated: SELECT only; anon / PUBLIC: nothing (both tables)', 'true',
       (to_regclass('public.match_lineups') is not null and to_regclass('public.match_lineup_players') is not null
        and not exists (select 1 from information_schema.role_table_grants
                         where table_schema = 'public' and table_name in ('match_lineups', 'match_lineup_players')
                           and ((grantee = 'authenticated' and privilege_type <> 'SELECT')
                                or grantee in ('anon', 'PUBLIC')))
        and (select count(*) from information_schema.role_table_grants
              where table_schema = 'public' and table_name in ('match_lineups', 'match_lineup_players')
                and grantee = 'authenticated' and privilege_type = 'SELECT') = 2)::text),
    ('04 keys: (match, club) lineup; (match, club, member) player; unique position', '3',
       (select count(*)::text from pg_constraint where connamespace = 'public'::regnamespace
          and ((conname = 'match_lineups_pkey' and contype = 'p')
            or (conname = 'match_lineup_players_pkey' and contype = 'p')
            or (conname = 'match_lineup_players_position_key' and contype = 'u')))),
    ('05 named check constraints present', '4',
       (select count(*)::text from pg_constraint where connamespace = 'public'::regnamespace and contype = 'c'
          and conname in ('match_lineups_name_check', 'match_lineups_leaders_distinct',
                          'match_lineup_players_selection_check', 'match_lineup_players_position_check'))),
    ('06 FK delete rules: match/club CASCADE, team RESTRICT, captain/vice/saver SET NULL, lineup/member CASCADE',
     'c/c/r/n/n/n/c/c',
       (select coalesce(max(confdeltype::text) filter (where conname = 'match_lineups_match_id_fkey'), '-') || '/'
               || coalesce(max(confdeltype::text) filter (where conname = 'match_lineups_club_id_fkey'), '-') || '/'
               || coalesce(max(confdeltype::text) filter (where conname = 'match_lineups_source_team_id_fkey'), '-') || '/'
               || coalesce(max(confdeltype::text) filter (where conname = 'match_lineups_captain_member_id_fkey'), '-') || '/'
               || coalesce(max(confdeltype::text) filter (where conname = 'match_lineups_vice_captain_member_id_fkey'), '-') || '/'
               || coalesce(max(confdeltype::text) filter (where conname = 'match_lineups_saved_by_fkey'), '-') || '/'
               || coalesce(max(confdeltype::text) filter (where conname = 'match_lineup_players_lineup_fkey'), '-') || '/'
               || coalesce(max(confdeltype::text) filter (where conname = 'match_lineup_players_member_id_fkey'), '-')
          from pg_constraint where connamespace = 'public'::regnamespace and contype = 'f')),
    ('07 triggers: lineup club, player club, member removal', '3',
       (select count(*)::text from pg_trigger
         where not tgisinternal
           and ((tgrelid = to_regclass('public.match_lineups') and tgname = 'match_lineups_validate')
             or (tgrelid = to_regclass('public.match_lineup_players') and tgname = 'match_lineup_players_validate')
             or (tgrelid = to_regclass('public.club_members') and tgname = 'club_members_leave_match_lineups')))),
    ('08 the existing team trigger is still in place', 'true',
       (exists (select 1 from pg_trigger where tgrelid = to_regclass('public.club_members')
                  and tgname = 'club_members_leave_teams' and not tgisinternal))::text),
    ('09 save_match_lineup / match_lineup / removal trigger: SECURITY DEFINER, empty search_path', '3/3',
       (select count(*)::text || '/' ||
               count(*) filter (where p.prosecdef and array_to_string(p.proconfig, ',') like '%search_path=""%')::text
          from pg_proc p where p.pronamespace = 'public'::regnamespace
           and p.proname in ('save_match_lineup', 'match_lineup', 'club_members_leave_match_lineups'))),
    ('10 the 2 API functions: authenticated yes, anon no', '2/0',
       (select count(*) filter (where has_function_privilege('authenticated', p.oid, 'execute'))::text || '/'
               || count(*) filter (where has_function_privilege('anon', p.oid, 'execute'))::text
          from pg_proc p where p.pronamespace = 'public'::regnamespace
           and p.proname in ('save_match_lineup', 'match_lineup'))),
    ('11 trigger functions: not callable by app roles', '3/0/0',
       (select count(*)::text || '/'
               || count(*) filter (where has_function_privilege('authenticated', p.oid, 'execute'))::text || '/'
               || count(*) filter (where has_function_privilege('anon', p.oid, 'execute'))::text
          from pg_proc p where p.pronamespace = 'public'::regnamespace
           and p.proname in ('match_lineups_validate', 'match_lineup_players_validate', 'club_members_leave_match_lineups'))),
    ('12 row counts (lineups / players)', '0/0',
       case when to_regclass('public.match_lineups') is null or to_regclass('public.match_lineup_players') is null then 'ABSENT'
            else (xpath('/row/v/text()', query_to_xml(
              'select (select count(*) from public.match_lineups)::text || ''/'' || (select count(*) from public.match_lineup_players)::text as v',
              false, true, '')))[1]::text end)
)
select check_name, expected, actual,
       case when actual is not distinct from expected then 'PASS' else 'FAIL' end as result
  from checks
 order by check_name;
