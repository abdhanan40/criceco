-- CricEco · LOCAL TEST ONLY — migration 9 (update_profile_details): what
-- needs test-only setup on a local database:
--   L1 every check runs before the first write: a counting trigger (on a
--      sequence — nextval is never rolled back) sees no write attempt from a
--      refused call;
--   L2 an INACTIVE city id is refused (current and permanent);
--   L3 last_updated_at itself: unchanged rows keep it, written rows get now();
--   L4 legacy phone values (another spelling, a number today's rule refuses,
--      "---", only whitespace) are neither rewritten nor block a name-only
--      save, and can still be cleared; digit-less values are compared with
--      whitespace removed ("- -" = "--");
--   L5 a signed-in user without a profile row → 'profile not found' (P0002);
--   L6 "same as current" with a permanent row that drifted from the current
--      one, and the current city since deactivated: a name-only save is not
--      refused, and the permanent row is brought back in step — with exactly
--      the current row's city id, also for a stale alias of a deactivated
--      city (L6f), a NULL id whose text now resolves (L6g) and the label of a
--      deactivated city (L6h).
-- Each refusal is checked by its exact message. Row locking (FOR NO KEY
-- UPDATE) needs two concurrent sessions: local/08b_update_profile_details_locking.sh.
-- Rolled back: nothing is kept. Run after migration 9 with the location data
-- (D1), as the database owner, with psql (it stops at the first error).
\set ON_ERROR_STOP on

begin;

