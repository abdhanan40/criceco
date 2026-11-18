-- CricEco · post-check for migrations 13 (phone sharing consent) and 14
-- (account deletion data). READ-ONLY: one SELECT, no DML/DDL, no personal
-- data in the output (counts and catalog facts only). Every row must say PASS.
-- Safe before the migrations too (the new objects then FAIL / ABSENT).
with checks(check_name, expected, actual) as (
  values
    ('01 profiles.share_phone_with_clubs: boolean, not null, default false', 'boolean/NO/false',
       (select data_type || '/' || is_nullable || '/' || coalesce(column_default, 'none')
          from information_schema.columns
         where table_schema = 'public' and table_name = 'profiles' and column_name = 'share_phone_with_clubs')),
    ('02 nobody shares a phone right after migrating (secure default)', '0',
       case when not exists (select 1 from information_schema.columns where table_schema = 'public'
                               and table_name = 'profiles' and column_name = 'share_phone_with_clubs') then 'ABSENT'
            else (xpath('/row/v/text()', query_to_xml(
              'select count(*)::text as v from public.profiles where share_phone_with_clubs', false, true, '')))[1]::text end),
    ('03 my_privacy_settings, set_phone_sharing, delete_account_data: SECURITY DEFINER, empty search_path', '3/3',
       (select count(*)::text || '/' ||
               count(*) filter (where p.prosecdef and array_to_string(p.proconfig, ',') like '%search_path=""%')::text
          from pg_proc p where p.pronamespace = 'public'::regnamespace
           and p.proname in ('my_privacy_settings', 'set_phone_sharing', 'delete_account_data'))),
    ('04 privacy functions: authenticated yes, anon no', 'true/true/false/false',
       case when to_regprocedure('public.my_privacy_settings()') is null
              or to_regprocedure('public.set_phone_sharing(boolean)') is null then 'ABSENT'
            else has_function_privilege('authenticated', 'public.my_privacy_settings()', 'execute')::text || '/'
              || has_function_privilege('authenticated', 'public.set_phone_sharing(boolean)', 'execute')::text || '/'
              || has_function_privilege('anon', 'public.my_privacy_settings()', 'execute')::text || '/'
              || has_function_privilege('anon', 'public.set_phone_sharing(boolean)', 'execute')::text end),
    ('05 delete_account_data: service_role only (authenticated no, anon no)', 'true/false/false',
       case when to_regprocedure('public.delete_account_data(uuid)') is null then 'ABSENT'
            else has_function_privilege('service_role', 'public.delete_account_data(uuid)', 'execute')::text || '/'
              || has_function_privilege('authenticated', 'public.delete_account_data(uuid)', 'execute')::text || '/'
              || has_function_privilege('anon', 'public.delete_account_data(uuid)', 'execute')::text end),
    ('06 club_member_list / club_join_requests return a phone only with consent', 'true/true',
       (exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'club_member_list'
                  and prosrc like '%case when p.share_phone_with_clubs or m.user_id = (select auth.uid()) then p.phone end%'))::text
       || '/' ||
       (exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'club_join_requests'
                  and prosrc like '%case when p.share_phone_with_clubs then p.phone end%'))::text),
    ('07 the two club functions keep their privileges (authenticated yes, anon no)', 'true/true/false/false',
       has_function_privilege('authenticated', 'public.club_member_list(uuid)', 'execute')::text || '/'
       || has_function_privilege('authenticated', 'public.club_join_requests(uuid)', 'execute')::text || '/'
       || has_function_privilege('anon', 'public.club_member_list(uuid)', 'execute')::text || '/'
       || has_function_privilege('anon', 'public.club_join_requests(uuid)', 'execute')::text),
    ('08 the two club functions still SECURITY DEFINER with empty search_path', '2',
       (select count(*)::text from pg_proc p where p.pronamespace = 'public'::regnamespace
           and p.proname in ('club_member_list', 'club_join_requests')
           and p.prosecdef and array_to_string(p.proconfig, ',') like '%search_path=""%')),
    ('09 deletion relies on these cascades from profiles / clubs (all present)', '9',
       (select count(*)::text from pg_constraint c
         where c.contype = 'f' and c.connamespace = 'public'::regnamespace and c.confdeltype = 'c'
           and c.conname in ('club_members_user_id_fkey', 'join_requests_user_id_fkey', 'club_code_attempts_user_id_fkey',
                             'user_roles_user_id_fkey', 'club_members_club_id_fkey', 'join_requests_club_id_fkey',
                             'teams_club_id_fkey', 'team_players_member_id_fkey', 'team_players_team_id_fkey'))),
    ('10 references to a deleted user in other rows become NULL (SET NULL)', '5',
       (select count(*)::text from pg_constraint c
         where c.contype = 'f' and c.connamespace = 'public'::regnamespace and c.confdeltype = 'n'
           and c.conname in ('join_requests_decided_by_fkey', 'club_members_removed_by_fkey', 'user_roles_granted_by_fkey',
                             'teams_captain_member_id_fkey', 'teams_vice_captain_member_id_fkey')))
)
select check_name, expected, actual,
       case when actual is not distinct from expected then 'PASS' else 'FAIL' end as result
  from checks
 order by check_name;
