-- CricEco · post-check for migration 29 (notification jobs: failure isolation
-- and a run log, M3 P6 hardening).
-- READ-ONLY: one SELECT, no DML/DDL, no personal data. Every row must say
-- PASS (rows 09–10 are INFO). Safe before the migration too (the new
-- objects then FAIL).
with
log as (select to_regclass('public.notification_job_runs') as oid,
               to_regclass('public.notification_job_runs_id_seq') as seq),
fns(name) as (values ('notification_send_reminders'), ('notification_cleanup'), ('push_sweep'),
                     ('notification_job_record')),
roles(r) as (values ('anon'), ('authenticated'), ('service_role')),
checks(check_name, expected, actual) as (
  values
    ('01 notification_job_runs exists, RLS on, no policies', 'true|0',
       (select coalesce((select c.relrowsecurity::text || '|' || (select count(*) from pg_policy p where p.polrelid = c.oid)::text
                           from pg_class c join log on c.oid = log.oid), '-'))),
    ('02 no app role has any right on the log table (anon / authenticated / service_role)', '0/0/0',
       (select coalesce((select string_agg((case when has_table_privilege(r, log.oid,
                                                'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') then 1 else 0 end)::text,
                                           '/' order by r)
                           from roles, log where log.oid is not null), '-'))),
    ('03 nor on its id sequence', '0/0/0',
       (select coalesce((select string_agg((case when has_sequence_privilege(r, log.seq, 'USAGE,SELECT,UPDATE') then 1 else 0 end)::text,
                                           '/' order by r)
                           from roles, log where log.seq is not null), '-'))),
    ('04 the outcome rule: ok ⇔ no error; at most 20 failed items; at most 300 characters of error', '1/1/1',
       (select count(*) filter (where k.conname = 'notification_job_runs_outcome')::text
               || '/' || count(*) filter (where pg_get_constraintdef(k.oid) like '%cardinality(failed_items) <= 20%')::text
               || '/' || count(*) filter (where pg_get_constraintdef(k.oid) like '%char_length(first_error) <= 300%')::text
          from pg_constraint k join log on k.conrelid = log.oid)),
    ('05 the 3 jobs and the log writer: SECURITY DEFINER, empty search_path', '4/4',
       (select count(p.oid)::text || '/'
               || count(p.oid) filter (where p.prosecdef and array_to_string(p.proconfig, ',') like '%search_path=""%')::text
          from fns f left join pg_proc p on p.proname = f.name and p.pronamespace = 'public'::regnamespace)),
    ('06 nobody calls them through the API (anon / authenticated / service_role)', '0/0/0',
       (select count(p.oid) filter (where has_function_privilege('anon', p.oid, 'execute'))::text
               || '/' || count(p.oid) filter (where has_function_privilege('authenticated', p.oid, 'execute'))::text
               || '/' || count(p.oid) filter (where has_function_privilege('service_role', p.oid, 'execute'))::text
          from fns f join pg_proc p on p.proname = f.name and p.pronamespace = 'public'::regnamespace
        having count(p.oid) = 4)),
    ('07 every job records its run and catches failures (reminders per item)', '3/3/true',
       (select count(*) filter (where p.prosrc like '%notification_job_record(%')::text
               || '/' || count(*) filter (where p.prosrc like '%exception when others%')::text
               || '/' || coalesce(bool_or(p.proname = 'notification_send_reminders'
                                          and p.prosrc like '%:owner_a%' and p.prosrc like '%:players%'
                                          and p.prosrc like '%''challenge:''%' and p.prosrc like '%''offer:''%'
                                          and p.prosrc like '%notification_add(%'
                                          and p.prosrc like '%notification_lineup_fanout(%'), false)::text
          from pg_proc p
         where p.pronamespace = 'public'::regnamespace
           and p.proname in ('notification_send_reminders', 'notification_cleanup', 'push_sweep'))),
    ('08 the cleanup keeps job runs 30 days; results unchanged (integer / jsonb / integer)', 'true|integer,jsonb,integer',
       (select coalesce(bool_or(p.proname = 'notification_cleanup'
                                and p.prosrc like '%notification_job_runs%interval ''30 days''%'), false)::text
               || '|' || string_agg(format_type(p.prorettype, null), ',' order by
                                    array_position(array['notification_send_reminders', 'notification_cleanup', 'push_sweep'], p.proname::text))
          from pg_proc p
         where p.pronamespace = 'public'::regnamespace
           and p.proname in ('notification_send_reminders', 'notification_cleanup', 'push_sweep'))),
    ('09 runs in the last 24 hours, by job and outcome (INFO; none until pg_cron runs the jobs)', 'info',
       (select case when log.oid is null then 'no run log' else
                 (xpath('/row/c/text()', query_to_xml(
                    'select coalesce(string_agg(job || '' '' || status || '' '' || n, ''; '' order by job, status), ''no runs'') as c
                       from (select job, status, count(*) as n from public.notification_job_runs
                              where started_at > now() - interval ''24 hours'' group by job, status) s',
                    false, true, '')))[1]::text end
          from log)),
    ('10 the latest run with errors (INFO: job, when, first error)', 'info',
       (select case when log.oid is null then 'no run log' else
                 (xpath('/row/c/text()', query_to_xml(
                    'select coalesce((select job || '' '' || to_char(started_at at time zone ''UTC'', ''YYYY-MM-DD HH24:MI'')
                                             || '' UTC: '' || errors || '' error(s), first: '' || first_error
                                        from public.notification_job_runs where errors > 0
                                       order by started_at desc limit 1), ''none'') as c',
                    false, true, '')))[1]::text end
          from log))
)
select check_name, expected, actual,
       case when expected = 'info' then 'INFO'
            when actual is not distinct from expected then 'PASS' else 'FAIL' end as result
  from checks
 order by check_name;
