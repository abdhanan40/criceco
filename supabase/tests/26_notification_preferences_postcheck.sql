-- CricEco · post-check for migration 26 (notification preferences, M3 P4).
-- READ-ONLY: one SELECT, no DML/DDL, no personal data (a row count only).
-- Every row must say PASS (row 09 is INFO). Safe before the migration too
-- (the new objects then FAIL).
with
api(name) as (values ('my_notification_preferences'), ('set_notification_preferences')),
internal(name) as (values ('notification_preferences_touch'), ('notification_category'), ('notification_muted')),
privs(p) as (values ('select'), ('insert'), ('update'), ('delete'), ('truncate'), ('references'), ('trigger')),
-- notification_category() of every type of migration 25, run dynamically so
-- this file also runs before the migration.
categories as (
  select case when to_regprocedure('public.notification_category(text)') is null then null else
           (xpath('/row/c/text()', query_to_xml(
              'select string_agg(t || ''='' || public.notification_category(t), '','' order by t) as c
                 from unnest(array[''join_request_received'', ''join_request_approved'', ''join_request_declined'',
                                   ''removed_from_club'', ''ownership_offered'', ''ownership_accepted'',
                                   ''ownership_rejected'', ''ownership_withdrawn'', ''challenge_received'',
                                   ''challenge_accepted'', ''challenge_declined'', ''schedule_proposed'',
                                   ''schedule_accepted'', ''schedule_declined'', ''match_rescheduled'',
                                   ''match_cancelled'', ''lineup_selected'', ''lineup_changed'', ''lineup_dropped'',
                                   ''result_published'', ''result_corrected'', ''player_of_match'',
                                   ''announcement'', ''some_future_type'']) t', false, true, '')))[1]::text
         end as c
),
checks(check_name, expected, actual) as (
  values
    ('01 table notification_preferences exists, RLS on, no policy', '1/true/0',
       (select count(c.oid)::text || '/' || coalesce(bool_and(c.relrowsecurity)::text, '-') || '/'
               || (select count(*)::text from pg_policy p where p.polrelid = to_regclass('public.notification_preferences'))
          from pg_class c where c.oid = to_regclass('public.notification_preferences'))),
    ('02 no table privilege for anon / authenticated / service_role', 'true',
       (select bool_and(not has_table_privilege(r.r, 'public.notification_preferences', v.p))::text
          from privs v cross join (values ('anon'), ('authenticated'), ('service_role')) r(r)
         where to_regclass('public.notification_preferences') is not null)),
    ('03 the 2 API functions: SECURITY DEFINER, empty search_path | authenticated / anon / service_role', '2/2|2/0/0',
       (select count(p.oid)::text || '/'
               || count(p.oid) filter (where p.prosecdef and array_to_string(p.proconfig, ',') like '%search_path=""%')::text
               || '|' || count(p.oid) filter (where has_function_privilege('authenticated', p.oid, 'execute'))::text
               || '/' || count(p.oid) filter (where has_function_privilege('anon', p.oid, 'execute'))::text
               || '/' || count(p.oid) filter (where has_function_privilege('service_role', p.oid, 'execute'))::text
          from api a left join pg_proc p on p.proname = a.name and p.pronamespace = 'public'::regnamespace)),
    ('04 the 3 internal functions: empty search_path; not callable by anon / authenticated / service_role', '3/3/0/0/0',
       (select count(p.oid)::text || '/'
               || count(p.oid) filter (where array_to_string(p.proconfig, ',') like '%search_path=""%')::text
               || '/' || count(p.oid) filter (where has_function_privilege('anon', p.oid, 'execute'))::text
               || '/' || count(p.oid) filter (where has_function_privilege('authenticated', p.oid, 'execute'))::text
               || '/' || count(p.oid) filter (where has_function_privilege('service_role', p.oid, 'execute'))::text
          from internal i left join pg_proc p on p.proname = i.name and p.pronamespace = 'public'::regnamespace)),
    ('05 both writers of migration 25 skip muted recipients (notification_add, publish_club_announcement)', '2/2',
       (select count(p.oid)::text || '/' || count(p.oid) filter (where p.prosrc like '%notification_muted(%')::text
          from pg_proc p
         where p.pronamespace = 'public'::regnamespace
           and p.proname in ('notification_add', 'publish_club_announcement'))),
    ('06 categories: membership always on (and for any new type); 5 optional', 'true',
       (select (c.c = 'announcement=announcements,challenge_accepted=challenges,challenge_declined=challenges,'
                     || 'challenge_received=challenges,join_request_approved=membership,'
                     || 'join_request_declined=membership,join_request_received=join_requests,'
                     || 'lineup_changed=matches,lineup_dropped=matches,lineup_selected=matches,'
                     || 'match_cancelled=matches,match_rescheduled=matches,ownership_accepted=membership,'
                     || 'ownership_offered=membership,ownership_rejected=membership,'
                     || 'ownership_withdrawn=membership,player_of_match=results,removed_from_club=membership,'
                     || 'result_corrected=results,result_published=results,schedule_accepted=challenges,'
                     || 'schedule_declined=challenges,schedule_proposed=challenges,some_future_type=membership')::text
          from categories c)),
    ('07 one row per person; deleted with the profile (ON DELETE CASCADE)', 'p/c',
       (select coalesce((select string_agg(k.contype::text, '' order by k.contype desc) from pg_constraint k
                          where k.conrelid = to_regclass('public.notification_preferences') and k.contype = 'p'), '-')
               || '/' || coalesce((select k.confdeltype::text from pg_constraint k
                                    where k.conrelid = to_regclass('public.notification_preferences')
                                      and k.contype = 'f'), '-'))),
    ('08 the five optional columns default to on', '5',
       (select count(*)::text from information_schema.columns c
         where c.table_schema = 'public' and c.table_name = 'notification_preferences'
           and c.column_name in ('join_requests', 'challenges', 'matches', 'results', 'announcements')
           and c.is_nullable = 'NO' and c.column_default = 'true')),
    ('09 rows (people who changed a preference)', 'info',
       (select case when to_regclass('public.notification_preferences') is null then '-' else
                 (xpath('/row/c/text()', query_to_xml('select count(*) as c from public.notification_preferences',
                                                      false, true, '')))[1]::text end))
)
select check_name, expected, actual,
       case when expected = 'info' then 'INFO'
            when actual is not distinct from expected then 'PASS' else 'FAIL' end as result
  from checks
 order by check_name;
