-- CricEco · migration 11 · club memberships (club_members, join_requests)
--
-- NOT APPLIED. Review first; apply only with separate approval, after a
-- fresh backup, inside   begin; set local lock_timeout = '5s'; … commit;
-- (the SQL Editor; or psql -v ON_ERROR_STOP=1). Rollback:
-- rollback/20261116_rollback_club_memberships.sql (migration 12 first).
--
-- What it adds (nothing existing is altered except one new AFTER INSERT
-- trigger on public.clubs, which adds the owner's membership row):
--   * public.club_members  — one row per (club, person); status active/removed
--   * public.join_requests — pending → approved / rejected / cancelled
--   * public.club_code_attempts — failed join-code attempts (brute-force
--     throttle; no policy, no grants: only the functions touch it)
--   * RLS: a person reads their own rows; a club owner reads their club's
--     rows. No direct INSERT / UPDATE / DELETE for anon or authenticated:
--     every change goes through the functions below, which check auth.uid()
--     against the database (never a client-supplied user id or role).
--   * Functions: lookup_club_by_code, request_to_join_club,
--     cancel_join_request, decide_join_request, remove_club_member,
--     club_join_requests, club_member_list, my_club_memberships,
--     my_join_requests, is_club_owner (helper for the policies),
--     club_code_throttled / club_code_failed (internal throttle helpers).
--
-- Security notes
--   * Approving a request creates a club membership only (player / coach /
--     manager). It never touches profiles.role or user_roles: no role
--     escalation. 'owner' memberships exist only for the club's owner
--     (trigger + backfill) and can't be granted, changed or removed.
--   * Club codes are never returned to non-members: the lookup takes a code
--     the caller already has and returns the club's public basics only.
--   * Brute force: at most 10 failed codes per person per 15 minutes (lookup
--     and request together); then 'club_join: too many attempts'. Codes are
--     6 characters of 32 (about 10^9). Platform rate limits and account
--     creation limits still apply on top (see the docs).
--   * Owners see an applicant's AGE, never the date of birth.
--   * Applicant / member personal data (name, phone, age, city, cricket
--     details) is returned only to the owner of the club the person applied
--     to or belongs to.
--
-- Lifecycle
--   join_requests.status: pending → approved | rejected (owner) | cancelled
--   (the applicant). At most ONE pending request per person (any club).
--   club_members.status:  active → removed (owner). A removed person may ask
--   again; approval re-activates the same row (one row per club and person).

-- ---------------------------------------------------------------------------
-- 0. Guards: refuse to run twice or on an unexpected schema
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regclass('public.club_members') is not null or to_regclass('public.join_requests') is not null
     or to_regclass('public.club_code_attempts') is not null then
    raise exception 'migration 11: club_members, join_requests or club_code_attempts already exists — nothing changed';
  end if;
  if to_regclass('public.clubs') is null or to_regclass('public.profiles') is null
     or to_regclass('public.player_profiles') is null or to_regclass('public.current_addresses') is null then
    raise exception 'migration 11: clubs, profiles, player_profiles and current_addresses are required';
  end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public'
                and p.proname in ('is_club_owner', 'clubs_add_owner_member', 'lookup_club_by_code',
                                  'request_to_join_club', 'cancel_join_request', 'decide_join_request',
                                  'remove_club_member', 'club_join_requests', 'club_member_list',
                                  'my_club_memberships', 'my_join_requests', 'club_code_throttled',
                                  'club_code_failed')) then
    raise exception 'migration 11: a membership function already exists — nothing changed';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
create table public.club_members (
  id              uuid primary key default gen_random_uuid(),
  club_id         uuid not null
                  constraint club_members_club_id_fkey references public.clubs (id) on delete cascade,
  user_id         uuid not null
                  constraint club_members_user_id_fkey references public.profiles (id) on delete cascade,
  member_role     text not null
                  constraint club_members_member_role_check
                  check (member_role in ('owner', 'player', 'coach', 'manager')),
  status          text not null default 'active'
                  constraint club_members_status_check check (status in ('active', 'removed')),
  joined_at       timestamptz not null default now(),
  removed_at      timestamptz,
  removed_by      uuid
                  constraint club_members_removed_by_fkey references public.profiles (id) on delete set null,
  created_at      timestamptz not null default now(),
  last_updated_at timestamptz not null default now(),
  constraint club_members_club_user_key unique (club_id, user_id),
  constraint club_members_removed_consistency check ((status = 'removed') = (removed_at is not null)),
  constraint club_members_owner_active check (member_role <> 'owner' or status = 'active')
);

