-- CricEco · ROLLBACK of migration 31 (M5 media uploads, M6 privacy visibility).
--
-- NOT APPLIED. Run only with explicit approval, after a backup, inside
--   begin; set local lock_timeout = '5s'; <this file> commit;
-- FIRST roll back (or never ship) an app build that calls set_my_avatar,
-- set_club_logo, set_profile_visibility or my_profile_visibility, or reads
-- the new avatar_path / club_logo_path columns: after this file they are gone.
--
-- Reverses migration 31:
--   1. drops its 7 storage.objects policies (signed-in users then have no
--      access to the two buckets; the server's service role keeps it);
--   2. deletes the buckets "avatars" / "club-logos" ONLY when they hold no
--      object. Uploaded files are never deleted here: a bucket that still
--      has files is kept (private, no policy) and reported with a NOTICE —
--      empty it in the Dashboard (Storage) first if it should go;
--   3. drops set_my_avatar, set_club_logo, set_profile_visibility,
--      my_profile_visibility, the
--      profiles_guard_avatar_path trigger and function, and the columns
--      profiles.avatar_path / public_profile / show_stats and clubs.logo_path
--      (the stored paths and visibility choices are lost; the files stay);
--   4. restores club_member_list (migration 13), club_join_requests
--      (migration 30) and my_club_memberships (migration 11) verbatim, with
--      their grants (authenticated; not public / anon). my_privacy_settings
--      (migration 13) was never changed by migration 31 and is not touched.
-- No other row is changed or deleted.
-- Generated from migrations 11 (20261116090000, lines 574–596), 13
-- (20261118090000, lines 147–184) and 30 (20261126090000, lines 373–422).

do $$
begin
  if to_regprocedure('public.set_my_avatar(text)') is null
     or to_regprocedure('public.set_club_logo(uuid, text)') is null
     or to_regprocedure('public.set_profile_visibility(boolean, boolean)') is null
     or to_regprocedure('public.my_profile_visibility()') is null
     or (select count(*) from information_schema.columns
          where table_schema = 'public'
            and ((table_name = 'profiles' and column_name in ('avatar_path', 'public_profile', 'show_stats'))
                 or (table_name = 'clubs' and column_name = 'logo_path'))) <> 4 then
    raise exception 'rollback 31: migration 31 is not (fully) applied — nothing changed';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Storage policies
-- ---------------------------------------------------------------------------
drop policy "criceco media: read avatars and club logos" on storage.objects;
drop policy "criceco avatars: insert in own folder" on storage.objects;
drop policy "criceco avatars: update in own folder" on storage.objects;
drop policy "criceco avatars: delete in own folder" on storage.objects;
drop policy "criceco club logos: insert for own club" on storage.objects;
drop policy "criceco club logos: update for own club" on storage.objects;
drop policy "criceco club logos: delete for own club" on storage.objects;

-- ---------------------------------------------------------------------------
-- 2. Buckets: only when empty (files are never deleted here)
-- ---------------------------------------------------------------------------
do $$
declare
  v_bucket text;
begin
  foreach v_bucket in array array['avatars', 'club-logos'] loop
    if exists (select 1 from storage.objects o where o.bucket_id = v_bucket) then
      raise notice 'rollback 31: bucket "%" still holds % file(s) — kept (private, no policy); empty it in the Dashboard first if it should go',
        v_bucket, (select count(*) from storage.objects o where o.bucket_id = v_bucket);
    else
      begin
        delete from storage.buckets b where b.id = v_bucket;
      exception when others then
        raise notice 'rollback 31: bucket "%" could not be deleted here (%) — kept; delete it in the Dashboard', v_bucket, sqlerrm;
      end;
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Functions, trigger, columns
-- ---------------------------------------------------------------------------
drop function public.set_my_avatar(text);
drop function public.set_club_logo(uuid, text);
drop function public.set_profile_visibility(boolean, boolean);
drop function public.my_profile_visibility();
drop trigger profiles_guard_avatar_path on public.profiles;
drop function public.profiles_guard_avatar_path();

-- The three functions return the new columns: dropped before the columns.
drop function public.club_member_list(uuid);
drop function public.club_join_requests(uuid);
drop function public.my_club_memberships();

alter table public.profiles drop column avatar_path, drop column public_profile, drop column show_stats;
alter table public.clubs drop column logo_path;

-- ---------------------------------------------------------------------------
-- 4. The functions as before migration 31 (verbatim)
-- ---------------------------------------------------------------------------
-- migration 13 (20261118090000), lines 147–184
create or replace function public.club_member_list(p_club_id uuid)
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
  is_wicketkeeper boolean
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
           pp.player_role, pp.batting_style, pp.bowling_style, coalesce(pp.is_wicketkeeper, false)
      from public.club_members m
      join public.profiles p on p.id = m.user_id
      left join public.player_profiles pp on pp.user_id = m.user_id
     where m.club_id = p_club_id
       and m.status = 'active'
     order by (m.member_role = 'owner') desc, m.joined_at;
end;
$$;

-- migration 30 (20261126090000), lines 373–422
create or replace function public.club_join_requests(p_club_id uuid)
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
  is_wicketkeeper boolean
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
           pp.player_role, pp.batting_style, pp.bowling_style, coalesce(pp.is_wicketkeeper, false)
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

-- migration 11 (20261116090000), lines 574–596
create or replace function public.my_club_memberships()
returns table (
  member_id   uuid,
  club_id     uuid,
  club_name   text,
  club_code   text,
  city        text,
  member_role text,
  joined_at   timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select m.id, c.id, c.name, c.code, c.city, m.member_role, m.joined_at
    from public.club_members m
    join public.clubs c on c.id = m.club_id
   where m.user_id = (select auth.uid())
     and m.status = 'active'
     and m.member_role <> 'owner'
   order by m.joined_at;
$$;

revoke execute on function public.club_member_list(uuid) from public, anon;
revoke execute on function public.club_join_requests(uuid) from public, anon;
revoke execute on function public.my_club_memberships() from public, anon;
grant execute on function public.club_member_list(uuid) to authenticated;
grant execute on function public.club_join_requests(uuid) to authenticated;
grant execute on function public.my_club_memberships() to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Self-check (raises — undoing the rollback — on any mismatch)
-- ---------------------------------------------------------------------------
do $$
declare
  v_fn regprocedure;
begin
  if (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p
       where p.oid = 'public.club_member_list(uuid)'::regprocedure) <> 'ac91f13f856dabdc03617a845883ff46'
     or (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p
          where p.oid = 'public.club_join_requests(uuid)'::regprocedure) <> '9ef95a33568e101f91b24d95a0d72f0f'
     or (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p
          where p.oid = 'public.my_club_memberships()'::regprocedure) <> 'eaecaca4655a66c5187640803ad5208c'
     or (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p
          where p.oid = 'public.my_privacy_settings()'::regprocedure) <> '6505982ba6501ccc6e846d5badf430ce' then
    raise exception 'rollback 31 self-check: a restored function differs from its migration';
  end if;
  foreach v_fn in array array['public.club_member_list(uuid)', 'public.club_join_requests(uuid)',
                              'public.my_club_memberships()']::regprocedure[] loop
    if not has_function_privilege('authenticated', v_fn, 'execute') or has_function_privilege('anon', v_fn, 'execute') then
      raise exception 'rollback 31 self-check: % privileges', v_fn;
    end if;
  end loop;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public'
                and ((table_name = 'profiles' and column_name in ('avatar_path', 'public_profile', 'show_stats'))
                     or (table_name = 'clubs' and column_name = 'logo_path')))
     or exists (select 1 from pg_policy where polrelid = 'storage.objects'::regclass
                   and (polname like 'criceco media:%' or polname like 'criceco avatars:%' or polname like 'criceco club logos:%'))
     or to_regprocedure('public.profiles_guard_avatar_path()') is not null
     or to_regprocedure('public.my_profile_visibility()') is not null then
    raise exception 'rollback 31 self-check: something of migration 31 is left';
  end if;
end $$;

notify pgrst, 'reload schema';
