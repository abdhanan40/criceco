-- CricEco · post-check for migration 32 (M7 club discovery: public club
-- profiles and directory, availability slots, player rankings, applicant
-- statistics).
-- READ-ONLY: one SELECT, no DML/DDL, no personal data (counts only). Every row
-- must say PASS (rows marked INFO only report). Safe before the migration too
-- (the new objects then FAIL).
with
api(sig) as (values ('public.club_public_profile(uuid)'), ('public.club_directory(text, text, integer, integer)'),
                    ('public.post_match_slot(uuid, text, integer, text, date, time, time, text, text, text)'),
                    ('public.withdraw_match_slot(uuid)'), ('public.my_club_slots(uuid, boolean)'),
                    ('public.open_match_slots(text, text, date, date, integer, integer)'),
                    ('public.player_rankings(text, uuid, text, integer)'), ('public.club_applicant_stats(uuid)')),
internal(sig) as (values ('public.club_public_stats(uuid)'), ('public.player_recent_form(uuid[])')),
fns as (select a.sig, to_regprocedure(a.sig) as oid, true as is_api from api a
        union all
        select i.sig, to_regprocedure(i.sig), false from internal i),
names(n) as (values ('club_public_stats'), ('club_public_profile'), ('club_directory'), ('post_match_slot'),
                    ('withdraw_match_slot'), ('my_club_slots'), ('open_match_slots'), ('player_recent_form'),
                    ('player_rankings'), ('club_applicant_stats')),
