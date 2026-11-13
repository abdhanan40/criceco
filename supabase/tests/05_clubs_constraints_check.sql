-- CricEco · clubs: value rules, create_club() inputs and timestamps.
-- One transaction, ROLLED BACK at the end: no data is kept.
-- Run after migration 5 (20261109090000_create_clubs.sql).
-- Uses one FRESH test user (Profile Setup not done; replace USER_A with its
-- UUID). Every check raises on failure, so reaching "ALL CLUBS CONSTRAINT
-- CHECKS PASSED" means all passed.
--
-- Run the WHOLE script at once — never a highlighted part. If it stops with
-- an error, run `rollback;` on its own before anything else.
-- Safety: every block first checks it is running as the signed-in test user
-- (or, for the last block, as the database owner touching only USER_A's
-- club), and every write names USER_A's rows explicitly.

begin;

select set_config('request.jwt.claims',
  json_build_object('sub', 'USER_A', 'role', 'authenticated')::text, true);
set local role authenticated;

select public.save_profile_setup(
  'Test User A', '+923001234567', date '2000-05-01',
  'Lahore', 'Gulberg', 'House 1, Street 2',
  true);

-- ---------------------------------------------------------------------------
-- create_club() inputs (no club exists yet, so every call really inserts)
-- ---------------------------------------------------------------------------
do $$
declare
  bad record;
  v_constraint text;
begin
  if current_user <> 'authenticated' or auth.uid() is distinct from 'USER_A'::uuid then
    raise exception 'UNSAFE: not running as test user USER_A — stopping (nothing written)';
  end if;

  -- Required values: a clear message, never a raw NOT NULL error.
  for bad in
    select * from (values
      ('empty name',  '',      'Lahore', 'corporate',    'club name is required'),
      ('blank name',  '   ',   'Lahore', 'corporate',    'club name is required'),
      ('null name',   null,    'Lahore', 'corporate',    'club name is required'),
      ('empty city',  'Lions', '',       'corporate',    'club city is required'),
      ('null city',   'Lions', null,     'corporate',    'club city is required'),
      ('null type',   'Lions', 'Lahore', null,           'club type is required'),
      ('blank type',  'Lions', 'Lahore', '  ',           'club type is required')
    ) as t(label, p_name, p_city, p_type, message)
  loop
    begin
      perform public.create_club(bad.p_name, bad.p_city, bad.p_type);
      raise exception 'FAIL: create_club accepted %', bad.label;
    exception when check_violation then
      if sqlerrm <> bad.message then
        raise exception 'FAIL: % gave "%" instead of "%"', bad.label, sqlerrm, bad.message;
      end if;
    end;
  end loop;

  -- Values the table rules refuse, reported by constraint name.
  for bad in
    select * from (values
      ('a name without letters', '123',           'Lahore',       'corporate', 'clubs_name_check'),
      ('a 101-character name',   repeat('a', 101), 'Lahore',      'corporate', 'clubs_name_check'),
      ('a 101-character city',   'Lions',          repeat('c', 101), 'corporate', 'clubs_city_check'),
      ('an unknown club type',   'Lions',          'Lahore',       'amateur',   'clubs_club_type_check'),
      ('a club type in capitals','Lions',          'Lahore',       'Corporate', 'clubs_club_type_check')
    ) as t(label, p_name, p_city, p_type, expected)
  loop
    begin
      perform public.create_club(bad.p_name, bad.p_city, bad.p_type);
      raise exception 'FAIL: create_club accepted %', bad.label;
    exception when check_violation then
      get stacked diagnostics v_constraint = constraint_name;
      if v_constraint is distinct from bad.expected then
        raise exception 'FAIL: % was refused by % instead of %', bad.label, v_constraint, bad.expected;
      end if;
    end;
  end loop;

  begin
    perform public.create_club('Lions', 'Lahore', 'corporate', 'Owner', 'Street', 'not-an-email');
    raise exception 'FAIL: create_club accepted an invalid email';
  exception when check_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint <> 'clubs_email_check' then raise; end if;
  end;

  if exists (select 1 from public.clubs where owner_id = 'USER_A') then
    raise exception 'FAIL: a refused create_club left a club behind';
  end if;
  raise notice 'PASS: create_club refuses missing and invalid values (nothing stored)';