comment on table public.club_members is
  'One row per (club, person). Written only by the membership functions and the clubs owner trigger.';

-- Exactly one owner row per club.
create unique index club_members_one_owner_key on public.club_members (club_id) where member_role = 'owner';
create index club_members_user_id_idx on public.club_members (user_id);
create index club_members_club_status_idx on public.club_members (club_id, status);
create index club_members_removed_by_idx on public.club_members (removed_by) where removed_by is not null;

create table public.join_requests (
  id              uuid primary key default gen_random_uuid(),
  club_id         uuid not null
                  constraint join_requests_club_id_fkey references public.clubs (id) on delete cascade,
  user_id         uuid not null
                  constraint join_requests_user_id_fkey references public.profiles (id) on delete cascade,
  status          text not null default 'pending'
                  constraint join_requests_status_check
                  check (status in ('pending', 'approved', 'rejected', 'cancelled')),
  message         text
                  constraint join_requests_message_check
                  check (message is null or char_length(btrim(message)) between 1 and 300),
  assigned_role   text
                  constraint join_requests_assigned_role_check
                  check (assigned_role is null or assigned_role in ('player', 'coach', 'manager')),
  decline_reason  text
                  constraint join_requests_decline_reason_check
                  check (decline_reason is null or char_length(btrim(decline_reason)) between 1 and 120),
  decided_at      timestamptz,
  decided_by      uuid
                  constraint join_requests_decided_by_fkey references public.profiles (id) on delete set null,
  created_at      timestamptz not null default now(),
  last_updated_at timestamptz not null default now(),
  constraint join_requests_decided_consistency check ((status = 'pending') = (decided_at is null)),
  constraint join_requests_role_on_approval check ((status = 'approved') = (assigned_role is not null)),
  constraint join_requests_reason_on_rejection check (decline_reason is null or status = 'rejected')
);

comment on table public.join_requests is
  'Requests to join a club by its code. Written only by the membership functions.';

-- At most ONE pending request per person (any club) — the app's single
-- Waiting for Approval flow; history is kept. (Implies one per club.)
create unique index join_requests_one_pending_key on public.join_requests (user_id) where status = 'pending';
create index join_requests_club_status_idx on public.join_requests (club_id, status, created_at);
create index join_requests_user_created_idx on public.join_requests (user_id, created_at desc);
create index join_requests_decided_by_idx on public.join_requests (decided_by) where decided_by is not null;

-- Failed club-code attempts (unknown or malformed codes), per person: the
-- brute-force throttle of lookup_club_by_code / request_to_join_club. No
-- policy and no grant: only those functions read or write it. Rows older
-- than a day are deleted as new ones arrive.
create table public.club_code_attempts (
  id           bigint generated always as identity primary key,
  user_id      uuid not null
               constraint club_code_attempts_user_id_fkey references public.profiles (id) on delete cascade,
  attempted_at timestamptz not null default now()
);

comment on table public.club_code_attempts is
  'Failed join-code attempts (throttle). Internal: no RLS policy, no grants.';

create index club_code_attempts_user_time_idx on public.club_code_attempts (user_id, attempted_at desc);

create trigger club_members_set_last_updated_at
  before update on public.club_members
  for each row execute function public.set_last_updated_at();

create trigger join_requests_set_last_updated_at
  before update on public.join_requests
  for each row execute function public.set_last_updated_at();

