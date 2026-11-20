-- CricEco · post-check for migration 19 (player availability).
-- READ-ONLY: one SELECT, no DML/DDL, no personal data. Every row must say PASS.
-- Safe before the migration too (the new objects then FAIL / ABSENT).
with checks(check_name, expected, actual) as (
  values
    ('01 table player_availability exists, RLS on', 'true',
       coalesce((select relrowsecurity::text from pg_class where oid = to_regclass('public.player_availability')), 'ABSENT')),
    ('02 one SELECT policy (own or owner of their club); no other policy', '1/1',
       (select count(*) filter (where cmd = 'SELECT')::text || '/' || count(*)::text
          from pg_policies where schemaname = 'public' and tablename = 'player_availability')),
    ('03 authenticated: SELECT only; anon / PUBLIC: nothing', 'true',
       (to_regclass('public.player_availability') is not null
        and not exists (select 1 from information_schema.role_table_grants
                         where table_schema = 'public' and table_name = 'player_availability'
                           and ((grantee = 'authenticated' and privilege_type <> 'SELECT')
                                or grantee in ('anon', 'PUBLIC')))
        and exists (select 1 from information_schema.role_table_grants where table_schema = 'public'
                      and table_name = 'player_availability' and grantee = 'authenticated'
                      and privilege_type = 'SELECT'))::text),
    ('04 one record per person (PK user_id); FK to profiles ON DELETE CASCADE', 'p/c',
       coalesce((select max(contype::text) filter (where conname = 'player_availability_pkey') || '/'
                        || max(confdeltype::text) filter (where conname = 'player_availability_user_id_fkey')
                   from pg_constraint where connamespace = 'public'::regnamespace
                    and conrelid = to_regclass('public.player_availability')), 'ABSENT')),
    ('05 named check constraints present (status, reason, notes, available is plain)', '4',
       (select count(*)::text from pg_constraint where connamespace = 'public'::regnamespace and contype = 'c'
          and conname in ('player_availability_status_check', 'player_availability_reason_check',
                          'player_availability_notes_check', 'player_availability_available_is_plain'))),
    ('06 lineup rule trigger on match_lineup_players', 'true',
       (exists (select 1 from pg_trigger where tgrelid = to_regclass('public.match_lineup_players')
                  and tgname = 'match_lineup_players_check_availability' and not tgisinternal))::text),
    ('07 the 4 privileged functions: SECURITY DEFINER, empty search_path', '4/4',
       (select count(*)::text || '/' ||
               count(*) filter (where p.prosecdef and array_to_string(p.proconfig, ',') like '%search_path=""%')::text
          from pg_proc p where p.pronamespace = 'public'::regnamespace
           and p.proname in ('is_owner_of_active_member', 'set_my_availability', 'my_availability',
                             'club_player_availability'))),
    ('08 the 3 API functions (+ policy helper): authenticated yes, anon no', '4/0',
       (select count(*) filter (where has_function_privilege('authenticated', p.oid, 'execute'))::text || '/'
               || count(*) filter (where has_function_privilege('anon', p.oid, 'execute'))::text
          from pg_proc p where p.pronamespace = 'public'::regnamespace
           and p.proname in ('is_owner_of_active_member', 'set_my_availability', 'my_availability',
                             'club_player_availability'))),
    ('09 internal helper and trigger function: not callable by app roles', '2/0/0',
       (select count(*)::text || '/'
               || count(*) filter (where has_function_privilege('authenticated', p.oid, 'execute'))::text || '/'
               || count(*) filter (where has_function_privilege('anon', p.oid, 'execute'))::text
          from pg_proc p where p.pronamespace = 'public'::regnamespace
           and p.proname in ('availability_locks_on', 'match_lineup_players_check_availability'))),
    ('10 row count', '0',
       case when to_regclass('public.player_availability') is null then 'ABSENT'
            else (xpath('/row/v/text()', query_to_xml(
              'select count(*)::text as v from public.player_availability', false, true, '')))[1]::text end)
)
select check_name, expected, actual,
       case when actual is not distinct from expected then 'PASS' else 'FAIL' end as result
  from checks
 order by check_name;
