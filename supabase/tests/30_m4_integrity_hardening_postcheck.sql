-- CricEco · post-check for migration 30 (M4 integrity & security hardening).
-- READ-ONLY: one SELECT, no DML/DDL, no personal data (counts only). Every row
-- must say PASS (rows marked INFO only report). Safe before the migration too
-- (the new objects then FAIL).
with
fn as (select to_regprocedure('public.save_team(uuid, text, text, integer, uuid, uuid, jsonb, integer)') as save_team,
              to_regprocedure('public.register_push_device(text, text)') as reg,
              to_regprocedure('public.club_join_requests(uuid)') as cjr,
              to_regprocedure('public.profiles_validate()') as val),
mv as (select to_regclass('public.push_token_moves') as oid, to_regclass('public.push_token_moves_id_seq') as seq),
ada as (select to_regclass('public.account_deletion_attempts') as oid,
               to_regclass('public.account_deletion_attempts_id_seq') as seq),
roles(r) as (values ('anon'), ('authenticated'), ('service_role')),
checks(check_name, expected, actual) as (
  values
    ('01 profiles: the 3 field rules exist and are validated', '3/3',
       (select count(*)::text || '/' || count(*) filter (where k.convalidated)::text
          from pg_constraint k
         where k.conrelid = 'public.profiles'::regclass
           and k.conname in ('profiles_full_name_check', 'profiles_phone_check', 'profiles_role_check'))),
    ('02 profiles: the rules say what they should (name 2–100 / Pakistani mobile / player|club_owner)', 'true/true/true',
       (select coalesce(bool_or(k.conname = 'profiles_full_name_check'
                                and pg_get_constraintdef(k.oid) like '%full_name IS NULL%>= 2%<= 100%'), false)::text
               || '/' || coalesce(bool_or(k.conname = 'profiles_phone_check'
                                and pg_get_constraintdef(k.oid) like '%phone IS NULL%'
                                -- position(), not LIKE: the pattern holds backslashes
                                and position('regexp_replace(phone, ''[\s-]''' in pg_get_constraintdef(k.oid)) > 0
                                and position('''^(\+92|92|0)3[0-9]{9}$''' in pg_get_constraintdef(k.oid)) > 0), false)::text
               || '/' || coalesce(bool_or(k.conname = 'profiles_role_check'
                                and pg_get_constraintdef(k.oid) like '%role IS NULL%''player''%''club_owner''%'), false)::text
          from pg_constraint k where k.conrelid = 'public.profiles'::regclass)),
    ('03 profiles_validate keeps its rules and adds "a completed profile keeps its phone"', 'true',
       (select coalesce((select p.prosrc like '%date_of_birth cannot be in the future%'
                                and p.prosrc like '%profile_completed requires full_name, phone and date_of_birth%'
                                and p.prosrc like '%profile_completed requires a current and a permanent address%'
                                and p.prosrc like '%profile_completed requires phone''%'
                           from pg_proc p join fn on p.oid = fn.val), false)::text)),
    ('04 profiles grants unchanged: authenticated SELECT/INSERT/UPDATE only, anon nothing', 'true|false|false',
       (select (has_table_privilege('authenticated', 'public.profiles', 'SELECT')
                and has_table_privilege('authenticated', 'public.profiles', 'INSERT')
                and has_table_privilege('authenticated', 'public.profiles', 'UPDATE'))::text
               || '|' || has_table_privilege('authenticated', 'public.profiles', 'DELETE,TRUNCATE,REFERENCES,TRIGGER')::text
               || '|' || has_table_privilege('anon', 'public.profiles', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')::text)),
    ('05 profiles: rows / completed / completed without a phone (INFO)', 'info',
       (select count(*)::text || ' / ' || count(*) filter (where profile_completed)::text || ' / '
               || count(*) filter (where profile_completed and nullif(btrim(coalesce(phone, '')), '') is null)::text
          from public.profiles)),
    ('06 teams.version: integer, NOT NULL, default 1, checked >= 1', 'integer|true|1|1',
       (select coalesce((select format_type(a.atttypid, a.atttypmod) || '|' || a.attnotnull::text || '|'
                                || coalesce(pg_get_expr(d.adbin, d.adrelid), '-') || '|'
                                || (select count(*) from pg_constraint k
                                     where k.conrelid = 'public.teams'::regclass and k.conname = 'teams_version_check')::text
                           from pg_attribute a
                           left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
                          where a.attrelid = 'public.teams'::regclass and a.attname = 'version' and not a.attisdropped), '-'))),
    ('07 save_team: ONE function, the 8-argument one (p_expected_version integer default null)', '1|true',
       (select count(*)::text || '|'
               || coalesce(bool_and(pg_get_function_arguments(p.oid) like '%p_players jsonb, p_expected_version integer DEFAULT NULL::integer'), false)::text
          from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'save_team')),
    ('08 save_team: SECURITY DEFINER, empty search_path, returns teams; execute anon / authenticated', 'true|teams|0/1',
       (select coalesce((select (p.prosecdef and array_to_string(p.proconfig, ',') = 'search_path=""')::text
                                || '|' || format_type(p.prorettype, null)
                                || '|' || (case when has_function_privilege('anon', p.oid, 'execute') then 1 else 0 end)::text
                                || '/' || (case when has_function_privilege('authenticated', p.oid, 'execute') then 1 else 0 end)::text
                           from pg_proc p join fn on p.oid = fn.save_team), '-'))),
    ('09 save_team: stale version → 40001 ''team: changed elsewhere''; a save increments version', 'true',
       (select coalesce((select p.prosrc like '%p_expected_version is not null and p_expected_version <> v_team.version%'
                                and p.prosrc like '%''team: changed elsewhere'' using errcode = ''40001''%'
                                and p.prosrc like '%version = version + 1%'
                           from pg_proc p join fn on p.oid = fn.save_team), false)::text)),
    ('10 push_token_moves exists, RLS on, no policies', 'true|0',
       (select coalesce((select c.relrowsecurity::text || '|' || (select count(*) from pg_policy p where p.polrelid = c.oid)::text
                           from pg_class c join mv on c.oid = mv.oid), '-'))),
    ('11 no app role has any right on push_token_moves / its sequence (anon/authenticated/service_role)', '0/0/0|0/0/0',
       (select coalesce((select string_agg((case when has_table_privilege(r, mv.oid,
                                              'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') then 1 else 0 end)::text,
                                           '/' order by r)
                                || '|' || string_agg((case when has_sequence_privilege(r, mv.seq, 'USAGE,SELECT,UPDATE') then 1 else 0 end)::text,
                                                     '/' order by r)
                           from roles, mv where mv.oid is not null and mv.seq is not null), '-'))),
    ('12 push_token_moves: index (user_id, moved_at); user_id → profiles ON DELETE CASCADE', 'true|c',
       (select coalesce((select bool_or(pg_get_indexdef(i.indexrelid) like '%(user_id, moved_at)')::text
                           from pg_index i join mv on i.indrelid = mv.oid), 'false')
               || '|' || coalesce((select k.confdeltype::text from pg_constraint k join mv on k.conrelid = mv.oid
                                    where k.contype = 'f' and k.confrelid = 'public.profiles'::regclass), '-'))),
    ('13 register_push_device: definer, empty search_path, move limit 3 / 24 h (P0001); execute anon/authenticated/service_role', 'true|true|0/1/0',
       (select coalesce((select (p.prosecdef and array_to_string(p.proconfig, ',') = 'search_path=""')::text
                                || '|' || (p.prosrc like '%push_token_moves%'
                                           and p.prosrc like '%interval ''24 hours'') >= 3%'
                                           and p.prosrc like '%''push: too many device moves'' using errcode = ''P0001''%'
                                           and p.prosrc like '%where t.token = v_token for update%'
                                           and p.prosrc like '%where p.id = v_uid for no key update%')::text
                                || '|' || (case when has_function_privilege('anon', p.oid, 'execute') then 1 else 0 end)::text
                                || '/' || (case when has_function_privilege('authenticated', p.oid, 'execute') then 1 else 0 end)::text
                                || '/' || (case when has_function_privilege('service_role', p.oid, 'execute') then 1 else 0 end)::text
                           from pg_proc p join fn on p.oid = fn.reg), '-'))),
    ('14 club_join_requests: same result columns, declined > 30 days hidden; execute anon / authenticated', 'true|true|0/1',
       (select coalesce((select (pg_get_function_result(p.oid) =
                                   'TABLE(request_id uuid, status text, message text, assigned_role text, decline_reason text, created_at timestamp with time zone, decided_at timestamp with time zone, full_name text, phone text, applicant_age integer, city text, player_role text, batting_style text, bowling_style text, is_wicketkeeper boolean)')::text
                                || '|' || (p.prosecdef and p.prosrc like '%not (r.status = ''rejected'' and r.decided_at < now() - interval ''30 days'')%'
                                           and p.prosrc like '%case when p.share_phone_with_clubs then p.phone end%')::text
                                || '|' || (case when has_function_privilege('anon', p.oid, 'execute') then 1 else 0 end)::text
                                || '/' || (case when has_function_privilege('authenticated', p.oid, 'execute') then 1 else 0 end)::text
                           from pg_proc p join fn on p.oid = fn.cjr), '-'))),
    ('15 club_ownership_transfers: a full index on to_user_id', 'CREATE INDEX club_ownership_transfers_to_user_id_idx ON public.club_ownership_transfers USING btree (to_user_id)',
       (select coalesce(pg_get_indexdef(to_regclass('public.club_ownership_transfers_to_user_id_idx')), '-'))),
    ('16 account_deletion_attempts: primary key (id, identity ALWAYS); table and sequence closed to anon/authenticated', 'PRIMARY KEY (id)|a|0/0|0/0',
       (select coalesce((select pg_get_constraintdef(k.oid) from pg_constraint k join ada on k.conrelid = ada.oid where k.contype = 'p'), '-')
               || '|' || coalesce((select a.attidentity::text from pg_attribute a join ada on a.attrelid = ada.oid
                                    where a.attname = 'id' and not a.attisdropped), '-')
               || '|' || coalesce((select (case when has_table_privilege('anon', ada.oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') then 1 else 0 end)::text
                                          || '/' || (case when has_table_privilege('authenticated', ada.oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE') then 1 else 0 end)::text
                                     from ada), '-')
               || '|' || coalesce((select (case when has_sequence_privilege('anon', ada.seq, 'USAGE,SELECT,UPDATE') then 1 else 0 end)::text
                                          || '/' || (case when has_sequence_privilege('authenticated', ada.seq, 'USAGE,SELECT,UPDATE') then 1 else 0 end)::text
                                     from ada where ada.seq is not null), '-'))),
    ('17 device moves recorded in the last 24 hours (INFO)', 'info',
       (select case when mv.oid is null then 'no table' else
                 (xpath('/row/c/text()', query_to_xml(
                    'select count(*) as c from public.push_token_moves where moved_at > now() - interval ''24 hours''',
                    false, true, '')))[1]::text end
          from mv))
)
select check_name, expected, actual,
       case when expected = 'info' then 'INFO'
            when actual is not distinct from expected then 'PASS' else 'FAIL' end as result
  from checks
 order by check_name;
