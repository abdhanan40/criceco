-- CricEco · LOCAL TEST ONLY — migration 31 (M5 media uploads, M6 privacy
-- visibility) on a DISPOSABLE database after migrations 1–30 (+ the D1
-- location seed), the Storage stand-in (26_m5_m6_media_local_check.sh stub)
-- and migration 31: the "postgres" database of a throwaway container of the
-- real Supabase image (fixture copy without its auth guard), or a plain
-- PostgreSQL database with 00_auth_stub.sql and 02_legacy_profiles_fixture.sql.
-- Synthetic data only (people ee910000-…, objects aa910000-…); everything
-- runs in ONE transaction that is ROLLED BACK at the end.
-- Run with psql:  psql -X -v ON_ERROR_STOP=1 -f 26_m5_m6_media_local_check.sql
-- Uploads are played by inserting into storage.objects AS the signed-in role
-- (as the Storage API does: its RLS decides). Every check prints "PASS: …";
-- the first failure stops the run ("FAIL: …").
-- Refuses to run where any auth user has a password (a real project).
\set ON_ERROR_STOP on

begin;

do $$
declare
  v_pw boolean := false;
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password') then
    execute 'select exists (select 1 from auth.users where coalesce(encrypted_password, '''') <> '''')' into v_pw;
  end if;
  if v_pw or exists (select 1 from auth.users where email is null or email not like '%@local.test') then
    raise exception 'LOCAL ONLY: this database has real users — refusing';
  end if;
  if to_regprocedure('public.set_my_avatar(text)') is null then
    raise exception 'apply migration 31 first';
  end if;
end $$;

create schema t26;
grant usage on schema t26 to anon, authenticated, service_role;

create function t26.ok(p_cond boolean, p_name text) returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_name; end if;
  raise notice 'PASS: %', p_name;
end $$;

