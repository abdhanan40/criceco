-- CricEco · LOCAL TEST ONLY — migration 30 (M4 integrity & security hardening)
-- on a DISPOSABLE database after migrations 1–29 (+ the D1 location seed) and
-- migration 30: either a plain PostgreSQL database with 00_auth_stub.sql and
-- 02_legacy_profiles_fixture.sql, or the "postgres" database of a throwaway
-- container of the real Supabase image (fixture copy without its auth guard).
-- Synthetic data only (people ee900000-…); everything runs in ONE transaction
-- that is ROLLED BACK at the end, so nothing is left behind.
-- Run with psql:  psql -X -v ON_ERROR_STOP=1 -f 25_m4_integrity_hardening_local_check.sql
-- Every check prints "PASS: …"; the first failure stops the run ("FAIL: …").
-- Refuses to run where any auth user has a password (a real project).
\set ON_ERROR_STOP on

begin;

do $$
declare
  v_pw boolean := false;
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password') then
    execute 'select exists (select 1 from auth.users where coalesce(encrypted_password, '''') <> '''')' into v_pw;
  end if;
  if v_pw or exists (select 1 from auth.users where email is null or email not like '%@local.test') then
    raise exception 'LOCAL ONLY: this database has real users — refusing';
  end if;
  if to_regclass('public.push_token_moves') is null then
    raise exception 'apply migration 30 first';
  end if;
end $$;

create schema t25;
grant usage on schema t25 to anon, authenticated, service_role;

create function t25.ok(p_cond boolean, p_name text) returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_name; end if;
  raise notice 'PASS: %', p_name;
end $$;

