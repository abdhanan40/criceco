-- CricEco · LOCAL TEST ONLY — migration 33 (M8 Player Hunt / Playing
-- Opportunities) on a DISPOSABLE database after migrations 1–31 (+ the D1
-- location seed and the Storage stand-in of 26_m5_m6_media_local_check.sh)
-- and migration 33: the "postgres" database of a throwaway container of the
-- real Supabase image (fixture copy without its auth guard), or a plain
-- PostgreSQL database with 00_auth_stub.sql and 02_legacy_profiles_fixture.sql.
-- Synthetic data only (people ee930000-…); everything runs in ONE
-- transaction that is ROLLED BACK at the end, so nothing is left behind.
-- Run with psql:  psql -X -v ON_ERROR_STOP=1 -f 28_m8_player_hunt_local_check.sql
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
  if to_regclass('public.hunt_posts') is null then
    raise exception 'apply migration 33 first';
  end if;
end $$;

create schema t28;
grant usage on schema t28 to anon, authenticated, service_role;

create function t28.ok(p_cond boolean, p_name text) returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAIL: %', p_name; end if;
  raise notice 'PASS: %', p_name;
end $$;

-- PASS when p_sql fails with exactly SQLSTATE p_state and a message LIKE p_like.
create function t28.err(p_sql text, p_state text, p_like text, p_name text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlstate = p_state and sqlerrm like p_like then
      raise notice 'PASS: % [% %]', p_name, sqlstate, sqlerrm;
      return;
    end if;
    raise exception 'FAIL: % — unexpected error [% %]', p_name, sqlstate, sqlerrm;
  end;
  raise exception 'FAIL: % — no error', p_name;
end $$;

create function t28.okq(p_sql text, p_name text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    raise exception 'FAIL: % — error [% %]', p_name, sqlstate, sqlerrm;
  end;
  raise notice 'PASS: %', p_name;
end $$;

-- Both spellings: the image's own auth.uid() reads request.jwt.claim.sub only.
create function t28.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true),
         set_config('request.jwt.claim.sub', p_uid::text, true);
$$;
create function t28.as_nobody() returns void language sql as $$
  select set_config('request.jwt.claims', '', true), set_config('request.jwt.claim.sub', '', true);
$$;
create function t28.p(p_n int) returns uuid language sql immutable as $$
  select ('ee930000-0000-4000-8000-' || lpad(p_n::text, 12, '0'))::uuid;
$$;
-- Named ids (posts, invites) kept across role switches.
create table t28.ids (k text primary key, v uuid not null);
create function t28.put(p_k text, p_v uuid) returns uuid language sql security definer set search_path = '' as $$
  insert into t28.ids (k, v) values (p_k, p_v) on conflict (k) do update set v = excluded.v returning v;
$$;
create function t28.id(p_k text) returns uuid language sql stable security definer set search_path = '' as $$
  select v from t28.ids where k = p_k;
$$;
create function t28.club(p_name text) returns uuid language sql stable security definer set search_path = '' as $$
  select c.id from public.clubs c where c.name = p_name;
$$;
-- Notifications (read as the test owner, whatever role is active).
create function t28.notes(p_recipient uuid, p_type text) returns int language sql stable security definer set search_path = '' as $$
  select count(*)::int from public.notifications n where n.recipient_id = p_recipient and n.type = p_type;
$$;
create function t28.note(p_recipient uuid, p_type text) returns public.notifications
language sql stable security definer set search_path = '' as $$
  select n.* from public.notifications n where n.recipient_id = p_recipient and n.type = p_type
   order by n.created_at desc limit 1;
$$;
create function t28.count_sql(p_sql text) returns int language plpgsql as $$
declare
  n int;
begin
  execute 'select count(*) from (' || p_sql || ') s' into n;
  return n;
end $$;
create function t28.make_person(p_n int, p_city text default 'Lahore') returns uuid language plpgsql as $$
declare
  v uuid := t28.p(p_n);
begin
  insert into auth.users (id, email) values (v, format('m8p%s@local.test', p_n));
  insert into public.profiles (id) values (v) on conflict (id) do nothing; -- the sign-up trigger made it already
  if p_city is not null then
    insert into public.current_addresses (user_id, city, area, address) values (v, p_city, 'Gulberg', 'Street 1');
    insert into public.permanent_addresses (user_id, city, area, address) values (v, p_city, 'Gulberg', 'Street 1');
  end if;
  update public.profiles
     set full_name = format('M8 Person %s', p_n),
         phone = format('+923%s', lpad((730000000 + p_n)::text, 9, '0')),
         date_of_birth = date '2000-05-01', profile_completed = (p_city is not null)
   where id = v;
  return v;
end $$;
create function t28.batsman(p_n int, p_keeper boolean default false) returns void language sql as $$
  insert into public.player_profiles (user_id, player_role, batting_style, bowling_style, is_wicketkeeper)
  values (t28.p(p_n), 'batsman', 'right_handed', null, p_keeper);
$$;
create function t28.bowler(p_n int) returns void language sql as $$
  insert into public.player_profiles (user_id, player_role, batting_style, bowling_style, is_wicketkeeper)
  values (t28.p(p_n), 'bowler', null, 'right_arm_fast', false);
$$;
grant select on t28.ids to anon, authenticated, service_role;
grant execute on all functions in schema t28 to anon, authenticated, service_role;

-- People: 1 owns "M8 Lions" (no cricket profile), 2 owns "M8 Kings" (bowler,
-- mutes join requests), 3 batsman (shares phone), 4 batsman with a private
-- profile, 5 bowler (hides stats, phone not shared), 6 no cricket profile,
-- 7 batsman member of Lions, 9 signed in without a profile row, 10
-- wicket-keeper without an address, 11 owns "M8 Bulk", 12 batsman never
-- listed.
select count(*) from (select t28.make_person(n) from unnest(array[1, 2, 3, 4, 5, 6, 7, 11, 12]) n) s;
select t28.make_person(10, null);
insert into auth.users (id, email) values (t28.p(9), 'm8p9@local.test');
delete from public.profiles where id = t28.p(9);
select t28.bowler(2);
select t28.batsman(3);
select t28.batsman(4);
select t28.bowler(5);
select t28.batsman(7);
select t28.batsman(10, true);
select t28.batsman(12);
update public.profiles set share_phone_with_clubs = true where id = t28.p(3);
update public.profiles set public_profile = false where id = t28.p(4);
update public.profiles set show_stats = false where id = t28.p(5);
insert into public.clubs (owner_id, name, city, club_type) values (t28.p(1), 'M8 Lions', 'Lahore', 'corporate');
insert into public.clubs (owner_id, name, city, club_type) values (t28.p(2), 'M8 Kings', 'Karachi', 'corporate');
insert into public.clubs (owner_id, name, city, club_type) values (t28.p(11), 'M8 Bulk', 'Multan', 'corporate');
insert into public.club_members (club_id, user_id, member_role, status)
values (t28.club('M8 Lions'), t28.p(7), 'player', 'active');
insert into public.notification_preferences (user_id, join_requests, challenges, matches, results, announcements)
values (t28.p(2), false, true, true, true, true);

-- ---------------------------------------------------------------------------
-- B. Access
-- ---------------------------------------------------------------------------
select t28.ok((select bool_and(has_function_privilege('authenticated', f::regprocedure, 'execute')
                               and not has_function_privilege('anon', f::regprocedure, 'execute'))
                 from unnest(array['public.my_hunt_listing()', 'public.set_my_hunt_listing(boolean, text, text)',
                                   'public.publish_hunt_post(uuid, text, text, integer, text, date, text, text, text)',
                                   'public.close_hunt_post(uuid)', 'public.club_hunt_posts(uuid)',
                                   'public.hunt_open_posts(text, text)', 'public.express_hunt_interest(uuid)',
                                   'public.withdraw_hunt_interest(uuid)', 'public.club_hunt_interests(uuid, uuid)',
                                   'public.hunt_open_players(text, text)', 'public.invite_hunt_player(uuid, uuid, uuid)',
                                   'public.club_hunt_invites(uuid)', 'public.my_hunt_invites()',
                                   'public.respond_hunt_invite(uuid, boolean)']) f),
              'B1 the 14 functions: authenticated may execute, anon may not');
select t28.ok(not (select bool_or(has_function_privilege(r, f::regprocedure, 'execute'))
                     from unnest(array['public.hunt_role_of(uuid)', 'public.hunt_player_stats(uuid)',
                                       'public.hunt_post_list(uuid, uuid, uuid, boolean, text, text)']) f,
                          unnest(array['anon', 'authenticated', 'service_role']) r),
              'B2 the 3 helpers: no API role may execute');
select t28.ok(not (select bool_or(has_table_privilege(r, t::regclass, 'SELECT,INSERT,UPDATE,DELETE'))
                     from unnest(array['public.hunt_listings', 'public.hunt_posts', 'public.hunt_interests',
                                       'public.hunt_invites']) t,
                          unnest(array['anon', 'authenticated', 'service_role']) r)
              and (select bool_and(c.relrowsecurity) from pg_class c
                    where c.oid in ('public.hunt_listings'::regclass, 'public.hunt_posts'::regclass,
                                    'public.hunt_interests'::regclass, 'public.hunt_invites'::regclass)),
              'B3 the 4 tables: RLS on, no table privilege for anon / authenticated / service_role');

set local role authenticated;
select t28.as_user(t28.p(3));
select t28.err('select * from public.hunt_posts', '42501', '%permission denied%', 'B4 a signed-in user cannot read hunt_posts directly');
select t28.err('insert into public.hunt_listings (user_id, listed, role, city) values (auth.uid(), true, ''batsman'', ''Lahore'')',
               '42501', '%permission denied%', 'B5 … nor write hunt_listings directly');
select t28.as_nobody();
select t28.err(s, '42501', 'hunt: not authenticated', 'B6 no signed-in user: ' || s)
  from unnest(array['select * from public.my_hunt_listing()',
                    'select * from public.set_my_hunt_listing(true)',
                    'select * from public.publish_hunt_post(gen_random_uuid(), ''batsman'', ''t20'', 1)',
                    'select public.close_hunt_post(gen_random_uuid())',
                    'select * from public.club_hunt_posts(gen_random_uuid())',
                    'select * from public.hunt_open_posts()',
                    'select public.express_hunt_interest(gen_random_uuid())',
                    'select public.withdraw_hunt_interest(gen_random_uuid())',
                    'select * from public.club_hunt_interests(gen_random_uuid())',
                    'select * from public.hunt_open_players()',
                    'select * from public.invite_hunt_player(gen_random_uuid(), gen_random_uuid())',
                    'select * from public.club_hunt_invites(gen_random_uuid())',
                    'select * from public.my_hunt_invites()',
                    'select * from public.respond_hunt_invite(gen_random_uuid(), true)']) s;
reset role;
set local role anon;
select t28.err('select * from public.my_hunt_listing()', '42501', '%permission denied%', 'B7 anon: my_hunt_listing refused');
select t28.err('select * from public.hunt_open_posts()', '42501', '%permission denied%', 'B8 anon: hunt_open_posts refused');
select t28.err('select * from public.hunt_open_players()', '42501', '%permission denied%', 'B9 anon: hunt_open_players refused');
reset role;

-- ---------------------------------------------------------------------------
-- C. The player's listing
-- ---------------------------------------------------------------------------
set local role authenticated;
select t28.as_user(t28.p(3));
select t28.ok((select listed is false and role = 'batsman' and city = 'Lahore' and listed_at is null and visible is false
                 from public.my_hunt_listing()),
              'C1 before anything is saved: not listed, role and city from the cricket profile / address');
select t28.ok((select listed and role = 'batsman' and city = 'Lahore' and listed_at = now() and visible
                 from public.set_my_hunt_listing(true)),
              'C2 listing on: listed, visible, listed_at set');
select t28.ok((select listed and role = 'wicket_keeper' and city = 'Karachi' and listed_at = now()
                 from public.set_my_hunt_listing(true, 'wicket_keeper', '  Karachi  ')),
              'C3 role and city can be set (city trimmed)');
select t28.ok((select listed and role = 'batsman' and city = 'Lahore' from public.set_my_hunt_listing(true, 'batsman', 'Lahore')),
              'C4 … and changed back');
select t28.err('select * from public.set_my_hunt_listing(true, ''keeper'')', '22023', 'hunt: invalid role', 'C5 an unknown role is refused');
select t28.err('select * from public.set_my_hunt_listing(null)', '22023', 'hunt: invalid listing', 'C6 a missing on/off is refused');
select t28.err(format('select * from public.set_my_hunt_listing(true, null, %L)', repeat('x', 101)), '22023', 'hunt: invalid city',
               'C7 a city over 100 characters is refused');
select t28.ok((select not listed and role = 'batsman' and city = 'Lahore' and listed_at = now() and not visible
                 from public.set_my_hunt_listing(false)),
              'C8 listing off keeps role, city and listed_at');
select public.set_my_hunt_listing(true);
select t28.as_user(t28.p(6));
select t28.err('select * from public.set_my_hunt_listing(true, ''batsman'', ''Lahore'')', 'P0001', 'hunt: player profile required',
               'C9 no cricket profile: listing on refused');
select t28.ok((select not listed and role is null and city = 'Lahore' from public.set_my_hunt_listing(false)),
              'C10 … listing off is fine (nothing stored)');
select t28.as_user(t28.p(10));
select t28.err('select * from public.set_my_hunt_listing(true)', '22023', 'hunt: city required', 'C11 no address and no city: refused');
select t28.ok((select listed and role = 'wicket_keeper' and city = 'Multan' from public.set_my_hunt_listing(true, null, 'Multan')),
              'C12 … with a city: listed; a wicket-keeper''s role is wicket_keeper');
select t28.as_user(t28.p(4));
select t28.ok((select listed and not visible from public.set_my_hunt_listing(true)),
              'C13 a private profile can list but is not visible');
select t28.as_user(t28.p(9));
select t28.err('select * from public.my_hunt_listing()', 'P0002', 'hunt: profile not found', 'C14 no profile row: my_hunt_listing P0002');
select t28.err('select * from public.set_my_hunt_listing(false)', 'P0002', 'hunt: profile not found', 'C15 … set_my_hunt_listing P0002');
select t28.as_user(t28.p(5));
select public.set_my_hunt_listing(true);
select t28.as_user(t28.p(7));
select public.set_my_hunt_listing(true);
select t28.as_user(t28.p(2));
select t28.ok((select listed and role = 'bowler' and city = 'Lahore' from public.set_my_hunt_listing(true)),
              'C16 a club owner with a cricket profile can list too');

-- ---------------------------------------------------------------------------
-- D. Club posts
-- ---------------------------------------------------------------------------
select t28.as_user(t28.p(1));
select t28.put('lions1', (select post_id from public.publish_hunt_post(
         t28.club('M8 Lions'), 'batsman', 't20', 2, '  Lahore ', ((now() at time zone 'Asia/Karachi')::date + 3),
         '14:00', 'under_2000', '  Bring your kit  ')));
select t28.ok((select status = 'open' and role = 'batsman' and format = 't20' and players_needed = 2 and city = 'Lahore'
                      and match_date = (now() at time zone 'Asia/Karachi')::date + 3 and match_time = '14:00'
                      and budget = 'under_2000' and notes = 'Bring your kit' and is_my_club and not interested
                      and interest_count = 0 and club_name = 'M8 Lions' and club_city = 'Lahore'
                      and expires_at = (((now() at time zone 'Asia/Karachi')::date + 4)::timestamp at time zone 'Asia/Karachi')
                 from public.club_hunt_posts(t28.club('M8 Lions')) where post_id = t28.id('lions1')),
              'D1 publish: every field stored, trimmed; a dated post expires at the end of that day (Pakistan)');
select t28.put('lions2', (select post_id from public.publish_hunt_post(t28.club('M8 Lions'), 'bowler', 'custom', 1)));
select t28.ok((select city is null and match_date is null and match_time is null and budget = 'any' and notes = ''
                      and expires_at = now() + interval '30 days'
                 from public.club_hunt_posts(t28.club('M8 Lions')) where post_id = t28.id('lions2')),
              'D2 an undated post for any location: defaults, expires after 30 days');
select t28.ok((select count(*) = 1 from public.publish_hunt_post(t28.club('M8 Lions'), 'wicket_keeper', 'odi', 11, null,
                                                                  null, '23:59', 'over_5000')),
              'D3 11 players, 23:59, over_5000 accepted');
select t28.err(format('select * from public.publish_hunt_post(%L, ''batsman'', ''t20'', 2, ''Lahore'', %L, ''14:00'', ''under_2000'')',
                      t28.club('M8 Lions'), (now() at time zone 'Asia/Karachi')::date + 3),
               'P0001', 'hunt: duplicate post', 'D4 the same open requirement again: duplicate');
select t28.err(format('select * from public.publish_hunt_post(%L, %s)', t28.club('M8 Lions'), a), '22023', m, 'D5 invalid: ' || m)
  from (values ('''keeper'', ''t20'', 1', 'hunt: invalid role'),
               ('null, ''t20'', 1', 'hunt: invalid role'),
               ('''batsman'', ''t30'', 1', 'hunt: invalid format'),
               ('''batsman'', ''t20'', 0', 'hunt: invalid players needed'),
               ('''batsman'', ''t20'', 12', 'hunt: invalid players needed'),
               ('''batsman'', ''t20'', null', 'hunt: invalid players needed'),
               (format('''batsman'', ''t20'', 1, null, %L', (now() at time zone 'Asia/Karachi')::date - 1), 'hunt: invalid date'),
               (format('''batsman'', ''t20'', 1, null, %L', (now() at time zone 'Asia/Karachi')::date + 181), 'hunt: invalid date'),
               ('''batsman'', ''t20'', 1, null, null, ''24:00''', 'hunt: invalid time'),
               ('''batsman'', ''t20'', 1, null, null, ''9:00''', 'hunt: invalid time'),
               ('''batsman'', ''t20'', 1, null, null, null, ''cheap''', 'hunt: invalid budget'),
               ('''batsman'', ''t20'', 1, null, null, null, null', 'hunt: invalid budget'),
               (format('''batsman'', ''t20'', 1, null, null, null, ''any'', %L', repeat('n', 281)), 'hunt: invalid notes'),
               (format('''batsman'', ''t20'', 1, %L', repeat('c', 101)), 'hunt: invalid city')) v(a, m);
select t28.as_user(t28.p(2));
select t28.err(format('select * from public.publish_hunt_post(%L, ''batsman'', ''t20'', 1)', t28.club('M8 Lions')),
               '42501', 'hunt: not allowed', 'D6 another club''s owner cannot post for it');
select t28.err('select * from public.publish_hunt_post(gen_random_uuid(), ''batsman'', ''t20'', 1)',
               '42501', 'hunt: not allowed', 'D7 an unknown club: not allowed');
select t28.err(format('select * from public.club_hunt_posts(%L)', t28.club('M8 Lions')), '42501', 'hunt: not allowed',
               'D8 another owner cannot list the club''s posts');
select t28.put('kings1', (select post_id from public.publish_hunt_post(t28.club('M8 Kings'), 'batsman', 't10', 3, 'Karachi')));
select t28.as_user(t28.p(3));
select t28.err(format('select * from public.publish_hunt_post(%L, ''batsman'', ''t20'', 1)', t28.club('M8 Lions')),
               '42501', 'hunt: not allowed', 'D9 a player cannot post');
select t28.ok((select count(*) = 4 and bool_and(not is_my_club and not interested and interest_count is null and status = 'open')
                 from public.hunt_open_posts()),
              'D10 players see every club''s open posts (no interest count, not their club)');
select t28.ok((select array_agg(post_id order by post_id) = array(select unnest(array[t28.id('lions1'), t28.id('kings1')]) order by 1)
                 from public.hunt_open_posts('batsman')),
              'D11 role filter');
select t28.ok((select count(*) = 1 from public.hunt_open_posts('bowler'))
              and (select count(*) = 3 from public.hunt_open_posts(null, 'karachi'))
              and (select count(*) = 3 from public.hunt_open_posts(null, 'LAHORE')),
              'D12 city filter (any case); a post for any location matches every city');
select t28.err('select * from public.hunt_open_posts(''keeper'')', '22023', 'hunt: invalid role', 'D13 unknown role filter refused');
select t28.as_user(t28.p(2));
select t28.ok((select bool_or(is_my_club and interest_count = 0 and post_id = t28.id('kings1'))
                      and bool_and(is_my_club = (club_id = t28.club('M8 Kings')))
                 from public.hunt_open_posts()),
              'D14 an owner sees their own club''s posts marked is_my_club, with the interest count');
select t28.err(format('select public.close_hunt_post(%L)', t28.id('lions2')), '42501', 'hunt: not allowed',
               'D15 another owner cannot close the post');
select t28.err('select public.close_hunt_post(gen_random_uuid())', '42501', 'hunt: not allowed', 'D16 an unknown post: not allowed');
select t28.as_user(t28.p(1));
select public.close_hunt_post(t28.id('lions2'));
select t28.okq(format('select public.close_hunt_post(%L)', t28.id('lions2')), 'D17 closing a closed post does nothing');
select t28.ok((select status = 'closed' from public.club_hunt_posts(t28.club('M8 Lions')) where post_id = t28.id('lions2'))
              and not exists (select 1 from public.hunt_open_posts() where post_id = t28.id('lions2')),
              'D18 a closed post: "closed" for the owner, gone from Playing Opportunities');
reset role;
update public.hunt_posts set created_at = now() - interval '40 days', expires_at = now() - interval '10 days'
 where role = 'wicket_keeper' and club_id = t28.club('M8 Lions');
set local role authenticated;
select t28.ok((select status = 'expired' from public.club_hunt_posts(t28.club('M8 Lions')) where role = 'wicket_keeper')
              and not exists (select 1 from public.hunt_open_posts() where role = 'wicket_keeper'),
              'D19 an open post past its expiry: "expired" for the owner, gone for players');
-- Limits: 10 open, 20 per 24 hours (the Kings already published 1).
select t28.as_user(t28.p(2));
select t28.ok((select count(*) = 9 from generate_series(1, 9) n,
                 lateral public.publish_hunt_post(t28.club('M8 Kings'), 'bowler', 't20', n)),
              'D20 up to 10 open posts');
select t28.err(format('select * from public.publish_hunt_post(%L, ''bowler'', ''t20'', 10)', t28.club('M8 Kings')),
               'P0001', 'hunt: too many open posts', 'D21 an 11th open post is refused');
select t28.ok(t28.count_sql(format('select public.close_hunt_post(x.post_id) from public.club_hunt_posts(%L) x where x.status = ''open''',
                                   t28.club('M8 Kings'))) = 10,
              'D22 the owner closes them');
select t28.ok((select count(*) = 10 from generate_series(1, 10) n,
                 lateral public.publish_hunt_post(t28.club('M8 Kings'), 'bowler', 't20', n)),
              'D23 10 more (20 in 24 hours)');
select t28.count_sql(format('select public.close_hunt_post(x.post_id) from public.club_hunt_posts(%L) x where x.status = ''open''',
                            t28.club('M8 Kings')));
select t28.err(format('select * from public.publish_hunt_post(%L, ''bowler'', ''t20'', 1)', t28.club('M8 Kings')),
               'P0001', 'hunt: too many posts', 'D24 a 21st post in 24 hours is refused');
reset role;
-- A fresh open Kings post (the limit is the owner's; set up as the test owner).
insert into public.hunt_posts (club_id, created_by, role, format, players_needed, city, expires_at)
values (t28.club('M8 Kings'), t28.p(2), 'batsman', 't20', 2, 'Karachi', now() + interval '7 days')
returning t28.put('kings2', id);

-- ---------------------------------------------------------------------------
-- E. Interest ("I'm Interested")
-- ---------------------------------------------------------------------------
set local role authenticated;
select t28.as_user(t28.p(3));
select t28.okq(format('select public.express_hunt_interest(%L)', t28.id('lions1')), 'E1 a player expresses interest');
select t28.ok((select n.inbox = 'club_owner' and n.club_id = t28.club('M8 Lions') and n.subject_id = t28.id('lions1')
                      and n.person_id = t28.p(3) and n.params ->> 'person_name' = 'M8 Person 3'
                      and n.params ->> 'club_name' = 'M8 Lions' and n.params ->> 'hunt_role' = 'batsman'
                      and n.params ->> 'format' = 't20' and (n.params ->> 'players_needed')::int = 2
                      and n.params ->> 'match_date' = ((now() at time zone 'Asia/Karachi')::date + 3)::text
                      and n.dedupe_key = 'hunt:interest:' || t28.id('lions1') || ':' || t28.p(3)
                      and n.read_at is null
                 from t28.note(t28.p(1), 'hunt_interest_received') n)
              and t28.notes(t28.p(1), 'hunt_interest_received') = 1,
              'E2 the owner is told: club_owner inbox, post, player, wording parameters');
select t28.ok((select interested from public.hunt_open_posts() where post_id = t28.id('lions1')),
              'E3 the post shows interested for the player');
select t28.okq(format('select public.express_hunt_interest(%L)', t28.id('lions1')), 'E4 interest again: no error');
select t28.ok(t28.notes(t28.p(1), 'hunt_interest_received') = 1, 'E5 … and nobody is told twice');
select t28.err(format('select public.express_hunt_interest(%L)', t28.id('lions2')), 'P0001', 'hunt: post closed',
               'E6 a closed post refuses interest');
select t28.err('select public.express_hunt_interest(gen_random_uuid())', 'P0002', 'hunt: post not found', 'E7 an unknown post: P0002');
select public.withdraw_hunt_interest(t28.id('lions1'));
select t28.ok((select not interested from public.hunt_open_posts() where post_id = t28.id('lions1')),
              'E8 withdraw: no longer interested');
select t28.okq(format('select public.withdraw_hunt_interest(%L)', t28.id('lions1')), 'E9 withdrawing again does nothing');
select public.express_hunt_interest(t28.id('lions1'));
select t28.ok(t28.notes(t28.p(1), 'hunt_interest_received') = 1, 'E10 interest again after withdrawing: nobody told again');
select public.express_hunt_interest(t28.id('kings2'));
select t28.ok(t28.notes(t28.p(2), 'hunt_interest_received') = 0, 'E11 an owner who muted join requests is not told');
select t28.as_user(t28.p(1));
select t28.err(format('select public.express_hunt_interest(%L)', t28.id('lions1')), 'P0001', 'hunt: own club',
               'E12 an owner cannot be interested in their own club''s post');
select t28.ok((select interest_count = 1 from public.club_hunt_posts(t28.club('M8 Lions')) where post_id = t28.id('lions1')),
              'E13 the owner sees interest_count 1');
select t28.as_user(t28.p(6));
select t28.err(format('select public.express_hunt_interest(%L)', t28.id('lions1')), 'P0001', 'hunt: player profile required',
               'E14 no cricket profile: refused');
select t28.as_user(t28.p(5));
select public.express_hunt_interest(t28.id('lions1'));
select t28.as_user(t28.p(12));
select public.express_hunt_interest(t28.id('lions1'));
select t28.as_user(t28.p(1));
select t28.ok((select count(*) = 3 from public.club_hunt_interests(t28.club('M8 Lions'))),
              'E15 the owner lists the 3 interested players');
select t28.ok((select phone = '+923730000003' and stats_visible and matches = 0 and runs = 0 and role = 'batsman'
                      and city = 'Lahore' and full_name = 'M8 Person 3'
                 from public.club_hunt_interests(t28.club('M8 Lions')) where user_id = t28.p(3)),
              'E16 consent: phone shown; show_stats on: figures shown');
select t28.ok((select phone is null and not stats_visible and matches is null and runs is null and wickets is null
                      and economy is null and role = 'bowler'
                 from public.club_hunt_interests(t28.club('M8 Lions'), t28.id('lions1')) where user_id = t28.p(5)),
              'E17 no consent: no phone; show_stats off: no figures');
select t28.ok((select count(*) = 0 from public.club_hunt_interests(t28.club('M8 Lions'), t28.id('lions2'))),
              'E18 the post filter');
select t28.as_user(t28.p(2));
select t28.err(format('select * from public.club_hunt_interests(%L)', t28.club('M8 Lions')), '42501', 'hunt: not allowed',
               'E19 another owner cannot list them');
reset role;
-- Daily limit: 30 interests per player (31 open posts of "M8 Bulk", set up directly).
insert into public.hunt_posts (club_id, created_by, role, format, players_needed, expires_at)
select t28.club('M8 Bulk'), t28.p(11), 'batsman', 't20', 1 + n % 11, now() + interval '7 days' from generate_series(1, 31) n;
create function t28.bulk(p_n int) returns uuid language sql stable security definer set search_path = '' as $$
  select h.id from public.hunt_posts h join public.clubs c on c.id = h.club_id
   where c.name = 'M8 Bulk' order by h.id offset p_n - 1 limit 1;
$$;
grant execute on function t28.bulk(int) to authenticated;
set local role authenticated;
select t28.as_user(t28.p(5));
-- p5 already has 1 (Lions): 29 more make 30.
select t28.ok(t28.count_sql('select public.express_hunt_interest(t28.bulk(n)) from generate_series(1, 29) n') = 29,
              'E20 up to 30 interests in 24 hours');
select t28.err('select public.express_hunt_interest(t28.bulk(30))', 'P0001', 'hunt: too many interests',
               'E21 a 31st interest in 24 hours is refused');
select t28.ok(t28.notes(t28.p(11), 'hunt_interest_received') = 29, 'E22 … the Bulk owner was told 29 times (once per post)');

-- ---------------------------------------------------------------------------
-- F. Available Players (club owners)
-- ---------------------------------------------------------------------------
select t28.as_user(t28.p(3));
select t28.err('select * from public.hunt_open_players()', '42501', 'hunt: not allowed', 'F1 a player (no club) cannot search');
select t28.as_user(t28.p(1));
select t28.ok((select array_agg(user_id order by user_id) from public.hunt_open_players())
                = array[t28.p(2), t28.p(3), t28.p(5), t28.p(7), t28.p(10)],
              'F2 only listed players with a public profile (not the private 4, not the unlisted 6 / 12)');
select t28.ok(pg_get_function_result('public.hunt_open_players(text, text)'::regprocedure) not like '%phone%',
              'F3 the search never returns a phone');
select t28.ok((select stats_visible and matches = 0 and wickets = 0 and full_name = 'M8 Person 3' and role = 'batsman'
                      and city = 'Lahore' and listed_at = now() and not is_me and not is_member and invite_id is null
                 from public.hunt_open_players() where user_id = t28.p(3))
              and (select not stats_visible and matches is null and runs is null and batting_average is null
                     from public.hunt_open_players() where user_id = t28.p(5)),
              'F4 figures only with show_stats');
select t28.ok((select array_agg(user_id order by user_id) from public.hunt_open_players('  lahore ', 'bowler'))
                = array[t28.p(2), t28.p(5)]
              and (select array_agg(user_id) from public.hunt_open_players('Multan')) = array[t28.p(10)]
              and (select array_agg(user_id) from public.hunt_open_players(null, 'wicket_keeper')) = array[t28.p(10)],
              'F5 city (any case, trimmed) and role filters');
select t28.ok((select bool_and(is_member = (user_id = t28.p(7))) from public.hunt_open_players()),
              'F6 is_member: the Lions member only');
select t28.err('select * from public.hunt_open_players(null, ''keeper'')', '22023', 'hunt: invalid role', 'F7 unknown role refused');
select t28.as_user(t28.p(2));
select t28.ok((select bool_and(is_me = (user_id = t28.p(2))) and bool_and(is_member = is_me) from public.hunt_open_players()),
              'F8 an owner who listed themselves sees is_me (and is a member of their own club)');

-- ---------------------------------------------------------------------------
-- G. Invites
-- ---------------------------------------------------------------------------
select t28.as_user(t28.p(1));
select t28.put('inv3', (select invite_id from public.invite_hunt_player(t28.club('M8 Lions'), t28.p(3), t28.id('lions1'))));
select t28.ok((select status = 'pending' and created_at = now() and expires_at = now() + interval '14 days'
                 from public.club_hunt_invites(t28.club('M8 Lions')) where invite_id = t28.id('inv3')),
              'G1 invite: pending, waits 14 days');
select t28.ok((select n.inbox = 'player' and n.club_id = t28.club('M8 Lions') and n.subject_id = t28.id('inv3')
                      and n.person_id is null and n.params ->> 'club_name' = 'M8 Lions' and n.params ->> 'city' = 'Lahore'
                      and n.params ->> 'hunt_role' = 'batsman' and n.params ->> 'format' = 't20'
                      and n.params ->> 'match_date' = ((now() at time zone 'Asia/Karachi')::date + 3)::text
                      and n.params ? 'expires_at' and n.dedupe_key = 'hunt:invite:' || t28.id('inv3')
                 from t28.note(t28.p(3), 'hunt_invite_received') n),
              'G2 the player is told: player inbox, club, invite, wording parameters');
select t28.err(format('select * from public.invite_hunt_player(%L, %L)', t28.club('M8 Lions'), t28.p(3)), 'P0001',
               'hunt: already invited', 'G3 a second invite while one is pending is refused');
select t28.err(format('select * from public.invite_hunt_player(%L, %L)', t28.club('M8 Lions'), t28.p(1)), '22023',
               'hunt: cannot invite yourself', 'G4 not yourself');
select t28.err(format('select * from public.invite_hunt_player(%L, null)', t28.club('M8 Lions')), '22023',
               'hunt: invalid player', 'G5 a player is required');
select t28.err(format('select * from public.invite_hunt_player(%L, %L)', t28.club('M8 Lions'), t28.p(7)), 'P0001',
               'hunt: already a member', 'G6 not an active member');
select t28.err(format('select * from public.invite_hunt_player(%L, %L)', t28.club('M8 Lions'), u), 'P0001',
               'hunt: player not available', 'G7 not available: ' || l)
  from (values (t28.p(4), 'private profile'), (t28.p(6), 'not listed'), (gen_random_uuid(), 'unknown user')) v(u, l);
select t28.err(format('select * from public.invite_hunt_player(%L, %L, %L)', t28.club('M8 Lions'), t28.p(10), t28.id('kings1')),
               '22023', 'hunt: invalid post', 'G8 a post of another club is refused');
select t28.put('inv12', (select invite_id from public.invite_hunt_player(t28.club('M8 Lions'), t28.p(12))));
select t28.ok(t28.id('inv12') is not null and t28.notes(t28.p(12), 'hunt_invite_received') = 1,
              'G9 an unlisted player who showed interest in the club''s post can be invited');
select t28.as_user(t28.p(2));
select t28.err(format('select * from public.invite_hunt_player(%L, %L)', t28.club('M8 Lions'), t28.p(5)), '42501',
               'hunt: not allowed', 'G10 another club''s owner cannot invite for it');
select t28.err(format('select * from public.invite_hunt_player(%L, %L)', t28.club('M8 Kings'), t28.p(12)), 'P0001',
               'hunt: player not available', 'G11 … nor reach the unlisted player (no interest in their posts)');
reset role;
insert into public.notification_preferences (user_id, join_requests, challenges, matches, results, announcements)
values (t28.p(5), false, false, false, false, false);
set local role authenticated;
select t28.as_user(t28.p(1));
select t28.put('inv5', (select invite_id from public.invite_hunt_player(t28.club('M8 Lions'), t28.p(5))));
select t28.ok(t28.notes(t28.p(5), 'hunt_invite_received') = 1,
              'G12 invites are "membership" (always on): delivered although every category is off');
select t28.ok((select invite_id = t28.id('inv3') and invite_status = 'pending' from public.hunt_open_players() where user_id = t28.p(3)),
              'G13 Available Players shows the pending invite');
select t28.ok((select phone is null from public.club_hunt_invites(t28.club('M8 Lions')) where invite_id = t28.id('inv3')),
              'G14 a pending invite shows no phone (even with consent)');
select t28.as_user(t28.p(3));
select t28.ok((select count(*) = 1 and bool_and(club_name = 'M8 Lions' and club_city = 'Lahore' and post_id = t28.id('lions1')
                                                and post_role = 'batsman' and post_format = 't20' and status = 'pending')
                 from public.my_hunt_invites()),
              'G15 the player lists their invite with the club and the requirement');
select t28.err(format('select * from public.respond_hunt_invite(%L, null)', t28.id('inv3')), '22023', 'hunt: invalid answer',
               'G16 an answer is required');
select t28.as_user(t28.p(5));
select t28.err(format('select * from public.respond_hunt_invite(%L, true)', t28.id('inv3')), 'P0002', 'hunt: invite not found',
               'G17 someone else''s invite: not found');
select t28.as_user(t28.p(3));
select t28.ok((select status = 'accepted' and responded_at = now() and invite_id = t28.id('inv3')
                 from public.respond_hunt_invite(t28.id('inv3'), true)),
              'G18 the player accepts');
select t28.ok((select n.inbox = 'club_owner' and n.club_id = t28.club('M8 Lions') and n.subject_id = t28.id('inv3')
                      and n.person_id = t28.p(3) and n.params ->> 'person_name' = 'M8 Person 3'
                      and n.params ->> 'club_name' = 'M8 Lions'
                 from t28.note(t28.p(1), 'hunt_invite_accepted') n)
              and t28.notes(t28.p(1), 'hunt_invite_accepted') = 1,
              'G19 the owner is told (hunt_invite_accepted)');
select t28.ok(not exists (select 1 from public.my_club_memberships()), 'G20 accepting does not join the club');
select t28.err(format('select * from public.respond_hunt_invite(%L, false)', t28.id('inv3')), 'P0001', 'hunt: invite not pending',
               'G21 answering again is refused');
select t28.as_user(t28.p(1));
select t28.ok((select phone = '+923730000003' and status = 'accepted' and full_name = 'M8 Person 3' and role = 'batsman'
                 from public.club_hunt_invites(t28.club('M8 Lions')) where invite_id = t28.id('inv3')),
              'G22 accepted + consent: the club sees the phone');
select t28.err(format('select * from public.invite_hunt_player(%L, %L)', t28.club('M8 Lions'), t28.p(3)), 'P0001',
               'hunt: already invited', 'G23 an accepted invite: not again for 30 days');
select t28.as_user(t28.p(5));
select t28.ok((select status = 'declined' from public.respond_hunt_invite(t28.id('inv5'), false)), 'G24 the player declines');
select t28.ok(t28.notes(t28.p(1), 'hunt_invite_accepted') = 1, 'G25 … and nobody is told');
select t28.as_user(t28.p(1));
select t28.err(format('select * from public.invite_hunt_player(%L, %L)', t28.club('M8 Lions'), t28.p(5)), 'P0001',
               'hunt: invite declined recently', 'G26 a declined invite: not again for 30 days');
select t28.ok((select phone is null and status = 'declined' from public.club_hunt_invites(t28.club('M8 Lions'))
                where invite_id = t28.id('inv5')),
              'G27 declined: no phone');
-- Expiry.
select t28.put('inv10', (select invite_id from public.invite_hunt_player(t28.club('M8 Lions'), t28.p(10))));
reset role;
update public.hunt_invites set created_at = now() - interval '15 days', expires_at = now() - interval '1 day'
 where id = t28.id('inv10');
set local role authenticated;
select t28.as_user(t28.p(10));
select t28.err(format('select * from public.respond_hunt_invite(%L, true)', t28.id('inv10')), 'P0001', 'hunt: invite not pending',
               'G28 an expired invite cannot be answered');
select t28.ok((select status = 'expired' from public.my_hunt_invites() where invite_id = t28.id('inv10')),
              'G29 … and shows as expired to the player');
select t28.as_user(t28.p(1));
select t28.ok((select invite_status = 'expired' from public.hunt_open_players() where user_id = t28.p(10)),
              'G30 … and to the club');
select t28.put('inv10b', (select invite_id from public.invite_hunt_player(t28.club('M8 Lions'), t28.p(10))));
reset role;
select t28.ok((select array_agg(status order by created_at) from public.hunt_invites where user_id = t28.p(10))
                = array['expired', 'pending'],
              'G31 after expiry the club may invite again; the old invite is stored as expired');
-- A muted owner (join requests off) is not told of an acceptance.
set local role authenticated;
select t28.as_user(t28.p(2));
select t28.put('kinv3', (select invite_id from public.invite_hunt_player(t28.club('M8 Kings'), t28.p(3))));
select t28.as_user(t28.p(3));
select public.respond_hunt_invite(t28.id('kinv3'), true);
select t28.ok(t28.notes(t28.p(2), 'hunt_invite_accepted') = 0 and t28.notes(t28.p(3), 'hunt_invite_received') = 2,
              'G32 an owner who muted join requests is not told of an acceptance');
-- Daily limit: 20 invites per club (Kings: 1 now + 19 set up directly).
reset role;
insert into public.hunt_invites (club_id, user_id, invited_by, status)
select t28.club('M8 Kings'), t28.p(10), t28.p(2), 'expired' from generate_series(1, 19);
set local role authenticated;
select t28.as_user(t28.p(2));
select t28.err(format('select * from public.invite_hunt_player(%L, %L)', t28.club('M8 Kings'), t28.p(5)), 'P0001',
               'hunt: too many invites', 'G33 a 21st invite in 24 hours is refused');
reset role;
select t28.err(format('insert into public.hunt_invites (club_id, user_id) values (%L, %L)', t28.club('M8 Lions'), t28.p(10)),
               '23505', '%hunt_invites_one_pending_idx%', 'G34 one pending invite per club and player (unique index)');
select t28.err(format('insert into public.hunt_interests (post_id, user_id) values (%L, %L)', t28.id('lions1'), t28.p(3)),
               '23505', '%hunt_interests_post_user_key%', 'G35 one interest per post and player (unique)');
select t28.err(format('insert into public.hunt_invites (club_id, user_id, invited_by, status) values (%L, %L, %L, ''expired'')',
                      t28.club('M8 Lions'), t28.p(10), t28.p(10)),
               '23514', '%hunt_invites_not_self%', 'G36 the table refuses a self-invite');
select t28.err(format('insert into public.hunt_posts (club_id, role, format, players_needed, expires_at) values (%L, ''batsman'', ''t20'', 12, now() + interval ''1 day'')',
                      t28.club('M8 Lions')),
               '23514', '%hunt_posts_players_needed_check%', 'G37 the table refuses 12 players');

-- ---------------------------------------------------------------------------
-- H. Account and club deletion
-- ---------------------------------------------------------------------------
select t28.put('inv3keep', t28.id('inv3'));
select t28.ok((select (public.delete_account_data(t28.p(3)) ->> 'profile')::int = 1), 'H1 player 3 deletes their account');
select t28.ok(not exists (select 1 from public.hunt_listings where user_id = t28.p(3))
              and not exists (select 1 from public.hunt_interests where user_id = t28.p(3))
              and not exists (select 1 from public.hunt_invites where user_id = t28.p(3)),
              'H2 … their listing, interests and invites are gone');
select t28.ok((select count(*) = 2
                      and bool_and(n.person_id is null and not (n.params ? 'person_name')
                                   and (n.params ->> 'person_deleted')::boolean)
                 from public.notifications n
                where n.recipient_id = t28.p(1)
                  and n.dedupe_key in ('hunt:interest:' || t28.id('lions1') || ':' || t28.p(3),
                                       'hunt:invite_accepted:' || t28.id('inv3keep'))),
              'H3 … and the owner''s two notifications about them forget the name ("Deleted player")');
set local role authenticated;
select t28.as_user(t28.p(11));
select t28.put('bulkinv', (select invite_id from public.invite_hunt_player(t28.club('M8 Bulk'), t28.p(5))));
reset role;
select t28.put('bulkclub', t28.club('M8 Bulk'));
delete from public.clubs where id = t28.id('bulkclub');
select t28.ok(not exists (select 1 from public.hunt_posts where club_id = t28.id('bulkclub'))
              and (select count(*) from public.hunt_interests where user_id = t28.p(5)) = 1
              and not exists (select 1 from public.hunt_invites where club_id = t28.id('bulkclub'))
              and (select n.club_id is null from public.notifications n
                    where n.dedupe_key = 'hunt:invite:' || t28.id('bulkinv')),
              'H4 deleting a club deletes its posts (with their interests) and invites; notifications keep no club');
select t28.ok((select count(*) from public.hunt_posts where id = t28.id('lions1')) = 1
              and (select created_by from public.hunt_posts where id = t28.id('lions1')) = t28.p(1),
              'H5 other clubs'' posts are untouched');

-- ---------------------------------------------------------------------------
-- I. Notification types and categories
-- ---------------------------------------------------------------------------
select t28.ok(public.notification_category('hunt_interest_received') = 'join_requests'
              and public.notification_category('hunt_invite_accepted') = 'join_requests'
              and public.notification_category('hunt_invite_received') = 'membership'
              and public.notification_category('join_request_received') = 'join_requests'
              and public.notification_category('match_reminder') = 'matches'
              and public.notification_category('challenge_expiring') = 'challenges'
              and public.notification_category('result_published') = 'results'
              and public.notification_category('announcement') = 'announcements'
              and public.notification_category('ownership_expiring') = 'membership',
              'I1 categories: the two owner types in join requests, the invite in membership; the others unchanged');
select t28.err(format('insert into public.notifications (recipient_id, inbox, type, dedupe_key) values (%L, ''player'', ''hunt_bogus'', ''t28:x'')',
                      t28.p(5)),
               '23514', '%notifications_type_check%', 'I2 an unknown type is still refused');
select t28.ok((select array_length(regexp_split_to_array(pg_get_constraintdef(k.oid), '::text'), 1) - 1
                 from pg_constraint k where k.conname = 'notifications_type_check') = 29,
              'I3 the type list has 29 types (26 + 3)');

rollback;
\echo 'local check 28: all checks passed; everything rolled back'
