-- CricEco · LOCAL TEST ONLY — the state BEFORE migration 7, for the
-- user_roles backfill check (local/06b). COMMITTED (the backfill must see
-- it). Run after migrations 1–5 and BEFORE migration 7, as the database owner.
-- Refuses to run on a real Supabase project (whose auth.users has an
-- encrypted_password column) or when migration 7 is already applied.
--
-- Accounts (emails *@s42.local.test), as the app could have left them:
--   player       — player profile, profiles.role = player
--   owner        — club, profiles.role = club_owner (set by clubs_set_owner_role)
--   both         — player profile and club, profiles.role = club_owner
--   legacy-owner — profiles.role = club_owner but NO club (pre-Stage-2 data)
--   legacy-player— profiles.role = player but NO player profile
--   none         — nothing, role NULL

do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password') then
    raise exception 'LOCAL ONLY: this looks like a real Supabase auth schema';
  end if;
  if to_regclass('public.user_roles') is not null then
    raise exception 'LOCAL ONLY: run before migration 7';
  end if;
end $$;

begin;

insert into auth.users (email)
select k || '@s42.local.test' from unnest(array['player', 'owner', 'both', 'legacy-owner', 'legacy-player', 'none']) k;

-- Completed Profile Setup for everyone (as the owner: RLS doesn't apply).
-- Addresses first: profile_completed requires both (profiles_validate).
insert into public.current_addresses (user_id, city, area, address)
select id, 'Lahore', 'Gulberg', 'House 1' from auth.users where email like '%@s42.local.test';
insert into public.permanent_addresses (user_id, city, area, address)
select id, 'Lahore', 'Gulberg', 'House 1' from auth.users where email like '%@s42.local.test';
update public.profiles p
   set full_name = 'S42 ' || split_part(u.email, '@', 1), phone = '+92300' || lpad((row_number)::text, 7, '0'),
       date_of_birth = date '1995-01-01', profile_completed = true
  from (select id, email, row_number() over (order by email) from auth.users where email like '%@s42.local.test') u
 where p.id = u.id;

insert into public.player_profiles (user_id, player_role, batting_style, bowling_style)
select id, 'batsman', 'right_handed', null from auth.users
 where email in ('player@s42.local.test', 'both@s42.local.test');
update public.profiles set role = 'player'
 where id in (select id from auth.users where email in ('player@s42.local.test', 'both@s42.local.test',
                                                       'legacy-player@s42.local.test'));
-- Clubs (clubs_set_owner_role turns player / NULL into club_owner).
insert into public.clubs (owner_id, name, city, club_type)
select id, 'S42 Club ' || split_part(email, '@', 1), 'Lahore', 'corporate' from auth.users
 where email in ('owner@s42.local.test', 'both@s42.local.test');
update public.profiles set role = 'club_owner'
 where id = (select id from auth.users where email = 'legacy-owner@s42.local.test');

-- Snapshot of profiles.role, to prove migration 7 leaves it alone.
create schema if not exists s42_fixture;
create table s42_fixture.roles_before as
  select p.id, coalesce(u.email, '(legacy)') as email, p.role from public.profiles p left join auth.users u on u.id = p.id;

commit;

select split_part(u.email, '@', 1) as account, p.role as profiles_role,
       exists (select 1 from public.player_profiles pp where pp.user_id = p.id) as player_profile,
       exists (select 1 from public.clubs c where c.owner_id = p.id) as club
  from public.profiles p join auth.users u on u.id = p.id
 where u.email like '%@s42.local.test'
 order by 1;
