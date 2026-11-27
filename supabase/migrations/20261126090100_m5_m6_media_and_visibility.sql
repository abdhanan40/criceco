-- CricEco · migration 31 · M5 media uploads (avatars, club logos) and
-- M6 privacy visibility
--
-- NOT APPLIED. Requires migrations 1–30 and Supabase Storage (storage.buckets,
-- storage.objects, storage.foldername). Review first; apply only with
-- separate approval, after a fresh backup, inside
--   begin; set local lock_timeout = '5s'; <this file> commit;
-- Rollback: supabase/rollback/20261126_rollback_m5_m6_media_and_visibility.sql.
-- Read-only check: supabase/tests/31_m5_m6_media_postcheck.sql.
-- Local test: supabase/tests/local/26_m5_m6_media_local_check.sql (+ .sh).
-- Design: docs/M5_M6_MEDIA_AND_VISIBILITY.md.
--
-- What changes (one transaction):
--   1. Storage buckets "avatars" and "club-logos": private (public = false),
--      2 MiB, image/jpeg, image/png, image/webp. Inserted only when missing;
--      an existing bucket of that id must already have exactly this
--      configuration (the self-check refuses otherwise).
--   2. storage.objects policies, for signed-in users only:
--        * read: any object in the two buckets;
--        * write (insert / update / delete): "avatars/<auth.uid()>/<uuid>.<ext>"
--          and "club-logos/<club id the caller owns>/<uuid>.<ext>", where
--          <uuid> is a lowercase UUID and <ext> jpg | jpeg | png | webp.
--          Any other name is refused.
--   3. profiles.avatar_path and clubs.logo_path (text, NULL = none), each
--      checked to be a path of that shape in the row's own folder. Not
--      writable by the app directly: clubs has no column grant for it;
--      profiles (table-wide grants since migration 10) refuses a change made
--      as anon / authenticated (trigger profiles_guard_avatar_path). They are
--      set through set_my_avatar(p_path) / set_club_logo(p_club_id, p_path),
--      which also require the object to exist in its bucket.
--   4. profiles.public_profile and profiles.show_stats (boolean, NOT NULL,
--      default true), the user's own preferences: through
--      set_profile_visibility(p_public_profile, p_show_stats) or the existing
--      own-row update; read through the new my_profile_visibility() (one
--      row). my_privacy_settings() (migration 13, a boolean the installed app
--      reads) is NOT touched.
--   5. club_member_list and club_join_requests return avatar_path,
--      my_club_memberships returns club_logo_path (each as the LAST column;
--      bodies otherwise unchanged from migrations 13 / 30 / 11).
-- No row is changed or deleted. Storage objects are never deleted here (nor
-- by delete_account_data: the app or a later job removes avatars/<uid>/).