-- ---------------------------------------------------------------------------
-- 2. Owner membership: a new club's owner row, and the existing clubs' rows
-- ---------------------------------------------------------------------------
create or replace function public.clubs_add_owner_member()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.club_members (club_id, user_id, member_role, status, joined_at)
  values (new.id, new.owner_id, 'owner', 'active', new.created_at)
  on conflict (club_id, user_id) do nothing;
  return null;
end;
$$;

create trigger clubs_add_owner_member
  after insert on public.clubs
  for each row execute function public.clubs_add_owner_member();

insert into public.club_members (club_id, user_id, member_role, status, joined_at)
select c.id, c.owner_id, 'owner', 'active', c.created_at
  from public.clubs c
on conflict (club_id, user_id) do nothing;

-- ---------------------------------------------------------------------------
-- 3. Row level security (read only; writes through the functions)
-- ---------------------------------------------------------------------------
-- Does the caller own [p_club_id]? SECURITY DEFINER so the policies below
-- don't depend on the clubs policies; it reveals nothing but that boolean.
create or replace function public.is_club_owner(p_club_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.clubs c where c.id = p_club_id and c.owner_id = (select auth.uid()));
$$;

alter table public.club_members enable row level security;
alter table public.join_requests enable row level security;
alter table public.club_code_attempts enable row level security; -- no policy: no direct access

create policy "club_members: select own or owned club"
  on public.club_members for select to authenticated
  using (user_id = (select auth.uid()) or public.is_club_owner(club_id));

create policy "join_requests: select own or owned club"
  on public.join_requests for select to authenticated
  using (user_id = (select auth.uid()) or public.is_club_owner(club_id));

revoke all on table public.club_members, public.join_requests, public.club_code_attempts from anon, authenticated;
grant select on table public.club_members, public.join_requests to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Functions (SECURITY DEFINER, search_path = '', the caller from auth.uid())
-- ---------------------------------------------------------------------------
-- Error messages start with "club_join:" so the app can tell them apart:
--   club_join: not authenticated (42501) · not allowed (42501) ·
--   own club (P0001) · already member (P0001) · already pending (P0001) ·
--   profile incomplete (P0001) · not pending (P0001) · too many attempts
--   (P0001) · invalid role (22023) · not found (P0002)
-- An unknown club code is NOT an error (that would roll back the throttle
-- record): lookup returns no row, request_to_join_club returns NULL.

