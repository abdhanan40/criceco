-- CricEco · post-check for migration 25 (notifications: the server inbox, M3 P1).
-- READ-ONLY: one SELECT, no DML/DDL, no personal data (row counts only).
-- Every row must say PASS (row 12 is INFO). Safe before the migration too
-- (the new objects then FAIL).
with
tabs(name) as (values ('notifications'), ('club_announcements'), ('notification_lineup_state')),
privs(p) as (values ('select'), ('insert'), ('update'), ('delete'), ('truncate'), ('references'), ('trigger')),
api(name) as (values ('my_notifications'), ('notification_unread_count'), ('mark_notifications_read'),
                     ('mark_all_notifications_read'), ('publish_club_announcement'), ('club_announcement'),
                     ('club_announcement_list')),
internal(name) as (values ('notifications_guard_update'), ('notification_add'), ('notification_person_name'),
                          ('notification_result_for'), ('notification_lineup_fanout'), ('join_requests_notify'),
                          ('club_members_notify_removed'), ('club_ownership_transfers_notify'),
                          ('match_challenges_notify'), ('matches_notify'), ('match_lineup_players_notify'),
                          ('match_results_notify')),
events(tab, trg) as (values ('join_requests', 'join_requests_notify'), ('club_members', 'club_members_notify_removed'),
                            ('club_ownership_transfers', 'club_ownership_transfers_notify'),
                            ('match_challenges', 'match_challenges_notify'), ('matches', 'matches_notify'),
                            ('match_lineup_players', 'match_lineup_players_notify'),
                            ('match_results', 'match_results_notify')),
