-- CricEco · ROLLBACK of migration 30 (M4 integrity & security hardening).
--
-- NOT APPLIED. Run only with explicit approval, after a backup, inside
--   begin; set local lock_timeout = '5s'; <this file> commit;
-- FIRST roll back (or never ship) an app build that sends p_expected_version
-- to save_team: after this file that argument no longer exists (PostgREST
-- answers "function not found").
--
-- Reverses all five parts of migration 30:
--   1. drops profiles_full_name_check / _phone_check / _role_check and restores
--      profiles_validate() of migration 2 verbatim;
--   2. drops the 8-argument save_team, drops teams.version (with its check)
--      and restores migration 12's 7-argument save_team verbatim (and its
--      grants: authenticated; not public / anon);
--   3. restores migration 27's register_push_device verbatim (CREATE OR
--      REPLACE keeps its grants) and drops push_token_moves (its rows are only
--      a 24-hour throttle record: nothing of value is lost);
--   4. restores migration 13's club_join_requests verbatim (grants kept);
--   5. drops club_ownership_transfers_to_user_id_idx and the id column (and
--      primary key) of account_deletion_attempts (its rows stay).
-- No other row is changed or deleted.
-- Generated from migrations 2 (20261027090100, lines 59–79), 12 (20261116090100,
-- lines 218–321), 13 (20261118090000, lines 97–144) and 27 (20261122090200,
-- lines 157–192).

do $$
begin
  if to_regclass('public.push_token_moves') is null
     or to_regprocedure('public.save_team(uuid, text, text, integer, uuid, uuid, jsonb, integer)') is null
     or not exists (select 1 from information_schema.columns
                     where table_schema = 'public' and table_name = 'teams' and column_name = 'version') then
    raise exception 'rollback 30: migration 30 is not applied — nothing changed';
  end if;
  -- The four functions must still be migration 30's (line endings ignored):
  -- anything changed since is not this rollback's to undo.
  if (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p
       where p.oid = 'public.profiles_validate()'::regprocedure) <> 'd5fd026cc1555113789cf7a4cd44bbcd'
     or (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p
          where p.oid = 'public.save_team(uuid, text, text, integer, uuid, uuid, jsonb, integer)'::regprocedure)
        <> '787eafbe79683667e594b7dcf930dd07'
     or (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p
          where p.oid = 'public.club_join_requests(uuid)'::regprocedure) <> '9ef95a33568e101f91b24d95a0d72f0f'
     or (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p
          where p.oid = 'public.register_push_device(text, text)'::regprocedure) <> '2689f2e67f4487abe15fc1dca4133162' then
    raise exception 'rollback 30: a function differs from migration 30 (changed since?) — nothing changed';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. profiles
-- ---------------------------------------------------------------------------
alter table public.profiles
  drop constraint profiles_full_name_check,
  drop constraint profiles_phone_check,
  drop constraint profiles_role_check;

-- Migration 2's profiles_validate, verbatim.
create or replace function public.profiles_validate()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.date_of_birth is not null and new.date_of_birth > current_date then
    raise exception 'date_of_birth cannot be in the future' using errcode = '23514';
  end if;
  if new.profile_completed and (tg_op = 'INSERT' or old.profile_completed is not true) then
    if new.full_name is null or new.phone is null or new.date_of_birth is null then
      raise exception 'profile_completed requires full_name, phone and date_of_birth' using errcode = '23514';
    end if;
    if not exists (select 1 from public.current_addresses where user_id = new.id)
       or not exists (select 1 from public.permanent_addresses where user_id = new.id) then
      raise exception 'profile_completed requires a current and a permanent address' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. teams
-- ---------------------------------------------------------------------------
drop function public.save_team(uuid, text, text, integer, uuid, uuid, jsonb, integer);
alter table public.teams drop column version;