-- PASS when p_sql fails with exactly SQLSTATE p_state and a message LIKE p_like.
create function t26.err(p_sql text, p_state text, p_like text, p_name text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlstate = p_state and sqlerrm like p_like then
      raise notice 'PASS: % [% %]', p_name, sqlstate, sqlerrm;
      return;
    end if;
    raise exception 'FAIL: % — unexpected error [% %]', p_name, sqlstate, sqlerrm;
  end;
  raise exception 'FAIL: % — no error', p_name;
end $$;

create function t26.okq(p_sql text, p_name text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    raise exception 'FAIL: % — error [% %]', p_name, sqlstate, sqlerrm;
  end;
  raise notice 'PASS: %', p_name;
end $$;

-- Rows touched by p_sql (an UPDATE / DELETE that RLS may filter).
create function t26.affected(p_sql text) returns int language plpgsql as $$
declare
  n int;
begin
  execute p_sql;
  get diagnostics n = row_count;
  return n;
end $$;

-- Both spellings: the image's own auth.uid() reads request.jwt.claim.sub only.
create function t26.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true),
         set_config('request.jwt.claim.sub', p_uid::text, true);
$$;
create function t26.as_nobody() returns void language sql as $$
  select set_config('request.jwt.claims', '', true), set_config('request.jwt.claim.sub', '', true);
$$;
create function t26.p(p_n int) returns uuid language sql immutable as $$
  select ('ee910000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
$$;
create function t26.o(p_n int) returns text language sql immutable as $$
  select 'aa910000-0000-4000-8000-' || lpad(p_n::text, 12, '0');
$$;
-- "<folder>/<object uuid>.<ext>"
create function t26.path(p_folder uuid, p_obj int, p_ext text default 'jpg') returns text language sql immutable as $$
  select p_folder::text || '/' || t26.o(p_obj) || '.' || p_ext;
$$;
create function t26.club(p_name text) returns uuid language sql stable security definer set search_path = '' as $$
  select c.id from public.clubs c where c.name = p_name;
$$;
-- An upload as the current role (RLS applies).
create function t26.up_sql(p_bucket text, p_name text) returns text language sql immutable as $$
  select format('insert into storage.objects (bucket_id, name, owner_id, metadata) values (%L, %L, auth.uid()::text, %L)',
                p_bucket, p_name, '{"mimetype": "image/jpeg", "size": 1000}');
$$;
create function t26.objects_seen(p_bucket text, p_like text) returns int language sql stable as $$
  select count(*)::int from storage.objects o where (p_bucket is null or o.bucket_id = p_bucket) and o.name like p_like;
$$;
create function t26.make_person(p_n int) returns uuid language plpgsql as $$
declare
  v uuid := t26.p(p_n);
begin
  insert into auth.users (id, email) values (v, format('m5p%s@local.test', p_n));
  insert into public.profiles (id) values (v) on conflict (id) do nothing; -- the sign-up trigger made it already
  insert into public.current_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
  insert into public.permanent_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
  update public.profiles
     set full_name = format('M5 Person %s', p_n),
         phone = format('+923%s', lpad((720000000 + p_n)::text, 9, '0')),
         date_of_birth = date '2000-05-01', profile_completed = true
   where id = v;
  return v;
end $$;
grant execute on all functions in schema t26 to anon, authenticated, service_role;

-- People: 1 owns "M5 Lions", 2 owns "M5 Kings", 3 a member of Lions,
-- 4 an applicant to Lions, 5 nobody's member, 6 an applicant declined 31
-- days ago, 9 a signed-in user without a profile row.
select count(*) from (select t26.make_person(n) from unnest(array[1, 2, 3, 4, 5, 6]) n) s;
insert into auth.users (id, email) values (t26.p(9), 'm5p9@local.test');
delete from public.profiles where id = t26.p(9);
insert into public.clubs (owner_id, name, city, club_type) values (t26.p(1), 'M5 Lions', 'Lahore', 'corporate');
insert into public.clubs (owner_id, name, city, club_type) values (t26.p(2), 'M5 Kings', 'Lahore', 'corporate');
insert into public.club_members (club_id, user_id, member_role, status)
values (t26.club('M5 Lions'), t26.p(3), 'player', 'active');
insert into public.join_requests (club_id, user_id, status, created_at)
values (t26.club('M5 Lions'), t26.p(4), 'pending', now() - interval '1 day');
insert into public.join_requests (club_id, user_id, status, decline_reason, decided_at, decided_by, created_at)
values (t26.club('M5 Lions'), t26.p(6), 'rejected', 'Squad full', now() - interval '31 days', t26.p(1), now() - interval '40 days');
-- A bucket of someone else's feature (no CricEco policy covers it).
insert into storage.buckets (id, name, public) values ('t26-other', 't26-other', false);
insert into storage.objects (bucket_id, name) values ('t26-other', t26.path(t26.p(5), 90));
-- Objects only the server could have put there (for the bucket checks).
insert into storage.objects (bucket_id, name) values ('club-logos', t26.path(t26.p(5), 91));
insert into storage.objects (bucket_id, name) values ('avatars', t26.path(t26.club('M5 Lions'), 92, 'png'));

-- ---------------------------------------------------------------------------
-- A. Buckets
-- ---------------------------------------------------------------------------
select t26.ok((select count(*) from storage.buckets b
                where b.id in ('avatars', 'club-logos') and b.name = b.id and b.public is false
                  and b.file_size_limit = 2097152
                  and b.allowed_mime_types::text[] = array['image/jpeg', 'image/png', 'image/webp']) = 2,
              'A1 buckets avatars / club-logos: private, 2 MiB, jpeg / png / webp');

-- ---------------------------------------------------------------------------
-- S. storage.objects policies
-- ---------------------------------------------------------------------------
set local role authenticated;
select t26.as_user(t26.p(5));
select t26.okq(t26.up_sql('avatars', t26.path(t26.p(5), 1)), 'S1 a user uploads avatars/<own id>/<uuid>.jpg');
select t26.okq(t26.up_sql('avatars', t26.path(t26.p(5), 2, 'jpeg')), 'S2 … and .jpeg');
select t26.okq(t26.up_sql('avatars', t26.path(t26.p(5), 3, 'png')), 'S3 … and .png');
select t26.okq(t26.up_sql('avatars', t26.path(t26.p(5), 4, 'webp')), 'S4 … and .webp');
select t26.err(t26.up_sql('avatars', t26.path(t26.p(1), 5)), '42501', '%row-level security%',
               'S5 an upload into another user''s avatar folder is refused');
select t26.err(t26.up_sql('avatars', t26.path(t26.p(5), 6, 'gif')), '42501', '%row-level security%',
               'S6 another extension (.gif) is refused');
select t26.err(t26.up_sql('avatars', t26.path(t26.p(5), 7, 'JPG')), '42501', '%row-level security%',
               'S7 an upper-case extension is refused');
select t26.err(t26.up_sql('avatars', t26.p(5)::text || '/photo.jpg'), '42501', '%row-level security%',
               'S8 a file name that is not a UUID is refused');
select t26.err(t26.up_sql('avatars', t26.p(5)::text || '/sub/' || t26.o(8) || '.jpg'), '42501', '%row-level security%',
               'S9 a nested folder is refused');
select t26.err(t26.up_sql('avatars', t26.o(9) || '.jpg'), '42501', '%row-level security%',
               'S10 a name without a folder is refused');
select t26.err(t26.up_sql('avatars', upper(t26.p(5)::text) || '/' || t26.o(10) || '.jpg'), '42501', '%row-level security%',
               'S11 the own folder in upper case is refused');
select t26.err(t26.up_sql('t26-other', t26.path(t26.p(5), 11)), '42501', '%row-level security%',
               'S12 no upload into another bucket');
select t26.err(t26.up_sql('club-logos', t26.path(t26.p(5), 12, 'png')), '42501', '%row-level security%',
               'S13 a user''s own id is no club-logos folder');

select t26.as_user(t26.p(1));
select t26.okq(t26.up_sql('club-logos', t26.path(t26.club('M5 Lions'), 20, 'png')), 'S14 an owner uploads club-logos/<own club>/<uuid>.png');
select t26.okq(t26.up_sql('club-logos', t26.path(t26.club('M5 Lions'), 21)), 'S15 … a second one (.jpg)');
select t26.err(t26.up_sql('club-logos', t26.path(t26.club('M5 Kings'), 22, 'png')), '42501', '%row-level security%',
               'S16 an upload for someone else''s club is refused');
select t26.err(t26.up_sql('club-logos', 'not-a-uuid/' || t26.o(23) || '.png'), '42501', '%row-level security%',
               'S17 a malformed club folder is refused (not a cast error)');
select t26.err(t26.up_sql('club-logos', t26.path(t26.club('M5 Lions'), 24, 'svg')), '42501', '%row-level security%',
               'S18 a club logo as .svg is refused');
select t26.err(t26.up_sql('club-logos', t26.path('ee910000-0000-4000-8000-00000000ffff'::uuid, 25, 'png')), '42501',
               '%row-level security%', 'S19 an unknown club folder is refused');
select t26.okq(t26.up_sql('avatars', t26.path(t26.p(1), 26)), 'S20 the owner uploads their own avatar');

select t26.as_user(t26.p(3));
select t26.err(t26.up_sql('club-logos', t26.path(t26.club('M5 Lions'), 30, 'png')), '42501', '%row-level security%',
               'S21 a member (not the owner) cannot upload the club logo');
select t26.okq(t26.up_sql('avatars', t26.path(t26.p(3), 31, 'webp')), 'S22 the member uploads their own avatar');
select t26.ok(t26.objects_seen('avatars', t26.p(5)::text || '/%') = 4 and t26.objects_seen('club-logos', t26.club('M5 Lions')::text || '/%') = 2
              and t26.objects_seen('club-logos', t26.p(5)::text || '/%') = 1,
              'S23 any signed-in user reads both buckets (4 avatars of person 5, 2 Lions logos, 1 server-made logo object)');
select t26.ok(not exists (select 1 from storage.objects o where o.bucket_id = 't26-other'),
              'S24 other buckets stay unreadable');
select t26.ok(t26.affected(format('update storage.objects set metadata = %L where bucket_id = %L and name = %L',
                                  '{}', 'avatars', t26.path(t26.p(5), 1))) = 0,
              'S25 another user''s avatar cannot be updated (0 rows)');
select t26.ok(t26.affected(format('delete from storage.objects where bucket_id = %L and name = %L',
                                  'avatars', t26.path(t26.p(5), 1))) = 0,
              'S26 another user''s avatar cannot be deleted (0 rows)');
select t26.ok(t26.affected(format('delete from storage.objects where bucket_id = %L and name = %L',
                                  'club-logos', t26.path(t26.club('M5 Lions'), 20, 'png'))) = 0,
              'S27 a member cannot delete the club logo (0 rows)');

select t26.as_user(t26.p(2));
select t26.ok(t26.affected(format('update storage.objects set metadata = %L where bucket_id = %L and name = %L',
                                  '{}', 'club-logos', t26.path(t26.club('M5 Lions'), 20, 'png'))) = 0,
              'S28 another club''s owner cannot update its logo (0 rows)');

select t26.as_user(t26.p(5));
select t26.err(format('update storage.objects set name = %L where bucket_id = %L and name = %L',
                      t26.path(t26.p(1), 40), 'avatars', t26.path(t26.p(5), 2, 'jpeg')),
               '42501', '%row-level security%', 'S29 moving an own avatar into another folder is refused');
select t26.err(format('update storage.objects set name = %L where bucket_id = %L and name = %L',
                      t26.path(t26.p(5), 41, 'exe'), 'avatars', t26.path(t26.p(5), 2, 'jpeg')),
               '42501', '%row-level security%', 'S30 renaming an own avatar to another extension is refused');
select t26.ok(t26.affected(format('update storage.objects set metadata = %L where bucket_id = %L and name = %L',
                                  '{"mimetype": "image/jpeg", "size": 2000}', 'avatars', t26.path(t26.p(5), 1))) = 1,
              'S31 a user updates (upserts) their own avatar');
select t26.ok(t26.affected(format('delete from storage.objects where bucket_id = %L and name = %L',
                                  'avatars', t26.path(t26.p(5), 4, 'webp'))) = 1,
              'S32 a user deletes their own avatar');
select t26.as_user(t26.p(1));
select t26.ok(t26.affected(format('delete from storage.objects where bucket_id = %L and name = %L',
                                  'club-logos', t26.path(t26.club('M5 Lions'), 21))) = 1,
              'S33 the owner deletes a club logo');

set local role anon;
select t26.as_nobody();
select t26.ok(t26.objects_seen(null, '%') = 0, 'S34 anon reads no object');
select t26.err(t26.up_sql('avatars', t26.path(t26.p(5), 50)), '42501', '%row-level security%', 'S35 anon cannot upload');

-- ---------------------------------------------------------------------------
-- R. set_my_avatar
-- ---------------------------------------------------------------------------
select t26.err(format('select public.set_my_avatar(%L)', t26.path(t26.p(5), 1)), '42501', 'permission denied%',
               'R1 anon cannot call set_my_avatar');
set local role authenticated;
select t26.err(format('select public.set_my_avatar(%L)', t26.path(t26.p(5), 1)), '42501', 'media: not authenticated',
               'R2 no signed-in user → media: not authenticated');
select t26.as_user(t26.p(5));
select t26.err($q$select public.set_my_avatar('nonsense')$q$, '22023', 'media: invalid path', 'R3 a malformed path → 22023');
select t26.err(format('select public.set_my_avatar(%L)', t26.path(t26.p(5), 1, 'gif')), '22023', 'media: invalid path',
               'R4 a .gif path → 22023');
select t26.err(format('select public.set_my_avatar(%L)', t26.path(t26.p(5), 1, 'JPG')), '22023', 'media: invalid path',
               'R5 an upper-case extension → 22023');
select t26.err(format('select public.set_my_avatar(%L)', ' ' || t26.path(t26.p(5), 1)), '22023', 'media: invalid path',
               'R6 a path with a leading space → 22023');
select t26.err(format('select public.set_my_avatar(%L)', t26.path(t26.p(1), 26)), '42501', 'media: not allowed',
               'R7 someone else''s (existing) avatar → 42501');
select t26.err(format('select public.set_my_avatar(%L)', t26.path(t26.p(5), 60)), '22023', 'media: file not found',
               'R8 an own path that was never uploaded → 22023');
select t26.err(format('select public.set_my_avatar(%L)', t26.path(t26.p(5), 91)), '22023', 'media: file not found',
               'R9 a name that exists only in another bucket → 22023');
select t26.err(format('select public.set_my_avatar(%L)', t26.path(t26.p(5), 4, 'webp')), '22023', 'media: file not found',
               'R10 a deleted avatar → 22023');
select t26.okq(format('select public.set_my_avatar(%L)', t26.path(t26.p(5), 1)), 'R11 set_my_avatar with an uploaded own avatar');
select t26.ok((select avatar_path from public.profiles where id = t26.p(5)) = t26.path(t26.p(5), 1),
              'R12 the own profile row shows avatar_path');
select t26.okq($q$select public.set_my_avatar(null)$q$, 'R13 set_my_avatar(null)');
select t26.ok((select avatar_path from public.profiles where id = t26.p(5)) is null, 'R14 … removes it from the profile');
select t26.ok(t26.objects_seen('avatars', t26.path(t26.p(5), 1)) = 1, 'R15 … and leaves the file (the app deletes it through Storage)');
select t26.okq(format('select public.set_my_avatar(%L)', t26.path(t26.p(5), 3, 'png')), 'R16 set_my_avatar (.png) again');
select t26.as_user(t26.p(9));
select t26.err(format('select public.set_my_avatar(%L)', t26.path(t26.p(9), 61)), '22023', 'media: file not found',
               'R17 without a profile row: the file check comes first');
select t26.err($q$select public.set_my_avatar(null)$q$, 'P0002', 'media: profile not found',
               'R18 without a profile row → P0002 media: profile not found');

-- ---------------------------------------------------------------------------
-- C. set_club_logo
-- ---------------------------------------------------------------------------
select t26.as_nobody();
select t26.err(format('select public.set_club_logo(%L, %L)', t26.club('M5 Lions'), t26.path(t26.club('M5 Lions'), 20, 'png')),
               '42501', 'media: not authenticated', 'C1 no signed-in user → media: not authenticated');
select t26.as_user(t26.p(3));
select t26.err(format('select public.set_club_logo(%L, %L)', t26.club('M5 Lions'), t26.path(t26.club('M5 Lions'), 20, 'png')),
               '42501', 'media: not allowed', 'C2 a member (not the owner) → 42501');
select t26.as_user(t26.p(1));
select t26.err(format('select public.set_club_logo(%L, %L)', t26.club('M5 Kings'), null), '42501', 'media: not allowed',
               'C3 someone else''s club → 42501');
select t26.err(format('select public.set_club_logo(%L, %L)', 'ee910000-0000-4000-8000-00000000ffff', null), '42501',
               'media: not allowed', 'C4 an unknown club → 42501 (looks like someone else''s)');
select t26.err($q$select public.set_club_logo(null, null)$q$, '42501', 'media: not allowed', 'C5 a NULL club → 42501');
select t26.err(format('select public.set_club_logo(%L, %L)', t26.club('M5 Lions'), t26.path(t26.club('M5 Kings'), 20, 'png')),
               '42501', 'media: not allowed', 'C6 a path in another club''s folder → 42501');
select t26.err(format('select public.set_club_logo(%L, %L)', t26.club('M5 Lions'), 'logo.png'), '22023', 'media: invalid path',
               'C7 a malformed path → 22023');
select t26.err(format('select public.set_club_logo(%L, %L)', t26.club('M5 Lions'), t26.path(t26.club('M5 Lions'), 20, 'svg')),
               '22023', 'media: invalid path', 'C8 an .svg path → 22023');
select t26.err(format('select public.set_club_logo(%L, %L)', t26.club('M5 Lions'), t26.path(t26.club('M5 Lions'), 70, 'png')),
               '22023', 'media: file not found', 'C9 a path never uploaded → 22023');
select t26.err(format('select public.set_club_logo(%L, %L)', t26.club('M5 Lions'), t26.path(t26.club('M5 Lions'), 92, 'png')),
               '22023', 'media: file not found', 'C10 a name that exists only in the avatars bucket → 22023');
select t26.err(format('select public.set_club_logo(%L, %L)', t26.club('M5 Lions'), t26.path(t26.club('M5 Lions'), 21)),
               '22023', 'media: file not found', 'C11 a deleted logo → 22023');
select t26.okq(format('select public.set_club_logo(%L, %L)', t26.club('M5 Lions'), t26.path(t26.club('M5 Lions'), 20, 'png')),
               'C12 set_club_logo with an uploaded logo');
select t26.ok((select logo_path from public.clubs where id = t26.club('M5 Lions')) = t26.path(t26.club('M5 Lions'), 20, 'png'),
              'C13 the own club row shows logo_path');
select t26.okq(format('select public.set_club_logo(%L, null)', t26.club('M5 Lions')), 'C14 set_club_logo(club, null)');
select t26.ok((select logo_path from public.clubs where id = t26.club('M5 Lions')) is null, 'C15 … removes it');
select t26.okq(format('select public.set_club_logo(%L, %L)', t26.club('M5 Lions'), t26.path(t26.club('M5 Lions'), 20, 'png')),
               'C16 set_club_logo again');

-- ---------------------------------------------------------------------------
-- D. Direct writes of the paths are refused; the preferences are not
-- ---------------------------------------------------------------------------
select t26.as_user(t26.p(5));
select t26.err(format('update public.profiles set avatar_path = %L where id = auth.uid()', t26.path(t26.p(5), 1)),
               '42501', 'media: avatar_path is set through set_my_avatar', 'D1 a direct update of avatar_path is refused');
select t26.err('update public.profiles set avatar_path = null where id = auth.uid()',
               '42501', 'media: avatar_path is set through set_my_avatar', 'D2 a direct clear of avatar_path is refused');
select t26.okq($q$update public.profiles set full_name = 'M5 Person Five' where id = auth.uid()$q$,
               'D3 other profile columns stay directly editable');
select t26.okq('update public.profiles set avatar_path = avatar_path where id = auth.uid()',
               'D4 an update that leaves avatar_path as it is passes');
select t26.ok((select avatar_path from public.profiles where id = t26.p(5)) = t26.path(t26.p(5), 3, 'png'),
              'D5 avatar_path unchanged by D1–D4');
select t26.as_user(t26.p(9));
select t26.err(format('insert into public.profiles (id, avatar_path) values (auth.uid(), %L)', t26.path(t26.p(9), 62)),
               '42501', 'media: avatar_path is set through set_my_avatar', 'D6 an insert with avatar_path is refused');
select t26.okq('insert into public.profiles (id) values (auth.uid())', 'D7 a plain own-profile insert still works');
select t26.as_user(t26.p(1));
select t26.err(format('update public.clubs set logo_path = null where id = %L', t26.club('M5 Lions')),
               '42501', 'permission denied%', 'D8 a direct update of clubs.logo_path is refused');
select t26.err(format('insert into public.clubs (owner_id, name, city, club_type, logo_path) values (auth.uid(), %L, %L, %L, %L)',
                      'M5 Other', 'Lahore', 'corporate', t26.path(t26.p(1), 63)),
               '42501', 'permission denied%', 'D9 an insert with clubs.logo_path is refused');
select t26.okq(format('update public.clubs set short_name = %L where id = %L', 'ML', t26.club('M5 Lions')),
               'D10 the owner still edits the club''s other columns');
select t26.as_user(t26.p(5));
select t26.okq('update public.profiles set public_profile = false, show_stats = false where id = auth.uid()',
               'D11 the preferences are directly editable on the own row');
select t26.err('update public.profiles set show_stats = null where id = auth.uid()', '23502', '%show_stats%',
               'D12 … but never NULL');
select t26.okq('update public.profiles set public_profile = true, show_stats = true where id = auth.uid()', 'D13 … reset');
reset role;
select t26.err(format('update public.profiles set avatar_path = %L where id = %L', t26.path(t26.p(1), 26), t26.p(5)),
               '23514', '%profiles_avatar_path_check%', 'D14 even the server cannot store a path in another user''s folder');
select t26.err(format('update public.clubs set logo_path = %L where id = %L', t26.path(t26.club('M5 Kings'), 20, 'png'), t26.club('M5 Lions')),
               '23514', '%clubs_logo_path_check%', 'D15 … nor a logo path in another club''s folder');
select t26.err(format('update public.profiles set avatar_path = %L where id = %L', t26.path(t26.p(5), 1, 'gif'), t26.p(5)),
               '23514', '%profiles_avatar_path_check%', 'D16 … nor another extension');

-- ---------------------------------------------------------------------------
-- V. Visibility preferences
-- ---------------------------------------------------------------------------
set local role authenticated;
select t26.as_user(t26.p(3));
select t26.ok((select count(*) = 1 and bool_and(s.public_profile and s.show_stats) from public.my_profile_visibility() s),
              'V1 my_profile_visibility: one row, defaults (public profile, stats shown)');
select t26.ok(public.my_privacy_settings() = false, 'V2 my_privacy_settings still returns the boolean phone consent (false)');
select t26.okq('select public.set_profile_visibility(false, null)', 'V3 set_profile_visibility(false, null)');
select t26.ok((select (s.public_profile, s.show_stats)::text from public.my_profile_visibility() s) = '(f,t)',
              'V4 … hides the profile, keeps the stats setting');
select t26.okq('select public.set_profile_visibility(null, false)', 'V5 set_profile_visibility(null, false)');
select t26.ok((select (s.public_profile, s.show_stats)::text from public.my_profile_visibility() s) = '(f,f)',
              'V6 … hides the stats, keeps the profile setting');
select t26.okq('select public.set_profile_visibility(null, null)', 'V7 set_profile_visibility(null, null)');
select t26.ok((select (public_profile, show_stats)::text from public.profiles where id = t26.p(3)) = '(f,f)',
              'V8 … changes nothing (the own row shows them too)');
select t26.ok((select count(*) from public.profiles where id = t26.p(5)) = 0, 'V9 other rows stay unreadable');
select t26.okq('select public.set_phone_sharing(true)', 'V10 set_phone_sharing(true)');
select t26.ok(public.my_privacy_settings() = true
              and (select (s.public_profile, s.show_stats)::text from public.my_profile_visibility() s) = '(f,f)',
              'V11 my_privacy_settings reads the consent, my_profile_visibility the two preferences');
select t26.okq('select public.set_profile_visibility(true, true)', 'V12 set_profile_visibility(true, true)');
reset role;
select t26.ok((select (public_profile, show_stats)::text from public.profiles where id = t26.p(5)) = '(t,t)'
              and (select (public_profile, show_stats)::text from public.profiles where id = t26.p(3)) = '(t,t)',
              'V13 only the caller''s row is changed');
set local role authenticated;
select t26.as_nobody();
select t26.err('select public.set_profile_visibility(false, false)', '42501', 'privacy: not authenticated',
               'V14 no signed-in user → privacy: not authenticated');
select t26.err('select * from public.my_profile_visibility()', '42501', 'privacy: not authenticated',
               'V15 my_profile_visibility without a user → 42501');
select t26.as_user('ee910000-0000-4000-8000-00000000fffe'::uuid);
select t26.err('select public.set_profile_visibility(false, false)', 'P0002', 'privacy: profile not found',
               'V16 set_profile_visibility without a profile row → P0002');
select t26.err('select * from public.my_profile_visibility()', 'P0002', 'privacy: profile not found',
               'V17 my_profile_visibility without a profile row → P0002');
set local role anon;
select t26.err('select public.set_profile_visibility(false, false)', '42501', 'permission denied%',
               'V18 anon cannot call set_profile_visibility');
select t26.err('select * from public.my_profile_visibility()', '42501', 'permission denied%',
               'V19 anon cannot call my_profile_visibility');

-- ---------------------------------------------------------------------------
-- E. The extra columns in the club views
-- ---------------------------------------------------------------------------
set local role authenticated;
select t26.as_user(t26.p(3));
select t26.okq(format('select public.set_my_avatar(%L)', t26.path(t26.p(3), 31, 'webp')), 'E1 the member sets an avatar');
select t26.as_user(t26.p(4));
select t26.okq(t26.up_sql('avatars', t26.path(t26.p(4), 32, 'jpeg')), 'E2 the applicant uploads an avatar');
select t26.okq(format('select public.set_my_avatar(%L)', t26.path(t26.p(4), 32, 'jpeg')), 'E3 … and sets it');
select t26.as_user(t26.p(1));
select t26.ok((select m.avatar_path from public.club_member_list(t26.club('M5 Lions')) m where m.user_id = t26.p(3))
                = t26.path(t26.p(3), 31, 'webp')
              and (select m.avatar_path from public.club_member_list(t26.club('M5 Lions')) m where m.user_id = t26.p(1)) is null,
              'E4 club_member_list returns each member''s avatar_path');
select t26.ok((select m.phone from public.club_member_list(t26.club('M5 Lions')) m where m.user_id = t26.p(3)) is not null
              and (select count(*) from public.club_member_list(t26.club('M5 Lions'))) = 2,
              'E5 … and is otherwise unchanged (2 members; phone shown with consent from V9)');
select t26.ok((select r.avatar_path from public.club_join_requests(t26.club('M5 Lions')) r where r.full_name = 'M5 Person 4')
                = t26.path(t26.p(4), 32, 'jpeg')
              and (select r.phone from public.club_join_requests(t26.club('M5 Lions')) r where r.full_name = 'M5 Person 4') is null,
              'E6 club_join_requests returns the applicant''s avatar_path (phone still only with consent)');
select t26.ok(not exists (select 1 from public.club_join_requests(t26.club('M5 Lions')) r where r.full_name = 'M5 Person 6'),
              'E7 club_join_requests keeps the 30-day rule of migration 30');
select t26.err(format('select * from public.club_member_list(%L)', t26.club('M5 Kings')), '42501', 'club_join: not allowed',
               'E8 club_member_list still only for the owner');
select t26.as_user(t26.p(3));
select t26.ok((select m.club_logo_path from public.my_club_memberships() m where m.club_id = t26.club('M5 Lions'))
                = t26.path(t26.club('M5 Lions'), 20, 'png'),
              'E9 my_club_memberships returns the club''s logo path');
reset role;
select t26.ok(pg_get_function_result('public.club_member_list(uuid)'::regprocedure) =
                'TABLE(member_id uuid, user_id uuid, member_role text, joined_at timestamp with time zone, full_name text, phone text, player_role text, batting_style text, bowling_style text, is_wicketkeeper boolean, avatar_path text)'
              and pg_get_function_result('public.club_join_requests(uuid)'::regprocedure) =
                'TABLE(request_id uuid, status text, message text, assigned_role text, decline_reason text, created_at timestamp with time zone, decided_at timestamp with time zone, full_name text, phone text, applicant_age integer, city text, player_role text, batting_style text, bowling_style text, is_wicketkeeper boolean, avatar_path text)'
              and pg_get_function_result('public.my_club_memberships()'::regprocedure) =
                'TABLE(member_id uuid, club_id uuid, club_name text, club_code text, city text, member_role text, joined_at timestamp with time zone, club_logo_path text)'
              and pg_get_function_result('public.my_profile_visibility()'::regprocedure) =
                'TABLE(public_profile boolean, show_stats boolean)'
              and pg_get_function_result('public.my_privacy_settings()'::regprocedure) = 'boolean'
              and (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p
                    where p.oid = 'public.my_privacy_settings()'::regprocedure) = '6505982ba6501ccc6e846d5badf430ce',
              'E10 result columns: the old ones in order, the new one last; my_privacy_settings untouched (boolean, migration 13 body)');

-- ---------------------------------------------------------------------------
-- G. Grants
-- ---------------------------------------------------------------------------
select t26.ok((select bool_and(has_function_privilege('authenticated', f, 'execute') and not has_function_privilege('anon', f, 'execute'))
                from unnest(array['public.set_my_avatar(text)', 'public.set_club_logo(uuid, text)',
                                  'public.set_profile_visibility(boolean, boolean)', 'public.my_profile_visibility()',
                                  'public.club_member_list(uuid)', 'public.club_join_requests(uuid)',
                                  'public.my_club_memberships()']::regprocedure[]) f),
              'G1 the seven functions: authenticated yes, anon no');
select t26.ok(not has_function_privilege('authenticated', 'public.profiles_guard_avatar_path()', 'execute')
              and not has_column_privilege('authenticated', 'public.clubs', 'logo_path', 'UPDATE')
              and not has_column_privilege('authenticated', 'public.clubs', 'logo_path', 'INSERT')
              and has_column_privilege('authenticated', 'public.clubs', 'logo_path', 'SELECT'),
              'G2 the guard function is closed; clubs.logo_path is read-only for authenticated');

-- ---------------------------------------------------------------------------
-- K. Account deletion leaves the files (documented: the app / a job removes them)
-- ---------------------------------------------------------------------------
delete from auth.users where id = t26.p(5);
select t26.ok(not exists (select 1 from public.profiles where id = t26.p(5))
              and (select count(*) from storage.objects o where o.bucket_id = 'avatars' and o.name like t26.p(5)::text || '/%') = 3,
              'K1 deleting an account removes the profile but not avatars/<uid>/ (3 files stay)');

rollback;
\echo 'local check 26: all checks passed; everything rolled back'
