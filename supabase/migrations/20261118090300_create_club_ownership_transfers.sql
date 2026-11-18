-- CricEco · migration 16 · club ownership transfer (offer → accept)
--
-- NOT APPLIED. Requires migrations 11–12 (memberships, teams). Independent of
-- 13–15, but deployed with them: account deletion (migration 15) needs a way
-- for an owner to hand the club over first. Review first; apply only with
-- separate approval, after a fresh backup, inside
--   begin; set local lock_timeout = '5s'; <this file> commit;
-- Rollback: supabase/rollback/20261118_rollback_club_ownership_transfers.sql.
-- Read-only check: supabase/tests/16_ownership_transfer_postcheck.sql.
--
-- Rules:
--   * Only the club's CURRENT owner offers the club, to an ACTIVE member of
--     that club who isn't the owner, owns no club (one club per owner) and has
--     a completed profile (the same conditions as creating a club).
--   * Nothing changes until the recipient ACCEPTS. The owner can cancel, the
--     recipient can decline; an offer expires after 7 days (marked lazily).
--   * One pending offer per club (unique partial index).
--   * Acceptance is one transaction, under row locks (both profiles in id
--     order — the order migration 15's delete_account_data uses — then the
--     club, then the membership): the old owner's membership becomes the role
--     they chose (manager by default), the recipient's becomes owner,
--     clubs.owner_id / owner_name move, user_roles follow. Every owner
--     permission (is_club_owner, RLS, the owner functions) reads
--     clubs.owner_id, so it moves with it. Members, requests, teams, squads,
--     captains: untouched (their ids don't change).
--   * club_ownership_transfers is the history (who, to whom, status, when).
--     RLS: SELECT for the club's current owner and the two people involved;
--     no direct writes for anyone — only the functions below.
-- All functions: SECURITY DEFINER, empty search_path, auth.uid() checks,
-- executable by authenticated only (never anon).

do $$
begin
  if to_regclass('public.club_members') is null or to_regprocedure('public.is_club_owner(uuid)') is null
     or to_regclass('public.teams') is null then
    raise exception 'migration 16: migrations 11 and 12 are required';
  end if;
  if to_regclass('public.club_ownership_transfers') is not null
     or exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'public'
                   and p.proname in ('offer_club_ownership', 'accept_ownership_transfer', 'reject_ownership_transfer',
                                     'cancel_ownership_transfer', 'club_ownership_transfers', 'my_ownership_offers')) then
    raise exception 'migration 16: already applied — nothing changed';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Offers and their history
-- ---------------------------------------------------------------------------
create table public.club_ownership_transfers (
  id                   uuid primary key default gen_random_uuid(),
  club_id              uuid not null
                       constraint club_ownership_transfers_club_id_fkey references public.clubs (id) on delete cascade,
  from_user_id         uuid
                       constraint club_ownership_transfers_from_user_id_fkey references public.profiles (id) on delete set null,
  to_user_id           uuid
                       constraint club_ownership_transfers_to_user_id_fkey references public.profiles (id) on delete set null,
  to_member_id         uuid
                       constraint club_ownership_transfers_to_member_id_fkey references public.club_members (id) on delete set null,
  previous_owner_role  text not null default 'manager'
                       constraint club_ownership_transfers_previous_owner_role_check
                       check (previous_owner_role in ('player', 'coach', 'manager')),
  status               text not null default 'pending'
                       constraint club_ownership_transfers_status_check
                       check (status in ('pending', 'accepted', 'rejected', 'cancelled', 'expired')),
  created_at           timestamptz not null default now(),
  expires_at           timestamptz not null default now() + interval '7 days',
  decided_at           timestamptz,
  constraint club_ownership_transfers_decided_consistency check ((status = 'pending') = (decided_at is null)),
  constraint club_ownership_transfers_not_self
    check (from_user_id is null or to_user_id is null or from_user_id <> to_user_id),
  constraint club_ownership_transfers_expiry_after_creation check (expires_at > created_at)
);

comment on table public.club_ownership_transfers is
  'Club ownership offers and their history. Written only by the ownership functions (migration 16).';

create unique index club_ownership_transfers_one_pending_key
  on public.club_ownership_transfers (club_id) where status = 'pending';
