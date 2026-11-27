-- CricEco · migration 30 · M4 integrity & security hardening
--
-- NOT APPLIED. Requires migrations 1–29. Review first; apply only with separate
-- approval, after a fresh backup, inside
--   begin; set local lock_timeout = '5s'; <this file> commit;
-- Rollback: supabase/rollback/20261126_rollback_m4_integrity_hardening.sql.
-- Read-only check: supabase/tests/30_m4_integrity_hardening_postcheck.sql.
-- Local test: supabase/tests/local/25_m4_integrity_hardening_local_check.sql.
-- Design: docs/M4_INTEGRITY_HARDENING.md.
--
-- What changes (five parts, one transaction):
--   1. profiles: the field rules of review section A as CHECK constraints
--      (full name 2–100 characters, a Pakistani mobile phone in any spelling
--      the app has stored, role player / club_owner; NULL stays allowed).
--      Added NOT VALID and then VALIDATEd here: any existing row that breaks
--      a rule stops the whole migration (nothing changes). And a COMPLETED
--      profile can no longer lose its phone (profiles_validate). Table grants
--      are NOT touched (save_profile_setup v1 / v2, update_profile_details run
--      as the caller and the app writes profiles.role directly).
--   2. teams: optimistic concurrency. teams.version (starts at 1, +1 on every
--      successful save_team). save_team takes an optional p_expected_version:
--      when given and different → SQLSTATE 40001 'team: changed elsewhere'.
--      The old 7-argument save_team is dropped (one signature for PostgREST);
--      a call without p_expected_version behaves exactly as before.
--   3. register_push_device: moving a token that belongs to ANOTHER person is
--      allowed at most 3 times per caller in 24 hours (then P0001 'push: too
--      many device moves'), recorded in the closed table push_token_moves. A
--      new token or the caller's own token is never limited.
--   4. club_join_requests: declined (status 'rejected') requests decided more
--      than 30 days ago are no longer returned. Same signature, columns, grants.
--   5. an index on club_ownership_transfers (to_user_id) (the foreign key's ON
--      DELETE SET NULL); a primary key (id) on account_deletion_attempts.
-- No row is changed or deleted (account_deletion_attempts rows get an id).

do $$
begin
  if to_regclass('public.push_token_moves') is not null
     or to_regclass('public.club_ownership_transfers_to_user_id_idx') is not null
     or exists (select 1 from information_schema.columns
                 where table_schema = 'public'
                   and ((table_name = 'teams' and column_name = 'version')
                        or (table_name = 'account_deletion_attempts' and column_name = 'id')))
     or exists (select 1 from pg_constraint
                 where (conrelid = 'public.profiles'::regclass
                        and conname in ('profiles_full_name_check', 'profiles_phone_check', 'profiles_role_check'))
                   or (conrelid = to_regclass('public.account_deletion_attempts') and contype = 'p'))
     or exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace
                   and p.proname = 'save_team' and p.pronargs <> 7) then
    raise exception 'migration 30: already applied (or a name is taken) — nothing changed';
  end if;
  if to_regclass('public.notification_job_runs') is null or to_regclass('public.device_tokens') is null
     or to_regclass('public.teams') is null or to_regclass('public.account_deletion_attempts') is null
     or to_regclass('public.club_ownership_transfers') is null
     or to_regprocedure('public.save_team(uuid, text, text, integer, uuid, uuid, jsonb)') is null
     or to_regprocedure('public.register_push_device(text, text)') is null
     or to_regprocedure('public.club_join_requests(uuid)') is null
     or to_regprocedure('public.profiles_validate()') is null then
    raise exception 'migration 30: migrations 1–29 are required';
  end if;
  -- The four functions this replaces must be exactly those of migrations 2,
  -- 12, 13 and 27 (the rollback restores them verbatim). Line endings ignored.
  if (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p
       where p.oid = 'public.profiles_validate()'::regprocedure) <> '83fc16a3a29fd7b2df5e08293eaf22a0'
     or (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p
          where p.oid = 'public.save_team(uuid, text, text, integer, uuid, uuid, jsonb)'::regprocedure)
        <> 'a346e309795ba1bd3d76862b07fa0d0b'
     or (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p
          where p.oid = 'public.club_join_requests(uuid)'::regprocedure) <> '84a60dff7fd3583933b3a60d9af5f48f'
     or (select md5(replace(p.prosrc, chr(13), '')) from pg_proc p
          where p.oid = 'public.register_push_device(text, text)'::regprocedure) <> '6f629ec9737797b8a81ac6c9db08c6b4' then
    raise exception 'migration 30: a function to replace differs from its migration (2 / 12 / 13 / 27) — nothing changed';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. profiles: field rules (review section A) and "a completed profile keeps