-- Brute-force throttle for club codes: at most 10 FAILED code attempts per
-- person in 15 minutes (lookups and requests together). Successful lookups
-- don't count. Internal helpers — not executable by app roles.
create or replace function public.club_code_throttled(p_uid uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select count(*) >= 10
    from public.club_code_attempts a
   where a.user_id = p_uid
     and a.attempted_at > now() - interval '15 minutes';
$$;

create or replace function public.club_code_failed(p_uid uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.club_code_attempts a
   where a.user_id = p_uid and a.attempted_at < now() - interval '1 day';
  insert into public.club_code_attempts (user_id) values (p_uid);
end;
$$;

-- The club behind a join code (Join a Club preview): public basics only,
-- plus the caller's own relationship to it. No row for an unknown code
-- (counted by the throttle).
create or replace function public.lookup_club_by_code(p_code text)
returns table (
  club_id        uuid,
  name           text,
  city           text,
  club_type      text,
  member_count   integer,
  is_own_club    boolean,
  is_member      boolean,
  has_pending    boolean
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid  uuid := auth.uid();
  v_code text := upper(btrim(coalesce(p_code, '')));
begin
  if v_uid is null then
    raise exception 'club_join: not authenticated' using errcode = '42501';
  end if;
  if public.club_code_throttled(v_uid) then
    raise exception 'club_join: too many attempts' using errcode = 'P0001';
  end if;
  if v_code !~ '^[A-Z0-9]{6}$' or not exists (select 1 from public.clubs c where c.code = v_code) then
    perform public.club_code_failed(v_uid);
    return;
  end if;
  return query
    select c.id, c.name, c.city, c.club_type,
           (select count(*)::integer from public.club_members m
             where m.club_id = c.id and m.status = 'active'),
           c.owner_id = v_uid,
           exists (select 1 from public.club_members m
                    where m.club_id = c.id and m.user_id = v_uid and m.status = 'active'),
           exists (select 1 from public.join_requests r
                    where r.club_id = c.id and r.user_id = v_uid and r.status = 'pending')
      from public.clubs c
     where c.code = v_code;
end;
$$;

-- Sends a join request for [p_code]. Refuses the caller's own club, a club
-- they already belong to, a second pending request (any club) and an
-- incomplete profile. An unknown code returns NULL (and counts as a failed
-- attempt) instead of raising, so the throttle record is kept.
create or replace function public.request_to_join_club(p_code text, p_message text default null)
returns public.join_requests
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_code    text := upper(btrim(coalesce(p_code, '')));
  v_club    public.clubs;
  v_request public.join_requests;
begin
  if v_uid is null then
    raise exception 'club_join: not authenticated' using errcode = '42501';
  end if;
  if public.club_code_throttled(v_uid) then
    raise exception 'club_join: too many attempts' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.profiles p where p.id = v_uid and p.profile_completed is true) then
    raise exception 'club_join: profile incomplete' using errcode = 'P0001';
  end if;
  if v_code ~ '^[A-Z0-9]{6}$' then
    select * into v_club from public.clubs c where c.code = v_code;
  end if;
  if v_club.id is null then
    perform public.club_code_failed(v_uid);
    return null;
  end if;
  if v_club.owner_id = v_uid then
    raise exception 'club_join: own club' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.club_members m
              where m.club_id = v_club.id and m.user_id = v_uid and m.status = 'active') then
    raise exception 'club_join: already member' using errcode = 'P0001';
  end if;
  begin
    insert into public.join_requests (club_id, user_id, message)
    values (v_club.id, v_uid, nullif(btrim(p_message), ''))
    returning * into v_request;
  exception when unique_violation then
    -- A pending request already exists (this club or another), or a second
    -- request at the same moment.
    raise exception 'club_join: already pending' using errcode = 'P0001';
  end;
  return v_request;
end;
$$;

-- The applicant withdraws their own pending request.
create or replace function public.cancel_join_request(p_request_id uuid)
returns public.join_requests
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_request public.join_requests;
begin
  if v_uid is null then
    raise exception 'club_join: not authenticated' using errcode = '42501';
  end if;
  select * into v_request from public.join_requests r where r.id = p_request_id for update;
  if not found or v_request.user_id <> v_uid then
    raise exception 'club_join: not found' using errcode = 'P0002';
  end if;
  if v_request.status <> 'pending' then
    raise exception 'club_join: not pending' using errcode = 'P0001';
  end if;
  update public.join_requests
     set status = 'cancelled', decided_at = now(), decided_by = v_uid
   where id = p_request_id
  returning * into v_request;
  return v_request;
end;
$$;

-- The club owner approves (with a club role) or rejects a pending request.
-- One transaction: the request row is locked, so two decisions can't race;
-- an already-decided request comes back unchanged (no duplicate member).
create or replace function public.decide_join_request(
  p_request_id uuid,
  p_approve    boolean,
  p_role       text default 'player',
  p_reason     text default null
)
returns public.join_requests
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_request public.join_requests;
  v_role    text := lower(btrim(coalesce(p_role, 'player')));
begin
  if v_uid is null then
    raise exception 'club_join: not authenticated' using errcode = '42501';
  end if;
  select * into v_request from public.join_requests r where r.id = p_request_id for update;
  if not found then
    raise exception 'club_join: not found' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.clubs c where c.id = v_request.club_id and c.owner_id = v_uid) then
    raise exception 'club_join: not allowed' using errcode = '42501';
  end if;
  if v_request.status <> 'pending' then
    return v_request;
  end if;
  if p_approve then
    if v_role not in ('player', 'coach', 'manager') then
      raise exception 'club_join: invalid role' using errcode = '22023';
    end if;
    insert into public.club_members as m (club_id, user_id, member_role, status, joined_at)
    values (v_request.club_id, v_request.user_id, v_role, 'active', now())
    on conflict (club_id, user_id) do update
       set member_role = excluded.member_role,
           status      = 'active',
           joined_at   = now(),
           removed_at  = null,
           removed_by  = null
     where m.member_role <> 'owner';
    update public.join_requests
       set status = 'approved', assigned_role = v_role, decided_at = now(), decided_by = v_uid
     where id = p_request_id
    returning * into v_request;
  else
    update public.join_requests
       set status = 'rejected', decline_reason = nullif(btrim(p_reason), ''),
           decided_at = now(), decided_by = v_uid
     where id = p_request_id
    returning * into v_request;
  end if;
  return v_request;