create index club_ownership_transfers_club_created_idx on public.club_ownership_transfers (club_id, created_at desc);
create index club_ownership_transfers_to_user_pending_idx
  on public.club_ownership_transfers (to_user_id) where status = 'pending';
create index club_ownership_transfers_from_user_id_idx on public.club_ownership_transfers (from_user_id);
create index club_ownership_transfers_to_member_id_idx on public.club_ownership_transfers (to_member_id);

alter table public.club_ownership_transfers enable row level security;

create policy "club_ownership_transfers: select involved or owner"
  on public.club_ownership_transfers for select to authenticated
  using (from_user_id = (select auth.uid()) or to_user_id = (select auth.uid()) or public.is_club_owner(club_id));

revoke all on table public.club_ownership_transfers from public, anon, authenticated;
grant select on table public.club_ownership_transfers to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Eligibility (internal): an active member of the club, not its owner,
--    owning no club, with a completed profile.
-- ---------------------------------------------------------------------------
create or replace function public.ownership_recipient_problem(p_club_id uuid, p_member public.club_members)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
begin
  select owner_id into v_owner from public.clubs where id = p_club_id;
  if p_member.id is null or p_member.club_id <> p_club_id or p_member.status <> 'active' then
    return 'not a member';
  end if;
  if p_member.user_id = v_owner then
    return 'self transfer';
  end if;
  if exists (select 1 from public.clubs where owner_id = p_member.user_id) then
    return 'recipient owns a club';
  end if;
  if not exists (select 1 from public.profiles p
                  where p.id = p_member.user_id and p.profile_completed is true and p.date_of_birth is not null)
     or not exists (select 1 from public.current_addresses where user_id = p_member.user_id)
     or not exists (select 1 from public.permanent_addresses where user_id = p_member.user_id) then
    return 'recipient profile incomplete';
  end if;
  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Offer (owner), cancel (owner), decline (recipient), accept (recipient)
-- ---------------------------------------------------------------------------
create or replace function public.offer_club_ownership(
  p_club_id              uuid,
  p_member_id            uuid,
  p_previous_owner_role  text default 'manager'
)
returns public.club_ownership_transfers
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_club    public.clubs;
  v_member  public.club_members;
  v_role    text := lower(btrim(coalesce(p_previous_owner_role, 'manager')));
  v_problem text;
  v_row     public.club_ownership_transfers;
begin
  if v_uid is null then
    raise exception 'ownership: not authenticated' using errcode = '42501';
  end if;
  select * into v_club from public.clubs where id = p_club_id for update;
  if not found then
    raise exception 'ownership: club not found' using errcode = 'P0002';
  end if;
  if v_club.owner_id <> v_uid then
    raise exception 'ownership: not allowed' using errcode = '42501';
  end if;
  if v_role not in ('player', 'coach', 'manager') then
    raise exception 'ownership: invalid' using errcode = '22023';
  end if;

  -- Offers past their expiry no longer count.
  update public.club_ownership_transfers
     set status = 'expired', decided_at = now()
   where club_id = p_club_id and status = 'pending' and expires_at <= now();

  select * into v_member from public.club_members where id = p_member_id for update;
  v_problem := public.ownership_recipient_problem(p_club_id, v_member);
  if v_problem is not null then
    raise exception 'ownership: %', v_problem
      using errcode = case v_problem when 'not a member' then '23514' when 'self transfer' then '22023' else 'P0001' end;
  end if;

  begin
    insert into public.club_ownership_transfers (club_id, from_user_id, to_user_id, to_member_id, previous_owner_role)
    values (p_club_id, v_uid, v_member.user_id, v_member.id, v_role)
    returning * into v_row;
  exception
    when unique_violation then
      raise exception 'ownership: already pending' using errcode = '23505';
  end;
  return v_row;
end;
$$;