--    its phone"
-- ---------------------------------------------------------------------------
-- The phone rule accepts every Pakistani mobile spelling the app has stored
-- (03XXXXXXXXX, 0300-1234567, 0300 1234567, 923…, +923…); the profile
-- functions write the canonical +923XXXXXXXXX form.
alter table public.profiles
  add constraint profiles_full_name_check
    check (full_name is null or char_length(btrim(full_name)) between 2 and 100) not valid,
  add constraint profiles_phone_check
    check (phone is null or regexp_replace(phone, '[\s-]', '', 'g') ~ '^(\+92|92|0)3[0-9]{9}$') not valid,
  add constraint profiles_role_check
    check (role is null or role in ('player', 'club_owner')) not valid;

-- Counts only (no personal data), then the real validation.
do $$
declare
  v_name  integer;
  v_phone integer;
  v_role  integer;
begin
  select count(*) filter (where full_name is not null and char_length(btrim(full_name)) not between 2 and 100),
         count(*) filter (where phone is not null and regexp_replace(phone, '[\s-]', '', 'g') !~ '^(\+92|92|0)3[0-9]{9}$'),
         count(*) filter (where role is not null and role not in ('player', 'club_owner'))
    into v_name, v_phone, v_role
    from public.profiles;
  if v_name + v_phone + v_role > 0 then
    raise exception 'migration 30: existing profiles break the new rules (full_name %, phone %, role %) — nothing changed',
      v_name, v_phone, v_role;
  end if;
end $$;

alter table public.profiles validate constraint profiles_full_name_check;
alter table public.profiles validate constraint profiles_phone_check;
alter table public.profiles validate constraint profiles_role_check;

comment on constraint profiles_full_name_check on public.profiles is 'Migration 30: NULL or 2–100 characters (trimmed).';
comment on constraint profiles_phone_check on public.profiles is
  'Migration 30: NULL or a Pakistani mobile number (03…, 923…, +923…; spaces and dashes ignored).';
comment on constraint profiles_role_check on public.profiles is 'Migration 30: NULL, player or club_owner.';

-- profiles_validate (final definition: migration 2) plus one rule: a profile
-- that is completed and has a phone can't lose it (UPDATE to NULL / blank,
-- also through update_profile_details or a direct API update). Everything else
-- as before; a legacy completed row that never had a phone stays editable.
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
  -- Migration 30: a completed profile keeps its phone.
  if tg_op = 'UPDATE' and new.profile_completed and old.profile_completed
     and nullif(btrim(coalesce(new.phone, '')), '') is null
     and nullif(btrim(coalesce(old.phone, '')), '') is not null then
    raise exception 'profile_completed requires phone' using errcode = '23514';
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. teams: optimistic concurrency
-- ---------------------------------------------------------------------------
alter table public.teams
  add column version integer not null default 1
    constraint teams_version_check check (version >= 1);

comment on column public.teams.version is
  'Migration 30: 1 at creation, +1 on every successful save_team. Send it back as p_expected_version.';

-- One signature only (PostgREST must not see two save_team candidates).
drop function public.save_team(uuid, text, text, integer, uuid, uuid, jsonb);