-- Inside the transaction, so a refusal here leaves nothing behind.
do $$
begin
  -- No Supabase admin role, and auth.users without Supabase's password
  -- column (pg_attribute shows it whatever the caller's column privileges).
  if exists (select 1 from pg_roles where rolname = 'supabase_admin')
     or exists (select 1 from pg_attribute where attrelid = to_regclass('auth.users')
                 and attname = 'encrypted_password' and not attisdropped) then
    raise exception 'LOCAL ONLY: this looks like a real Supabase project';
  end if;
  if to_regprocedure('public.update_profile_details(text, text, date, text, integer, text, text, text, integer, text, text)') is null then
    raise exception 'LOCAL ONLY: run migration 9 first';
  end if;
end $$;

-- A local user, the cities and the write counter.
create schema s436;
create table s436.ids (k text primary key, v text);
with u as (insert into auth.users (email) values ('edit-l1@s436.local.test') returning id)
insert into s436.ids select 'user', id::text from u;
insert into s436.ids
select k, (select id from public.cities where geonames_id = gid)::text
  from (values ('lahore', 1172451), ('karachi', 1174872), ('faisalabad', 1179400), ('jhelum', 1175864),
               ('kamra_attock', 1340665), ('attock', 1184249), ('kamra_rwp', 1175082)) v(k, gid);
create sequence s436.writes;
create function s436.count_write() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform nextval('s436.writes');
  return new;
end $$;
-- Named to fire first among the BEFORE UPDATE triggers.
create trigger aaa_s436_count before update on public.profiles for each row execute function s436.count_write();
create trigger aaa_s436_count before update on public.current_addresses for each row execute function s436.count_write();
create trigger aaa_s436_count before update on public.permanent_addresses for each row execute function s436.count_write();
create function s436.writes() returns bigint language sql security definer set search_path = '' as $$
  select case when is_called then last_value else 0 end from s436.writes
$$;
grant usage on schema s436 to authenticated;
grant select on s436.ids to authenticated;
grant execute on function s436.writes() to authenticated;
-- Runs [p_call] as the caller: it must be refused (23514) with exactly
-- [p_message], and attempt no write before refusing.
create function s436.refused_before_writing(p_call text, p_message text) returns void language plpgsql as $$
declare
  n bigint := s436.writes();
begin
  begin
    execute p_call;
    raise exception 'FAIL: accepted: %', p_call;
  exception when check_violation then
    if sqlerrm <> p_message then
      raise exception 'FAIL: % → "%" (wanted "%")', p_call, sqlerrm, p_message;
    end if;
  end;
  if s436.writes() <> n then
    raise exception 'FAIL: % attempted % write(s) before refusing', p_call, s436.writes() - n;
  end if;
end $$;
grant execute on function s436.refused_before_writing(text, text) to authenticated;

select set_config('request.jwt.claims',
  json_build_object('sub', (select v from s436.ids where k = 'user'), 'role', 'authenticated')::text, true);
set local role authenticated;

-- L1: refused calls attempt no write at all.
do $$
declare
  lahore int := (select v::int from s436.ids where k = 'lahore');
  karachi int := (select v::int from s436.ids where k = 'karachi');
  faisalabad int := (select v::int from s436.ids where k = 'faisalabad');
  dob date := date '2000-05-01';
  n bigint;
begin
  if auth.uid() is distinct from (select v::uuid from s436.ids where k = 'user') then
    raise exception 'UNSAFE: not the local test user';
  end if;
  perform public.save_profile_setup_v2('Local Editor', '0300 1234567', dob, lahore, 'Gulberg', 'House 1', true);
  n := s436.writes();

  -- Each refusal comes after a valid change earlier in the argument list.
  begin
    perform public.update_profile_details('Changed Name', '03001234567', dob, 'Atlantis', -1, 'Gulberg', 'House 1');
    raise exception 'FAIL: accepted an unknown city id';
  exception when check_violation then
    if sqlerrm <> 'current_city_id must be an active city' then raise; end if;
  end;
  begin
    perform public.update_profile_details('Changed Name', '03339876543', dob, 'Karachi', karachi, '', 'House 1');
    raise exception 'FAIL: accepted an empty area';
  exception when check_violation then
    if sqlerrm <> 'current_addresses.area must be 1–150 characters (constraint "current_addresses_area_check")' then raise; end if;
  end;
  begin
    perform public.update_profile_details('Changed Name', '03339876543', current_date + 30, 'Lahore', null, 'Gulberg', 'House 1');
    raise exception 'FAIL: accepted a future date of birth';
  exception when check_violation then
    if sqlerrm <> 'date_of_birth cannot be in the future' then raise; end if;
  end;
  if s436.writes() <> n then
    raise exception 'FAIL: a refused call attempted % write(s) before refusing', s436.writes() - n;
  end if;
  -- The text path and the other checks, each after a valid name change.
  perform s436.refused_before_writing(format('select public.update_profile_details(%L, %L, %L::date, %L, null, %L, %L)',
    'Changed Name', '03339876543', dob, repeat('k', 101), 'Gulberg', 'House 1'),
    'current_addresses.city must be 1–100 characters (constraint "current_addresses_city_check")');
  perform s436.refused_before_writing(format('select public.update_profile_details(%L, %L, %L::date, %L, null, %L, %L)',
    'Changed Name', '03339876543', dob, 'Karachi', repeat('a', 151), 'House 1'),
    'current_addresses.area must be 1–150 characters (constraint "current_addresses_area_check")');
  perform s436.refused_before_writing(format('select public.update_profile_details(%L, %L, %L::date, %L, null, %L, %L)',
    'Changed Name', '03339876543', dob, 'Karachi', 'Saddar', ' '),
    'current_addresses.address must be 1–500 characters (constraint "current_addresses_address_check")');
  perform s436.refused_before_writing(format('select public.update_profile_details(%L, %L, %L::date, %L, null, %L, %L)',
    'Changed Name', '+15550000000', dob, 'Karachi', 'Saddar', 'House 2'),
    'phone must be a Pakistani mobile number');
  perform s436.refused_before_writing(format('select public.update_profile_details(%L, %L, %L::date, %L, null, %L, %L)',
    'Changed Name', '03339876543', date '1899-01-01', 'Karachi', 'Saddar', 'House 2'),
    'date_of_birth is required (1900 or later)');
  perform s436.refused_before_writing(format('select public.update_profile_details(%L, %L, %L::date, %L, null, %L, %L)',
    repeat('n', 101), '03339876543', dob, 'Karachi', 'Saddar', 'House 2'),
    'full_name must be 2–100 characters');

  -- Separate permanent address: a bad permanent id after valid name and current changes.
  perform public.save_profile_setup_v2('Local Editor', '0300 1234567', dob, lahore, 'Gulberg', 'House 1', false,
                                       faisalabad, 'Civil Lines', 'Street 9');
  n := s436.writes();
  begin
    perform public.update_profile_details('Changed Name', '03339876543', dob, 'Karachi', karachi, 'Saddar', 'House 2',
                                          'Atlantis', -1, 'Cantt', 'Street 9');
    raise exception 'FAIL: accepted an unknown permanent city id';
  exception when check_violation then
    if sqlerrm <> 'permanent_city_id must be an active city' then raise; end if;
  end;
  if s436.writes() <> n then
    raise exception 'FAIL: the refused permanent id came after % write(s)', s436.writes() - n;
  end if;
  -- The separate permanent address's own checks, after valid name and current changes.
  perform s436.refused_before_writing(format('select public.update_profile_details(%L, %L, %L::date, %L, %s, %L, %L, %L, null, %L, %L)',
    'Changed Name', '03339876543', dob, 'Karachi', karachi, 'Saddar', 'House 2', 'Faisalabad', '', 'Street 9'),
    'permanent_addresses.area must be 1–150 characters (constraint "permanent_addresses_area_check")');
  perform s436.refused_before_writing(format('select public.update_profile_details(%L, %L, %L::date, %L, %s, %L, %L, %L, null, %L, %L)',
    'Changed Name', '03339876543', dob, 'Karachi', karachi, 'Saddar', 'House 2', 'Faisalabad', 'Civil Lines', ' '),
    'permanent_addresses.address must be 1–500 characters (constraint "permanent_addresses_address_check")');
  perform s436.refused_before_writing(format('select public.update_profile_details(%L, %L, %L::date, %L, %s, %L, %L, %L, null, %L, %L)',
    'Changed Name', '03339876543', dob, 'Karachi', karachi, 'Saddar', 'House 2', repeat('p', 101), 'Civil Lines', 'Street 9'),
    'permanent_addresses.city must be 1–100 characters (constraint "permanent_addresses_city_check")');

  -- Positive control: the counter does see writes (name: 1 row; current + permanent: 2 more).
  perform public.update_profile_details('Changed Name', '03001234567', dob, 'Lahore', null, 'Gulberg', 'House 1');
  perform public.update_profile_details('Changed Name', '03001234567', dob, 'Karachi', karachi, 'Saddar', 'House 1',
                                        'Lahore', lahore, 'Civil Lines', 'Street 9');
  if s436.writes() - n <> 3 then
    raise exception 'FAIL: the write counter saw % writes (wanted 3)', s436.writes() - n;
  end if;
  raise notice 'PASSED: L1 every check runs before the first write (refused calls attempt none)';
end $$;

-- L2: deactivate Jhelum (as the owner), then it is refused.
reset role;
update public.cities set is_active = false where id = (select v::int from s436.ids where k = 'jhelum');
-- L3 setup: stamp the user's rows with an old last_updated_at (the trigger
-- would overwrite it, so it is off for this one statement).
alter table public.profiles disable trigger profiles_set_last_updated_at;
alter table public.current_addresses disable trigger current_addresses_set_last_updated_at;
alter table public.permanent_addresses disable trigger permanent_addresses_set_last_updated_at;
update public.profiles set last_updated_at = '2001-01-01 00:00+00' where id = (select v::uuid from s436.ids where k = 'user');
update public.current_addresses set last_updated_at = '2001-01-01 00:00+00' where user_id = (select v::uuid from s436.ids where k = 'user');
update public.permanent_addresses set last_updated_at = '2001-01-01 00:00+00' where user_id = (select v::uuid from s436.ids where k = 'user');
alter table public.profiles enable trigger profiles_set_last_updated_at;
alter table public.current_addresses enable trigger current_addresses_set_last_updated_at;
alter table public.permanent_addresses enable trigger permanent_addresses_set_last_updated_at;
set local role authenticated;