do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'public'
                and ((table_name = 'profiles' and column_name in ('avatar_path', 'public_profile', 'show_stats'))
                     or (table_name = 'clubs' and column_name = 'logo_path')))
     or to_regprocedure('public.set_my_avatar(text)') is not null
     or to_regprocedure('public.set_club_logo(uuid, text)') is not null
     or to_regprocedure('public.set_profile_visibility(boolean, boolean)') is not null
     or to_regprocedure('public.my_profile_visibility()') is not null
     or to_regprocedure('public.profiles_guard_avatar_path()') is not null
     or exists (select 1 from pg_policy where polname like 'criceco media:%' or polname like 'criceco avatars:%'
                   or polname like 'criceco club logos:%') then
    raise exception 'migration 31: already applied (or a name is taken) — nothing changed';
  end if;
  if to_regclass('public.push_token_moves') is null
     or to_regprocedure('public.save_team(uuid, text, text, integer, uuid, uuid, jsonb, integer)') is null
     or to_regprocedure('public.club_member_list(uuid)') is null
     or to_regprocedure('public.club_join_requests(uuid)') is null
     or to_regprocedure('public.my_club_memberships()') is null
     or to_regprocedure('public.is_club_owner(uuid)') is null then
    raise exception 'migration 31: migrations 1–30 are required';
  end if;
  if to_regclass('storage.buckets') is null or to_regclass('storage.objects') is null
     or to_regprocedure('storage.foldername(text)') is null
     or (select count(*) from information_schema.columns
          where table_schema = 'storage' and table_name = 'buckets'
            and column_name in ('id', 'name', 'public', 'file_size_limit', 'allowed_mime_types')) <> 5
     or (select count(*) from information_schema.columns
          where table_schema = 'storage' and table_name = 'objects' and column_name in ('bucket_id', 'name')) <> 2 then
    raise exception 'migration 31: Supabase Storage (storage.buckets / objects / foldername) is required';
  end if;
  -- set_my_avatar / set_club_logo (SECURITY DEFINER, owned by this role) look
  -- the uploaded object up in storage.objects, whose RLS has no policy for
  -- this role: it must bypass RLS and may read the table.
  if not (select r.rolsuper or r.rolbypassrls from pg_roles r where r.rolname = current_user)
     or not has_table_privilege(current_user, 'storage.objects', 'SELECT')
     or not has_table_privilege(current_user, 'storage.buckets', 'SELECT')
     or not has_table_privilege(current_user, 'storage.buckets', 'INSERT') then
    raise exception 'migration 31: % must bypass RLS and read storage.objects / write storage.buckets', current_user;
  end if;
  -- The functions replaced or used must be exactly those of migrations 11,
  -- 13 and 30 (the rollback restores the three replaced ones verbatim; the
  -- policies use is_club_owner). Line endings ignored.
  if (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p
       where p.oid = 'public.club_member_list(uuid)'::regprocedure) <> 'ac91f13f856dabdc03617a845883ff46'
     or (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p
          where p.oid = 'public.club_join_requests(uuid)'::regprocedure) <> '9ef95a33568e101f91b24d95a0d72f0f'
     or (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p
          where p.oid = 'public.my_club_memberships()'::regprocedure) <> 'eaecaca4655a66c5187640803ad5208c'
     or (select md5(replace(p.prosrc, chr(13), '')) || p.prosecdef::text from pg_proc p
          where p.oid = 'public.is_club_owner(uuid)'::regprocedure) <> 'f9100b85bcfaa52aac0aa03f292b14fbtrue' then
    raise exception 'migration 31: a function to replace or use differs from its migration (11 / 13 / 30) — nothing changed';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Buckets (private; the app reads through signed / authenticated URLs)
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', false, 2097152, array['image/jpeg', 'image/png', 'image/webp']),
       ('club-logos', 'club-logos', false, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- 2. storage.objects policies (signed-in users only; anon gets nothing)
-- ---------------------------------------------------------------------------
-- The name is exactly "<folder>/<lowercase uuid>.<jpg|jpeg|png|webp>" with a
-- lowercase UUID as the folder; the folder is checked with
-- storage.foldername. For club logos the folder is cast to uuid only after
-- the shape matched (CASE), so a malformed name is refused, not an error.
create policy "criceco media: read avatars and club logos"
  on storage.objects for select to authenticated
  using (bucket_id in ('avatars', 'club-logos'));

create policy "criceco avatars: insert in own folder"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars'
              and name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|jpeg|png|webp)$'
              and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "criceco avatars: update in own folder"
  on storage.objects for update to authenticated
  using (bucket_id = 'avatars'
         and name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|jpeg|png|webp)$'
         and (storage.foldername(name))[1] = (select auth.uid())::text)
  with check (bucket_id = 'avatars'
              and name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|jpeg|png|webp)$'
              and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "criceco avatars: delete in own folder"
  on storage.objects for delete to authenticated
  using (bucket_id = 'avatars'
         and name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|jpeg|png|webp)$'
         and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "criceco club logos: insert for own club"
  on storage.objects for insert to authenticated
  with check (case when bucket_id = 'club-logos'
                        and name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|jpeg|png|webp)$'
                   then public.is_club_owner(((storage.foldername(name))[1])::uuid)
                   else false end);