-- Migration 12's save_team, verbatim.
-- Saves a team's details and its whole squad in one transaction.
-- p_players: a JSON array in pick order, e.g.
--   [{"member_id": "…", "selection": "playing"}, {"member_id": "…", "selection": "sub"}]
create or replace function public.save_team(
  p_team_id           uuid,
  p_name              text,
  p_format            text,
  p_custom_overs      integer,
  p_captain_member_id uuid,
  p_vice_member_id    uuid,
  p_players           jsonb
)
returns public.teams
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_team    public.teams;
  v_format  text := lower(btrim(coalesce(p_format, '')));
  v_total   integer;
  v_count   integer;
  v_playing integer;
  v_subs    integer;
begin
  if v_uid is null then
    raise exception 'team: not authenticated' using errcode = '42501';
  end if;
  select * into v_team from public.teams t where t.id = p_team_id for update;
  if not found then
    raise exception 'team: not found' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.clubs c where c.id = v_team.club_id and c.owner_id = v_uid) then
    raise exception 'team: not allowed' using errcode = '42501';
  end if;
  if v_team.status <> 'active' then
    raise exception 'team: archived' using errcode = 'P0001';
  end if;

  -- The squad: an array of {member_id, selection}, no repeats, within 11 + 4,
  -- every player an active member of this club.
  if p_players is null or jsonb_typeof(p_players) <> 'array' then
    raise exception 'team: invalid' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(p_players) e
              where jsonb_typeof(e) <> 'object'
                 or coalesce(e ->> 'selection', '') not in ('playing', 'sub')
                 or coalesce(e ->> 'member_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') then
    raise exception 'team: invalid' using errcode = '22023';
  end if;
  select count(*), count(distinct e ->> 'member_id'),
         count(*) filter (where e ->> 'selection' = 'playing'),
         count(*) filter (where e ->> 'selection' = 'sub')
    into v_total, v_count, v_playing, v_subs
    from jsonb_array_elements(p_players) e;
  if v_count <> v_total then
    raise exception 'team: invalid' using errcode = '22023'; -- a player listed twice
  end if;
  if v_playing > 11 or v_subs > 4 then
    raise exception 'team: squad full' using errcode = '23514';
  end if;
  if exists (select 1 from jsonb_array_elements(p_players) e
              where not exists (select 1 from public.club_members m
                                 where m.id = (e ->> 'member_id')::uuid
                                   and m.club_id = v_team.club_id and m.status = 'active')) then
    raise exception 'team: player not in club' using errcode = '23514';
  end if;

  -- Captain / vice-captain: optional, in this squad, two different people.
  if p_captain_member_id is not null and p_captain_member_id = p_vice_member_id then
    raise exception 'team: invalid' using errcode = '22023';
  end if;
  if (p_captain_member_id is not null and not exists (
        select 1 from jsonb_array_elements(p_players) e where (e ->> 'member_id')::uuid = p_captain_member_id))
     or (p_vice_member_id is not null and not exists (
        select 1 from jsonb_array_elements(p_players) e where (e ->> 'member_id')::uuid = p_vice_member_id)) then
    raise exception 'team: invalid' using errcode = '22023';
  end if;

  begin
    update public.teams
       set name = regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g'),
           format = v_format,
           custom_overs = case when v_format = 'custom' then p_custom_overs end,
           captain_member_id = p_captain_member_id,
           vice_captain_member_id = p_vice_member_id
     where id = p_team_id
    returning * into v_team;
  exception
    when unique_violation then
      raise exception 'team: duplicate name' using errcode = '23505';
    when check_violation or not_null_violation or numeric_value_out_of_range then
      raise exception 'team: invalid' using errcode = '22023';
  end;

  delete from public.team_players where team_id = p_team_id;
  insert into public.team_players (team_id, member_id, selection, position)
  select p_team_id, (e.value ->> 'member_id')::uuid, e.value ->> 'selection', e.ordinality::smallint
    from jsonb_array_elements(p_players) with ordinality as e(value, ordinality);

  return v_team;
end;
$$;