do $$
declare
  lahore int := (select v::int from s436.ids where k = 'lahore');
  karachi int := (select v::int from s436.ids where k = 'karachi');
  jhelum int := (select v::int from s436.ids where k = 'jhelum');
  dob date := date '2000-05-01';
  old timestamptz := '2001-01-01 00:00+00';
begin
  -- Stored now: name "Changed Name", current Karachi (id) / Saddar, permanent Lahore (id) / Civil Lines, separate.
  begin
    perform public.update_profile_details('Changed Name', '03001234567', dob, 'Jhelum', jhelum, 'Saddar', 'House 1');
    raise exception 'FAIL: accepted an inactive current city';
  exception when check_violation then
    if sqlerrm <> 'current_city_id must be an active city' then raise; end if;
  end;
  begin
    perform public.update_profile_details('Changed Name', '03001234567', dob, 'Karachi', null, 'Saddar', 'House 1',
                                          'Jhelum', jhelum, 'Civil Lines', 'Street 9');
    raise exception 'FAIL: accepted an inactive permanent city';
  exception when check_violation then
    if sqlerrm <> 'permanent_city_id must be an active city' then raise; end if;
  end;
  raise notice 'PASSED: L2 an inactive city id is refused (current and permanent)';

  -- L3: unchanged → every last_updated_at stays; name → only the profile's moves; address → only that row's.
  perform public.update_profile_details('Changed Name', '0300-1234567', dob, 'Karachi', karachi, 'Saddar', 'House 1',
                                        'Lahore', lahore, 'Civil Lines', 'Street 9');
  if (select last_updated_at from public.profiles where id = auth.uid()) <> old
     or (select last_updated_at from public.current_addresses where user_id = auth.uid()) <> old
     or (select last_updated_at from public.permanent_addresses where user_id = auth.uid()) <> old then
    raise exception 'FAIL: an unchanged call moved last_updated_at';
  end if;
  perform public.update_profile_details('Renamed', '03001234567', dob, 'Karachi', null, 'Saddar', 'House 1',
                                        'Lahore', null, 'Civil Lines', 'Street 9');
  if (select last_updated_at from public.profiles where id = auth.uid()) <> now()
     or (select last_updated_at from public.current_addresses where user_id = auth.uid()) <> old
     or (select last_updated_at from public.permanent_addresses where user_id = auth.uid()) <> old then
    raise exception 'FAIL: a name change must move only the profile''s last_updated_at';
  end if;
  perform public.update_profile_details('Renamed', '03001234567', dob, 'Karachi', null, 'Clifton', 'House 1',
                                        'Lahore', null, 'Civil Lines', 'Street 9');
  if (select last_updated_at from public.current_addresses where user_id = auth.uid()) <> now()
     or (select last_updated_at from public.permanent_addresses where user_id = auth.uid()) <> old then
    raise exception 'FAIL: a current-address change must move only that row''s last_updated_at';
  end if;
  raise notice 'PASSED: L3 last_updated_at kept for unchanged rows, now() for written rows';
