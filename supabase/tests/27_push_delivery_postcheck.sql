-- CricEco · post-check for migration 27 (push delivery, M3 P5).
-- READ-ONLY: one SELECT, no DML/DDL, no personal data (row counts only; never
-- a token). Every row must say PASS (rows 09–10 are INFO). Safe before the
-- migration too (the new objects then FAIL).
with
tabs(name) as (values ('device_tokens'), ('push_deliveries')),
privs(p) as (values ('select'), ('insert'), ('update'), ('delete'), ('truncate'), ('references'), ('trigger')),
app(name) as (values ('register_push_device'), ('unregister_push_device')),
dispatcher(name) as (values ('push_claim'), ('push_report')),
internal(name) as (values ('push_wake'), ('notifications_queue_push')),
checks(check_name, expected, actual) as (
  values
    ('01 tables device_tokens / push_deliveries exist, RLS on, no policy', '2/2/0',
       (select count(c.oid)::text || '/' || count(c.oid) filter (where c.relrowsecurity)::text || '/'
               || (select count(*)::text from pg_policy p
                    where p.polrelid in (to_regclass('public.device_tokens'), to_regclass('public.push_deliveries')))
          from tabs t left join pg_class c on c.oid = to_regclass('public.' || t.name))),
    ('02 no table privilege for anon / authenticated / service_role (both tables)', 'true',
       (select (count(*) = 2 * 7 * 3 and bool_and(not has_table_privilege(r.r, 'public.' || t.name, v.p)))::text
          from tabs t cross join privs v cross join (values ('anon'), ('authenticated'), ('service_role')) r(r)
         where to_regclass('public.' || t.name) is not null)),
    ('03 the app functions: SECURITY DEFINER, empty search_path | authenticated / anon / service_role', '2/2|2/0/0',
       (select count(p.oid)::text || '/'
               || count(p.oid) filter (where p.prosecdef and array_to_string(p.proconfig, ',') like '%search_path=""%')::text
               || '|' || count(p.oid) filter (where has_function_privilege('authenticated', p.oid, 'execute'))::text
               || '/' || count(p.oid) filter (where has_function_privilege('anon', p.oid, 'execute'))::text
               || '/' || count(p.oid) filter (where has_function_privilege('service_role', p.oid, 'execute'))::text
          from app a left join pg_proc p on p.proname = a.name and p.pronamespace = 'public'::regnamespace)),
    ('04 the dispatcher functions: SECURITY DEFINER, empty search_path | service_role / authenticated / anon', '2/2|2/0/0',
       (select count(p.oid)::text || '/'
               || count(p.oid) filter (where p.prosecdef and array_to_string(p.proconfig, ',') like '%search_path=""%')::text
               || '|' || count(p.oid) filter (where has_function_privilege('service_role', p.oid, 'execute'))::text
               || '/' || count(p.oid) filter (where has_function_privilege('authenticated', p.oid, 'execute'))::text
               || '/' || count(p.oid) filter (where has_function_privilege('anon', p.oid, 'execute'))::text
          from dispatcher d left join pg_proc p on p.proname = d.name and p.pronamespace = 'public'::regnamespace)),
    ('05 internal functions: empty search_path; not callable by anon / authenticated / service_role', '2/2/0/0/0',
       (select count(p.oid)::text || '/'
               || count(p.oid) filter (where array_to_string(p.proconfig, ',') like '%search_path=""%')::text
               || '/' || count(p.oid) filter (where has_function_privilege('anon', p.oid, 'execute'))::text
               || '/' || count(p.oid) filter (where has_function_privilege('authenticated', p.oid, 'execute'))::text
               || '/' || count(p.oid) filter (where has_function_privilege('service_role', p.oid, 'execute'))::text
          from internal i left join pg_proc p on p.proname = i.name and p.pronamespace = 'public'::regnamespace)),
    ('06 the queue trigger on notifications: AFTER INSERT, enabled', 'true',
       (select (count(*) = 1)::text from pg_trigger tg
         where tg.tgrelid = to_regclass('public.notifications') and tg.tgname = 'notifications_queue_push'
           and tg.tgenabled = 'O' and tg.tgtype & 2 = 0 and tg.tgtype & 4 = 4)),
    ('07 a token is one installation (unique); FK delete rules token→profile / queue→notification', 'true|c|c',
       (select coalesce((select (count(*) = 1)::text from pg_constraint k
                          where k.conrelid = to_regclass('public.device_tokens') and k.conname = 'device_tokens_token_key'
                            and k.contype = 'u'), '-')
               || '|' || coalesce((select k.confdeltype::text from pg_constraint k
                                    where k.conrelid = to_regclass('public.device_tokens') and k.contype = 'f'), '-')
               || '|' || coalesce((select k.confdeltype::text from pg_constraint k
                                    where k.conrelid = to_regclass('public.push_deliveries') and k.contype = 'f'), '-'))),
    ('08 the queue holds no text or token (columns)', 'attempts,claimed_at,created_at,finished_at,last_error,notification_id,status',
       (select string_agg(c.column_name, ',' order by c.column_name) from information_schema.columns c
         where c.table_schema = 'public' and c.table_name = 'push_deliveries')),
    ('09 the wake-up is configured: pg_net and Vault present (INFO until that approved settings step)', 'info',
       (select 'net:' || (to_regnamespace('net') is not null)::text || ' vault:' || (to_regnamespace('vault') is not null)::text)),
    ('10 rows: devices / queue by status', 'info',
       (select case when to_regclass('public.push_deliveries') is null then '-' else
                 (xpath('/row/c/text()', query_to_xml(
                    'select (select count(*) from public.device_tokens)::text || '' / '' ||
                            coalesce((select string_agg(s || '':'' || n, '','' order by s)
                                        from (select status s, count(*) n from public.push_deliveries group by status) x), ''empty'') as c',
                    false, true, '')))[1]::text end))
)
select check_name, expected, actual,
       case when expected = 'info' then 'INFO'
            when actual is not distinct from expected then 'PASS' else 'FAIL' end as result
  from checks
 order by check_name;