create policy "criceco club logos: update for own club"
  on storage.objects for update to authenticated
  using (case when bucket_id = 'club-logos'
                   and name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|jpeg|png|webp)$'
              then public.is_club_owner(((storage.foldername(name))[1])::uuid)
              else false end)
  with check (case when bucket_id = 'club-logos'
                        and name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|jpeg|png|webp)$'
                   then public.is_club_owner(((storage.foldername(name))[1])::uuid)
                   else false end);

create policy "criceco club logos: delete for own club"
  on storage.objects for delete to authenticated
  using (case when bucket_id = 'club-logos'
                   and name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|jpeg|png|webp)$'
              then public.is_club_owner(((storage.foldername(name))[1])::uuid)
              else false end);

-- ---------------------------------------------------------------------------
-- 3. The paths (set only through the two functions below)
-- ---------------------------------------------------------------------------
alter table public.profiles
  add column avatar_path text
    constraint profiles_avatar_path_check
    check (avatar_path is null
           or (avatar_path ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|jpeg|png|webp)$'
               and split_part(avatar_path, '/', 1) = id::text));

alter table public.clubs
  add column logo_path text
    constraint clubs_logo_path_check
    check (logo_path is null
           or (logo_path ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|jpeg|png|webp)$'
               and split_part(logo_path, '/', 1) = id::text));

comment on column public.profiles.avatar_path is
  'Migration 31: object name in Storage bucket "avatars" ("<user id>/<uuid>.<jpg|jpeg|png|webp>"), NULL = none. Set only through set_my_avatar.';
comment on column public.clubs.logo_path is
  'Migration 31: object name in Storage bucket "club-logos" ("<club id>/<uuid>.<jpg|jpeg|png|webp>"), NULL = none. Set only through set_club_logo.';

-- clubs uses column grants (migration 5): logo_path has none for the API
-- roles. Stated explicitly (a no-op when nothing was granted).
revoke insert (logo_path), update (logo_path) on table public.clubs from public, anon, authenticated;

-- profiles has table-wide INSERT / UPDATE for authenticated (migration 10),
-- so a trigger refuses avatar_path changes made as the API roles. Inside
-- set_my_avatar (SECURITY DEFINER) current_user is the function's owner.
create function public.profiles_guard_avatar_path()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user in ('anon', 'authenticated')
     and ((tg_op = 'INSERT' and new.avatar_path is not null)
          or (tg_op = 'UPDATE' and new.avatar_path is distinct from old.avatar_path)) then
    raise exception 'media: avatar_path is set through set_my_avatar' using errcode = '42501';
  end if;
  return new;
end;
$$;

revoke execute on function public.profiles_guard_avatar_path() from public, anon, authenticated;

create trigger profiles_guard_avatar_path
  before insert or update of avatar_path on public.profiles
  for each row execute function public.profiles_guard_avatar_path();

-- The caller's avatar: p_path = "<auth.uid()>/<uuid>.<ext>" of an object
-- already uploaded to "avatars", or NULL to remove it from the profile (the
-- file itself is deleted by the app through Storage).
create function public.set_my_avatar(p_path text)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'media: not authenticated' using errcode = '42501';
  end if;
  if p_path is not null then
    if p_path !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|jpeg|png|webp)$' then
      raise exception 'media: invalid path' using errcode = '22023';
    end if;
    if split_part(p_path, '/', 1) <> v_uid::text then
      raise exception 'media: not allowed' using errcode = '42501';
    end if;
    if not exists (select 1 from storage.objects o where o.bucket_id = 'avatars' and o.name = p_path) then
      raise exception 'media: file not found' using errcode = '22023';
    end if;
  end if;
  update public.profiles set avatar_path = p_path where id = v_uid;
  if not found then
    raise exception 'media: profile not found' using errcode = 'P0002';
  end if;
end;
$$;