end $$;

-- L4: legacy phone values (W1). Older rows may hold another spelling of a
-- valid number, or a number today's rule refuses; a name-only save must
-- neither rewrite nor refuse them. Stored now: "Renamed", +923001234567.
reset role;
update public.profiles set phone = '0300 1234567' where id = (select v::uuid from s436.ids where k = 'user');
set local role authenticated;
do $$
declare
  dob date := date '2000-05-01';
  n bigint := s436.writes();
begin
  -- The app sends the phone as it shows it; either spelling = no change.
  perform public.update_profile_details('Legacy One', '0300 1234567', dob, 'Karachi', null, 'Clifton', 'House 1',
                                        'Lahore', null, 'Civil Lines', 'Street 9');
  perform public.update_profile_details('Legacy One', '+923001234567', dob, 'Karachi', null, 'Clifton', 'House 1',
                                        'Lahore', null, 'Civil Lines', 'Street 9');
  if (select (full_name, phone) from public.profiles where id = auth.uid())::text
       is distinct from row('Legacy One', '0300 1234567')::text
     or s436.writes() - n <> 1 then
    raise exception 'FAIL: a name-only save rewrote a legacy phone spelling (or wrote % rows, wanted 1)', s436.writes() - n;
  end if;
  raise notice 'PASSED: L4a a legacy phone spelling is kept as stored by a name-only save';
end $$;

reset role;
update public.profiles set phone = '+15551234567' where id = (select v::uuid from s436.ids where k = 'user');
set local role authenticated;
do $$
declare
  dob date := date '2000-05-01';
  n bigint := s436.writes();
begin
  -- A stored number the rule refuses doesn't block a name-only save (also
  -- sent in another spelling of the same digits).
  perform public.update_profile_details('Legacy Two', '+15551234567', dob, 'Karachi', null, 'Clifton', 'House 1',
                                        'Lahore', null, 'Civil Lines', 'Street 9');
  perform public.update_profile_details('Legacy Two', '+1 555-123-4567', dob, 'Karachi', null, 'Clifton', 'House 1',
                                        'Lahore', null, 'Civil Lines', 'Street 9');
  if (select (full_name, phone) from public.profiles where id = auth.uid())::text
       is distinct from row('Legacy Two', '+15551234567')::text
     or s436.writes() - n <> 1 then
    raise exception 'FAIL: a stored non-Pakistani phone blocked or changed a name-only save';
  end if;
  -- Changing it to another invalid number is still refused (nothing written);
  -- clearing it is allowed; a valid number is stored canonically.
  n := s436.writes();
  begin
    perform public.update_profile_details('Legacy Three', '+15559999999', dob, 'Karachi', null, 'Clifton', 'House 1',
                                          'Lahore', null, 'Civil Lines', 'Street 9');
    raise exception 'FAIL: accepted a new non-Pakistani phone';
  exception when check_violation then
    if sqlerrm <> 'phone must be a Pakistani mobile number' then raise; end if;
  end;
  if s436.writes() <> n or (select full_name from public.profiles where id = auth.uid()) <> 'Legacy Two' then
    raise exception 'FAIL: the refused phone change wrote something';
  end if;
  perform public.update_profile_details('Legacy Two', null, dob, 'Karachi', null, 'Clifton', 'House 1',
                                        'Lahore', null, 'Civil Lines', 'Street 9');
  if (select phone from public.profiles where id = auth.uid()) is not null then
    raise exception 'FAIL: a legacy phone must be clearable';
  end if;
  perform public.update_profile_details('Legacy Two', '0333-9876543', dob, 'Karachi', null, 'Clifton', 'House 1',
                                        'Lahore', null, 'Civil Lines', 'Street 9');
  if (select phone from public.profiles where id = auth.uid()) <> '+923339876543' then
    raise exception 'FAIL: a new phone must be stored as +923XXXXXXXXX';
  end if;
  raise notice 'PASSED: L4b a stored invalid phone neither blocks nor is changed by a name-only save; new values still checked';
