-- CricEco · post-check for migration 28 (scheduled notification jobs, M3 P6).
-- READ-ONLY: one SELECT, no DML/DDL, no personal data. Every row must say
-- PASS (rows 06–07 are INFO). Safe before the migration too (the new
-- objects then FAIL).
with
jobs(name) as (values ('notification_send_reminders'), ('notification_cleanup'), ('push_sweep'),
                      ('notification_jobs_schedule')),
categories as (
  select case when to_regprocedure('public.notification_category(text)') is null then null else
           (xpath('/row/c/text()', query_to_xml(
              'select string_agg(t || ''='' || public.notification_category(t), '','' order by t) as c
                 from unnest(array[''match_reminder'', ''challenge_expiring'', ''ownership_expiring'']) t',
              false, true, '')))[1]::text
         end as c
),
checks(check_name, expected, actual) as (
  values
    ('01 the type list has the three reminder types (26 types)', '26|true',
       (select coalesce((select ((length(pg_get_constraintdef(k.oid)) - length(replace(pg_get_constraintdef(k.oid), '''', ''))) / 2)::text
                                 || '|' || (pg_get_constraintdef(k.oid) like '%match_reminder%challenge_expiring%ownership_expiring%')::text
                            from pg_constraint k
                           where k.conrelid = to_regclass('public.notifications') and k.conname = 'notifications_type_check'), '-'))),
    ('02 reminder categories: match → matches, challenge → challenges, ownership → membership (always on)',
       'challenge_expiring=challenges,match_reminder=matches,ownership_expiring=membership',
       (select c from categories)),
    ('03 the 4 job functions: SECURITY DEFINER, empty search_path', '4/4',
       (select count(p.oid)::text || '/'
               || count(p.oid) filter (where p.prosecdef and array_to_string(p.proconfig, ',') like '%search_path=""%')::text
          from jobs j left join pg_proc p on p.proname = j.name and p.pronamespace = 'public'::regnamespace)),
    ('04 nobody calls them through the API (anon / authenticated / service_role)', '0/0/0',
       (select count(p.oid) filter (where has_function_privilege('anon', p.oid, 'execute'))::text
               || '/' || count(p.oid) filter (where has_function_privilege('authenticated', p.oid, 'execute'))::text
               || '/' || count(p.oid) filter (where has_function_privilege('service_role', p.oid, 'execute'))::text
          from jobs j join pg_proc p on p.proname = j.name and p.pronamespace = 'public'::regnamespace
        having count(p.oid) = 4)),
    ('05 the reminders go through notification_add (preferences, no self-notice)', 'true',
       (select (p.prosrc like '%notification_add(%' and p.prosrc like '%notification_lineup_fanout(%')::text
          from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'notification_send_reminders')),
    ('06 pg_cron: enabled, and the three CricEco jobs (INFO until that approved settings step)', 'info',
       (select case when to_regnamespace('cron') is null then 'pg_cron not enabled' else
                 (xpath('/row/c/text()', query_to_xml(
                    'select coalesce(string_agg(jobname || '' '' || schedule || case when active then '''' else '' (inactive)'' end, ''; '' order by jobname), ''no CricEco job'') as c
                       from cron.job where jobname like ''criceco-%''', false, true, '')))[1]::text end)),
    ('07 notifications older than 90 days (the cleanup''s backlog)', 'info',
       (select (xpath('/row/c/text()', query_to_xml(
                  'select count(*) as c from public.notifications where created_at < now() - interval ''90 days''',
                  false, true, '')))[1]::text))
)
select check_name, expected, actual,
       case when expected = 'info' then 'INFO'
            when actual is not distinct from expected then 'PASS' else 'FAIL' end as result
  from checks
 order by check_name;