create or replace function public.cancel_ownership_transfer(p_transfer_id uuid)
returns public.club_ownership_transfers
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_row public.club_ownership_transfers;
begin
  if v_uid is null then
    raise exception 'ownership: not authenticated' using errcode = '42501';
  end if;
  select * into v_row from public.club_ownership_transfers where id = p_transfer_id for update;
  if not found then
    raise exception 'ownership: not found' using errcode = 'P0002';
  end if;
  if v_row.from_user_id is distinct from v_uid
     or not exists (select 1 from public.clubs where id = v_row.club_id and owner_id = v_uid) then
    raise exception 'ownership: not allowed' using errcode = '42501';
  end if;
  if v_row.status <> 'pending' then
    raise exception 'ownership: not pending' using errcode = 'P0001';
  end if;
  update public.club_ownership_transfers
     set status = case when expires_at <= now() then 'expired' else 'cancelled' end, decided_at = now()
   where id = p_transfer_id
  returning * into v_row;
  return v_row;
end;
$$;

create or replace function public.reject_ownership_transfer(p_transfer_id uuid)
returns public.club_ownership_transfers
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_row public.club_ownership_transfers;
begin
  if v_uid is null then
    raise exception 'ownership: not authenticated' using errcode = '42501';
  end if;
  select * into v_row from public.club_ownership_transfers where id = p_transfer_id for update;
  if not found then
    raise exception 'ownership: not found' using errcode = 'P0002';
  end if;
  if v_row.to_user_id is distinct from v_uid then
    raise exception 'ownership: not allowed' using errcode = '42501';
  end if;
  if v_row.status <> 'pending' then
    raise exception 'ownership: not pending' using errcode = 'P0001';
  end if;
  update public.club_ownership_transfers
     set status = case when expires_at <= now() then 'expired' else 'rejected' end, decided_at = now()
   where id = p_transfer_id
  returning * into v_row;
  return v_row;
end;
$$;

-- Accept: the only place ownership changes. Returns the offer: status
-- 'accepted', or 'expired' when it ran out (nothing else changes then).
create or replace function public.accept_ownership_transfer(p_transfer_id uuid)
returns public.club_ownership_transfers
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_row     public.club_ownership_transfers;
  v_club    public.clubs;
  v_member  public.club_members;
  v_problem text;
  v_name    text;
begin
  if v_uid is null then
    raise exception 'ownership: not authenticated' using errcode = '42501';
  end if;
  select * into v_row from public.club_ownership_transfers where id = p_transfer_id;
  if not found then
    raise exception 'ownership: not found' using errcode = 'P0002';
  end if;
  if v_row.to_user_id is distinct from v_uid then
    raise exception 'ownership: not allowed' using errcode = '42501';
  end if;

  -- Locks, profiles first (by id, as account deletion — migration 15 — locks
  -- a profile first), then the offer, the club and the recipient's membership:
  -- one order everywhere, so no deadlock with a concurrent deletion.
  perform 1 from public.profiles where id in (v_row.from_user_id, v_row.to_user_id) order by id for update;
  select * into v_row from public.club_ownership_transfers where id = p_transfer_id for update;
  if v_row.to_user_id is distinct from v_uid then
    raise exception 'ownership: not allowed' using errcode = '42501';
  end if;
  if v_row.status <> 'pending' then
    raise exception 'ownership: not pending' using errcode = 'P0001';
  end if;
  if v_row.expires_at <= now() then
    update public.club_ownership_transfers set status = 'expired', decided_at = now()
     where id = p_transfer_id returning * into v_row;
    return v_row;
  end if;

  select * into v_club from public.clubs where id = v_row.club_id for update;
  if not found then
    raise exception 'ownership: club not found' using errcode = 'P0002';
  end if;
  if v_club.owner_id is distinct from v_row.from_user_id then
    raise exception 'ownership: no longer valid' using errcode = 'P0001';
  end if;
  select * into v_member from public.club_members where id = v_row.to_member_id for update;
  if v_member.user_id is distinct from v_uid then
    raise exception 'ownership: not a member' using errcode = '23514';
  end if;
  v_problem := public.ownership_recipient_problem(v_club.id, v_member);
  if v_problem is not null then
    raise exception 'ownership: %', v_problem
      using errcode = case v_problem when 'not a member' then '23514' else 'P0001' end;
  end if;

  -- Memberships: the old owner first (one owner per club), then the new one.
  update public.club_members
     set member_role = v_row.previous_owner_role
   where club_id = v_club.id and user_id = v_row.from_user_id and member_role = 'owner';
  update public.club_members set member_role = 'owner' where id = v_member.id;

  -- The club itself, and with it every owner permission.
  select btrim(full_name) into v_name from public.profiles where id = v_uid;
  update public.clubs
     set owner_id = v_uid,
         owner_name = case when char_length(coalesce(v_name, '')) between 2 and 100 then v_name else null end
   where id = v_club.id;

  -- Roles (informational): the new owner gains club_owner, the old one loses it.
  insert into public.user_roles (user_id, role) values (v_uid, 'club_owner') on conflict (user_id, role) do nothing;
  delete from public.user_roles
   where user_id = v_row.from_user_id and role = 'club_owner'
     and not exists (select 1 from public.clubs where owner_id = v_row.from_user_id);

  update public.club_ownership_transfers set status = 'accepted', decided_at = now()
   where id = p_transfer_id returning * into v_row;
  return v_row;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Reads