end $$;

-- L4c (F2, F12): stored values with no digits — dashes only ("---"), or
-- only whitespace. Sent back unchanged (as the app shows them) they neither
-- block a name-only save nor are rewritten; an explicit clear (NULL or a
-- blank that differs) clears them to NULL.
reset role;
update public.profiles set phone = '---' where id = (select v::uuid from s436.ids where k = 'user');
set local role authenticated;
do $$
declare
  dob date := date '2000-05-01';
  n bigint := s436.writes();
begin
  perform public.update_profile_details('Junk One', '---', dob, 'Karachi', null, 'Clifton', 'House 1',
                                        'Lahore', null, 'Civil Lines', 'Street 9');
  if (select (full_name, phone) from public.profiles where id = auth.uid())::text
       is distinct from row('Junk One', '---')::text or s436.writes() - n <> 1 then
    raise exception 'FAIL: L4c a stored "---" sent back blocked or changed a name-only save';
  end if;
  perform public.update_profile_details('Junk One', null, dob, 'Karachi', null, 'Clifton', 'House 1',
                                        'Lahore', null, 'Civil Lines', 'Street 9');
  if (select phone from public.profiles where id = auth.uid()) is not null then
    raise exception 'FAIL: L4c a stored "---" must be clearable';
  end if;
end $$;
reset role;
update public.profiles set phone = '   ' where id = (select v::uuid from s436.ids where k = 'user');
set local role authenticated;
do $$
declare
  dob date := date '2000-05-01';
  n bigint := s436.writes();
begin
  perform public.update_profile_details('Junk Two', '   ', dob, 'Karachi', null, 'Clifton', 'House 1',
                                        'Lahore', null, 'Civil Lines', 'Street 9');
  if (select (full_name, phone) from public.profiles where id = auth.uid())::text
       is distinct from row('Junk Two', '   ')::text or s436.writes() - n <> 1 then
    raise exception 'FAIL: L4c a stored blank phone sent back must stay as it is';
  end if;
  perform public.update_profile_details('Junk Two', '', dob, 'Karachi', null, 'Clifton', 'House 1',
                                        'Lahore', null, 'Civil Lines', 'Street 9');
  if (select phone from public.profiles where id = auth.uid()) is not null then
    raise exception 'FAIL: L4c an empty phone must clear a stored blank one';
  end if;
  raise notice 'PASSED: L4c stored "---" / blank phones: kept when sent back, cleared on request';
end $$;

-- L4d (finding 2): values without digits are compared with all whitespace
-- removed, on both sides: a stored "- -" sent back as "--" (or as stored)
-- is no change; a different digit-less value is still refused.
reset role;
update public.profiles set phone = '- -' where id = (select v::uuid from s436.ids where k = 'user');
set local role authenticated;
do $$
declare
  dob date := date '2000-05-01';
  n bigint := s436.writes();
begin
  perform public.update_profile_details('Dash One', '--', dob, 'Karachi', null, 'Clifton', 'House 1',
                                        'Lahore', null, 'Civil Lines', 'Street 9');
  perform public.update_profile_details('Dash One', '- -', dob, 'Karachi', null, 'Clifton', 'House 1',
                                        'Lahore', null, 'Civil Lines', 'Street 9');
  perform public.update_profile_details('Dash One', E'-\t-', dob, 'Karachi', null, 'Clifton', 'House 1',
                                        'Lahore', null, 'Civil Lines', 'Street 9');
  if (select (full_name, phone) from public.profiles where id = auth.uid())::text
       is distinct from row('Dash One', '- -')::text or s436.writes() - n <> 1 then
    raise exception 'FAIL: L4d "- -" sent back as "--" (or as stored) must be no change';
  end if;
  perform s436.refused_before_writing(format('select public.update_profile_details(%L, %L, %L::date, %L, null, %L, %L, %L, null, %L, %L)',
    'Dash Two', '---', dob, 'Karachi', 'Clifton', 'House 1', 'Lahore', 'Civil Lines', 'Street 9'),
    'phone must be a Pakistani mobile number');
  raise notice 'PASSED: L4d digit-less phones compared without whitespace ("- -" = "--"); another digit-less value refused';
end $$;

