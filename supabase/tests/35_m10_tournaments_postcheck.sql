-- CricEco · post-check for migration 35 (M10 Tournaments).
-- READ-ONLY: one SELECT, no DML/DDL, no personal data (counts only). Every row
-- must say PASS (rows marked INFO only report). Safe before the migration too
-- (the new objects then FAIL).
with
tbl as (select c.oid, c.relname, c.relrowsecurity
          from pg_class c
         where c.relnamespace = 'public'::regnamespace
           and c.relname in ('tournaments', 'tournament_registrations', 'tournament_registration_players',
                             'tournament_fixtures') and c.relkind = 'r'),
api(sig) as (values ('public.create_tournament(uuid, text, text, text, text, integer, text, date, date, date, integer, integer, integer, text, text[])'),
                    ('public.my_hosted_tournaments(uuid)'), ('public.browse_tournaments(text)'),
                    ('public.tournament_detail(uuid)'), ('public.tournament_hub_stats(uuid)'),
                    ('public.tournament_teams(uuid)'), ('public.tournament_registration_squad(uuid)'),
                    ('public.submit_tournament_registration(uuid, uuid, text, uuid, jsonb, uuid, uuid, uuid, boolean)'),
                    ('public.decide_tournament_registration(uuid, boolean)'), ('public.remove_tournament_team(uuid)'),
                    ('public.my_tournament_registrations(uuid, text)'), ('public.generate_tournament_fixtures(uuid)'),
                    ('public.tournament_fixtures(uuid)'), ('public.tournament_points_table(uuid)'),
                    ('public.tournament_awards(uuid)')),
apifn as (select to_regprocedure(a.sig) as oid from api a),
helper(sig) as (values ('public.tournament_status_now(text, date)'),
                       ('public.tournament_list(uuid, uuid, uuid, boolean, text)'),
                       ('public.tournament_registration_rows(uuid, uuid, uuid)'),
                       ('public.tournament_fixture_decide(uuid, uuid, boolean)'),
                       ('public.tournament_advance_byes(uuid)'), ('public.tournament_standings(uuid)'),
                       ('public.tournament_registrations_validate()'),
                       ('public.tournament_registration_players_validate()')),
helperfn as (select to_regprocedure(h.sig) as oid from helper h),
scorer as (select to_regprocedure('public.record_tournament_fixture_result(uuid, uuid, uuid)') as oid),
typecheck as (select pg_get_constraintdef(k.oid) as def, k.convalidated
                from pg_constraint k
               where k.conrelid = 'public.notifications'::regclass and k.conname = 'notifications_type_check'),
