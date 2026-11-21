-- CricEco · post-check for migration 23 (my_matches).
-- READ-ONLY: one SELECT, no DML/DDL, no personal data. Every row must say PASS.
-- Safe before the migration too (the new object then FAILs).
with checks(check_name, expected, actual) as (
  values
    ('01 my_matches(): SECURITY DEFINER, empty search_path', '1/1',
       (select count(*)::text || '/' ||
               count(*) filter (where p.prosecdef and array_to_string(p.proconfig, ',') like '%search_path=""%')::text
          from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'my_matches')),
    ('02 authenticated yes, anon no', '1/0',
       (select count(*) filter (where has_function_privilege('authenticated', p.oid, 'execute'))::text || '/'
               || count(*) filter (where has_function_privilege('anon', p.oid, 'execute'))::text
          from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'my_matches')),
    ('03 no arguments; 19 output columns, own selection only', '0/19/true',
       (select coalesce(max(p.pronargs)::text, '-') || '/'
               || coalesce(max(cardinality(p.proargnames))::text, '-') || '/'
               || coalesce(bool_and('selection' = any (p.proargnames) and not ('opponent_lineup' = any (p.proargnames)))::text, '-')
          from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'my_matches'))
)
select check_name, expected, actual,
       case when actual is not distinct from expected then 'PASS' else 'FAIL' end as result
  from checks
 order by check_name;