end $$;

-- A valid club; blank optional values are stored as NULL.
do $$
declare
  c public.clubs;
begin
  if current_user <> 'authenticated' or auth.uid() is distinct from 'USER_A'::uuid then
    raise exception 'UNSAFE: not running as test user USER_A — stopping (nothing written)';
  end if;
  c := public.create_club('1st XI', ' Lahore ', 'college_university', '   ', '', '  ', ' ');
  if c.name <> '1st XI' or c.city <> 'Lahore' or c.club_type <> 'college_university' then
    raise exception 'FAIL: valid values not stored as expected';
  end if;
  if c.owner_name is not null or c.address is not null or c.email is not null or c.home_ground_id is not null then
    raise exception 'FAIL: blank optional values were not stored as NULL';
  end if;
  if c.code !~ '^[A-HJ-NP-Z2-9]{6}$' then
    raise exception 'FAIL: join code % is not 6 characters from the code alphabet', c.code;
  end if;
  raise notice 'PASS: a valid club is created; blank optional values become NULL';
end $$;

-- ---------------------------------------------------------------------------
-- Every value rule, on update (the Club profile edit path)
-- ---------------------------------------------------------------------------
do $$
declare
  bad record;
  v_constraint text;
begin
  if current_user <> 'authenticated' or auth.uid() is distinct from 'USER_A'::uuid then
    raise exception 'UNSAFE: not running as test user USER_A — stopping (nothing written)';
  end if;

  for bad in
    select * from (values
      ('empty name',                'name',             '',                         'text',     'clubs_name_check'),
      ('blank name',                'name',             '   ',                      'text',     'clubs_name_check'),
      ('name without letters',      'name',             '2024',                     'text',     'clubs_name_check'),
      ('101-character name',        'name',             repeat('n', 101),           'text',     'clubs_name_check'),
      ('empty short name',          'short_name',       '',                         'text',     'clubs_short_name_check'),
      ('41-character short name',   'short_name',       repeat('s', 41),            'text',     'clubs_short_name_check'),
      ('empty city',                'city',             '',                         'text',     'clubs_city_check'),
      ('101-character city',        'city',             repeat('c', 101),           'text',     'clubs_city_check'),
      ('unknown club type',         'club_type',        'amateur',                  'text',     'clubs_club_type_check'),
      ('1-character owner name',    'owner_name',       'A',                        'text',     'clubs_owner_name_check'),
      ('101-character owner name',  'owner_name',       repeat('o', 101),           'text',     'clubs_owner_name_check'),
      ('empty address',             'address',          '',                         'text',     'clubs_address_check'),
      ('501-character address',     'address',          repeat('x', 501),           'text',     'clubs_address_check'),
      ('email without @',           'email',            'club.example.com',         'text',     'clubs_email_check'),
      ('email without domain dot',  'email',            'club@example',             'text',     'clubs_email_check'),
      ('email with a space',        'email',            'club owner@example.com',   'text',     'clubs_email_check'),
      ('255-character email',       'email',            repeat('e', 243) || '@example.com', 'text', 'clubs_email_check'),
      ('empty home ground id',      'home_ground_id',   '',                         'text',     'clubs_home_ground_id_check'),
      ('65-character home ground',  'home_ground_id',   repeat('g', 65),            'text',     'clubs_home_ground_id_check'),
      ('established 1799',          'established_year', '1799',                     'smallint', 'clubs_established_year_check'),
      ('established 2101',          'established_year', '2101',                     'smallint', 'clubs_established_year_check')
    ) as t(label, col, val, typ, expected)
  loop
    begin
      execute format('update public.clubs set %I = $1::%s where owner_id = $2', bad.col, bad.typ)
        using bad.val, 'USER_A'::uuid;
      raise exception 'FAIL: accepted %', bad.label;
    exception when check_violation then
      get stacked diagnostics v_constraint = constraint_name;
      if v_constraint is distinct from bad.expected then
        raise exception 'FAIL: % was refused by % instead of %', bad.label, v_constraint, bad.expected;
      end if;
    end;
  end loop;

  -- Required columns can't be cleared.
  for bad in select unnest(array['name', 'city', 'club_type']) as col loop
    begin
      execute format('update public.clubs set %I = null where owner_id = $1', bad.col) using 'USER_A'::uuid;
      raise exception 'FAIL: % was cleared', bad.col;
    exception when not_null_violation then null;
    end;
  end loop;
  raise notice 'PASS: every club value rule refuses bad values';