checks(check_name, expected, actual) as (
  values
    ('01 the 4 tables exist, RLS on, no policy', '4|4|0',
       (select count(*)::text || '|' || count(*) filter (where relrowsecurity)::text || '|'
               || (select count(*) from pg_policy p where p.polrelid in (select oid from tbl))::text from tbl)),
    ('02 no table privilege for anon / authenticated / service_role', '0',
       (select count(*)::text from tbl, unnest(array['anon', 'authenticated', 'service_role']) r
         where has_table_privilege(r, tbl.oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'))),
    ('03 foreign keys: 7 ON DELETE CASCADE (clubs, tournaments, entries, members, next fixture), 9 SET NULL', '7|9',
       (select count(*) filter (where k.confdeltype = 'c')::text || '|' || count(*) filter (where k.confdeltype = 'n')::text
          from pg_constraint k where k.contype = 'f' and k.conrelid in (select oid from tbl))),
    ('04 one live entry per club; one captain / vice-captain / keeper per squad; a match in one fixture', 'true|3|true',
       (select exists (select 1 from pg_indexes i where i.schemaname = 'public'
                          and i.indexname = 'tournament_registrations_one_active_idx'
                          and i.indexdef like 'CREATE UNIQUE INDEX%(tournament_id, club_id) WHERE (status = ANY (ARRAY[''pending''::text, ''approved''::text]))')::text
               || '|' || (select count(*) from pg_indexes i where i.schemaname = 'public'
                            and i.indexname in ('tournament_registration_players_one_captain_idx',
                                                'tournament_registration_players_one_vice_idx',
                                                'tournament_registration_players_one_keeper_idx')
                            and i.indexdef like 'CREATE UNIQUE INDEX%')::text
               || '|' || exists (select 1 from pg_indexes i where i.schemaname = 'public'
                                    and i.indexname = 'tournament_fixtures_match_id_key'
                                    and i.indexdef like 'CREATE UNIQUE INDEX%')::text)),
    ('05 the 35 check constraints exist and are validated', '35|35',
       (select count(*)::text || '|' || count(*) filter (where k.convalidated)::text
          from pg_constraint k where k.contype = 'c' and k.conrelid in (select oid from tbl))),
    ('06 the 15 app functions: exist, SECURITY DEFINER, search_path empty, authenticated yes, anon no', '15|15|15|15|0',
       (select count(oid)::text || '|'
               || count(*) filter (where (select p.prosecdef from pg_proc p where p.oid = apifn.oid))::text || '|'
               || count(*) filter (where (select array_to_string(p.proconfig, ',') from pg_proc p where p.oid = apifn.oid)
                                         = 'search_path=""')::text || '|'
               || count(*) filter (where oid is not null and has_function_privilege('authenticated', oid, 'execute'))::text || '|'
               || count(*) filter (where oid is not null and has_function_privilege('anon', oid, 'execute'))::text
          from apifn)),
    ('07 record_tournament_fixture_result: SECURITY DEFINER, search_path empty; service_role only', 'true|true|true|false|false',
       (select coalesce((select p.prosecdef::text || '|' || (array_to_string(p.proconfig, ',') = 'search_path=""')::text || '|'
                                || has_function_privilege('service_role', s.oid, 'execute')::text || '|'
                                || has_function_privilege('authenticated', s.oid, 'execute')::text || '|'
                                || has_function_privilege('anon', s.oid, 'execute')::text
                           from scorer s join pg_proc p on p.oid = s.oid), 'missing'))),
    ('08 the 8 internal helpers exist; no API role may execute them', '8|0',
       (select count(oid)::text || '|'
               || (select count(*) from helperfn h, unnest(array['anon', 'authenticated', 'service_role']) r
                    where h.oid is not null and has_function_privilege(r, h.oid, 'execute'))::text
          from helperfn)),
    ('09 the 2 integrity triggers are enabled', '2',
       (select count(*)::text from pg_trigger t
         where not t.tgisinternal and t.tgenabled = 'O'
           and t.tgname in ('tournament_registrations_validate', 'tournament_registration_players_validate'))),
    ('10 notifications_type_check: 34 types (the 29 of migration 33 + 5 tournament types), validated', '34|true|true',
       (select coalesce((select (array_length(regexp_split_to_array(def, '::text'), 1) - 1)::text || '|'
                                || (def like '%''hunt_invite_accepted''%''tournament_registration_received''%''tournament_registration_approved''%''tournament_registration_rejected''%''tournament_team_removed''%''tournament_fixtures_published''%')::text
                                || '|' || convalidated::text
                           from typecheck), 'missing'))),
    ('11 categories: received → join_requests, decisions / removal → challenges, fixtures → matches; earlier ones unchanged',
     'join_requests|challenges|challenges|challenges|matches|join_requests|membership|matches',
       (select public.notification_category('tournament_registration_received') || '|'
               || public.notification_category('tournament_registration_approved') || '|'
               || public.notification_category('tournament_registration_rejected') || '|'
               || public.notification_category('tournament_team_removed') || '|'
               || public.notification_category('tournament_fixtures_published') || '|'
               || public.notification_category('hunt_interest_received') || '|'
               || public.notification_category('hunt_invite_received') || '|'
               || public.notification_category('match_reminder'))),
    ('12 notification_category / notification_add still closed to the API roles', 'false',
       (select (has_function_privilege('authenticated', 'public.notification_category(text)', 'execute')
                or has_function_privilege('anon', 'public.notification_category(text)', 'execute')
                or has_function_privilege('authenticated', 'public.notification_add(uuid, text, text, text, jsonb, uuid, uuid, uuid, uuid)', 'execute')
                or has_function_privilege('anon', 'public.notification_add(uuid, text, text, text, jsonb, uuid, uuid, uuid, uuid)', 'execute'))::text)),
    ('13 notification_add (migration 26) and delete_account_data (migration 15) unchanged', 'true|true',
       (select (md5(replace(p.prosrc, chr(13), '')) = 'a6fc6bc7e42b161bc56a5b1ef9f8aa68')::text from pg_proc p
         where p.oid = 'public.notification_add(uuid, text, text, text, jsonb, uuid, uuid, uuid, uuid)'::regprocedure)
       || '|' ||
       (select (md5(replace(p.prosrc, chr(13), '')) = '82d006dbd4e4fee1565a1d71f7b3e13f')::text from pg_proc p
         where p.oid = 'public.delete_account_data(uuid)'::regprocedure)),
    ('14 result types: the 4 tournament lists agree; the 4 entry lists agree', 'true|true',
       (select coalesce((select (pg_get_function_result(to_regprocedure('public.my_hosted_tournaments(uuid)'))
                                 = pg_get_function_result(to_regprocedure('public.tournament_detail(uuid)'))
                                 and pg_get_function_result(to_regprocedure('public.browse_tournaments(text)'))
                                     = pg_get_function_result(to_regprocedure('public.tournament_detail(uuid)'))
                                 and pg_get_function_result(to_regprocedure('public.create_tournament(uuid, text, text, text, text, integer, text, date, date, date, integer, integer, integer, text, text[])'))
                                     = pg_get_function_result(to_regprocedure('public.tournament_detail(uuid)')))::text
                                || '|' ||
                                (pg_get_function_result(to_regprocedure('public.submit_tournament_registration(uuid, uuid, text, uuid, jsonb, uuid, uuid, uuid, boolean)'))
                                 = pg_get_function_result(to_regprocedure('public.tournament_teams(uuid)'))
                                 and pg_get_function_result(to_regprocedure('public.decide_tournament_registration(uuid, boolean)'))
                                     = pg_get_function_result(to_regprocedure('public.tournament_teams(uuid)'))
                                 and pg_get_function_result(to_regprocedure('public.remove_tournament_team(uuid)'))
                                     = pg_get_function_result(to_regprocedure('public.tournament_teams(uuid)')))::text
                          where to_regprocedure('public.tournament_teams(uuid)') is not null), 'missing'))),
    ('15 rows: tournaments / entries / squad places / fixtures / decided fixtures (INFO)', 'info',
       (select case when to_regclass('public.tournament_fixtures') is null then 'not applied' else
                 (xpath('/row/c/text()', query_to_xml(
                    'select (select count(*) from public.tournaments) || '' / ''
                            || (select count(*) from public.tournament_registrations) || '' / ''
                            || (select count(*) from public.tournament_registration_players) || '' / ''
                            || (select count(*) from public.tournament_fixtures) || '' / ''
                            || (select count(*) from public.tournament_fixtures where decided_at is not null) as c',
                    false, true, '')))[1]::text end))
)
select check_name, expected, actual,
       case when expected = 'info' then 'INFO'
            when actual is not distinct from expected then 'PASS' else 'FAIL' end as result
  from checks
 order by check_name;