-- L5: a signed-in user without a profile row (m3) → "profile not found", nothing written.
reset role;
with u as (insert into auth.users (email) values ('edit-l5@s436.local.test') returning id)
insert into s436.ids select 'user2', id::text from u;
delete from public.profiles where id = (select v::uuid from s436.ids where k = 'user2');
select set_config('request.jwt.claims',
  json_build_object('sub', (select v from s436.ids where k = 'user2'), 'role', 'authenticated')::text, true);
set local role authenticated;
do $$
declare
  n bigint := s436.writes();
begin
  if auth.uid() is distinct from (select v::uuid from s436.ids where k = 'user2') then
    raise exception 'UNSAFE: not the second local test user';
  end if;
  begin
    perform public.update_profile_details('No Profile', '03001234567', date '2000-05-01', 'Lahore', null, 'Gulberg', 'House 1');
    raise exception 'FAIL: accepted a call without a profile row';
  exception when no_data_found then
    if sqlerrm <> 'profile not found' then raise; end if;
  end;
  if s436.writes() <> n or exists (select 1 from public.profiles where id = auth.uid())
     or exists (select 1 from public.current_addresses) or exists (select 1 from public.permanent_addresses) then
    raise exception 'FAIL: a call without a profile row wrote something';
  end if;
  raise notice 'PASSED: L5 no profile row → profile not found (P0002), nothing written';
end $$;

-- L6 (findings 5 and F1): "same as current", but the permanent row drifted
-- (another city id and text, e.g. left over from older data) and the current
-- city was deactivated since. A name-only save must not be refused about the
-- permanent city, and the permanent row is brought back in step with the
-- current row as stored — on the app's normal TEXT-ONLY path (no id sent)
-- first, then with the unchanged id sent; then the same with an ambiguous
-- city name ("Kamra", two towns), where the text alone can't give the id.
reset role;
select set_config('request.jwt.claims',
  json_build_object('sub', (select v from s436.ids where k = 'user'), 'role', 'authenticated')::text, true);
set local role authenticated;
do $$
begin
  perform public.save_profile_setup_v2('Drift Test', '0300 1234567', date '2000-05-01',
                                       (select v::int from s436.ids where k = 'lahore'), 'Gulberg', 'House 1', true);
end $$;
reset role;
-- s436.drift(): the owner pushes the permanent row to Faisalabad (as old data could have left it).
create function s436.drift() returns void language sql security definer set search_path = '' as $$
  update public.permanent_addresses set city_id = (select v::int from s436.ids where k = 'faisalabad'), area = 'Civil Lines'
   where user_id = (select v::uuid from s436.ids where k = 'user');
$$;
grant execute on function s436.drift() to authenticated;
update public.cities set is_active = false where id = (select v::int from s436.ids where k = 'lahore');
set local role authenticated;
do $$
declare
  lahore int := (select v::int from s436.ids where k = 'lahore');
  faisalabad int := (select v::int from s436.ids where k = 'faisalabad');
  kamra int := (select v::int from s436.ids where k = 'kamra_attock');
  dob date := date '2000-05-01';
  want text;