create function t25.expect_error(p_sql text, p_like text, p_name text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm like p_like or sqlstate like p_like then
      raise notice 'PASS: % [% %]', p_name, sqlstate, sqlerrm;
      return;
    end if;
    raise exception 'FAIL: % — unexpected error [% %]', p_name, sqlstate, sqlerrm;
  end;
  raise exception 'FAIL: % — no error', p_name;
end $$;

-- Runs p_sql; PASS when it succeeds.
create function t25.expect_ok(p_sql text, p_name text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    raise exception 'FAIL: % — error [% %]', p_name, sqlstate, sqlerrm;
  end;
  raise notice 'PASS: %', p_name;
end $$;

-- Both spellings: the image's own auth.uid() reads request.jwt.claim.sub only.
create function t25.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true),
         set_config('request.jwt.claim.sub', p_uid::text, true);
$$;
create function t25.p(p_n int) returns uuid language sql immutable as $$
  select ('ee900000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
$$;
create function t25.tok(p_label text) returns text language sql immutable as $$
  select 'fcm_m4_' || p_label || '_' || repeat('b', 40);
$$;
create function t25.make_person(p_n int, p_completed boolean default true) returns uuid language plpgsql as $$
declare
  v uuid := t25.p(p_n);
begin
  insert into auth.users (id, email) values (v, format('m4p%s@local.test', p_n));
  insert into public.profiles (id) values (v) on conflict (id) do nothing; -- the sign-up trigger made it already
  insert into public.current_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
  insert into public.permanent_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
  update public.profiles
     set full_name = format('M4 Person %s', p_n),
         phone = format('+923%s', lpad((710000000 + p_n)::text, 9, '0')),
         date_of_birth = date '2000-05-01', profile_completed = p_completed
   where id = v;
  return v;
end $$;
create function t25.owner_of(p_token text) returns uuid language sql stable security definer set search_path = '' as $$
  select d.user_id from public.device_tokens d where d.token = p_token;
$$;
create function t25.moves(p_n int) returns int language sql stable security definer set search_path = '' as $$
  select count(*)::int from public.push_token_moves m
   where m.user_id = ('ee900000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
$$;
create function t25.register(p_n int, p_label text) returns void language plpgsql as $$
begin
  perform t25.as_user(t25.p(p_n));
  perform public.register_push_device(t25.tok(p_label), 'android');
end $$;
create function t25.club() returns uuid language sql stable security definer set search_path = '' as $$
  select c.id from public.clubs c where c.name = 'M4 Lions';
$$;
create function t25.mem(p_n int) returns uuid language sql stable security definer set search_path = '' as $$
  select m.id from public.club_members m
   where m.user_id = ('ee900000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid and m.club_id = t25.club();
$$;
create function t25.squad(p_ns int[]) returns jsonb language sql stable as $$
  select coalesce(jsonb_agg(jsonb_build_object('member_id', t25.mem(n), 'selection', 'playing') order by o), '[]')
    from unnest(p_ns) with ordinality u(n, o);
$$;
grant execute on all functions in schema t25 to anon, authenticated, service_role;

-- Synthetic people: 1 club owner (M4 Lions), 2 another owner, 11–13 members,
-- 21–26 push users, 31–36 applicants, 40 an incomplete profile.
select count(*) from (select t25.make_person(n) from unnest(array[1, 2, 11, 12, 13, 21, 22, 23, 24, 25, 26,
                                                                 31, 32, 33, 34, 35, 36]) n) s;
select t25.make_person(40, false);
insert into public.clubs (owner_id, name, city, club_type) values (t25.p(1), 'M4 Lions', 'Lahore', 'corporate');
insert into public.clubs (owner_id, name, city, club_type) values (t25.p(2), 'M4 Kings', 'Lahore', 'corporate');
insert into public.club_members (club_id, user_id, member_role, status)
select t25.club(), t25.p(n), 'player', 'active' from unnest(array[11, 12, 13]) n;

-- ---------------------------------------------------------------------------
-- P. profiles: the field rules, as the signed-in user through the API grants
-- ---------------------------------------------------------------------------
set local role authenticated;
select t25.as_user(t25.p(40));
select t25.expect_error($q$update public.profiles set full_name = 'X' where id = t25.p(40)$q$,
                        '%profiles_full_name_check%', 'P1 a 1-character name is refused');
select t25.expect_error(format('update public.profiles set full_name = %L where id = t25.p(40)', repeat('n', 101)),
                        '%profiles_full_name_check%', 'P2 a 101-character name is refused');
select t25.expect_error($q$update public.profiles set full_name = '   A   ' where id = t25.p(40)$q$,
                        '%profiles_full_name_check%', 'P3 a name that is 1 character once trimmed is refused');
select t25.expect_ok($q$update public.profiles set full_name = 'Al' where id = t25.p(40)$q$, 'P4 a 2-character name is saved');
select t25.expect_ok(format('update public.profiles set full_name = %L where id = t25.p(40)', repeat('n', 100)),
                     'P5 a 100-character name is saved');
select t25.expect_ok($q$update public.profiles set full_name = null where id = t25.p(40)$q$,
                     'P6 no name (NULL) is still allowed on an incomplete profile');
select count(*) from (select t25.expect_ok(format('update public.profiles set phone = %L where id = t25.p(40)', v),
                                            'P7 a stored Pakistani mobile spelling is accepted: ' || v)
                        from unnest(array['03001234567', '0300-1234567', '0300 1234567', '923001234567',
                                          '+923001234567', '+92 300 123-4567']) v) s;
select t25.expect_error($q$update public.profiles set phone = '12345' where id = t25.p(40)$q$,
                        '%profiles_phone_check%', 'P8 a short number is refused');
select t25.expect_error($q$update public.profiles set phone = '+924001234567' where id = t25.p(40)$q$,
                        '%profiles_phone_check%', 'P9 a non-mobile number is refused');
select t25.expect_error($q$update public.profiles set phone = '0300123456' where id = t25.p(40)$q$,
                        '%profiles_phone_check%', 'P10 a mobile number one digit short is refused');
select t25.expect_error($q$update public.profiles set phone = '' where id = t25.p(40)$q$,
                        '%profiles_phone_check%', 'P11 an empty phone is refused (NULL is "no phone")');
select t25.expect_error($q$update public.profiles set phone = '   ' where id = t25.p(40)$q$,
                        '%profiles_phone_check%', 'P12 a blank phone is refused');
select t25.expect_ok($q$update public.profiles set phone = null where id = t25.p(40)$q$,
                     'P13 an incomplete profile may have no phone');
select t25.expect_ok($q$update public.profiles set role = 'player' where id = t25.p(40)$q$, 'P14 role player is saved');
select t25.expect_ok($q$update public.profiles set role = 'club_owner' where id = t25.p(40)$q$, 'P15 role club_owner is saved');
select t25.expect_ok($q$update public.profiles set role = null where id = t25.p(40)$q$, 'P16 no role (NULL) is allowed');
select t25.expect_error($q$update public.profiles set role = 'admin' where id = t25.p(40)$q$,
                        '%profiles_role_check%', 'P17 role admin is refused');
select t25.expect_error($q$update public.profiles set role = 'Player' where id = t25.p(40)$q$,
                        '%profiles_role_check%', 'P18 role matching is exact (Player is refused)');

-- A completed profile keeps its phone.
select t25.as_user(t25.p(11));
select t25.expect_error($q$update public.profiles set phone = null where id = t25.p(11)$q$,
                        'profile_completed requires phone', 'P19 a completed profile cannot drop its phone (direct update)');
select t25.expect_error($q$select public.update_profile_details('M4 Person 11', '', date '2000-05-01', 'Lahore', null,
                                                                'Gulberg', 'Street 1')$q$,
                        'profile_completed requires phone', 'P20 nor clear it in Edit Profile (update_profile_details)');
select t25.expect_ok($q$update public.profiles set phone = '0300-7654321' where id = t25.p(11)$q$,
                     'P21 a completed profile may change its phone to another valid one');
select t25.expect_ok($q$select public.update_profile_details('M4 Person Eleven', '+923007654322', date '2000-05-01',
                                                             'Lahore', null, 'Gulberg', 'Street 1')$q$,
                     'P22 Edit Profile still saves name and phone');
select t25.ok((select full_name = 'M4 Person Eleven' and phone = '+923007654322' and profile_completed
                 from public.profiles where id = t25.p(11)), 'P22b (saved as sent, still completed)');
select t25.expect_error($q$update public.profiles set full_name = 'Q' where id = t25.p(11)$q$,
                        '%profiles_full_name_check%', 'P23 the name rule also holds on a completed profile');
reset role;

-- A legacy completed profile that never had a phone stays editable.
alter table public.profiles disable trigger profiles_validate;
update public.profiles set phone = null where id = t25.p(12);
alter table public.profiles enable trigger profiles_validate;
set local role authenticated;
select t25.as_user(t25.p(12));
select t25.expect_ok($q$update public.profiles set full_name = 'M4 Legacy' where id = t25.p(12)$q$,
                     'P24 a legacy completed profile without a phone can still change its name');
select t25.expect_ok($q$update public.profiles set phone = '03011112222' where id = t25.p(12)$q$,
                     'P25 and can add a phone');
select t25.expect_error($q$update public.profiles set phone = null where id = t25.p(12)$q$,
                        'profile_completed requires phone', 'P26 which it then keeps');
select t25.ok((select count(*) from public.profiles) = 1, 'P27 RLS: a user still sees only their own profile');
reset role;
set local role anon;
select t25.expect_error($q$update public.profiles set full_name = 'Anon' where id = t25.p(40)$q$, '42501',
                        'P28 anon cannot write profiles');
reset role;
select t25.ok(has_table_privilege('authenticated', 'public.profiles', 'SELECT')
              and has_table_privilege('authenticated', 'public.profiles', 'INSERT')
              and has_table_privilege('authenticated', 'public.profiles', 'UPDATE')
              and not has_table_privilege('authenticated', 'public.profiles', 'DELETE,TRUNCATE')
              and not has_table_privilege('anon', 'public.profiles', 'SELECT,INSERT,UPDATE,DELETE'),
              'P29 profiles grants unchanged (authenticated S/I/U, anon none)');
select t25.expect_error($q$insert into public.profiles (id, full_name) values (t25.p(99), 'Z')$q$,
                        '%profiles_full_name_check%', 'P30 the rules apply to inserts too');

-- ---------------------------------------------------------------------------
-- T. teams: optimistic concurrency through save_team
-- ---------------------------------------------------------------------------
create table t25.team (id uuid, version int);
grant all on t25.team to authenticated, anon;
set local role authenticated;
select t25.as_user(t25.p(1));
insert into t25.team select t.id, t.version from public.create_team(t25.club(), 'M4 XI', 't20') t;
select t25.ok((select version = 1 from t25.team), 'T1 a new team starts at version 1');
select t25.ok((select version = 1 from public.teams where id = (select id from t25.team)),
              'T1b the version is readable through the teams select');
select t25.ok((select r.version = 2 and r.name = 'M4 XI Two'
                 from public.save_team((select id from t25.team), 'M4 XI Two', 't20', null, null, null,
                                       t25.squad(array[11, 12])) r),
              'T2 the old 7-argument call (no expected version) still saves, version 1 → 2');
select t25.ok((select r.version = 3
                 from public.save_team((select id from t25.team), 'M4 XI Three', 'custom', 20, t25.mem(11), t25.mem(12),
                                       t25.squad(array[11, 12, 13]), 2) r),
              'T3 a save with the current version (2) succeeds, version → 3');
select t25.expect_error($q$select public.save_team((select id from t25.team), 'M4 Stale', 't20', null, null, null,
                                                   t25.squad(array[11]), 2)$q$,
                        '40001', 'T4 a save with a stale version (2) is refused with 40001');
select t25.expect_error($q$select public.save_team((select id from t25.team), 'M4 Stale', 't20', null, null, null,
                                                   t25.squad(array[11]), 2)$q$,
                        'team: changed elsewhere', 'T4b … and the message ''team: changed elsewhere''');
select t25.ok((select t.version = 3 and t.name = 'M4 XI Three' and t.format = 'custom' and t.custom_overs = 20
                      and t.captain_member_id = t25.mem(11)
                      and (select count(*) from public.team_players tp where tp.team_id = t.id) = 3
                 from public.teams t where t.id = (select id from t25.team)),
              'T5 the refused save changed nothing (details, squad, version)');
select t25.ok((select r.version = 4
                 from public.save_team(p_team_id => (select id from t25.team), p_name => 'M4 XI Four', p_format => 't10',
                                       p_custom_overs => null, p_captain_member_id => null, p_vice_member_id => null,
                                       p_players => t25.squad(array[13]), p_expected_version => 3) r),
              'T6 named arguments with p_expected_version (as PostgREST sends them) work, version → 4');
select t25.expect_error($q$select public.save_team((select id from t25.team), 'M4 XI Five', 't20', null, null, null,
                                                   t25.squad(array[11, 11]), 4)$q$,
                        'team: invalid', 'T7 an invalid squad is refused as before');
select t25.ok((select version = 4 from public.teams where id = (select id from t25.team)),
              'T7b a refused save does not move the version');
select t25.expect_error($q$select public.save_team((select id from t25.team), 'M4 XI Five', 't20', null, null, null,
                                                   t25.squad(array[11]), 99)$q$,
                        '40001', 'T8 a version from the future is also a conflict');
select t25.as_user(t25.p(2));
select t25.expect_error($q$select public.save_team((select id from t25.team), 'Taken', 't20', null, null, null, '[]', 1)$q$,
                        'team: not allowed', 'T9 another club''s owner is refused before any version check');
select t25.as_user(t25.p(1));
select t25.ok((select r.version = 4 and r.status = 'archived' from public.archive_team((select id from t25.team)) r),
              'T10 archive_team leaves the version as it is');
select t25.expect_error($q$select public.save_team((select id from t25.team), 'M4 XI', 't20', null, null, null, '[]', 1)$q$,
                        'team: archived', 'T11 an archived team says archived (not a version conflict)');
reset role;
set local role anon;
select t25.expect_error($q$select public.save_team((select id from t25.team), 'Anon', 't20', null, null, null, '[]', 1)$q$,
                        '%permission denied%', 'T12 anon cannot call save_team');
reset role;
select t25.ok((select count(*) = 1 and bool_and(p.pronargs = 8 and p.pronargdefaults = 1)
                 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'save_team'),
              'T13 exactly one save_team (8 arguments, the last optional)');

-- ---------------------------------------------------------------------------
-- D. push: device moves from other people, at most 3 per caller in 24 hours
-- ---------------------------------------------------------------------------
set local role authenticated;
select t25.register(21, 'a1');
select t25.ok(t25.owner_of(t25.tok('a1')) = t25.p(21) and t25.moves(21) = 0, 'D1 a brand-new token registers (no move)');
select t25.register(21, 'a1'); select t25.register(21, 'a1'); select t25.register(21, 'a1');
select t25.register(21, 'a1'); select t25.register(21, 'a1');
select t25.ok(t25.owner_of(t25.tok('a1')) = t25.p(21) and t25.moves(21) = 0,
              'D2 re-registering one''s own token is never limited (6 times, no move)');
select t25.register(21, 'a2'); select t25.register(21, 'a3'); select t25.register(21, 'a4');
select t25.register(22, 'a1');
select t25.register(22, 'a2');
select t25.register(22, 'a3');
select t25.ok(t25.owner_of(t25.tok('a1')) = t25.p(22) and t25.owner_of(t25.tok('a3')) = t25.p(22) and t25.moves(22) = 3,
              'D3 3 tokens taken over from another person are moved (3 moves recorded)');
select t25.as_user(t25.p(22));
select t25.expect_error(format('select public.register_push_device(%L)', t25.tok('a4')), 'P0001',
                        'D4 the 4th takeover within 24 hours is refused (P0001)');
select t25.expect_error(format('select public.register_push_device(%L)', t25.tok('a4')), 'push: too many device moves',
                        'D4b … with ''push: too many device moves''');
select t25.ok(t25.owner_of(t25.tok('a4')) = t25.p(21) and t25.moves(22) = 3,
              'D5 the refused move changed nothing (token kept by its owner, no move recorded)');
select t25.register(22, 'b1');
select t25.ok(t25.owner_of(t25.tok('b1')) = t25.p(22), 'D6 a brand-new token is still accepted after the limit');
select t25.register(22, 'a1'); select t25.register(22, 'a2');
select t25.ok(t25.owner_of(t25.tok('a1')) = t25.p(22) and t25.moves(22) = 3,
              'D7 re-registering tokens already moved to the caller is not a move');
select t25.register(21, 'a1');
select t25.ok(t25.owner_of(t25.tok('a1')) = t25.p(21) and t25.moves(21) = 1,
              'D8 the original owner can take a token back (their own first move)');
reset role;
-- Moves older than 24 hours no longer count (and are pruned).
insert into public.push_token_moves (user_id, moved_at)
select t25.p(23), now() - interval '25 hours' from generate_series(1, 3);
insert into public.push_token_moves (user_id, moved_at)
select t25.p(24), now() - interval '23 hours' from generate_series(1, 3);
set local role authenticated;
select t25.register(23, 'a4');
select t25.ok(t25.owner_of(t25.tok('a4')) = t25.p(23) and t25.moves(23) = 1,
              'D9 3 moves 25 hours ago do not count; the old rows are removed');
select t25.as_user(t25.p(24));
select t25.expect_error(format('select public.register_push_device(%L)', t25.tok('a4')), 'push: too many device moves',
                        'D10 3 moves 23 hours ago still count');
select t25.expect_error('select count(*) from public.push_token_moves', '%permission denied%',
                        'D11 a user cannot read push_token_moves (not even their own)');
select t25.expect_error($q$insert into public.push_token_moves (user_id) values (t25.p(24))$q$, '%permission denied%',
                        'D11b nor write it');
reset role;
set local role service_role;
select t25.expect_error('select count(*) from public.push_token_moves', '%permission denied%',
                        'D12 service_role cannot read it either');
select t25.expect_error(format('select public.register_push_device(%L)', t25.tok('sr')), '%permission denied%',
                        'D12b nor register devices');
reset role;
set local role anon;
select t25.expect_error(format('select public.register_push_device(%L)', t25.tok('x')), '%permission denied%',
                        'D13 anon cannot register a device');
reset role;
delete from auth.users where id = t25.p(22);
select t25.ok(t25.moves(22) = 0, 'D14 deleting the account removes its moves (cascade)');

-- ---------------------------------------------------------------------------
-- J. club_join_requests: declined requests older than 30 days are hidden
-- ---------------------------------------------------------------------------
insert into public.join_requests (club_id, user_id, status, assigned_role, decline_reason, decided_at, decided_by, created_at)
values (t25.club(), t25.p(31), 'pending',  null,     null,      null,                                     null,     now() - interval '60 days'),
       (t25.club(), t25.p(32), 'approved', 'player', null,      now() - interval '40 days',               t25.p(1), now() - interval '41 days'),
       (t25.club(), t25.p(33), 'rejected', null,     'Full',    now() - interval '10 days',               t25.p(1), now() - interval '11 days'),
       (t25.club(), t25.p(34), 'rejected', null,     null,      now() - interval '30 days' + interval '1 minute', t25.p(1), now() - interval '31 days'),
       (t25.club(), t25.p(35), 'rejected', null,     'Old',     now() - interval '31 days',               t25.p(1), now() - interval '32 days'),
       (t25.club(), t25.p(36), 'cancelled', null,    null,      now() - interval '1 day',                 null,     now() - interval '2 days');
set local role authenticated;
select t25.as_user(t25.p(1));
select t25.ok((select string_agg(r.full_name, ',' order by r.full_name) from public.club_join_requests(t25.club()) r)
              = 'M4 Person 31,M4 Person 32,M4 Person 33,M4 Person 34',
              'J1 pending (60 days), approved (40 days), declined 10 days and just under 30 days ago are shown');
select t25.ok(not exists (select 1 from public.club_join_requests(t25.club()) r where r.full_name = 'M4 Person 35'),
              'J2 a request declined 31 days ago is hidden');
select t25.ok(pg_get_function_result('public.club_join_requests(uuid)'::regprocedure)
              = 'TABLE(request_id uuid, status text, message text, assigned_role text, decline_reason text, created_at timestamp with time zone, decided_at timestamp with time zone, full_name text, phone text, applicant_age integer, city text, player_role text, batting_style text, bowling_style text, is_wicketkeeper boolean)',
              'J3 the result columns are unchanged');
select t25.as_user(t25.p(2));
select t25.expect_error('select * from public.club_join_requests(t25.club())', 'club_join: not allowed',
                        'J4 another owner is refused');
reset role;
set local role anon;
select t25.expect_error('select * from public.club_join_requests(t25.club())', '%permission denied%',
                        'J5 anon cannot call club_join_requests');
reset role;

-- ---------------------------------------------------------------------------
-- K. keys and indexes
-- ---------------------------------------------------------------------------
select t25.ok(pg_get_indexdef(to_regclass('public.club_ownership_transfers_to_user_id_idx'))
              = 'CREATE INDEX club_ownership_transfers_to_user_id_idx ON public.club_ownership_transfers USING btree (to_user_id)',
              'K1 club_ownership_transfers has a full index on to_user_id');
select t25.ok(exists (select 1 from pg_constraint k where k.conrelid = 'public.account_deletion_attempts'::regclass
                         and k.contype = 'p' and pg_get_constraintdef(k.oid) = 'PRIMARY KEY (id)'),
              'K2 account_deletion_attempts has a primary key (id)');
set local role service_role;
select public.account_deletion_failed(t25.p(13));
select public.account_deletion_failed(t25.p(13));
select t25.ok(not public.account_deletion_throttled(t25.p(13)), 'K3 the deletion throttle still works (2 attempts, not throttled)');
reset role;
select t25.ok((select count(*) = 2 and count(distinct id) = 2 and bool_and(id is not null)
                 from public.account_deletion_attempts where user_id = t25.p(13)),
              'K4 each attempt gets its own id');
set local role authenticated;
select t25.as_user(t25.p(13));
select t25.expect_error('select count(*) from public.account_deletion_attempts', '%permission denied%',
                        'K5 a user still cannot read account_deletion_attempts');
reset role;
select t25.ok(not has_sequence_privilege('anon', 'public.account_deletion_attempts_id_seq', 'USAGE,SELECT,UPDATE')
              and not has_sequence_privilege('authenticated', 'public.account_deletion_attempts_id_seq', 'USAGE,SELECT,UPDATE')
              and not has_sequence_privilege('authenticated', 'public.push_token_moves_id_seq', 'USAGE,SELECT,UPDATE'),
              'K6 the new identity sequences are closed');
select t25.ok(not has_function_privilege('anon', 'public.save_team(uuid, text, text, integer, uuid, uuid, jsonb, integer)', 'execute')
              and has_function_privilege('authenticated', 'public.save_team(uuid, text, text, integer, uuid, uuid, jsonb, integer)', 'execute')
              and has_function_privilege('authenticated', 'public.register_push_device(text, text)', 'execute')
              and not has_function_privilege('service_role', 'public.register_push_device(text, text)', 'execute')
              and has_function_privilege('authenticated', 'public.club_join_requests(uuid)', 'execute')
              and not has_function_privilege('anon', 'public.club_join_requests(uuid)', 'execute'),
              'K7 function grants as intended');

rollback;
\echo 'local check 25: all checks passed; everything rolled back'
