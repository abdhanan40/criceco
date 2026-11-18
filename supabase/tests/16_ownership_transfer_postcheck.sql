-- CricEco · post-check for migration 16 (club ownership transfer). READ-ONLY:
-- one SELECT, no DML/DDL, no personal data. Every row must say PASS.
-- Safe before the migration too (the new objects then FAIL / ABSENT).
with checks(check_name, expected, actual) as (
  values
    ('01 table club_ownership_transfers exists, RLS on', 'true',
       coalesce((select relrowsecurity::text from pg_class where oid = to_regclass('public.club_ownership_transfers')), 'ABSENT')),
    ('02 one SELECT policy (involved or owner); no other policy', '1/1',
       (select count(*) filter (where cmd = 'SELECT')::text || '/' || count(*)::text
          from pg_policies where schemaname = 'public' and tablename = 'club_ownership_transfers')),
    ('03 authenticated: SELECT only; anon: nothing', 'true',
       (to_regclass('public.club_ownership_transfers') is not null
        and not exists (select 1 from information_schema.role_table_grants where table_schema = 'public'
                          and table_name = 'club_ownership_transfers'
                          and ((grantee = 'authenticated' and privilege_type <> 'SELECT') or grantee in ('anon', 'PUBLIC')))
        and exists (select 1 from information_schema.role_table_grants where table_schema = 'public'
                      and table_name = 'club_ownership_transfers' and grantee = 'authenticated' and privilege_type = 'SELECT'))::text),
    ('04 one pending offer per club (unique partial index)', 'true',
       (exists (select 1 from pg_indexes where schemaname = 'public' and indexname = 'club_ownership_transfers_one_pending_key'
                  and indexdef like 'CREATE UNIQUE INDEX%' and indexdef like '%(club_id)%' and indexdef like '%pending%'))::text),
    ('05 named constraints present (status, role, decided, not self, expiry)', '5',
       (select count(*)::text from pg_constraint where connamespace = 'public'::regnamespace
          and conname in ('club_ownership_transfers_status_check', 'club_ownership_transfers_previous_owner_role_check',
                          'club_ownership_transfers_decided_consistency', 'club_ownership_transfers_not_self',
                          'club_ownership_transfers_expiry_after_creation'))),
    ('06 history survives a deleted person (FKs to profiles / members SET NULL; club CASCADE)', 'c/n/n/n',
       (select coalesce(max(confdeltype::text) filter (where conname = 'club_ownership_transfers_club_id_fkey'), '-') || '/'
               || coalesce(max(confdeltype::text) filter (where conname = 'club_ownership_transfers_from_user_id_fkey'), '-') || '/'
               || coalesce(max(confdeltype::text) filter (where conname = 'club_ownership_transfers_to_user_id_fkey'), '-') || '/'
               || coalesce(max(confdeltype::text) filter (where conname = 'club_ownership_transfers_to_member_id_fkey'), '-')
          from pg_constraint where connamespace = 'public'::regnamespace)),
    ('07 the 7 functions: SECURITY DEFINER, empty search_path', '7/7',
       (select count(*)::text || '/' ||
               count(*) filter (where p.prosecdef and array_to_string(p.proconfig, ',') like '%search_path=""%')::text
          from pg_proc p where p.pronamespace = 'public'::regnamespace
           and p.proname in ('ownership_recipient_problem', 'offer_club_ownership', 'cancel_ownership_transfer',
                             'reject_ownership_transfer', 'accept_ownership_transfer', 'club_ownership_transfers',
                             'my_ownership_offers'))),
    ('08 the 6 API functions: authenticated yes, anon no', '6/0',
       (select count(*) filter (where has_function_privilege('authenticated', p.oid, 'execute'))::text || '/'
               || count(*) filter (where has_function_privilege('anon', p.oid, 'execute'))::text
          from pg_proc p where p.pronamespace = 'public'::regnamespace
           and p.proname in ('offer_club_ownership', 'cancel_ownership_transfer', 'reject_ownership_transfer',
                             'accept_ownership_transfer', 'club_ownership_transfers', 'my_ownership_offers'))),
    ('09 the eligibility helper: not callable by app roles', 'false/false',
       coalesce((select has_function_privilege('authenticated', p.oid, 'execute')::text || '/'
                        || has_function_privilege('anon', p.oid, 'execute')::text
                   from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'ownership_recipient_problem'),
                'ABSENT')),
    ('10 no offers yet', '0',
       case when to_regclass('public.club_ownership_transfers') is null then 'ABSENT'
            else (xpath('/row/v/text()', query_to_xml(
              'select count(*)::text as v from public.club_ownership_transfers', false, true, '')))[1]::text end)
)
select check_name, expected, actual,
       case when actual is not distinct from expected then 'PASS' else 'FAIL' end as result
  from checks
 order by check_name;
