-- CricEco · post-check for migrations 11 (club memberships) and 12 (teams).
-- READ-ONLY: one SELECT, no DML/DDL. Run after applying both migrations;
-- every row must say OK. Not yet run anywhere (the migrations are unapplied).
with checks(check_name, ok) as (
  values
    ('tables exist',
       to_regclass('public.club_members') is not null and to_regclass('public.join_requests') is not null
       and to_regclass('public.teams') is not null and to_regclass('public.team_players') is not null),
    ('RLS on, all four tables',
       (select bool_and(c.relrowsecurity) from pg_class c
         where c.oid in ('public.club_members'::regclass, 'public.join_requests'::regclass,
                         'public.teams'::regclass, 'public.team_players'::regclass))),
    ('anon has no privileges on the four tables',
       not exists (select 1 from information_schema.role_table_grants
                    where table_schema = 'public' and grantee = 'anon'
                      and table_name in ('club_members', 'join_requests', 'teams', 'team_players'))),
    ('authenticated may only SELECT the four tables',
       not exists (select 1 from information_schema.role_table_grants
                    where table_schema = 'public' and grantee = 'authenticated'
                      and table_name in ('club_members', 'join_requests', 'teams', 'team_players')
                      and privilege_type <> 'SELECT')),
    ('every membership function: SECURITY DEFINER, search_path empty',
       (select bool_and(p.prosecdef and coalesce(array_to_string(p.proconfig, ','), '') like '%search_path=""%')
          from pg_proc p
         where p.pronamespace = 'public'::regnamespace
           and p.proname in ('lookup_club_by_code', 'request_to_join_club', 'cancel_join_request',
                             'decide_join_request', 'remove_club_member', 'club_join_requests',
                             'club_member_list', 'my_club_memberships', 'my_join_requests',
                             'create_team', 'save_team', 'archive_team'))),
    ('anon may not execute any of them',
       not exists (select 1 from information_schema.routine_privileges
                    where routine_schema = 'public' and grantee in ('anon', 'PUBLIC')
                      and routine_name in ('lookup_club_by_code', 'request_to_join_club', 'cancel_join_request',
                                           'decide_join_request', 'remove_club_member', 'club_join_requests',
                                           'club_member_list', 'my_club_memberships', 'my_join_requests',
                                           'create_team', 'save_team', 'archive_team', 'is_club_owner'))),
    ('throttle table: RLS on, no policy, no app-role grants',
       to_regclass('public.club_code_attempts') is not null
       and (select c.relrowsecurity from pg_class c where c.oid = 'public.club_code_attempts'::regclass)
       and not exists (select 1 from pg_policies p where p.schemaname = 'public' and p.tablename = 'club_code_attempts')
       and not exists (select 1 from information_schema.role_table_grants
                        where table_schema = 'public' and table_name = 'club_code_attempts'
                          and grantee in ('anon', 'authenticated', 'PUBLIC'))),
    ('internal helpers not executable by app roles',
       not exists (select 1 from information_schema.routine_privileges
                    where routine_schema = 'public' and grantee in ('anon', 'authenticated', 'PUBLIC')
                      and routine_name in ('club_code_throttled', 'club_code_failed',
                                           'clubs_add_owner_member', 'team_players_validate',
                                           'club_members_leave_teams'))),
    ('one pending request per person (unique index on user_id)',
       exists (select 1 from pg_indexes
                where schemaname = 'public' and indexname = 'join_requests_one_pending_key'
                  and indexdef like '%(user_id)%' and indexdef like '%pending%')),
    ('every club has exactly one owner membership',
       (select count(*) from public.clubs)
       = (select count(*) from public.club_members where member_role = 'owner' and status = 'active')
       and not exists (select 1 from public.clubs c
                        where not exists (select 1 from public.club_members m
                                           where m.club_id = c.id and m.user_id = c.owner_id
                                             and m.member_role = 'owner'))),
    ('profiles / user_roles untouched by these migrations (no new columns)',
       not exists (select 1 from information_schema.columns
                    where table_schema = 'public' and table_name in ('profiles', 'user_roles')
                      and column_name in ('club_id', 'member_role')))
)
select check_name, case when ok then 'OK' else 'FAILED' end as result from checks order by 1;
