-- CricEco · post-check for migration 17 (match challenges and matches).
-- READ-ONLY: one SELECT, no DML/DDL, no personal data. Every row must say PASS.
-- Safe before the migration too (the new objects then FAIL / ABSENT).
with checks(check_name, expected, actual) as (
  values
    ('01 tables match_challenges / matches exist, RLS on', 'true/true',
       coalesce((select relrowsecurity::text from pg_class where oid = to_regclass('public.match_challenges')), 'ABSENT')
       || '/' ||
       coalesce((select relrowsecurity::text from pg_class where oid = to_regclass('public.matches')), 'ABSENT')),
    ('02 one SELECT policy per table; no other policy', '1/1|1/1',
       (select count(*) filter (where cmd = 'SELECT' and tablename = 'match_challenges')::text || '/'
               || count(*) filter (where tablename = 'match_challenges')::text || '|'
               || count(*) filter (where cmd = 'SELECT' and tablename = 'matches')::text || '/'
               || count(*) filter (where tablename = 'matches')::text
          from pg_policies where schemaname = 'public' and tablename in ('match_challenges', 'matches'))),
    ('03 authenticated: SELECT only; anon / PUBLIC: nothing (both tables)', 'true',
       (to_regclass('public.match_challenges') is not null and to_regclass('public.matches') is not null
        and not exists (select 1 from information_schema.role_table_grants
                         where table_schema = 'public' and table_name in ('match_challenges', 'matches')
                           and ((grantee = 'authenticated' and privilege_type <> 'SELECT')
                                or grantee in ('anon', 'PUBLIC')))
        and (select count(*) from information_schema.role_table_grants
              where table_schema = 'public' and table_name in ('match_challenges', 'matches')
                and grantee = 'authenticated' and privilege_type = 'SELECT') = 2)::text),
    ('04 one pending challenge per club pair (unique partial index, both directions)', 'true',
       (exists (select 1 from pg_indexes where schemaname = 'public' and indexname = 'match_challenges_one_pending_pair_key'
                  and indexdef like 'CREATE UNIQUE INDEX%' and indexdef like '%LEAST(from_club_id, to_club_id)%'
                  and indexdef like '%GREATEST(from_club_id, to_club_id)%' and indexdef like '%pending%'))::text),
    ('05 one match per challenge, one challenge per match (unique keys)', '2',
       (select count(*)::text from pg_constraint where connamespace = 'public'::regnamespace and contype = 'u'
          and conname in ('matches_challenge_id_key', 'match_challenges_match_id_key'))),
    ('06 named check constraints present', '27',
       (select count(*)::text from pg_constraint where connamespace = 'public'::regnamespace and contype = 'c'
          and conname in ('match_challenges_format_check', 'match_challenges_custom_overs_check',
                          'match_challenges_venue_name_check', 'match_challenges_message_check',
                          'match_challenges_status_check', 'match_challenges_not_self',
                          'match_challenges_overs_follow_format', 'match_challenges_decided_consistency',
                          'match_challenges_match_on_accept', 'match_challenges_expiry_after_creation',
                          'matches_format_check', 'matches_custom_overs_check', 'matches_status_check',
                          'matches_venue_name_check', 'matches_city_check', 'matches_two_clubs',
                          'matches_overs_follow_format', 'matches_scheduled_when_confirmed',
                          'matches_cancelled_consistency', 'matches_proposal_complete',
                          'matches_proposed_by_participant', 'matches_cancelled_by_participant',
                          'matches_proposed_venue_name_check', 'matches_proposed_city_check',
                          'matches_proposal_version_check', 'matches_cancel_reason_check',
                          'matches_proposal_only_when_open'))),
    ('07 FK delete rules: clubs CASCADE; decider / challenge / match links SET NULL', 'c/c/n/c/c/n/n',
       (select coalesce(max(confdeltype::text) filter (where conname = 'match_challenges_from_club_id_fkey'), '-') || '/'
               || coalesce(max(confdeltype::text) filter (where conname = 'match_challenges_to_club_id_fkey'), '-') || '/'
               || coalesce(max(confdeltype::text) filter (where conname = 'match_challenges_decided_by_fkey'), '-') || '/'
               || coalesce(max(confdeltype::text) filter (where conname = 'matches_club_a_id_fkey'), '-') || '/'
               || coalesce(max(confdeltype::text) filter (where conname = 'matches_club_b_id_fkey'), '-') || '/'
               || coalesce(max(confdeltype::text) filter (where conname = 'matches_challenge_id_fkey'), '-') || '/'
               || coalesce(max(confdeltype::text) filter (where conname = 'match_challenges_match_id_fkey'), '-')
          from pg_constraint where connamespace = 'public'::regnamespace and contype = 'f')),
    ('08 triggers: 2 status guards + last_updated_at', '3',
       (select count(*)::text from pg_trigger
         where not tgisinternal
           and ((tgrelid = to_regclass('public.match_challenges') and tgname = 'match_challenges_guard_update')
             or (tgrelid = to_regclass('public.matches') and tgname in ('matches_guard_update', 'matches_set_last_updated_at'))))),
    ('09 the 10 privileged functions: SECURITY DEFINER, empty search_path', '10/10',
       (select count(*)::text || '/' ||
               count(*) filter (where p.prosecdef and array_to_string(p.proconfig, ',') like '%search_path=""%')::text
          from pg_proc p where p.pronamespace = 'public'::regnamespace
           and p.proname in ('is_active_club_member', 'match_lock_clubs', 'match_club_directory', 'send_challenge',
                             'respond_to_challenge', 'club_challenges', 'propose_match_schedule',
                             'respond_to_match_schedule', 'cancel_match', 'club_matches'))),
    ('10 the 9 API functions (+ policy helper): authenticated yes, anon no', '9/0',
       (select count(*) filter (where has_function_privilege('authenticated', p.oid, 'execute'))::text || '/'
               || count(*) filter (where has_function_privilege('anon', p.oid, 'execute'))::text
          from pg_proc p where p.pronamespace = 'public'::regnamespace
           and p.proname in ('is_active_club_member', 'match_club_directory', 'send_challenge', 'respond_to_challenge',
                             'club_challenges', 'propose_match_schedule', 'respond_to_match_schedule',
                             'cancel_match', 'club_matches'))),
    ('11 internal helpers and trigger functions: not callable by app roles', '4/0/0',
       (select count(*)::text || '/'
               || count(*) filter (where has_function_privilege('authenticated', p.oid, 'execute'))::text || '/'
               || count(*) filter (where has_function_privilege('anon', p.oid, 'execute'))::text
          from pg_proc p where p.pronamespace = 'public'::regnamespace
           and p.proname in ('match_lock_clubs', 'match_duration', 'match_challenges_guard_update', 'matches_guard_update'))),
    ('12 existing tables unchanged: still no new policy on clubs / club_members / teams', 'true',
       (not exists (select 1 from pg_policies where schemaname = 'public'
                     and tablename in ('clubs', 'club_members', 'teams', 'team_players')
                     and (policyname ilike '%match%' or policyname ilike '%challenge%')))::text),
    ('13 row counts (challenges / matches)', '0/0',
       case when to_regclass('public.match_challenges') is null or to_regclass('public.matches') is null then 'ABSENT'
            else (xpath('/row/v/text()', query_to_xml(
              'select (select count(*) from public.match_challenges)::text || ''/'' || (select count(*) from public.matches)::text as v',
              false, true, '')))[1]::text end)
)
select check_name, expected, actual,
       case when actual is not distinct from expected then 'PASS' else 'FAIL' end as result
  from checks
 order by check_name;
