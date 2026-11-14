-- CricEco · LOCAL TEST ONLY — user_roles (migration 7): backfill from the
-- fixture of local/06a, triggers (grant / revoke), cascades, create_club, and
-- profiles.role untouched. Rolled back: nothing is kept.
-- Run after local/06a and migration 7, as the database owner.

do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password') then
    raise exception 'LOCAL ONLY: this looks like a real Supabase auth schema';
  end if;
  if to_regclass('s42_fixture.roles_before') is null then
    raise exception 'LOCAL ONLY: run local/06a_user_roles_fixture.sql before migration 7 first';
  end if;
end $$;

begin;

do $$
declare
  uid_player uuid := (select id from auth.users where email = 'player@s42.local.test');
  uid_owner  uuid := (select id from auth.users where email = 'owner@s42.local.test');
  uid_both   uuid := (select id from auth.users where email = 'both@s42.local.test');
  uid_lowner uuid := (select id from auth.users where email = 'legacy-owner@s42.local.test');
  uid_lplay  uuid := (select id from auth.users where email = 'legacy-player@s42.local.test');
  uid_none   uuid := (select id from auth.users where email = 'none@s42.local.test');
  roles text;
begin
  -- R2: backfill from the rows only.
  select string_agg(split_part(u.email, '@', 1) || '=' || coalesce(r.roles, '-'), ' ' order by u.email) into roles
    from auth.users u
    left join (select user_id, string_agg(role::text, '+' order by role) as roles from public.user_roles group by user_id) r
      on r.user_id = u.id
   where u.email like '%@s42.local.test';
  if roles <> 'both=player+club_owner legacy-owner=- legacy-player=- none=- owner=club_owner player=player' then
    raise exception 'FAIL R2: backfill gave %', roles;
  end if;
  if (select count(*) from public.user_roles)
     <> (select count(*) from public.player_profiles) + (select count(*) from public.clubs) then
    raise exception 'FAIL R2: total roles must equal player profiles + clubs';
  end if;
  if exists (select 1 from public.user_roles where granted_by is not null) then
    raise exception 'FAIL R2: backfilled roles are system grants (granted_by NULL)';
  end if;
  if (select granted_at from public.user_roles where user_id = uid_player and role = 'player')
     <> (select created_at from public.player_profiles where user_id = uid_player) then
    raise exception 'FAIL R2: granted_at must come from the source row';
  end if;
  raise notice 'PASSED R2: backfill = rows only (both → 2 roles; legacy owner without club → none)';

  -- R10: profiles.role untouched by migration 7.
  if exists (select 1 from s42_fixture.roles_before b join public.profiles p on p.id = b.id
              where p.role is distinct from b.role)
     or (select count(*) from s42_fixture.roles_before) <> (select count(*) from public.profiles) then
    raise exception 'FAIL R10: migration 7 changed profiles.role';
  end if;
  raise notice 'PASSED R10: profiles.role unchanged for every account';

  -- R5: triggers grant / revoke.
  insert into public.player_profiles (user_id, player_role, batting_style, bowling_style)
  values (uid_none, 'bowler', null, 'left_arm_fast');
  if not exists (select 1 from public.user_roles where user_id = uid_none and role = 'player') then
    raise exception 'FAIL R5: a new player profile must grant player';
  end if;
  delete from public.player_profiles where user_id = uid_player;
  if exists (select 1 from public.user_roles where user_id = uid_player) then
    raise exception 'FAIL R5: deleting the player profile must remove player';
  end if;
  delete from public.clubs where owner_id = uid_owner;
  if exists (select 1 from public.user_roles where user_id = uid_owner) then
    raise exception 'FAIL R5: deleting the club must remove club_owner';
  end if;
  raise notice 'PASSED R5: grant on insert, revoke on delete';

  -- R7: deleting the account cascades (profiles → player_profiles / clubs / user_roles).
  delete from auth.users where id = uid_both;
  if exists (select 1 from public.user_roles where user_id = uid_both) then
    raise exception 'FAIL R7: roles must go with the account';
  end if;
  raise notice 'PASSED R7: account deletion cascades';
end $$;

-- R6: create_club as the signed-in legacy owner (Profile Setup done, no club yet).
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from auth.users where email = 'legacy-owner@s42.local.test'),
                    'role', 'authenticated')::text, true);
set local role authenticated;
do $$
declare
  c1 public.clubs;
  c2 public.clubs;
begin
  if current_user <> 'authenticated' then
    raise exception 'UNSAFE: not running as authenticated';
  end if;
  if exists (select 1 from public.user_roles) then
    raise exception 'FAIL R6: the legacy owner must start without roles';
  end if;
  c1 := public.create_club('S42 Legacy Club', 'Lahore', 'corporate');
  c2 := public.create_club('S42 Legacy Club', 'Lahore', 'corporate');
  if c1.id <> c2.id or array(select role::text from public.user_roles) <> array['club_owner'] then
    raise exception 'FAIL R6: create_club must grant club_owner once (retry: same club, no duplicate)';
  end if;
  if (select role from public.profiles where id = auth.uid()) <> 'club_owner' then
    raise exception 'FAIL R6: profiles.role behaviour changed';
  end if;
  begin
    insert into public.user_roles (user_id, role) values (auth.uid(), 'admin');
    raise exception 'FAIL R4: a user granted themselves admin';
  exception when insufficient_privilege then null;
  end;
  raise notice 'PASSED R6/R4: create_club grants club_owner once; no self-granted roles';
end $$;
reset role;

do $$ begin raise notice 'ALL local/06b_user_roles_local_check CHECKS PASSED (rolling back)'; end $$;

rollback;
