-- CricEco · ROLLBACK of migration 13 (phone-number sharing consent).
-- Only with explicit approval, inside
--   begin; set local lock_timeout = '5s'; <this file> commit;
-- Run the account-deletion rollback (migration 14) first if it is applied.
--
-- WARNING: this restores migration 11's behaviour — club owners again receive
-- every member's and applicant's phone number — and drops every user's
-- consent choice (profiles.share_phone_with_clubs). An app built with
-- CRICECO_ACCOUNT_PRIVACY=true then fails to read / save the setting.

do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'profiles' and column_name = 'share_phone_with_clubs') then
    raise exception 'rollback 13: migration 13 is not applied — nothing changed';
  end if;
end $$;

-- The two club functions exactly as in migration 11.
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
           p.full_name, p.phone,
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
    select m.id, m.user_id, m.member_role, m.joined_at, p.full_name, p.phone,
           pp.player_role, pp.batting_style, pp.bowling_style, coalesce(pp.is_wicketkeeper, false)
      from public.club_members m
      join public.profiles p on p.id = m.user_id
      left join public.player_profiles pp on pp.user_id = m.user_id
     where m.club_id = p_club_id
       and m.status = 'active'
     order by (m.member_role = 'owner') desc, m.joined_at;
end;
$$;

drop function public.set_phone_sharing(boolean);
drop function public.my_privacy_settings();
alter table public.profiles drop column share_phone_with_clubs;

notify pgrst, 'reload schema';