tbl as (select to_regclass('public.club_match_slots') as oid),
checks(check_name, expected, actual) as (
  values
    ('01 club_match_slots: RLS on, no policy; no privilege for anon / authenticated / service_role', 'true|0|false|false|false',
       (select case when t.oid is null then 'missing' else
                 (select c.relrowsecurity::text from pg_class c where c.oid = t.oid) || '|'
                 || (select count(*)::text from pg_policy p where p.polrelid = t.oid) || '|'
                 || has_table_privilege('anon', t.oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')::text || '|'
                 || has_table_privilege('authenticated', t.oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')::text || '|'
                 || has_table_privilege('service_role', t.oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')::text end
          from tbl t)),
    ('02 club_match_slots columns',
     'id uuid NO, club_id uuid NO, format text NO, custom_overs smallint YES, city text NO, ground_id text YES, '
     'venue_name text YES, starts_at timestamp with time zone NO, ends_at timestamp with time zone NO, notes text YES, '
     'status text NO, closed_at timestamp with time zone YES, created_by uuid YES, created_at timestamp with time zone NO, '
     'last_updated_at timestamp with time zone NO',
       (select coalesce(string_agg(c.column_name || ' ' || c.data_type || ' ' || c.is_nullable, ', ' order by c.ordinal_position), 'missing')
          from information_schema.columns c where c.table_schema = 'public' and c.table_name = 'club_match_slots')),
    ('03 club_match_slots: the 12 named constraints exist and are validated; status open | withdrawn | expired | taken', '12/12/true',
       (select count(*)::text || '/' || count(*) filter (where k.convalidated)::text || '/'
               || coalesce(bool_or(k.conname = 'club_match_slots_status_check'
                                   and pg_get_constraintdef(k.oid) like '%''open''%''withdrawn''%''expired''%''taken''%'), false)::text
          from pg_constraint k
         where k.conrelid = (select oid from tbl)
           and k.conname in ('club_match_slots_format_check', 'club_match_slots_custom_overs_check',
                             'club_match_slots_city_check', 'club_match_slots_ground_id_check',
                             'club_match_slots_venue_name_check', 'club_match_slots_notes_check',
                             'club_match_slots_status_check', 'club_match_slots_overs_follow_format',
                             'club_match_slots_time_range', 'club_match_slots_closed_consistency',
                             'club_match_slots_club_id_fkey', 'club_match_slots_created_by_fkey'))),
    ('04 club_match_slots: indexes and the last_updated_at trigger',
     'club_match_slots_club_idx, club_match_slots_created_by_idx, club_match_slots_open_club_idx, club_match_slots_open_starts_idx, club_match_slots_pkey|true',
       (select coalesce((select string_agg(i.indexname, ', ' order by i.indexname) from pg_indexes i
                          where i.schemaname = 'public' and i.tablename = 'club_match_slots'), 'missing') || '|'
               || coalesce((select (t.tgenabled = 'O')::text from pg_trigger t
                             where t.tgrelid = (select oid from tbl) and t.tgname = 'club_match_slots_set_last_updated_at'), 'missing'))),
    ('05 the 8 API functions: present / SECURITY DEFINER / search_path "" / authenticated yes / anon no', '8/8/8/8/8',
       (select count(f.oid)::text || '/' || count(*) filter (where p.prosecdef)::text || '/'
               || count(*) filter (where array_to_string(p.proconfig, ',') = 'search_path=""')::text || '/'
               || count(*) filter (where has_function_privilege('authenticated', f.oid, 'execute'))::text || '/'
               || count(*) filter (where not has_function_privilege('anon', f.oid, 'execute'))::text
          from fns f left join pg_proc p on p.oid = f.oid where f.is_api)),
    ('06 the 2 internal helpers: present / SECURITY DEFINER, search_path "" / executable by authenticated or anon', '2/2/0',
       (select count(f.oid)::text || '/'
               || count(*) filter (where p.prosecdef and array_to_string(p.proconfig, ',') = 'search_path=""')::text || '/'
               || count(*) filter (where has_function_privilege('authenticated', f.oid, 'execute')
                                      or has_function_privilege('anon', f.oid, 'execute'))::text
          from fns f left join pg_proc p on p.oid = f.oid where not f.is_api and f.oid is not null)),
    ('07 the ten functions have exactly the documented arguments and result columns (md5)', 'aa7b9a241648f9bee2f3d6d5a571f5d7',
       (select coalesce(md5(string_agg(p.proname || '=' || pg_get_function_identity_arguments(p.oid) || '=' || pg_get_function_result(p.oid),
                                      ';' order by p.proname)), 'missing')
          from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname in (select n2.n from names n2))),
    ('08 one function per name (no stray overloads)', '10',
       (select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname in (select n2.n from names n2))),
    ('09 no public result carries an owner, phone, e-mail, address, join code, birth date or created_by column', '0',
       (select count(*)::text from fns f
         where f.is_api and f.oid is not null
           and pg_get_function_result(f.oid) ~ '(owner|phone|email|address|code|date_of_birth|created_by)')),
    ('10 the functions used are still those of migrations 11 and 22 (member_stats, is_club_owner)', 'true|true',
       (select coalesce((select (md5(replace(p.prosrc, chr(13), '')) = '8ca6dc8d797d94b255fbe871400bb212' and p.prosecdef)::text
                           from pg_proc p where p.oid = to_regprocedure('public.member_stats(uuid[])')), 'missing') || '|'
               || coalesce((select (md5(replace(p.prosrc, chr(13), '')) = 'f9100b85bcfaa52aac0aa03f292b14fb' and p.prosecdef)::text
                              from pg_proc p where p.oid = to_regprocedure('public.is_club_owner(uuid)')), 'missing'))),
    ('11 slots by status: open (not started) / open (started, to expire) / withdrawn / expired / taken (INFO)', 'info',
       (select case when (select oid from tbl) is null then 'no table' else
                 (xpath('/row/c/text()', query_to_xml(
                    'select (select count(*) from public.club_match_slots where status = ''open'' and starts_at > now()) || '' / ''
                            || (select count(*) from public.club_match_slots where status = ''open'' and starts_at <= now()) || '' / ''
                            || (select count(*) from public.club_match_slots where status = ''withdrawn'') || '' / ''
                            || (select count(*) from public.club_match_slots where status = ''expired'') || '' / ''
                            || (select count(*) from public.club_match_slots where status = ''taken'') as c',
                    false, true, '')))[1]::text end)),
    ('12 clubs / players who would be listed in the rankings (counts, INFO)', 'info',
       (select (select count(*) from public.clubs)::text || ' / '
               || (select count(*) from public.profiles p
                    where p.show_stats and p.public_profile
                      and char_length(btrim(coalesce(p.full_name, ''))) > 0
                      and exists (select 1 from public.player_profiles pp where pp.user_id = p.id)
                      and exists (select 1 from public.club_members m where m.user_id = p.id and m.status = 'active'))::text))
)
select check_name, expected, actual,
       case when expected = 'info' then 'INFO'
            when actual is not distinct from expected then 'PASS' else 'FAIL' end as result
  from checks
 order by check_name;