-- Saves a team's details and its whole squad in one transaction.
-- p_players: a JSON array in pick order, e.g.
--   [{"member_id": "…", "selection": "playing"}, {"member_id": "…", "selection": "sub"}]
-- p_expected_version (migration 30): the version the editor loaded. When given
-- and the team has been saved since → 40001 'team: changed elsewhere'
-- (nothing written). NULL: no check (as before migration 30).
create function public.save_team(
  p_team_id           uuid,
  p_name              text,
  p_format            text,
  p_custom_overs      integer,
  p_captain_member_id uuid,
  p_vice_member_id    uuid,
  p_players           jsonb,
  p_expected_version  integer default null
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
  -- Migration 30: saved by someone else (another device) since it was loaded.
  if p_expected_version is not null and p_expected_version <> v_team.version then
    raise exception 'team: changed elsewhere' using errcode = '40001';
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
           vice_captain_member_id = p_vice_member_id,
           version = version + 1
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

revoke execute on function public.save_team(uuid, text, text, integer, uuid, uuid, jsonb, integer) from public, anon;
grant execute on function public.save_team(uuid, text, text, integer, uuid, uuid, jsonb, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Push: at most 3 device moves from other people per caller in 24 hours
-- ---------------------------------------------------------------------------
create table public.push_token_moves (
  id       bigint generated always as identity primary key,
  user_id  uuid not null
           constraint push_token_moves_user_id_fkey references public.profiles (id) on delete cascade,
  moved_at timestamptz not null default now()
);

create index push_token_moves_user_moved_idx on public.push_token_moves (user_id, moved_at);

comment on table public.push_token_moves is
  'Migration 30: a device token taken over from another person (throttle, 3 per 24 h). Written and read only by register_push_device; rows older than 24 h are removed there.';

alter table public.push_token_moves enable row level security;
-- No policy, no grant: only register_push_device (SECURITY DEFINER) touches it.
revoke all on table public.push_token_moves from public, anon, authenticated, service_role;
revoke all on sequence public.push_token_moves_id_seq from public, anon, authenticated, service_role;

-- register_push_device (migration 27) plus the move limit. The token's row is
-- locked (FOR UPDATE) before its owner is read, so the owner seen is the one
-- replaced; a token registered by someone else at the same moment is waited
-- for (the unique key) and then locked and read like any other. A caller's
-- moves are counted one at a time (their profile row, FOR NO KEY UPDATE —
-- only on a move). Same rows written as migration 27's upsert. A refused
-- move changes nothing.
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
  v_owner uuid;
  v_new   boolean := false;
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
  -- Migration 30: taking a token over from someone else, at most 3 times in
  -- 24 hours (a new token and the caller's own are never limited).
  loop
    select t.user_id into v_owner from public.device_tokens t where t.token = v_token for update;
    exit when found;
    insert into public.device_tokens (user_id, token, platform)
    values (v_uid, v_token, p_platform)
    on conflict (token) do nothing;
    if found then
      v_new := true;
      exit;
    end if;
    -- Registered by someone else at the same moment: lock that row, look again.
  end loop;
  if not v_new and v_owner <> v_uid then
    perform 1 from public.profiles p where p.id = v_uid for no key update;
    delete from public.push_token_moves m where m.user_id = v_uid and m.moved_at <= now() - interval '24 hours';
    if (select count(*) from public.push_token_moves m
         where m.user_id = v_uid and m.moved_at > now() - interval '24 hours') >= 3 then
      raise exception 'push: too many device moves' using errcode = 'P0001';
    end if;
    insert into public.push_token_moves (user_id) values (v_uid);
  end if;
  -- A token is one installation: signing in there as someone else moves it.
  if not v_new then
    update public.device_tokens t
       set user_id = v_uid, platform = p_platform, last_seen_at = now(),
           created_at = case when t.user_id = v_uid then t.created_at else now() end
     where t.token = v_token;
  end if;
  -- At most 10 devices per person: the longest unseen go.
  delete from public.device_tokens t
   where t.user_id = v_uid
     and t.id not in (select x.id from public.device_tokens x where x.user_id = v_uid
                       order by x.last_seen_at desc, x.id desc limit 10);
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. club_join_requests: declined requests older than 30 days are not shown
--    (body as in migration 13, apart from the last condition)
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
       -- Migration 30: a declined applicant's details go after 30 days.
       and not (r.status = 'rejected' and r.decided_at < now() - interval '30 days')
     order by r.created_at;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Indexes and keys
-- ---------------------------------------------------------------------------
-- Deleting a profile sets to_user_id NULL on its offers (ON DELETE SET NULL):
-- the existing index covers pending offers only.
create index club_ownership_transfers_to_user_id_idx on public.club_ownership_transfers (to_user_id);

alter table public.account_deletion_attempts
  add column id bigint generated always as identity
    constraint account_deletion_attempts_pkey primary key;
-- The table stays closed (its grants are unchanged); so is the new sequence.
revoke all on sequence public.account_deletion_attempts_id_seq from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. Self-check (raises — rolling everything back — on any mismatch)
-- ---------------------------------------------------------------------------
do $$
declare
  v_fn regprocedure := 'public.save_team(uuid, text, text, integer, uuid, uuid, jsonb, integer)'::regprocedure;
begin
  if (select count(*) from pg_constraint
       where conrelid = 'public.profiles'::regclass and convalidated
         and conname in ('profiles_full_name_check', 'profiles_phone_check', 'profiles_role_check')) <> 3 then
    raise exception 'migration 30 self-check: the profiles rules are not all validated';
  end if;
  if not has_table_privilege('authenticated', 'public.profiles', 'SELECT')
     or not has_table_privilege('authenticated', 'public.profiles', 'INSERT')
     or not has_table_privilege('authenticated', 'public.profiles', 'UPDATE')
     or has_table_privilege('anon', 'public.profiles', 'SELECT') then
    raise exception 'migration 30 self-check: the profiles grants changed';
  end if;
  if (select pg_get_function_identity_arguments(p.oid) from pg_proc p
       where p.pronamespace = 'public'::regnamespace and p.proname = 'save_team') is distinct from
     'p_team_id uuid, p_name text, p_format text, p_custom_overs integer, p_captain_member_id uuid, p_vice_member_id uuid, p_players jsonb, p_expected_version integer' then
    raise exception 'migration 30 self-check: save_team is not the single 8-argument function';
  end if;
  if not has_function_privilege('authenticated', v_fn, 'execute') or has_function_privilege('anon', v_fn, 'execute')
     or (select not p.prosecdef or array_to_string(p.proconfig, ',') <> 'search_path=""' from pg_proc p where p.oid = v_fn) then
    raise exception 'migration 30 self-check: save_team privileges / properties';
  end if;
  if not has_function_privilege('authenticated', 'public.register_push_device(text, text)', 'execute')
     or has_function_privilege('anon', 'public.register_push_device(text, text)', 'execute')
     or has_function_privilege('service_role', 'public.register_push_device(text, text)', 'execute')
     or not has_function_privilege('authenticated', 'public.club_join_requests(uuid)', 'execute')
     or has_function_privilege('anon', 'public.club_join_requests(uuid)', 'execute') then
    raise exception 'migration 30 self-check: register_push_device / club_join_requests privileges';
  end if;
  if not (select c.relrowsecurity from pg_class c where c.oid = 'public.push_token_moves'::regclass)
     or exists (select 1 from pg_policy where polrelid = 'public.push_token_moves'::regclass)
     or has_table_privilege('anon', 'public.push_token_moves', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
     or has_table_privilege('authenticated', 'public.push_token_moves', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
     or has_table_privilege('service_role', 'public.push_token_moves', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') then
    raise exception 'migration 30 self-check: push_token_moves is not closed';
  end if;
  if has_table_privilege('anon', 'public.account_deletion_attempts', 'SELECT,INSERT,UPDATE,DELETE')
     or has_table_privilege('authenticated', 'public.account_deletion_attempts', 'SELECT,INSERT,UPDATE,DELETE')
     or not exists (select 1 from pg_constraint
                     where conrelid = 'public.account_deletion_attempts'::regclass and contype = 'p')
     or to_regclass('public.club_ownership_transfers_to_user_id_idx') is null then
    raise exception 'migration 30 self-check: account_deletion_attempts / ownership index';
  end if;
end $$;

notify pgrst, 'reload schema';