end;
$$;

-- The club owner removes a member (never the owner row). The person's team
-- places are cleared by migration 12's trigger.
create or replace function public.remove_club_member(p_member_id uuid)
returns public.club_members
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_member public.club_members;
begin
  if v_uid is null then
    raise exception 'club_join: not authenticated' using errcode = '42501';
  end if;
  select * into v_member from public.club_members m where m.id = p_member_id for update;
  if not found then
    raise exception 'club_join: not found' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.clubs c where c.id = v_member.club_id and c.owner_id = v_uid) then
    raise exception 'club_join: not allowed' using errcode = '42501';
  end if;
  if v_member.member_role = 'owner' then
    raise exception 'club_join: not allowed' using errcode = '42501';
  end if;
  if v_member.status = 'removed' then
    return v_member;
  end if;
  update public.club_members
     set status = 'removed', removed_at = now(), removed_by = v_uid
   where id = p_member_id
  returning * into v_member;
  return v_member;
end;
$$;

-- The owner's view of their club's requests, with the applicant's details.
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

-- The caller's active memberships of other people's clubs (their own club is
-- clubs.owner_id). A member may see their club's code.
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

-- The caller's own join requests (newest first), with the club's name.
create or replace function public.my_join_requests()
returns table (
  request_id     uuid,
  club_id        uuid,
  club_name      text,
  club_code      text,
  status         text,
  assigned_role  text,
  decline_reason text,
  created_at     timestamptz,
  decided_at     timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select r.id, c.id, c.name, c.code, r.status, r.assigned_role, r.decline_reason, r.created_at, r.decided_at
    from public.join_requests r
    join public.clubs c on c.id = r.club_id
   where r.user_id = (select auth.uid())
   order by r.created_at desc;
$$;

-- ---------------------------------------------------------------------------
-- 5. Privileges: signed-in users only
-- ---------------------------------------------------------------------------
revoke execute on function public.is_club_owner(uuid) from public, anon;
revoke execute on function public.clubs_add_owner_member() from public, anon, authenticated;
revoke execute on function public.club_code_throttled(uuid) from public, anon, authenticated;
revoke execute on function public.club_code_failed(uuid) from public, anon, authenticated;
revoke execute on function public.lookup_club_by_code(text) from public, anon;
revoke execute on function public.request_to_join_club(text, text) from public, anon;
revoke execute on function public.cancel_join_request(uuid) from public, anon;
revoke execute on function public.decide_join_request(uuid, boolean, text, text) from public, anon;
revoke execute on function public.remove_club_member(uuid) from public, anon;
revoke execute on function public.club_join_requests(uuid) from public, anon;
revoke execute on function public.club_member_list(uuid) from public, anon;
revoke execute on function public.my_club_memberships() from public, anon;
revoke execute on function public.my_join_requests() from public, anon;

grant execute on function public.is_club_owner(uuid) to authenticated;
grant execute on function public.lookup_club_by_code(text) to authenticated;
grant execute on function public.request_to_join_club(text, text) to authenticated;
grant execute on function public.cancel_join_request(uuid) to authenticated;
grant execute on function public.decide_join_request(uuid, boolean, text, text) to authenticated;
grant execute on function public.remove_club_member(uuid) to authenticated;
grant execute on function public.club_join_requests(uuid) to authenticated;
grant execute on function public.club_member_list(uuid) to authenticated;
grant execute on function public.my_club_memberships() to authenticated;
grant execute on function public.my_join_requests() to authenticated;

notify pgrst, 'reload schema';