checks(check_name, expected, actual) as (
  values
    ('01 tables notifications / club_announcements / notification_lineup_state exist, RLS on', '3/3',
       (select count(c.oid)::text || '/' || count(c.oid) filter (where c.relrowsecurity)::text
          from tabs t left join pg_class c on c.relname = t.name and c.relnamespace = 'public'::regnamespace
                                          and c.relkind = 'r')),
    ('02 policies: notifications one SELECT (own rows); the other two none', '1/r/own|0|0',
       (select replace(
                 (select count(*)::text || '/' || coalesce(min(p.polcmd)::text, '-') || '/'
                         || coalesce(bool_and(pg_get_expr(p.polqual, p.polrelid) like '%recipient_id = ( SELECT auth.uid()%')::text, '-')
                    from pg_policy p where p.polrelid = to_regclass('public.notifications'))
                 || '|' || (select count(*)::text from pg_policy p where p.polrelid = to_regclass('public.club_announcements'))
                 || '|' || (select count(*)::text from pg_policy p where p.polrelid = to_regclass('public.notification_lineup_state')),
                 '/true', '/own'))),
    ('03 table privileges: authenticated SELECT on notifications only; nothing else for anon / authenticated / service_role',
       'true',
       (select (bool_and(case when t.name = 'notifications' and r.r = 'authenticated' and v.p = 'select'
                              then has_table_privilege(r.r, 'public.' || t.name, v.p)
                              else not has_table_privilege(r.r, 'public.' || t.name, v.p) end))::text
          from tabs t cross join privs v cross join (values ('anon'), ('authenticated'), ('service_role')) r(r)
         where to_regclass('public.' || t.name) is not null
        having count(distinct t.name) = 3)),
    ('04 the 7 API functions: SECURITY DEFINER, empty search_path | authenticated / anon / service_role', '7/7|7/0/0',
       (select count(p.oid)::text || '/'
               || count(p.oid) filter (where p.prosecdef and array_to_string(p.proconfig, ',') like '%search_path=""%')::text
               || '|' || count(p.oid) filter (where has_function_privilege('authenticated', p.oid, 'execute'))::text
               || '/' || count(p.oid) filter (where has_function_privilege('anon', p.oid, 'execute'))::text
               || '/' || count(p.oid) filter (where has_function_privilege('service_role', p.oid, 'execute'))::text
          from api a left join pg_proc p on p.proname = a.name and p.pronamespace = 'public'::regnamespace)),
    ('05 the 12 internal functions: empty search_path; not callable by anon / authenticated / service_role', '12/12/0/0/0',
       (select count(p.oid)::text || '/'
               || count(p.oid) filter (where array_to_string(p.proconfig, ',') like '%search_path=""%')::text
               || '/' || count(p.oid) filter (where has_function_privilege('anon', p.oid, 'execute'))::text
               || '/' || count(p.oid) filter (where has_function_privilege('authenticated', p.oid, 'execute'))::text
               || '/' || count(p.oid) filter (where has_function_privilege('service_role', p.oid, 'execute'))::text
          from internal i left join pg_proc p on p.proname = i.name and p.pronamespace = 'public'::regnamespace)),
    ('06 event triggers: 7, enabled, AFTER, on their tables; the line-up one deferred to commit', '7/7/true',
       (select count(tg.oid)::text || '/' || count(tg.oid) filter (where tg.tgenabled = 'O')::text || '/'
               || coalesce(bool_and((tg.tgname <> 'match_lineup_players_notify') or (tg.tgdeferrable and tg.tginitdeferred))
                           and bool_and(tg.tgtype & 2 = 0), false)::text
          from events e
          left join pg_trigger tg on tg.tgname = e.trg and tg.tgrelid = to_regclass('public.' || e.tab)
                                 and not tg.tgisinternal)),
    ('07 notifications guard trigger (BEFORE UPDATE) present', 'true',
       (select (count(*) = 1)::text from pg_trigger tg
         where tg.tgrelid = to_regclass('public.notifications') and tg.tgname = 'notifications_guard_update'
           and tg.tgtype & 2 = 2 and tg.tgtype & 16 = 16)),
    ('08 one per event and person (unique key); FK delete rules recipient / club / match / person', 'true|c/n/n/n',
       (select (select (count(*) = 1)::text from pg_constraint k
                 where k.conrelid = to_regclass('public.notifications') and k.contype = 'u'
                   and k.conname = 'notifications_recipient_dedupe_key')
               || '|' || coalesce(string_agg(k.confdeltype::text, '/' order by k.conname = 'notifications_recipient_id_fkey' desc,
                                                                        k.conname), '-')
          from pg_constraint k
         where k.conrelid = to_regclass('public.notifications') and k.contype = 'f')),
    ('09 notification types: 23; inboxes: player / club_owner', '23|true',
       (select coalesce((select (length(pg_get_constraintdef(k.oid)) - length(replace(pg_get_constraintdef(k.oid), '''', ''))) / 2
                           from pg_constraint k
                          where k.conrelid = to_regclass('public.notifications') and k.conname = 'notifications_type_check')::text, '-')
               || '|' || coalesce((select pg_get_constraintdef(k.oid) like '%player%club_owner%'
                                     from pg_constraint k
                                    where k.conrelid = to_regclass('public.notifications')
                                      and k.conname = 'notifications_inbox_check')::text, '-'))),
    ('10 no notification table in the Realtime publication yet (D12)', '0',
       (select count(*)::text from pg_publication_tables pt
         where pt.schemaname = 'public' and pt.tablename in ('notifications', 'club_announcements', 'notification_lineup_state'))),
    ('11 existing tables keep their policies (no new policy on the 7 event tables)', 'true',
       (select (count(*) filter (where pol.polname ilike '%notif%') = 0)::text
          from events e join pg_policy pol on pol.polrelid = to_regclass('public.' || e.tab))),
    ('12 row counts (notifications / announcements / line-up state)', 'info',
       (select string_agg(case when to_regclass('public.' || t.name) is null then '-'
                               else (xpath('/row/c/text()',
                                           query_to_xml(format('select count(*) as c from public.%I', t.name),
                                                        false, true, '')))[1]::text end,
                          '/' order by t.ord)
          from (values (1, 'notifications'), (2, 'club_announcements'), (3, 'notification_lineup_state')) t(ord, name)))
)
select check_name, expected, actual,
       case when expected = 'info' then 'INFO'
            when actual is not distinct from expected then 'PASS' else 'FAIL' end as result
  from checks
 order by check_name;