begin
  perform s436.drift();
  if (select (city, city_id, area) from public.permanent_addresses where user_id = auth.uid())::text
       is distinct from row('Faisalabad', faisalabad, 'Civil Lines')::text
     or (select (city_id, permanent_same_as_current) from public.current_addresses ca
           join public.profiles p on p.id = ca.user_id where ca.user_id = auth.uid())::text
       is distinct from row(lahore, true)::text then
    raise exception 'FAIL: L6 setup (drifted permanent row, same as current) did not hold';
  end if;
  want := row('Lahore', lahore, 'Gulberg', 'House 1')::text;

  -- L6a: text-only name-only save (no id sent — the app's normal path).
  perform public.update_profile_details('Drift Text', '03001234567', dob, 'Lahore', null, 'Gulberg', 'House 1');
  if (select full_name from public.profiles where id = auth.uid()) <> 'Drift Text'
     or (select (city, city_id, area, address) from public.current_addresses where user_id = auth.uid())::text <> want
     or (select (city, city_id, area, address) from public.permanent_addresses where user_id = auth.uid())::text <> want then
    raise exception 'FAIL: L6a text-only: the drifted permanent row must become the current row (%), got %', want,
      (select (city, city_id, area, address) from public.permanent_addresses where user_id = auth.uid())::text;
  end if;

  -- L6b: the same with the unchanged current id sent.
  perform s436.drift();
  perform public.update_profile_details('Drift Id', '03001234567', dob, 'Lahore', lahore, 'Gulberg', 'House 1');
  if (select full_name from public.profiles where id = auth.uid()) <> 'Drift Id'
     or (select (city, city_id, area, address) from public.permanent_addresses where user_id = auth.uid())::text <> want then
    raise exception 'FAIL: L6b with the id: the drifted permanent row must become the current row';
  end if;

  -- L6c: in step → a save writes neither address row.
  want := (select ctid::text from public.permanent_addresses where user_id = auth.uid())
       || (select ctid::text from public.current_addresses where user_id = auth.uid());
  perform public.update_profile_details('Drift Id', '03001234567', dob, 'Lahore', null, 'Gulberg', 'House 1');
  if want <> (select ctid::text from public.permanent_addresses where user_id = auth.uid())
            || (select ctid::text from public.current_addresses where user_id = auth.uid()) then
    raise exception 'FAIL: L6c rows in step must not be rewritten';
  end if;

  -- L6d: a NEW pick of a deactivated city is still refused.
  begin
    perform public.update_profile_details('Drift Id', '03001234567', dob, 'Faisalabad', faisalabad, 'Civil Lines', 'House 1');
    perform public.update_profile_details('Drift Id', '03001234567', dob, 'Lahore', lahore, 'Gulberg', 'House 1');
    raise exception 'FAIL: L6d accepted re-picking the deactivated city';
  exception when check_violation then
    if sqlerrm <> 'current_city_id must be an active city' then raise; end if;
  end;

  -- L6e: ambiguous name. Current = Kamra (Attock) by id; permanent drifted;
  -- a text-only save sending "Kamra" (two towns: the text alone resolves to
  -- no id) still gives the permanent row the current row's id.
  perform public.update_profile_details('Drift Kamra', '03001234567', dob, 'Kamra', kamra, 'Cantt', 'House 1');
  perform s436.drift();
  perform public.update_profile_details('Drift Kamra', '03001234567', dob, 'Kamra', null, 'Cantt', 'House 1');
  if (select (city, city_id, area) from public.permanent_addresses where user_id = auth.uid())::text
       is distinct from row('Kamra', kamra, 'Cantt')::text then
    raise exception 'FAIL: L6e the permanent row must take the current row''s id for an ambiguous name, got %',
      (select (city, city_id, area) from public.permanent_addresses where user_id = auth.uid())::text;
  end if;
  raise notice 'PASSED: L6 a drifted same-as-current permanent row never blocks a save and is brought back in step (text-only path, with the id, ambiguous name); rows in step are not rewritten';
end $$;

-- L6f (finding 1, case 1): the current row's id came from an ALIAS whose
-- city was deactivated since — its text no longer keeps that id under
-- migration 8. The permanent copy must still get exactly that id (with the
-- city's plain name), and a later save must not rewrite it again.
reset role;
insert into public.city_aliases (city_id, alias, source)
values ((select v::int from s436.ids where k = 'attock'), 'Atk Testalias', 'manual');
set local role authenticated;
do $$
declare
  attock int := (select v::int from s436.ids where k = 'attock');
begin
  -- Text only: migration 8 resolves the alias to Attock on the current row; the copy follows.
  perform public.update_profile_details('Alias Test', '03001234567', date '2000-05-01', 'Atk Testalias', null, 'Saddar', 'House 1');
  if (select (city, city_id) from public.current_addresses where user_id = auth.uid())::text
       is distinct from row('Atk Testalias', attock)::text
     or (select (city, city_id) from public.permanent_addresses where user_id = auth.uid())::text
       is distinct from row('Atk Testalias', attock)::text then
    raise exception 'FAIL: L6f setup: the alias must resolve to Attock on both rows';
  end if;
end $$;
reset role;
update public.cities set is_active = false where id = (select v::int from s436.ids where k = 'attock');
set local role authenticated;
do $$
declare
  attock int := (select v::int from s436.ids where k = 'attock');
  v text;
begin
  perform s436.drift();
  perform public.update_profile_details('Alias Test', '03001234567', date '2000-05-01', 'Atk Testalias', null, 'Saddar', 'House 1');
  if (select (city, city_id) from public.current_addresses where user_id = auth.uid())::text
       is distinct from row('Atk Testalias', attock)::text then
    raise exception 'FAIL: L6f the current row must keep its text and id';
  end if;
  if (select (city_id, city, area, address) from public.permanent_addresses where user_id = auth.uid())::text
       is distinct from row(attock, (select name from public.cities where id = attock), 'Saddar', 'House 1')::text then
    raise exception 'FAIL: L6f the permanent copy must get exactly the current id (stale alias), got %',
      (select (city_id, city, area, address) from public.permanent_addresses where user_id = auth.uid())::text;
  end if;
  v := (select ctid::text from public.permanent_addresses where user_id = auth.uid());
  perform public.update_profile_details('Alias Test', '03001234567', date '2000-05-01', 'Atk Testalias', null, 'Saddar', 'House 1');
  if v <> (select ctid::text from public.permanent_addresses where user_id = auth.uid()) then
    raise exception 'FAIL: L6f a later save must not rewrite the permanent copy again';
  end if;
  raise notice 'PASSED: L6f stale alias: the permanent copy gets exactly the current id (plain name), and stays in step';
end $$;

-- L6g (finding 1, case 2): the current row has NO city id, but its text
-- now resolves to a city (here: its id was cleared directly). The permanent
-- copy must get exactly NULL too — not the id migration 8 would resolve from
-- the text — and a later save must not rewrite it again.
set local role authenticated;
do $$
begin
  perform public.update_profile_details('Null Test', '03001234567', date '2000-05-01', 'Karachi', null, 'Saddar', 'House 1');
end $$;
reset role;
update public.current_addresses set city_id = null where user_id = (select v::uuid from s436.ids where k = 'user');
set local role authenticated;
do $$
declare
  karachi int := (select v::int from s436.ids where k = 'karachi');
  v text;
begin
  if (select (city, city_id) from public.current_addresses where user_id = auth.uid())::text
       is distinct from row('Karachi', null::int)::text
     or public.resolve_city_id('Karachi') is distinct from karachi then
    raise exception 'FAIL: L6g setup: current must be (Karachi, NULL) with Karachi resolvable';
  end if;
  perform s436.drift();
  perform public.update_profile_details('Null Test', '03001234567', date '2000-05-01', 'Karachi', null, 'Saddar', 'House 1');
  if (select (city_id, city, area, address) from public.permanent_addresses where user_id = auth.uid())::text
       is distinct from row(null::int, 'Karachi', 'Saddar', 'House 1')::text then
    raise exception 'FAIL: L6g the permanent copy must get exactly the current NULL id, got %',
      (select (city_id, city, area, address) from public.permanent_addresses where user_id = auth.uid())::text;
  end if;
  v := (select ctid::text from public.permanent_addresses where user_id = auth.uid());
  perform public.update_profile_details('Null Test', '03001234567', date '2000-05-01', 'Karachi', null, 'Saddar', 'House 1');
  if v <> (select ctid::text from public.permanent_addresses where user_id = auth.uid()) then
    raise exception 'FAIL: L6g a later save must not rewrite the permanent copy again';
  end if;
  raise notice 'PASSED: L6g current id NULL with resolvable text: the permanent copy gets exactly NULL, and stays in step';
end $$;

-- L6h: the current text is the LABEL of a city deactivated since ("Kamra
-- (Rawalpindi)"). Migration 8 still lets a row keep its label with that id,
-- so the permanent copy gets exactly the current text AND id — not the plain
-- name — and a later save must not rewrite it again.
set local role authenticated;
do $$
begin
  perform public.update_profile_details('Label Test', '03001234567', date '2000-05-01', 'Kamra (Rawalpindi)', null, 'Saddar', 'House 1');
end $$;
reset role;
update public.cities set is_active = false where id = (select v::int from s436.ids where k = 'kamra_rwp');
set local role authenticated;
do $$
declare
  rwp int := (select v::int from s436.ids where k = 'kamra_rwp');
  v text;
begin
  if (select (city, city_id) from public.current_addresses where user_id = auth.uid())::text
       is distinct from row('Kamra (Rawalpindi)', rwp)::text then
    raise exception 'FAIL: L6h setup: current must be (Kamra (Rawalpindi), Kamra Rawalpindi id)';
  end if;
  perform s436.drift();
  perform public.update_profile_details('Label Test', '03001234567', date '2000-05-01', 'Kamra (Rawalpindi)', null, 'Saddar', 'House 1');
  if (select (city_id, city, area, address) from public.permanent_addresses where user_id = auth.uid())::text
       is distinct from row(rwp, 'Kamra (Rawalpindi)', 'Saddar', 'House 1')::text then
    raise exception 'FAIL: L6h the permanent copy must get exactly the current label and id, got %',
      (select (city_id, city, area, address) from public.permanent_addresses where user_id = auth.uid())::text;
  end if;
  v := (select ctid::text from public.permanent_addresses where user_id = auth.uid());
  perform public.update_profile_details('Label Test', '03001234567', date '2000-05-01', 'Kamra (Rawalpindi)', null, 'Saddar', 'House 1');
  if v <> (select ctid::text from public.permanent_addresses where user_id = auth.uid()) then
    raise exception 'FAIL: L6h a later save must not rewrite the permanent copy again';
  end if;
  raise notice 'PASSED: L6h label of a deactivated city: the permanent copy gets exactly the current label and id, and stays in step';
end $$;

rollback;