-- ---------------------------------------------------------------------------
-- A club's offers, newest first: for its current owner (all) and for the two
-- people of each offer (their own). Status 'expired' when a pending offer ran out.
create or replace function public.club_ownership_transfers(p_club_id uuid)
returns table (
  transfer_id          uuid,
  club_id              uuid,
  club_name            text,
  status               text,
  previous_owner_role  text,
  to_member_id         uuid,
  from_name            text,
  to_name              text,
  from_me              boolean,
  created_at           timestamptz,
  expires_at           timestamptz,
  decided_at           timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'ownership: not authenticated' using errcode = '42501';
  end if;
  return query
    select t.id, t.club_id, c.name,
           case when t.status = 'pending' and t.expires_at <= now() then 'expired' else t.status end,
           t.previous_owner_role, t.to_member_id, pf.full_name, pt.full_name, coalesce(t.from_user_id = auth.uid(), false),
           t.created_at, t.expires_at, t.decided_at
      from public.club_ownership_transfers t
      join public.clubs c on c.id = t.club_id
      left join public.profiles pf on pf.id = t.from_user_id
      left join public.profiles pt on pt.id = t.to_user_id
     where t.club_id = p_club_id
       and (c.owner_id = auth.uid() or t.from_user_id = auth.uid() or t.to_user_id = auth.uid())
     order by t.created_at desc;
end;
$$;

-- The caller's open offers (pending, not expired), newest first.
create or replace function public.my_ownership_offers()
returns table (
  transfer_id          uuid,
  club_id              uuid,
  club_name            text,
  status               text,
  previous_owner_role  text,
  to_member_id         uuid,
  from_name            text,
  to_name              text,
  from_me              boolean,
  created_at           timestamptz,
  expires_at           timestamptz,
  decided_at           timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select t.id, t.club_id, c.name, t.status, t.previous_owner_role, t.to_member_id, pf.full_name, pt.full_name,
         false, t.created_at, t.expires_at, t.decided_at
    from public.club_ownership_transfers t
    join public.clubs c on c.id = t.club_id
    left join public.profiles pf on pf.id = t.from_user_id
    left join public.profiles pt on pt.id = t.to_user_id
   where t.to_user_id = (select auth.uid())
     and t.status = 'pending'
     and t.expires_at > now()
   order by t.created_at desc;
$$;

-- ---------------------------------------------------------------------------
-- 5. Privileges
-- ---------------------------------------------------------------------------
revoke execute on function public.ownership_recipient_problem(uuid, public.club_members) from public, anon, authenticated;
revoke execute on function public.offer_club_ownership(uuid, uuid, text) from public, anon;
revoke execute on function public.cancel_ownership_transfer(uuid) from public, anon;
revoke execute on function public.reject_ownership_transfer(uuid) from public, anon;
revoke execute on function public.accept_ownership_transfer(uuid) from public, anon;
revoke execute on function public.club_ownership_transfers(uuid) from public, anon;
revoke execute on function public.my_ownership_offers() from public, anon;

grant execute on function public.offer_club_ownership(uuid, uuid, text) to authenticated;
grant execute on function public.cancel_ownership_transfer(uuid) to authenticated;
grant execute on function public.reject_ownership_transfer(uuid) to authenticated;
grant execute on function public.accept_ownership_transfer(uuid) to authenticated;
grant execute on function public.club_ownership_transfers(uuid) to authenticated;
grant execute on function public.my_ownership_offers() to authenticated;

notify pgrst, 'reload schema';
