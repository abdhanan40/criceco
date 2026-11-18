-- CricEco · migration 13 · phone-number sharing consent
--
-- NOT APPLIED. Requires migration 11 (club memberships). Review first; apply
-- only with separate approval, after a fresh backup, inside
--   begin; set local lock_timeout = '5s'; <this file> commit;
-- Rollback: supabase/rollback/20261118_rollback_phone_sharing_consent.sql.
-- Read-only check: supabase/tests/13_account_privacy_postcheck.sql.
--
-- Before: club owners always received the phone number of every member
-- (club_member_list) and applicant (club_join_requests), whatever the app's
-- "Show phone number" switch said — that switch was stored on the device.
--
-- Policy (secure default):
--   * profiles.share_phone_with_clubs, default FALSE: a phone number is shown
--     to a club owner only when its owner agreed. Existing users start at
--     false — their numbers stop being shared until they opt in.
--   * The owner's own row in club_member_list always carries their own phone.
--   * Names, age, city and cricket details stay visible to the club owner
--     (needed to decide on a request); only the phone needs consent.
--   * The user reads / changes the consent through my_privacy_settings() /
--     set_phone_sharing(p_share): SECURITY DEFINER, empty search_path, for
--     auth.uid() only. anon has no access to anything here.
-- The functions keep their signatures and result columns: an app built
-- before this migration keeps working (it just gets NULL phones).

do $$
begin
  if to_regclass('public.club_members') is null or to_regprocedure('public.club_member_list(uuid)') is null then
    raise exception 'migration 13: migration 11 (club memberships) is required';
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'profiles' and column_name = 'share_phone_with_clubs') then
    raise exception 'migration 13: profiles.share_phone_with_clubs already exists — nothing changed';
  end if;
  if to_regprocedure('public.my_privacy_settings()') is not null
     or to_regprocedure('public.set_phone_sharing(boolean)') is not null then
    raise exception 'migration 13: a privacy function already exists — nothing changed';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. The consent
-- ---------------------------------------------------------------------------
alter table public.profiles
  add column share_phone_with_clubs boolean not null default false;

comment on column public.profiles.share_phone_with_clubs is
  'Consent: club owners of clubs this user joins or applies to may see the phone number. Default false.';

-- ---------------------------------------------------------------------------
-- 2. Reading and changing it (own account only)
-- ---------------------------------------------------------------------------
create or replace function public.my_privacy_settings()
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_share boolean;
begin
  if auth.uid() is null then
    raise exception 'privacy: not authenticated' using errcode = '42501';
  end if;
  select p.share_phone_with_clubs into v_share from public.profiles p where p.id = auth.uid();
  return coalesce(v_share, false);
end;
$$;

create or replace function public.set_phone_sharing(p_share boolean)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'privacy: not authenticated' using errcode = '42501';
  end if;
  if p_share is null then
    raise exception 'privacy: invalid' using errcode = '22023';
  end if;
  update public.profiles set share_phone_with_clubs = p_share where id = auth.uid();
  if not found then
    raise exception 'privacy: profile not found' using errcode = 'P0002';
  end if;
  return p_share;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. The club owner's views: the phone only with consent
--    (bodies as in migration 11, apart from the phone column)
-- ---------------------------------------------------------------------------
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
     order by r.created_at;
end;
$$;

-- The owner's view of their club's active members (the owner row included).
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

-- ---------------------------------------------------------------------------
-- 4. Privileges (CREATE OR REPLACE kept the two club functions' grants)
-- ---------------------------------------------------------------------------
revoke execute on function public.my_privacy_settings() from public, anon;
revoke execute on function public.set_phone_sharing(boolean) from public, anon;
grant execute on function public.my_privacy_settings() to authenticated;
grant execute on function public.set_phone_sharing(boolean) to authenticated;

notify pgrst, 'reload schema';
