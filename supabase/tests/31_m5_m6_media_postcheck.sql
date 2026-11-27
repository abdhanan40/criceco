-- CricEco · post-check for migration 31 (M5 media uploads, M6 privacy visibility).
-- READ-ONLY: one SELECT, no DML/DDL, no personal data (counts only). Every row
-- must say PASS (rows marked INFO only report). Safe before the migration too
-- (the new objects then FAIL).
with
fn as (select to_regprocedure('public.set_my_avatar(text)') as avatar,
              to_regprocedure('public.set_club_logo(uuid, text)') as logo,
              to_regprocedure('public.set_profile_visibility(boolean, boolean)') as vis,
              to_regprocedure('public.my_profile_visibility()') as myvis,
              to_regprocedure('public.my_privacy_settings()') as priv,
              to_regprocedure('public.club_member_list(uuid)') as cml,
              to_regprocedure('public.club_join_requests(uuid)') as cjr,
              to_regprocedure('public.my_club_memberships()') as mcm,
              to_regprocedure('public.profiles_guard_avatar_path()') as guard),
cols as (select c.table_name || '.' || c.column_name as col,
                c.data_type || '|' || (c.is_nullable = 'NO')::text || '|' || coalesce(c.column_default, '-') as spec
           from information_schema.columns c
          where c.table_schema = 'public'
            and ((c.table_name = 'profiles' and c.column_name in ('avatar_path', 'public_profile', 'show_stats'))
                 or (c.table_name = 'clubs' and c.column_name = 'logo_path'))),
pol as (select p.polname, p.polcmd, p.polroles, p.polpermissive, pg_get_expr(p.polqual, p.polrelid) as q,
               pg_get_expr(p.polwithcheck, p.polrelid) as c
          from pg_policy p
         where p.polrelid = to_regclass('storage.objects')
           and (p.polname like 'criceco media:%' or p.polname like 'criceco avatars:%' or p.polname like 'criceco club logos:%')),