-- A club's logo, by its owner: p_path = "<p_club_id>/<uuid>.<ext>" of an
-- object already uploaded to "club-logos", or NULL to remove it. An unknown
-- club and someone else's club look the same (not allowed).
create function public.set_club_logo(p_club_id uuid, p_path text)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'media: not authenticated' using errcode = '42501';
  end if;
  perform 1 from public.clubs c where c.id = p_club_id and c.owner_id = v_uid for update;
  if not found then
    raise exception 'media: not allowed' using errcode = '42501';
  end if;
  if p_path is not null then
    if p_path !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|jpeg|png|webp)$' then
      raise exception 'media: invalid path' using errcode = '22023';
    end if;
    if split_part(p_path, '/', 1) <> p_club_id::text then
      raise exception 'media: not allowed' using errcode = '42501';
    end if;
    if not exists (select 1 from storage.objects o where o.bucket_id = 'club-logos' and o.name = p_path) then
      raise exception 'media: file not found' using errcode = '22023';
    end if;
  end if;
  update public.clubs set logo_path = p_path where id = p_club_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Visibility preferences (the user's own)
-- ---------------------------------------------------------------------------
alter table public.profiles
  add column public_profile boolean not null default true,
  add column show_stats boolean not null default true;

comment on column public.profiles.public_profile is
  'Migration 31: the user lets other players see their profile. Default true. Own row only.';
comment on column public.profiles.show_stats is
  'Migration 31: the user lets other players see their statistics. Default true. Own row only.';

-- NULL = leave unchanged.
create function public.set_profile_visibility(p_public_profile boolean, p_show_stats boolean)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'privacy: not authenticated' using errcode = '42501';
  end if;
  update public.profiles
     set public_profile = coalesce(p_public_profile, public_profile),
         show_stats = coalesce(p_show_stats, show_stats)
   where id = auth.uid();
  if not found then
    raise exception 'privacy: profile not found' using errcode = 'P0002';
  end if;
end;
$$;

-- The caller's two visibility preferences: one row. (my_privacy_settings of
-- migration 13 stays as it is: installed app builds read it as a boolean.)
create function public.my_profile_visibility()
returns table (
  public_profile boolean,
  show_stats     boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'privacy: not authenticated' using errcode = '42501';
  end if;
  return query
    select p.public_profile, p.show_stats from public.profiles p where p.id = auth.uid();
  if not found then
    raise exception 'privacy: profile not found' using errcode = 'P0002';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. The extra column in the club views (a new result type: drop + create)
-- ---------------------------------------------------------------------------
drop function public.club_member_list(uuid);
drop function public.club_join_requests(uuid);
drop function public.my_club_memberships();

-- The owner's view of their club's active members (migration 13) + avatar_path.
create function public.club_member_list(p_club_id uuid)
returns table (
  member_id       uuid,
  user_id         uuid,
  member_role     text,
  joined_at       timestamptz,
  full_name       text,
  phone           text,
  player_role     text,
  batting_style   text,
  bowling_style   text,
  is_wicketkeeper boolean,
  avatar_path     text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'club_join: not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.clubs c where c.id = p_club_id and c.owner_id = auth.uid()) then
    raise exception 'club_join: not allowed' using errcode = '42501';
  end if;
  return query
    select m.id, m.user_id, m.member_role, m.joined_at, p.full_name,
           -- Migration 13: only with the member's consent (the owner's own row always).
           case when p.share_phone_with_clubs or m.user_id = (select auth.uid()) then p.phone end,
           pp.player_role, pp.batting_style, pp.bowling_style, coalesce(pp.is_wicketkeeper, false),
           p.avatar_path
      from public.club_members m
      join public.profiles p on p.id = m.user_id
      left join public.player_profiles pp on pp.user_id = m.user_id
     where m.club_id = p_club_id
       and m.status = 'active'
     order by (m.member_role = 'owner') desc, m.joined_at;
end;
$$;

-- The owner's view of their club's requests (migration 30) + avatar_path.
create function public.club_join_requests(p_club_id uuid)
returns table (
  request_id      uuid,
  status          text,
  message         text,
  assigned_role   text,
  decline_reason  text,
  created_at      timestamptz,
  decided_at      timestamptz,
  full_name       text,
  phone           text,
  applicant_age   integer,
  city            text,
  player_role     text,
  batting_style   text,
  bowling_style   text,
  is_wicketkeeper boolean,
  avatar_path     text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'club_join: not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.clubs c where c.id = p_club_id and c.owner_id = auth.uid()) then
    raise exception 'club_join: not allowed' using errcode = '42501';
  end if;
  return query
    select r.id, r.status, r.message, r.assigned_role, r.decline_reason, r.created_at, r.decided_at,
           p.full_name,
           -- Migration 13: only with the applicant's consent.
           case when p.share_phone_with_clubs then p.phone end,
           case when p.date_of_birth is null then null
                else date_part('year', age(current_date, p.date_of_birth))::integer end,
           a.city,
           pp.player_role, pp.batting_style, pp.bowling_style, coalesce(pp.is_wicketkeeper, false),
           p.avatar_path
      from public.join_requests r
      join public.profiles p on p.id = r.user_id
      left join public.current_addresses a on a.user_id = r.user_id
      left join public.player_profiles pp on pp.user_id = r.user_id
     where r.club_id = p_club_id
       and r.status <> 'cancelled'
       -- Migration 30: a declined applicant's details go after 30 days.
       and not (r.status = 'rejected' and r.decided_at < now() - interval '30 days')
     order by r.created_at;
end;
$$;

-- The caller's active memberships of other people's clubs (migration 11)
-- + club_logo_path.
create function public.my_club_memberships()
returns table (
  member_id      uuid,
  club_id        uuid,
  club_name      text,
  club_code      text,
  city           text,
  member_role    text,
  joined_at      timestamptz,
  club_logo_path text
)
language sql
stable
security definer
set search_path = ''
as $$
  select m.id, c.id, c.name, c.code, c.city, m.member_role, m.joined_at, c.logo_path
    from public.club_members m
    join public.clubs c on c.id = m.club_id
   where m.user_id = (select auth.uid())
     and m.status = 'active'
     and m.member_role <> 'owner'
   order by m.joined_at;
$$;

-- ---------------------------------------------------------------------------
-- 6. Privileges: signed-in users only (as the replaced functions had)
-- ---------------------------------------------------------------------------
revoke execute on function public.set_my_avatar(text) from public, anon;
revoke execute on function public.set_club_logo(uuid, text) from public, anon;
revoke execute on function public.set_profile_visibility(boolean, boolean) from public, anon;
revoke execute on function public.my_profile_visibility() from public, anon;
revoke execute on function public.club_member_list(uuid) from public, anon;
revoke execute on function public.club_join_requests(uuid) from public, anon;
revoke execute on function public.my_club_memberships() from public, anon;

grant execute on function public.set_my_avatar(text) to authenticated;
grant execute on function public.set_club_logo(uuid, text) to authenticated;
grant execute on function public.set_profile_visibility(boolean, boolean) to authenticated;
grant execute on function public.my_profile_visibility() to authenticated;
grant execute on function public.club_member_list(uuid) to authenticated;
grant execute on function public.club_join_requests(uuid) to authenticated;
grant execute on function public.my_club_memberships() to authenticated;

-- ---------------------------------------------------------------------------
-- 7. Self-check (raises — rolling everything back — on any mismatch)
-- ---------------------------------------------------------------------------
do $$
declare
  v_fn regprocedure;
begin
  if (select count(*) from storage.buckets b
       where b.id in ('avatars', 'club-logos') and b.name = b.id and b.public is false
         and b.file_size_limit = 2097152
         and b.allowed_mime_types::text[] @> array['image/jpeg', 'image/png', 'image/webp']
         and b.allowed_mime_types::text[] <@ array['image/jpeg', 'image/png', 'image/webp']) <> 2 then
    raise exception 'migration 31 self-check: bucket "avatars" / "club-logos" is missing or configured differently (an existing bucket of that id?)';
  end if;
  if (select count(*) from pg_policy pol
       where pol.polrelid = 'storage.objects'::regclass
         and pol.polroles = array[(select oid from pg_roles where rolname = 'authenticated')]::oid[]
         and pol.polpermissive
         and pol.polname in ('criceco media: read avatars and club logos',
                             'criceco avatars: insert in own folder', 'criceco avatars: update in own folder',
                             'criceco avatars: delete in own folder', 'criceco club logos: insert for own club',
                             'criceco club logos: update for own club', 'criceco club logos: delete for own club')) <> 7
     or not (select c.relrowsecurity from pg_class c where c.oid = 'storage.objects'::regclass) then
    raise exception 'migration 31 self-check: the storage.objects policies (7, to authenticated, RLS on)';
  end if;
  if (select count(*) from pg_constraint k
       where k.convalidated and ((k.conrelid = 'public.profiles'::regclass and k.conname = 'profiles_avatar_path_check')
                                 or (k.conrelid = 'public.clubs'::regclass and k.conname = 'clubs_logo_path_check'))) <> 2
     or not exists (select 1 from pg_trigger t where t.tgrelid = 'public.profiles'::regclass
                     and t.tgname = 'profiles_guard_avatar_path' and t.tgenabled = 'O') then
    raise exception 'migration 31 self-check: the path checks / profiles trigger';
  end if;
  if has_column_privilege('authenticated', 'public.clubs', 'logo_path', 'INSERT')
     or has_column_privilege('authenticated', 'public.clubs', 'logo_path', 'UPDATE')
     or has_column_privilege('anon', 'public.clubs', 'logo_path', 'INSERT,UPDATE')
     or not has_column_privilege('authenticated', 'public.clubs', 'logo_path', 'SELECT')
     or not has_table_privilege('authenticated', 'public.profiles', 'SELECT')
     or not has_table_privilege('authenticated', 'public.profiles', 'INSERT')
     or not has_table_privilege('authenticated', 'public.profiles', 'UPDATE')
     or has_table_privilege('anon', 'public.profiles', 'SELECT') then
    raise exception 'migration 31 self-check: clubs.logo_path is writable, or the profiles grants changed';
  end if;
  foreach v_fn in array array['public.set_my_avatar(text)', 'public.set_club_logo(uuid, text)',
                              'public.set_profile_visibility(boolean, boolean)', 'public.my_profile_visibility()',
                              'public.club_member_list(uuid)', 'public.club_join_requests(uuid)',
                              'public.my_club_memberships()']::regprocedure[] loop
    if not has_function_privilege('authenticated', v_fn, 'execute') or has_function_privilege('anon', v_fn, 'execute')
       or (select not p.prosecdef or array_to_string(p.proconfig, ',') <> 'search_path=""' from pg_proc p where p.oid = v_fn) then
      raise exception 'migration 31 self-check: % privileges / properties', v_fn;
    end if;
  end loop;
  if has_function_privilege('authenticated', 'public.profiles_guard_avatar_path()', 'execute') then
    raise exception 'migration 31 self-check: profiles_guard_avatar_path is executable by authenticated';
  end if;
  if pg_get_function_result('public.club_member_list(uuid)'::regprocedure) not like '%is_wicketkeeper boolean, avatar_path text)'
     or pg_get_function_result('public.club_join_requests(uuid)'::regprocedure) not like '%is_wicketkeeper boolean, avatar_path text)'
     or pg_get_function_result('public.my_club_memberships()'::regprocedure) not like '%joined_at timestamp with time zone, club_logo_path text)'
     or pg_get_function_result('public.my_profile_visibility()'::regprocedure)
        <> 'TABLE(public_profile boolean, show_stats boolean)'
     -- my_privacy_settings (migration 13) untouched: still a boolean.
     or pg_get_function_result('public.my_privacy_settings()'::regprocedure) <> 'boolean'
     or (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p
          where p.oid = 'public.my_privacy_settings()'::regprocedure) <> '6505982ba6501ccc6e846d5badf430ce' then
    raise exception 'migration 31 self-check: a result type is not the intended one';
  end if;
end $$;

notify pgrst, 'reload schema';