revoke execute on function public.save_team(uuid, text, text, integer, uuid, uuid, jsonb) from public, anon;
grant execute on function public.save_team(uuid, text, text, integer, uuid, uuid, jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. push: migration 27's register_push_device, verbatim; the throttle table
-- ---------------------------------------------------------------------------
create or replace function public.register_push_device(p_token text, p_platform text default 'android')
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := auth.uid();
  v_token text := btrim(coalesce(p_token, ''));
begin
  if v_uid is null then
    raise exception 'push: not authenticated' using errcode = '42501';
  end if;
  if char_length(v_token) not between 20 and 4096 or v_token ~ '\s' then
    raise exception 'push: invalid token' using errcode = '22023';
  end if;
  if p_platform is null or p_platform not in ('android') then
    raise exception 'push: invalid platform' using errcode = '22023';
  end if;
  if not exists (select 1 from public.profiles p where p.id = v_uid) then
    raise exception 'push: not found' using errcode = 'P0002';
  end if;
  -- A token is one installation: signing in there as someone else moves it.
  insert into public.device_tokens as t (user_id, token, platform)
  values (v_uid, v_token, p_platform)
  on conflict (token) do update
     set user_id = excluded.user_id, platform = excluded.platform, last_seen_at = now(),
         created_at = case when t.user_id = excluded.user_id then t.created_at else now() end;
  -- At most 10 devices per person: the longest unseen go.
  delete from public.device_tokens t
   where t.user_id = v_uid
     and t.id not in (select x.id from public.device_tokens x where x.user_id = v_uid
                       order by x.last_seen_at desc, x.id desc limit 10);
end;
$$;

drop table public.push_token_moves;

-- ---------------------------------------------------------------------------
-- 4. club_join_requests: migration 13's, verbatim
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

-- ---------------------------------------------------------------------------
-- 5. Indexes and keys
-- ---------------------------------------------------------------------------
drop index public.club_ownership_transfers_to_user_id_idx;
alter table public.account_deletion_attempts drop column id;

-- ---------------------------------------------------------------------------
-- 6. Self-check: back to migrations 1–29 (raises — rolling everything back)
-- ---------------------------------------------------------------------------
do $$
begin
  if (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p
       where p.oid = 'public.profiles_validate()'::regprocedure) <> '83fc16a3a29fd7b2df5e08293eaf22a0'
     or (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p
          where p.oid = 'public.save_team(uuid, text, text, integer, uuid, uuid, jsonb)'::regprocedure)
        <> 'a346e309795ba1bd3d76862b07fa0d0b'
     or (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p
          where p.oid = 'public.club_join_requests(uuid)'::regprocedure) <> '84a60dff7fd3583933b3a60d9af5f48f'
     or (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p
          where p.oid = 'public.register_push_device(text, text)'::regprocedure) <> '6f629ec9737797b8a81ac6c9db08c6b4' then
    raise exception 'rollback 30 self-check: a restored function is not its migration''s';
  end if;
  if (select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'save_team') <> 1
     or not has_function_privilege('authenticated', 'public.save_team(uuid, text, text, integer, uuid, uuid, jsonb)', 'execute')
     or has_function_privilege('anon', 'public.save_team(uuid, text, text, integer, uuid, uuid, jsonb)', 'execute')
     or not has_function_privilege('authenticated', 'public.register_push_device(text, text)', 'execute')
     or has_function_privilege('anon', 'public.register_push_device(text, text)', 'execute')
     or not has_function_privilege('authenticated', 'public.club_join_requests(uuid)', 'execute')
     or has_function_privilege('anon', 'public.club_join_requests(uuid)', 'execute') then
    raise exception 'rollback 30 self-check: function grants';
  end if;
  if to_regclass('public.push_token_moves') is not null
     or to_regclass('public.club_ownership_transfers_to_user_id_idx') is not null
     or exists (select 1 from information_schema.columns
                 where table_schema = 'public'
                   and ((table_name = 'teams' and column_name = 'version')
                        or (table_name = 'account_deletion_attempts' and column_name = 'id')))
     or exists (select 1 from pg_constraint where conrelid = 'public.profiles'::regclass
                   and conname in ('profiles_full_name_check', 'profiles_phone_check', 'profiles_role_check')) then
    raise exception 'rollback 30 self-check: an object of migration 30 is still there';
  end if;
end $$;

notify pgrst, 'reload schema';