newcols as (select count(*) = 4 as ok from cols),
checks(check_name, expected, actual) as (
  values
    ('01 columns: profiles.avatar_path text NULL; public_profile / show_stats boolean NOT NULL default true; clubs.logo_path text NULL',
     'clubs.logo_path text|false|-; profiles.avatar_path text|false|-; profiles.public_profile boolean|true|true; profiles.show_stats boolean|true|true',
       (select coalesce(string_agg(col || ' ' || spec, '; ' order by col), 'missing') from cols)),
    ('02 the path checks exist, are validated and require <own id>/<uuid>.<jpg|jpeg|png|webp>', '2/2/2',
       (select count(*)::text || '/' || count(*) filter (where k.convalidated)::text || '/'
               || count(*) filter (where position('(jpg|jpeg|png|webp)$' in pg_get_constraintdef(k.oid)) > 0
                                     and pg_get_constraintdef(k.oid) like '%split_part(%, ''/''::text, 1) = (id)::text%')::text
          from pg_constraint k
         where (k.conrelid = 'public.profiles'::regclass and k.conname = 'profiles_avatar_path_check')
            or (k.conrelid = 'public.clubs'::regclass and k.conname = 'clubs_logo_path_check'))),
    ('03 avatar_path guard: BEFORE INSERT OR UPDATE OF avatar_path, enabled; its function closed to the API roles', 'true|false',
       (select coalesce((select bool_and(t.tgenabled = 'O'
                                         and pg_get_triggerdef(t.oid) like '%BEFORE INSERT OR UPDATE OF avatar_path ON public.profiles%')::text
                           from pg_trigger t
                          where t.tgrelid = 'public.profiles'::regclass and t.tgname = 'profiles_guard_avatar_path'), 'missing')
               || '|' || coalesce((select (has_function_privilege('authenticated', fn.guard, 'execute')
                                           or has_function_privilege('anon', fn.guard, 'execute'))::text from fn
                                    where fn.guard is not null), 'missing'))),
    ('04 clubs.logo_path: authenticated may read, not insert / update; anon nothing', 'true|false|false',
       (select case when not exists (select 1 from cols where col = 'clubs.logo_path') then 'missing' else
                 has_column_privilege('authenticated', 'public.clubs', 'logo_path', 'SELECT')::text || '|'
                 || (has_column_privilege('authenticated', 'public.clubs', 'logo_path', 'INSERT')
                     or has_column_privilege('authenticated', 'public.clubs', 'logo_path', 'UPDATE'))::text || '|'
                 || has_column_privilege('anon', 'public.clubs', 'logo_path', 'SELECT,INSERT,UPDATE,REFERENCES')::text end)),
    ('05 profiles grants unchanged: authenticated SELECT/INSERT/UPDATE only, anon nothing', 'true|false|false',
       (select (has_table_privilege('authenticated', 'public.profiles', 'SELECT')
                and has_table_privilege('authenticated', 'public.profiles', 'INSERT')
                and has_table_privilege('authenticated', 'public.profiles', 'UPDATE'))::text
               || '|' || has_table_privilege('authenticated', 'public.profiles', 'DELETE,TRUNCATE,REFERENCES,TRIGGER')::text
               || '|' || has_table_privilege('anon', 'public.profiles', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')::text)),
    ('06 buckets avatars / club-logos: private, 2 MiB, image/jpeg + png + webp',
     'avatars|false|2097152|{image/jpeg,image/png,image/webp}; club-logos|false|2097152|{image/jpeg,image/png,image/webp}',
       (select case when to_regclass('storage.buckets') is null then 'no storage' else
                 coalesce((xpath('/row/c/text()', query_to_xml(
                   'select string_agg(id || ''|'' || coalesce(public::text, ''-'') || ''|'' || coalesce(file_size_limit::text, ''-'')
                                      || ''|'' || coalesce(allowed_mime_types::text, ''-''), ''; '' order by id) as c
                      from storage.buckets where id in (''avatars'', ''club-logos'')', false, true, '')))[1]::text, 'missing') end)),
    ('07 storage.objects: RLS on; 7 CricEco policies, all permissive and to authenticated only', 'true|7|7',
       (select coalesce((select c.relrowsecurity::text from pg_class c where c.oid = to_regclass('storage.objects')), 'no storage')
               || '|' || (select count(*) from pol)::text
               || '|' || (select count(*) from pol
                           where pol.polpermissive and pol.polroles = array[(select oid from pg_roles where rolname = 'authenticated')]::oid[])::text)),
    ('08 policies: read 1 (both buckets); avatars 3 by auth.uid() folder; club logos 3 by is_club_owner; all with the name pattern',
     'r=1 a=3 c=3 shape=6',
       (select 'r=' || count(*) filter (where polcmd = 'r' and q like '%avatars%' and q like '%club-logos%')
               || ' a=' || count(*) filter (where polcmd <> 'r' and coalesce(q, c) like '%''avatars''%'
                                             and coalesce(c, q) like '%foldername(name))[1] = (( SELECT auth.uid()%')
               || ' c=' || count(*) filter (where polcmd <> 'r' and coalesce(q, c) like '%''club-logos''%'
                                             and coalesce(c, q) like '%is_club_owner(%foldername(name))[1])::uuid)%')
               || ' shape=' || count(*) filter (where polcmd <> 'r' and position('(jpg|jpeg|png|webp)$' in coalesce(c, q)) > 0
                                                 and (q is null or position('(jpg|jpeg|png|webp)$' in q) > 0))
          from pol)),
    ('09 set_my_avatar / set_club_logo / set_profile_visibility / my_profile_visibility: SECURITY DEFINER, search_path "", authenticated only', '4/4',
       (select count(*)::text || '/' || count(*) filter (where p.prosecdef and array_to_string(p.proconfig, ',') = 'search_path=""'
                                                          and has_function_privilege('authenticated', p.oid, 'execute')
                                                          and not has_function_privilege('anon', p.oid, 'execute'))::text
          from pg_proc p, fn where p.oid in (fn.avatar, fn.logo, fn.vis, fn.myvis))),
    ('10 my_profile_visibility is one row (public_profile, show_stats); club_member_list / club_join_requests / my_club_memberships: new last column, same properties and grants',
     'true/true/true/true',
       (select coalesce((select (pg_get_function_result(fn.myvis) = 'TABLE(public_profile boolean, show_stats boolean)')::text
                                || '/' || (pg_get_function_result(fn.cml) like 'TABLE(member_id uuid, %, is_wicketkeeper boolean, avatar_path text)')::text
                                || '/' || (pg_get_function_result(fn.cjr) like 'TABLE(request_id uuid, %, is_wicketkeeper boolean, avatar_path text)')::text
                                || '/' || (pg_get_function_result(fn.mcm) like 'TABLE(member_id uuid, %, joined_at timestamp with time zone, club_logo_path text)'
                                           and (select bool_and(p.prosecdef and array_to_string(p.proconfig, ',') = 'search_path=""'
                                                                and has_function_privilege('authenticated', p.oid, 'execute')
                                                                and not has_function_privilege('anon', p.oid, 'execute'))
                                                  from pg_proc p where p.oid in (fn.cml, fn.cjr, fn.mcm)))::text
                           from fn), 'missing'))),
    ('11 the club views keep phone consent (13) and the 30-day rule (30)', 'true',
       (select coalesce((select bool_and(case when p.oid = fn.cjr
                                              then p.prosrc like '%case when p.share_phone_with_clubs then p.phone end%'
                                                   and p.prosrc like '%r.decided_at < now() - interval ''30 days''%'
                                              else p.prosrc like '%case when p.share_phone_with_clubs or m.user_id = (select auth.uid()) then p.phone end%' end)::text
                           from pg_proc p, fn where p.oid in (fn.cml, fn.cjr)), 'missing'))),
    ('12 set_my_avatar''s owner bypasses RLS and may read storage.objects (else every path is "file not found")', 'true',
       (select coalesce((select ((r.rolsuper or r.rolbypassrls)
                                 and has_table_privilege(r.oid, 'storage.objects', 'SELECT'))::text
                           from pg_proc p join pg_roles r on r.oid = p.proowner, fn
                          where p.oid = fn.avatar and to_regclass('storage.objects') is not null), 'missing'))),
    ('13 profiles with an avatar / clubs with a logo / profiles not public / stats hidden (INFO)', 'info',
       (select case when not (select ok from newcols) then 'columns missing' else
                 (xpath('/row/c/text()', query_to_xml(
                    'select (select count(*) from public.profiles where avatar_path is not null) || '' / ''
                            || (select count(*) from public.clubs where logo_path is not null) || '' / ''
                            || (select count(*) from public.profiles where not public_profile) || '' / ''
                            || (select count(*) from public.profiles where not show_stats) as c',
                    false, true, '')))[1]::text end)),
    ('14 files in avatars / club-logos (INFO)', 'info',
       (select case when to_regclass('storage.objects') is null then 'no storage' else
                 (xpath('/row/c/text()', query_to_xml(
                    'select (select count(*) from storage.objects where bucket_id = ''avatars'') || '' / ''
                            || (select count(*) from storage.objects where bucket_id = ''club-logos'') as c',
                    false, true, '')))[1]::text end)),
    ('15 my_privacy_settings untouched (migration 13: boolean, same body, authenticated only)', 'boolean|true|true',
       (select coalesce((select pg_get_function_result(p.oid) || '|'
                                || (md5(replace(p.prosrc, chr(13), '')) = '6505982ba6501ccc6e846d5badf430ce')::text || '|'
                                || (has_function_privilege('authenticated', p.oid, 'execute')
                                    and not has_function_privilege('anon', p.oid, 'execute'))::text
                           from pg_proc p join fn on p.oid = fn.priv), 'missing')))
)
select check_name, expected, actual,
       case when expected = 'info' then 'INFO'
            when actual is not distinct from expected then 'PASS' else 'FAIL' end as result
  from checks
 order by check_name;
