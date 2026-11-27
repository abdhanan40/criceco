-- CricEco · post-check for migration 33 (M8 Player Hunt / Playing Opportunities).
-- READ-ONLY: one SELECT, no DML/DDL, no personal data (counts only). Every row
-- must say PASS (rows marked INFO only report). Safe before the migration too
-- (the new objects then FAIL).
with
tbl as (select c.oid, c.relname, c.relrowsecurity
          from pg_class c
         where c.relnamespace = 'public'::regnamespace
           and c.relname in ('hunt_listings', 'hunt_posts', 'hunt_interests', 'hunt_invites') and c.relkind = 'r'),
api(sig) as (values ('public.my_hunt_listing()'), ('public.set_my_hunt_listing(boolean, text, text)'),
                    ('public.publish_hunt_post(uuid, text, text, integer, text, date, text, text, text)'),
                    ('public.close_hunt_post(uuid)'), ('public.club_hunt_posts(uuid)'),
                    ('public.hunt_open_posts(text, text)'), ('public.express_hunt_interest(uuid)'),
                    ('public.withdraw_hunt_interest(uuid)'), ('public.club_hunt_interests(uuid, uuid)'),
                    ('public.hunt_open_players(text, text)'), ('public.invite_hunt_player(uuid, uuid, uuid)'),
                    ('public.club_hunt_invites(uuid)'), ('public.my_hunt_invites()'),
                    ('public.respond_hunt_invite(uuid, boolean)')),
apifn as (select to_regprocedure(a.sig) as oid from api a),
helper(sig) as (values ('public.hunt_role_of(uuid)'), ('public.hunt_player_stats(uuid)'),
                       ('public.hunt_post_list(uuid, uuid, uuid, boolean, text, text)')),
helperfn as (select to_regprocedure(h.sig) as oid from helper h),
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
    ('03 foreign keys: 6 ON DELETE CASCADE (profiles, clubs, posts), 3 SET NULL', '6|3',
       (select count(*) filter (where k.confdeltype = 'c')::text || '|' || count(*) filter (where k.confdeltype = 'n')::text
          from pg_constraint k where k.contype = 'f' and k.conrelid in (select oid from tbl))),
    ('04 one interest per post and player; one pending invite per club and player', 'true|true',
       (select exists (select 1 from pg_constraint k where k.conname = 'hunt_interests_post_user_key' and k.contype = 'u')::text
               || '|' || exists (select 1 from pg_indexes i where i.schemaname = 'public'
                                    and i.indexname = 'hunt_invites_one_pending_idx'
                                    and i.indexdef like 'CREATE UNIQUE INDEX%(club_id, user_id) WHERE (status = ''pending''::text)')::text)),
    ('05 the 15 check constraints exist and are validated', '15|15',
       (select count(*)::text || '|' || count(*) filter (where k.convalidated)::text
          from pg_constraint k where k.contype = 'c' and k.conrelid in (select oid from tbl))),
    ('06 the 14 functions: exist, SECURITY DEFINER, search_path empty, authenticated yes, anon no', '14|14|14|14|0',
       (select count(oid)::text || '|'
               || count(*) filter (where (select p.prosecdef from pg_proc p where p.oid = apifn.oid))::text || '|'
               || count(*) filter (where (select array_to_string(p.proconfig, ',') from pg_proc p where p.oid = apifn.oid)
                                         = 'search_path=""')::text || '|'
               || count(*) filter (where oid is not null and has_function_privilege('authenticated', oid, 'execute'))::text || '|'
               || count(*) filter (where oid is not null and has_function_privilege('anon', oid, 'execute'))::text
          from apifn)),
    ('07 the 3 internal helpers exist; no API role may execute them', '3|0',
       (select count(oid)::text || '|'
               || (select count(*) from helperfn h, unnest(array['anon', 'authenticated', 'service_role']) r
                    where h.oid is not null and has_function_privilege(r, h.oid, 'execute'))::text
          from helperfn)),
    ('08 notifications_type_check: 29 types (the 26 of migration 28 + the 3 hunt types), validated', '29|true|true',
       (select coalesce((select (array_length(regexp_split_to_array(def, '::text'), 1) - 1)::text || '|'
                                || (def like '%''ownership_expiring''%''hunt_invite_received''%''hunt_interest_received''%''hunt_invite_accepted''%')::text
                                || '|' || convalidated::text
                           from typecheck), 'missing'))),
    ('09 categories: interest / accepted → join_requests, invite → membership; join_request_received unchanged',
     'join_requests|join_requests|membership|join_requests|matches',
       (select public.notification_category('hunt_interest_received') || '|' || public.notification_category('hunt_invite_accepted')
               || '|' || public.notification_category('hunt_invite_received') || '|'
               || public.notification_category('join_request_received') || '|' || public.notification_category('match_reminder'))),
    ('10 notification_category / notification_add still closed to the API roles', 'false',
       (select (has_function_privilege('authenticated', 'public.notification_category(text)', 'execute')
                or has_function_privilege('anon', 'public.notification_category(text)', 'execute')
                or has_function_privilege('authenticated', 'public.notification_add(uuid, text, text, text, jsonb, uuid, uuid, uuid, uuid)', 'execute')
                or has_function_privilege('anon', 'public.notification_add(uuid, text, text, text, jsonb, uuid, uuid, uuid, uuid)', 'execute'))::text)),
    ('11 notification_add (migration 26) and delete_account_data (migration 15) unchanged', 'true|true',
       (select (md5(replace(p.prosrc, chr(13), '')) = 'a6fc6bc7e42b161bc56a5b1ef9f8aa68')::text from pg_proc p
         where p.oid = 'public.notification_add(uuid, text, text, text, jsonb, uuid, uuid, uuid, uuid)'::regprocedure)
       || '|' ||
       (select (md5(replace(p.prosrc, chr(13), '')) = '82d006dbd4e4fee1565a1d71f7b3e13f')::text from pg_proc p
         where p.oid = 'public.delete_account_data(uuid)'::regprocedure)),
    ('12 result types: the 3 post lists agree; Available Players returns no phone', 'true|true',
       (select coalesce((select (pg_get_function_result(to_regprocedure('public.hunt_open_posts(text, text)'))
                                 = pg_get_function_result(to_regprocedure('public.club_hunt_posts(uuid)'))
                                 and pg_get_function_result(to_regprocedure('public.publish_hunt_post(uuid, text, text, integer, text, date, text, text, text)'))
                                     = pg_get_function_result(to_regprocedure('public.club_hunt_posts(uuid)')))::text
                                || '|' || (pg_get_function_result(to_regprocedure('public.hunt_open_players(text, text)')) not like '%phone%')::text
                          where to_regprocedure('public.hunt_open_players(text, text)') is not null), 'missing'))),
    ('13 rows: listed players / open posts / interests / pending invites (INFO)', 'info',
       (select case when to_regclass('public.hunt_posts') is null then 'not applied' else
                 (xpath('/row/c/text()', query_to_xml(
                    'select (select count(*) from public.hunt_listings where listed) || '' / ''
                            || (select count(*) from public.hunt_posts where status = ''open'' and expires_at > now()) || '' / ''
                            || (select count(*) from public.hunt_interests) || '' / ''
                            || (select count(*) from public.hunt_invites where status = ''pending'') as c',
                    false, true, '')))[1]::text end))
)
select check_name, expected, actual,
       case when expected = 'info' then 'INFO'
            when actual is not distinct from expected then 'PASS' else 'FAIL' end as result
  from checks
 order by check_name;