end $$;

-- Boundary values are accepted.
do $$
declare
  ok record;
  n  integer;
begin
  if current_user <> 'authenticated' or auth.uid() is distinct from 'USER_A'::uuid then
    raise exception 'UNSAFE: not running as test user USER_A — stopping (nothing written)';
  end if;
  for ok in
    select * from (values
      ('1-letter name',             'name',             'A',                      'text'),
      ('100-character name',        'name',             repeat('n', 100),         'text'),
      ('Urdu name',                 'name',             'لاہور لائنز',            'text'),
      ('40-character short name',   'short_name',       repeat('s', 40),          'text'),
      ('100-character city',        'city',             repeat('c', 100),         'text'),
      ('each club type: professional', 'club_type',     'professional',           'text'),
      ('each club type: corporate', 'club_type',        'corporate',              'text'),
      ('2-character owner name',    'owner_name',       'Al',                     'text'),
      ('500-character address',     'address',          repeat('x', 500),         'text'),
      ('a normal email',            'email',            'owner.name@example.com.pk', 'text'),
      ('64-character home ground',  'home_ground_id',   repeat('g', 64),          'text'),
      ('established 1800',          'established_year', '1800',                   'smallint'),
      ('established 2100',          'established_year', '2100',                   'smallint')
    ) as t(label, col, val, typ)
  loop
    execute format('update public.clubs set %I = $1::%s where owner_id = $2', ok.col, ok.typ)
      using ok.val, 'USER_A'::uuid;
    -- (EXECUTE doesn't set FOUND; the row count says whether it was saved.)
    get diagnostics n = row_count;
    if n <> 1 then raise exception 'FAIL: % was not saved', ok.label; end if;
  end loop;
  -- Optional values can be cleared again.
  update public.clubs
     set short_name = null, owner_name = null, address = null, email = null,
         home_ground_id = null, established_year = null
   where owner_id = 'USER_A';
  raise notice 'PASS: boundary values are accepted; optional values can be cleared';
end $$;

-- ---------------------------------------------------------------------------
-- As the database owner (USER_A's club only): created_at stays, the code
-- rule holds even where column grants don't apply.
-- ---------------------------------------------------------------------------
reset role;
do $$
declare
  before_created timestamptz;
  v_constraint text;
begin
  if (select count(*) from public.clubs where owner_id = 'USER_A') <> 1 then
    raise exception 'UNSAFE: expected exactly USER_A''s test club — stopping';
  end if;
  select created_at into before_created from public.clubs where owner_id = 'USER_A';
  update public.clubs set created_at = created_at - interval '10 days' where owner_id = 'USER_A';
  if (select created_at from public.clubs where owner_id = 'USER_A') <> before_created then
    raise exception 'FAIL: created_at changed';
  end if;
  begin
    update public.clubs set code = 'abc123' where owner_id = 'USER_A';
    raise exception 'FAIL: a malformed join code was accepted';
  exception when check_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint <> 'clubs_code_check' then raise; end if;
  end;
  raise notice 'PASS: created_at can''t change; the join-code format is enforced';
end $$;

-- Reaching this line means every check above passed.
select 'ALL CLUBS CONSTRAINT CHECKS PASSED' as result;

rollback;
