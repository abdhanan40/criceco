-- CricEco · migration 9 (update_profile_details): catalog, privileges and
-- behaviour. Everything runs inside one transaction and is ROLLED BACK at
-- the end: no data is kept. Run after migration 9, with the location data
-- (D1) loaded.
--
-- PART 1 (catalog, privileges) is read-only and needs no test users. PART 2
-- needs TWO FRESH test users (Profile Setup not done): create them in
-- Dashboard → Authentication → Users → Add user (auto-confirm) and
-- search-replace USER_A and USER_B below with their UUIDs.
-- Both are checked to be fresh (the sign-up trigger's bare profile: no name,
-- no role, Profile Setup not done, no rows) before anything is written.
-- Run the WHOLE script at once. Everything after `begin;` is one
-- transaction: a failing check raises an exception, after which nothing
-- else runs (SQL Editor) or every later statement fails (psql) — then run
-- `rollback;` on its own. Afterwards delete the test users (their rows go
-- with them).
-- "Unchanged" is checked by each row's ctid (a written row gets a new row
-- version), since last_updated_at = now() is constant inside one
-- transaction. Cities are looked up by GeoNames id (stable across databases).

begin;

-- ===================== PART 1 — as the database owner (read-only) =====================

-- The row-lock check, a TEXT check of a function definition's EXPLICIT
-- locking clauses: NULL when its SELECT … FOR … clauses are exactly the
-- three FOR NO KEY UPDATE locks on the caller's profile, current and
-- permanent rows, in that TEXTUAL order, and it contains no other explicit
-- lock (LOCK, advisory locks, NOWAIT / SKIP LOCKED, other FOR clauses);
-- else what is wrong. It does NOT inspect implicit row locks — those every
-- UPDATE / INSERT (incl. ON CONFLICT) / DELETE / MERGE / foreign-key check
-- takes — nor locks taken inside functions the body calls, so it does not
-- by itself prove the order in which rows are locked at run time.
--   1. Forms this check does not parse are REFUSED (looked for in the raw
--      text, so no stripping can hide them): E'…' strings, dollar quotes
--      other than the one pair that wraps the body ($function$ … $function$;
--      any tag, also with digits or letters beyond a-z), and nested
--      /* /* */ */ block comments. A -- comment ends at a line feed or a
--      carriage return, as in PostgreSQL.
--   2. String literals ('…', '' escapes), /* */ and -- comments are each
--      replaced by ONE SPACE, in one left-to-right pass (whichever starts
--      first wins, so "--" inside a string or a quote inside a comment can't
--      hide code), and tokens around a comment can't join ("for/**/update").
--   3. Then refused: a quoted identifier ("…" is not parsed), dynamic SQL
--      (EXECUTE: its statement is a string), the three FOR NO KEY UPDATE
--      locks missing or out of order, any other FOR UPDATE / FOR SHARE /
--      FOR KEY SHARE / FOR NO KEY UPDATE, NOWAIT, SKIP LOCKED, LOCK [TABLE],
--      advisory locks — matched whitespace-tolerantly.
-- Limits: it reads TEXT. Beyond the implicit locks above, it can't tell
-- whether a lock clause actually runs (e.g. under "if false"). The ACTUAL
-- row-lock behaviour — which lock is held on each row, that a concurrent
-- writer is waited for, side by side with save_profile_setup_v2 — is
-- verified by the two-session test tests/local/08b, locally only. Being
-- strict, it can refuse harmless code (e.g. a "$x$" or "e'" in a comment).
create function pg_temp.lock_clause_problem(p_def text) returns text language plpgsql immutable as $fn$
declare
  -- A -- comment ends at a line feed OR a carriage return, as in PostgreSQL.
  tokens constant text := $re$'([^']|'')*'|/\*([^*]|\*+[^*/])*\*+/|--[^\r\n]*$re$;
  raw  text := lower(p_def);
  code text := lower(regexp_replace(p_def, tokens, ' ', 'g'));
begin
  -- 1. Not parsed → refused (raw text).
  if raw ~ $re$\me'$re$ then
    return 'an E-string (not parsed by this check)';
  end if;
  -- Any $tag$ (PostgreSQL allows letters beyond a-z, e.g. $é$, and digits).
  if (select count(*) from regexp_matches(raw, $re$\$[^$[:space:]]*\$$re$, 'g')) > 2 then
    return 'a nested dollar quote (not parsed by this check)';
  end if;
  if exists (select 1 from regexp_matches(raw, '(' || tokens || ')', 'g') t
              where t[1] like '/*%' and position('/*' in substr(t[1], 3)) > 0) then
    return 'a nested block comment (not parsed by this check)';
  end if;
  -- 3. On the code with strings and comments removed.
  if position('"' in code) > 0 then
    return 'a quoted identifier (not parsed by this check)';
  end if;
  if code ~ $re$\mexecute\M$re$ then
    return 'dynamic SQL (EXECUTE)';
  end if;
  if (select array_agg(m[1] order by ord)
        from regexp_matches(code,
               $re$from\s+public\.(profiles|current_addresses|permanent_addresses)\s+[a-z]+\s+where\s+[a-z_.]+\s*=\s*v_uid\s+for\s+no\s+key\s+update\s*;$re$,
               'g') with ordinality as x(m, ord))
       is distinct from array['profiles', 'current_addresses', 'permanent_addresses'] then
    return 'the three FOR NO KEY UPDATE row locks (profile → current → permanent) are not all there, in order';
  end if;
  if (select count(*) from regexp_matches(code, $re$\mfor\s+(no\s+key\s+update|update|share|key\s+share)\M$re$, 'g')) <> 3 then
    return 'another FOR UPDATE / FOR SHARE / FOR KEY SHARE / FOR NO KEY UPDATE clause';
  end if;
  if code ~ $re$\m(nowait|skip\s+locked)\M$re$ then
    return 'NOWAIT or SKIP LOCKED';
  end if;
  if code ~ $re$\mlock\M$re$ then
    return 'a LOCK [TABLE] statement';
  end if;
  if code ~ $re$pg_[a-z_]*advisory$re$ then
    return 'an advisory lock';
  end if;
  return null;
end $fn$;

-- Its own cases first (pure string checks: nothing is read or written).
-- Each invalid case names the refusal it must reach (so every branch is
-- exercised on its own); each case except the plain one must differ from
-- the plain text (a replace() that matched nothing would test nothing).
do $$
declare
  ok constant text := $s$
    select 1 from public.profiles pr where pr.id = v_uid
     for no key update;
    select 1 from public.current_addresses ca where ca.user_id = v_uid
     for no key update;
    select 1 from public.permanent_addresses pa where pa.user_id = v_uid
     for no key update;$s$;
  wrapped constant text := E'create or replace function public.f()\n returns void\n language plpgsql\nas $function$\nbegin'
                           || ok || E'\nend;\n$function$\n';
  c record;
  got text;
  n_valid int := 0;
  n_invalid int := 0;
begin
  for c in select * from (values
    -- valid (want NULL): plain, odd whitespace / tabs / line breaks / upper
    -- case, comments inside the clauses, lock words in strings / comments,
    -- and the body wrapped in its $function$ pair as pg_get_functiondef shows it
    ('valid plain', ok, null),
    ('valid odd whitespace', replace(replace(replace(ok, ' for no key update;', E'\tFOR   NO\n  KEY  UPDATE ;'),
       'from public.current', E'FROM\n public.current'), 'where pa.user_id', E'WHERE\tpa.user_id'), null),
    ('valid comments inside clauses', replace(ok, E'\n     for no key update;', ' for /* row lock */ no -- note' || E'\n key update ;'), null),
    ('valid lock words in strings / comments', ok || $s$ raise exception 'for update nowait; lock table x; execute'; /* for share */ -- skip locked $s$, null),
    ('valid wrapped in $function$', wrapped, null),
    -- invalid (want: the refusal named)
    ('E-string', ok || $s$ v := E'\'' ; $s$, 'E-string'),
    ('nested dollar quote', replace(wrapped, 'begin', $s$begin v := $x$ for update $x$;$s$), 'nested dollar quote'),
    ('dollar tag with digits', ok || $s$ v := $q1$'$q1$; perform 1 from public.clubs c for update; v := $q1$'$q1$;$s$, 'nested dollar quote'),
    ('dollar tag with non-ASCII letters', ok || $s$ v := $é$'$é$; perform 1 from public.clubs c for update; v := $é$'$é$;$s$, 'nested dollar quote'),
    ('a carriage return ends a -- comment', ok || E' -- note\r perform 1 from public.clubs c for update;\n', 'another FOR'),
    ('nested block comment', ok || $s$ /* a /* b */ ' */ perform 1 from public.clubs c for update; -- '$s$, 'nested block comment'),
    ('quoted identifier with --', ok || ' perform 1 from public.clubs as "a--b" for update;', 'quoted identifier'),
    ('quoted identifier with a quote', ok || $s$ perform 1 from public.clubs as "it's" for update; -- '$s$, 'quoted identifier'),
    ('EXECUTE a lock', ok || $s$ execute 'select 1 from public.clubs for update';$s$, 'dynamic SQL'),
    ('EXECUTE lock table', ok || $s$ execute 'lock table public.clubs';$s$, 'dynamic SQL'),
    ('a required lock missing', replace(ok, E'ca.user_id = v_uid\n     for no key update;', 'ca.user_id = v_uid;'), 'not all there'),
    ('FOR UPDATE instead', regexp_replace(ok, 'for no key update;', 'for update;'), 'not all there'),
    ('wrong order', replace(replace(replace(ok, 'public.profiles pr where pr.id', 'public.XX'),
       'public.current_addresses ca where ca.user_id', 'public.profiles pr where pr.id'),
       'public.XX', 'public.current_addresses ca where ca.user_id'), 'not all there'),
    ('required lock /**/nowait', regexp_replace(ok, 'for no key update;', 'for no key update/**/nowait;'), 'not all there'),
    ('skip locked on a required lock', regexp_replace(ok, 'for no key update;', E'for no key update skip\n locked;'), 'not all there'),
    ('for/**/update', ok || ' perform 1 from public.clubs c where c.owner_id = v_uid for/**/update;', 'another FOR'),
    ('for share/**/nowait', ok || ' perform 1 from public.clubs c for share/**/nowait;', 'another FOR'),
    ('-- inside a string hides nothing', ok || $s$ if v_phone = '--' then perform 1 from public.clubs c for update; end if;$s$, 'another FOR'),
    ('/* */ inside strings hides nothing', ok || $s$ v := '/*'; perform 1 from public.clubs c for update; v := '*/';$s$, 'another FOR'),
    ('quote inside a comment hides nothing', ok || $s$ /* it's */ perform 1 from public.clubs c for update; /* ' */$s$, 'another FOR'),
    ('for  update (spacing)', ok || E' perform 1 from public.clubs c for \n  update;', 'another FOR'),
    ('for key share', ok || ' perform 1 from public.clubs c for key share;', 'another FOR'),
    ('NOWAIT on its own', ok || ' perform 1 from public.clubs c nowait;', 'NOWAIT or SKIP LOCKED'),
    ('SKIP LOCKED on its own', ok || E' perform 1 from public.clubs c skip\n  locked;', 'NOWAIT or SKIP LOCKED'),
    ('LOCK TABLE', ok || ' lock table public.clubs in exclusive mode;', 'LOCK [TABLE]'),
    ('LOCK without TABLE', ok || ' lock public.clubs;', 'LOCK [TABLE]'),
    ('advisory lock', ok || ' perform pg_advisory_xact_lock(4361);', 'advisory'),
    ('try advisory lock', ok || ' perform pg_try_advisory_lock(1);', 'advisory')
  ) v(name, def, want) loop
    if c.name <> 'valid plain' and c.def = ok then
      raise exception 'FAIL: lock check self-test "%": the case text equals the plain text (its replace() matched nothing)', c.name;
    end if;
    got := pg_temp.lock_clause_problem(c.def);
    if c.want is null and got is not null then
      raise exception 'FAIL: lock check self-test "%": wanted no problem, got "%"', c.name, got;
    elsif c.want is not null and (got is null or position(c.want in got) = 0) then
      raise exception 'FAIL: lock check self-test "%": wanted "%", got "%"', c.name, c.want, coalesce(got, 'no problem');
    end if;
    if c.want is null then n_valid := n_valid + 1; else n_invalid := n_invalid + 1; end if;
  end loop;
  if (n_valid, n_invalid) <> (5, 28) then
    raise exception 'FAIL: lock check self-test ran % valid / % invalid cases (wanted 5 / 28)', n_valid, n_invalid;
  end if;
  raise notice 'PASSED: the lock check''s own cases (% valid, % invalid — each invalid one reaching its own refusal)', n_valid, n_invalid;
end $$;

do $$
declare
  f regprocedure := to_regprocedure(
    'public.update_profile_details(text, text, date, text, integer, text, text, text, integer, text, text)');
  t text;
begin
  if f is null then
    raise exception 'FAIL: update_profile_details(text, text, date, text, integer, text, text, text, integer, text, text) missing';
  end if;
  if (select prosecdef from pg_proc where oid = f)
     or (select provolatile from pg_proc where oid = f) <> 'v'
     or (select prorettype from pg_proc where oid = f) <> 'void'::regtype
     or not ('search_path=""' = any (coalesce((select proconfig from pg_proc where oid = f), '{}'))) then
    raise exception 'FAIL: update_profile_details must be SECURITY INVOKER, VOLATILE, return void, pin search_path to ''''';
  end if;
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'update_profile_details') <> 1 then
    raise exception 'FAIL: exactly one update_profile_details overload expected';
  end if;
  if has_function_privilege('anon', f, 'execute')
     or not has_function_privilege('authenticated', f, 'execute')
     or exists (select 1 from pg_proc p, aclexplode(p.proacl) a
                 where p.oid = f and a.grantee = 0 and a.privilege_type = 'EXECUTE') then
    raise exception 'FAIL: function privileges (PUBLIC and anon none; authenticated execute)';
  end if;
  foreach t in array array['current_addresses', 'permanent_addresses'] loop
    if not has_table_privilege('authenticated', 'public.' || t, 'select')
       or not has_table_privilege('authenticated', 'public.' || t, 'insert')
       or not has_table_privilege('authenticated', 'public.' || t, 'update')
       or has_table_privilege('authenticated', 'public.' || t, 'delete')
       or has_table_privilege('anon', 'public.' || t, 'select') then
      raise exception 'FAIL: % grants changed', t;
    end if;
    if (select count(*) from pg_policies where schemaname = 'public' and tablename = t) <> 3
       or exists (select 1 from pg_policies where schemaname = 'public' and tablename = t and cmd = 'DELETE')
       or not (select relrowsecurity from pg_class where oid = ('public.' || t)::regclass) then
      raise exception 'FAIL: % row level security / policies changed', t;
    end if;
  end loop;
  if not (select relrowsecurity from pg_class where oid = 'public.profiles'::regclass) then
    raise exception 'FAIL: profiles row level security must stay on';
  end if;
  -- The row locks: exactly the caller's profile → current → permanent rows
  -- FOR NO KEY UPDATE, and no other lock (pg_temp.lock_clause_problem above).
  if pg_temp.lock_clause_problem(pg_get_functiondef(f)) is not null then
    raise exception 'FAIL: update_profile_details row locks: %', pg_temp.lock_clause_problem(pg_get_functiondef(f));
  end if;
  -- A row lock needs UPDATE rights and an own-row UPDATE policy on each
  -- locked table, also for an address-only save (existing grants / policies).
  if not has_any_column_privilege('authenticated', 'public.profiles', 'UPDATE')
     or not exists (select 1 from pg_policies
                     where schemaname = 'public' and tablename = 'profiles' and cmd in ('UPDATE', 'ALL')
                       and roles && array['authenticated', 'public']::name[]) then
    raise exception 'FAIL: authenticated needs UPDATE on profiles and an UPDATE policy (the row lock needs both)';
  end if;
  if to_regprocedure('public.save_profile_setup(text, text, date, text, text, text, boolean, text, text, text)') is null
     or to_regprocedure('public.save_profile_setup_v2(text, text, date, integer, text, text, boolean, integer, text, text)') is null then
    raise exception 'FAIL: save_profile_setup v1 and v2 must still exist';
  end if;
  raise notice 'PASSED: function properties, privileges, address grants / RLS / policies unchanged, v1 / v2 kept';
end $$;

-- ===================== PART 2 — as the fresh test users =====================
create temporary table g (k text primary key, id integer) on commit drop;
insert into g
select k, (select id from public.cities where geonames_id = gid)
  from (values ('lahore', 1172451), ('faisalabad', 1179400), ('karachi', 1174872),
               ('kamra_attock', 1340665), ('kamra_rwp', 1175082)) v(k, gid);
grant select on g to authenticated;

-- Everyone else's rows, to compare at the end (one hash; no personal data shown).
create temporary table others_before on commit drop as
  select md5(coalesce(string_agg(r, '|' order by r), '')) as h from (
    select 'p' || id || coalesce(full_name, '') || coalesce(phone, '') || coalesce(date_of_birth::text, '')
           || coalesce(profile_completed::text, '') || coalesce(role, '') || coalesce(last_updated_at::text, '') as r
      from public.profiles where id not in ('USER_A', 'USER_B')
    union all
    select 'c' || user_id || city || coalesce(city_id::text, '') || area || address || last_updated_at
      from public.current_addresses where user_id not in ('USER_A', 'USER_B')
    union all
    select 'm' || user_id || city || coalesce(city_id::text, '') || area || address || last_updated_at
      from public.permanent_addresses where user_id not in ('USER_A', 'USER_B')) x;

-- The signed-in user's three row versions ("-" = no row).
create function pg_temp.rows_now() returns text language sql stable as $$
  select coalesce((select ctid::text from public.profiles where id = auth.uid()), '-') || ' '
      || coalesce((select ctid::text from public.current_addresses where user_id = auth.uid()), '-') || ' '
      || coalesce((select ctid::text from public.permanent_addresses where user_id = auth.uid()), '-')
$$;
-- Runs [p_call]; it must be refused with [p_state] and a message containing
-- [p_fragment] (the call's own changes are rolled back, as for an API call).
create function pg_temp.refused(p_call text, p_state text, p_fragment text) returns void language plpgsql as $$
begin
  execute p_call;
  raise exception 'FAIL: accepted: %', p_call;
exception when others then
  if sqlstate is distinct from p_state or position(p_fragment in sqlerrm) = 0 then
    raise exception 'FAIL: % → % "%" (wanted % "%")', p_call, sqlstate, sqlerrm, p_state, p_fragment;
  end if;
end $$;
grant execute on function pg_temp.rows_now() to authenticated;
grant execute on function pg_temp.refused(text, text, text) to authenticated;

select set_config('request.jwt.claims', json_build_object('sub', 'USER_A', 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare
  lahore int := (select id from g where k = 'lahore');
  faisalabad int := (select id from g where k = 'faisalabad');
  karachi int := (select id from g where k = 'karachi');
  kamra_attock int := (select id from g where k = 'kamra_attock');
  kamra_rwp int := (select id from g where k = 'kamra_rwp');
  dob date := date '2000-05-01';
  v0 text;
  v1 text;
  pr record;
  c record;
  m record;
  call text;
begin
  if current_user <> 'authenticated' or auth.uid() is distinct from 'USER_A'::uuid then
    raise exception 'UNSAFE: not running as test user USER_A — stopping (nothing written)';
  end if;
  -- A FRESH user only (never a real account's UUID pasted by mistake): the
  -- sign-up trigger's bare profile row — no name, no role, Profile Setup not
  -- done — and no addresses or player profile.
  if not exists (select 1 from public.profiles where id = auth.uid()
                  and full_name is null and role is null and profile_completed is not true)
     or exists (select 1 from public.current_addresses) or exists (select 1 from public.permanent_addresses)
     or exists (select 1 from public.player_profiles) then
    raise exception 'UNSAFE: USER_A is not a fresh test user (named, role set, Profile Setup done, or rows exist) — stopping';
  end if;
  if lahore is null or faisalabad is null or karachi is null or kamra_attock is null or kamra_rwp is null then
    raise exception 'FAIL: the location data (D1) must be loaded';
  end if;

  -- Profile Setup (v2): Lahore, "same as current".
  perform public.save_profile_setup_v2('Test Editor', '0300 1234567', dob, lahore, 'Gulberg', 'House 1', true);

  -- U1: the stored values again (text path, and with the unchanged id) → nothing written.
  v0 := pg_temp.rows_now();
  perform public.update_profile_details('Test Editor', '+923001234567', dob, 'Lahore', null, 'Gulberg', 'House 1');
  perform public.update_profile_details(' Test Editor ', '0300 1234567', dob, 'Lahore', lahore, ' Gulberg', 'House 1 ');
  perform public.update_profile_details('Test Editor', '0300-1234567', dob, 'Lahore', null, 'Gulberg', 'House 1',
                                        'Karachi', karachi, 'X', 'Y'); -- "same as current": permanent arguments ignored
  if pg_temp.rows_now() <> v0 then
    raise exception 'FAIL: unchanged values (or another spelling of the same phone) wrote a row: % → %', v0, pg_temp.rows_now();
  end if;
  raise notice 'PASSED: unchanged values write nothing (last_updated_at kept); same-as-current ignores the permanent arguments';

  -- U2: name only → only the profile row.
  perform public.update_profile_details('Test Editor Two', '+923001234567', dob, 'Lahore', null, 'Gulberg', 'House 1');
  v1 := pg_temp.rows_now();
  if split_part(v1, ' ', 1) = split_part(v0, ' ', 1) or split_part(v1, ' ', 2) <> split_part(v0, ' ', 2)
     or split_part(v1, ' ', 3) <> split_part(v0, ' ', 3)
     or (select full_name from public.profiles where id = auth.uid()) <> 'Test Editor Two' then
    raise exception 'FAIL: a name-only change must write the profile row only (% → %)', v0, v1;
  end if;
  raise notice 'PASSED: a name-only change writes only the profile row';

  -- U3: phone cleared (P2), empty = none, then set again in another spelling.
  perform public.update_profile_details('Test Editor Two', null, dob, 'Lahore', null, 'Gulberg', 'House 1');
  if (select phone from public.profiles where id = auth.uid()) is not null then
    raise exception 'FAIL: the phone must be clearable';
  end if;
  v0 := pg_temp.rows_now();
  perform public.update_profile_details('Test Editor Two', '  ', dob, 'Lahore', null, 'Gulberg', 'House 1');
  perform public.update_profile_details('Test Editor Two', E' \t ', dob, 'Lahore', null, 'Gulberg', 'House 1');
  if pg_temp.rows_now() <> v0 then
    raise exception 'FAIL: a blank phone (spaces, a tab) with no phone stored must write nothing';
  end if;
  -- Dashes alone are not a blank phone: refused like any other invalid number.
  perform pg_temp.refused(format('select public.update_profile_details(%L, %L, %L::date, %L, null, %L, %L)',
    'Test Editor Two', ' - ', dob, 'Lahore', 'Gulberg', 'House 1'), '23514', 'phone must be a Pakistani mobile number');
  perform pg_temp.refused(format('select public.update_profile_details(%L, %L, %L::date, %L, null, %L, %L)',
    'Test Editor Two', '--', dob, 'Lahore', 'Gulberg', 'House 1'), '23514', 'phone must be a Pakistani mobile number');
  perform public.update_profile_details('Test Editor Two', '0333 9876543', dob, 'Lahore', null, 'Gulberg', 'House 1');
  if (select phone from public.profiles where id = auth.uid()) <> '+923339876543' then
    raise exception 'FAIL: the phone must be stored as +923XXXXXXXXX';
  end if;
  -- A blank phone (only whitespace) clears a stored one too; then set again.
  perform public.update_profile_details('Test Editor Two', E' \t ', dob, 'Lahore', null, 'Gulberg', 'House 1');
  if (select phone from public.profiles where id = auth.uid()) is not null then
    raise exception 'FAIL: a whitespace-only phone must clear the stored phone';
  end if;
  perform public.update_profile_details('Test Editor Two', '0333 9876543', dob, 'Lahore', null, 'Gulberg', 'House 1');
  raise notice 'PASSED: phone cleared, empty = none, stored canonically';

  -- U4: refusals, each with a name change too. The FUNCTION's own message is
  -- required (the table CHECK constraints would raise a different text). Two
  -- refusals here can't tell the function's check from a later one —
  -- "date_of_birth cannot be in the future" (profiles_validate raises the
  -- same text) — so local/08 L1 proves those run before any write. That a
  -- refused call leaves nothing behind is also shown there (a refused call's
  -- changes are rolled back here either way).
  perform pg_temp.refused(format('select public.update_profile_details(%L, %L, %L::date, %L, null, %L, %L)',
    'Changed', '12345', dob, 'Lahore', 'Gulberg', 'House 1'), '23514', 'phone must be a Pakistani mobile number');
  perform pg_temp.refused(format('select public.update_profile_details(%L, %L, %L::date, %L, null, %L, %L)',
    'A', '03339876543', dob, 'Lahore', 'Gulberg', 'House 1'), '23514', 'full_name must be 2–100 characters');
  perform pg_temp.refused(format('select public.update_profile_details(%L, %L, %L::date, %L, null, %L, %L)',
    '  ', '03339876543', dob, 'Lahore', 'Gulberg', 'House 1'), '23514', 'full_name must be 2–100 characters');
  perform pg_temp.refused(format('select public.update_profile_details(%L, %L, %L::date, %L, null, %L, %L)',
    'Changed', '03339876543', current_date + 1, 'Lahore', 'Gulberg', 'House 1'), '23514', 'date_of_birth cannot be in the future');
  perform pg_temp.refused(format('select public.update_profile_details(%L, %L, %L::date, %L, null, %L, %L)',
    'Changed', '03339876543', date '1899-12-31', 'Lahore', 'Gulberg', 'House 1'), '23514', 'date_of_birth is required (1900 or later)');
  perform pg_temp.refused(format('select public.update_profile_details(%L, %L, %L::date, %L, %s, %L, %L)',
    'Changed', '03339876543', dob, 'Atlantis', -1, 'Gulberg', 'House 1'), '23514', 'current_city_id must be an active city');
  perform pg_temp.refused(format('select public.update_profile_details(%L, %L, %L::date, %L, null, %L, %L)',
    'Changed', '03339876543', dob, 'Karachi', '  ', 'House 1'), '23514', 'current_addresses.area must be 1–150 characters (constraint "current_addresses_area_check")');
  perform pg_temp.refused(format('select public.update_profile_details(%L, %L, %L::date, %L, null, %L, %L)',
    'Changed', '03339876543', dob, repeat('k', 101), 'Gulberg', 'House 1'), '23514', 'current_addresses.city must be 1–100 characters (constraint "current_addresses_city_check")');
  perform pg_temp.refused(format('select public.update_profile_details(%L, %L, %L::date, %L, null, %L, %L)',
    'Changed', '03339876543', dob, 'Lahore', 'Gulberg', ''), '23514', 'current_addresses.address must be 1–500 characters (constraint "current_addresses_address_check")');
  perform pg_temp.refused(format('select public.update_profile_details(%L, %L, %L::date, %L, null, %L, %L)',
    'Changed', '03339876543', dob, 'Lahore', repeat('a', 151), 'House 1'), '23514', 'current_addresses.area must be 1–150 characters (constraint "current_addresses_area_check")');
  perform pg_temp.refused(format('select public.update_profile_details(%L, %L, %L::date, %L, null, %L, %L)',
    repeat('n', 101), '03339876543', dob, 'Lahore', 'Gulberg', 'House 1'), '23514', 'full_name must be 2–100 characters');
  perform pg_temp.refused(format('select public.update_profile_details(null, %L, %L::date, %L, null, %L, %L)',
    '03339876543', dob, 'Lahore', 'Gulberg', 'House 1'), '23514', 'full_name must be 2–100 characters');
  perform pg_temp.refused(format('select public.update_profile_details(%L, %L, %L::date, null, %s, null, null)',
    'Changed', '03339876543', dob, karachi), '23514', 'current_addresses.area must be 1–150 characters');
  raise notice 'PASSED: refusals with the function''s own messages (phone, name ×4, date of birth ×2, city id, area ×3, city, address)';

  -- U5: date of birth.
  perform public.update_profile_details('Test Editor Two', '03339876543', date '2001-06-02', 'Lahore', null, 'Gulberg', 'House 1');
  if (select date_of_birth from public.profiles where id = auth.uid()) <> date '2001-06-02' then
    raise exception 'FAIL: date of birth not saved';
  end if;
  -- Cleared (approved: a completed profile may clear it) and set again.
  perform public.update_profile_details('Test Editor Two', '03339876543', null, 'Lahore', null, 'Gulberg', 'House 1');
  if (select (date_of_birth is null, profile_completed) from public.profiles where id = auth.uid())::text
       is distinct from row(true, true)::text then
    raise exception 'FAIL: the date of birth must be clearable (and Profile Setup stays done)';
  end if;
  perform public.update_profile_details('Test Editor Two', '03339876543', date '2001-06-02', 'Lahore', null, 'Gulberg', 'House 1');
  dob := date '2001-06-02';
  raise notice 'PASSED: date of birth saved, cleared and saved again';

  -- U6: a new city id → both rows (same as current) get the id and its plain name; the profile row is not written.
  v0 := pg_temp.rows_now();
  perform public.update_profile_details('Test Editor Two', '03339876543', dob, 'Kamra (Attock)', kamra_attock, 'Cantt', 'House 1');
  v1 := pg_temp.rows_now();
  select city, city_id, area into c from public.current_addresses where user_id = auth.uid();
  select city, city_id, area into m from public.permanent_addresses where user_id = auth.uid();
  if (c.city, c.city_id, c.area) is distinct from ('Kamra'::text, kamra_attock, 'Cantt'::text)
     or (m.city, m.city_id, m.area) is distinct from ('Kamra'::text, kamra_attock, 'Cantt'::text)
     or split_part(v1, ' ', 1) <> split_part(v0, ' ', 1) then
    raise exception 'FAIL: a new id stored %/%/% and %/%/%', c.city, c.city_id, c.area, m.city, m.city_id, m.area;
  end if;
  -- U7: the other Kamra (same name, another id).
  perform public.update_profile_details('Test Editor Two', '03339876543', dob, 'Kamra', kamra_rwp, 'Cantt', 'House 1');
  if (select city_id from public.current_addresses where user_id = auth.uid()) <> kamra_rwp
     or (select city_id from public.permanent_addresses where user_id = auth.uid()) <> kamra_rwp then
    raise exception 'FAIL: the same-named town''s id was not stored';
  end if;
  raise notice 'PASSED: a new id is stored with its plain name (also the same-named town); same as current follows';

  -- U8: text only (no id) — migration 8 keeps the stored id while the new
  -- text still names that city: its label, then the ambiguous plain name
  -- "Kamra" (two towns) — the id is never dropped.
  perform public.update_profile_details('Test Editor Two', '03339876543', dob, 'Kamra (Rawalpindi)', null, 'Saddar', 'House 1');
  if (select (city, city_id, area) from public.current_addresses where user_id = auth.uid())::text
       is distinct from row('Kamra (Rawalpindi)', kamra_rwp, 'Saddar')::text
     or (select (city, city_id) from public.permanent_addresses where user_id = auth.uid())::text
       is distinct from row('Kamra (Rawalpindi)', kamra_rwp)::text then
    raise exception 'FAIL: the label text must keep the stored id';
  end if;
  perform public.update_profile_details('Test Editor Two', '03339876543', dob, 'Kamra', null, 'Saddar', 'House 1');
  if (select (city, city_id) from public.current_addresses where user_id = auth.uid())::text
       is distinct from row('Kamra', kamra_rwp)::text
     or (select (city, city_id) from public.permanent_addresses where user_id = auth.uid())::text
       is distinct from row('Kamra', kamra_rwp)::text then
    raise exception 'FAIL: the ambiguous plain name must keep the stored id';
  end if;
  -- U8b (finding 6): a supplied id always wins. The unchanged id with its
  -- label → normalised to the plain name; with another city's text → that
  -- text is ignored (nothing written); a new id with another city's text →
  -- the id's city.
  perform public.update_profile_details('Test Editor Two', '03339876543', dob, 'Kamra (Rawalpindi)', null, 'Saddar', 'House 1');
  perform public.update_profile_details('Test Editor Two', '03339876543', dob, 'Kamra (Rawalpindi)', kamra_rwp, 'Saddar', 'House 1');
  if (select (city, city_id) from public.current_addresses where user_id = auth.uid())::text
       is distinct from row('Kamra', kamra_rwp)::text
     or (select (city, city_id) from public.permanent_addresses where user_id = auth.uid())::text
       is distinct from row('Kamra', kamra_rwp)::text then
    raise exception 'FAIL: an unchanged id must normalise the stored text to its plain name';
  end if;
  v0 := pg_temp.rows_now();
  perform public.update_profile_details('Test Editor Two', '03339876543', dob, 'Lahore', kamra_rwp, 'Saddar', 'House 1');
  if pg_temp.rows_now() <> v0
     or (select (city, city_id) from public.current_addresses where user_id = auth.uid())::text
       is distinct from row('Kamra', kamra_rwp)::text then
    raise exception 'FAIL: other text with the unchanged id must be ignored (the id wins)';
  end if;
  raise notice 'PASSED: text keeps the id (label, ambiguous name); a supplied id wins over its text';
  perform public.update_profile_details('Test Editor Two', '03339876543', dob, 'Karachi', null, 'Saddar', 'House 1');
  if (select city_id from public.current_addresses where user_id = auth.uid()) <> karachi
     or (select city_id from public.permanent_addresses where user_id = auth.uid()) <> karachi then
    raise exception 'FAIL: new city text must be re-resolved (migration 8)';
  end if;
  perform public.update_profile_details('Test Editor Two', '03339876543', dob, 'Faisalabad', lahore, 'Saddar', 'House 1');
  if (select (city, city_id) from public.current_addresses where user_id = auth.uid())::text
       is distinct from row('Lahore', lahore)::text
     or (select (city, city_id) from public.permanent_addresses where user_id = auth.uid())::text
       is distinct from row('Lahore', lahore)::text then
    raise exception 'FAIL: a new id with another city''s text must store the id''s city';
  end if;
  raise notice 'PASSED: text-only changes keep or re-resolve the id';

  -- U9: all address arguments NULL → addresses left alone; the name still saved.
  v0 := pg_temp.rows_now();
  perform public.update_profile_details('Test Editor Three', '03339876543', dob, null, null, null, null);
  v1 := pg_temp.rows_now();
  if split_part(v1, ' ', 2) <> split_part(v0, ' ', 2) or split_part(v1, ' ', 3) <> split_part(v0, ' ', 3)
     or (select full_name from public.profiles where id = auth.uid()) <> 'Test Editor Three' then
    raise exception 'FAIL: NULL address arguments must leave the addresses alone';
  end if;
  raise notice 'PASSED: NULL address arguments leave the addresses alone';

  -- U10: a separate permanent address (Profile Setup again with "No").
  perform public.save_profile_setup_v2('Test Editor Three', '03339876543', dob, karachi, 'Saddar', 'House 1', false,
                                       faisalabad, 'Civil Lines', 'Street 9');
  v0 := pg_temp.rows_now();
  perform public.update_profile_details('Test Editor Three', '03339876543', dob, 'Lahore', lahore, 'Gulberg', 'House 1',
                                        'Faisalabad', null, 'Civil Lines', 'Street 9');
  v1 := pg_temp.rows_now();
  if split_part(v1, ' ', 3) <> split_part(v0, ' ', 3) or split_part(v1, ' ', 2) = split_part(v0, ' ', 2)
     or (select city_id from public.current_addresses where user_id = auth.uid()) <> lahore
     or (select city_id from public.permanent_addresses where user_id = auth.uid()) <> faisalabad then
    raise exception 'FAIL: a separate permanent address must stay as it is';
  end if;
  v0 := v1;
  perform public.update_profile_details('Test Editor Three', '03339876543', dob, 'Lahore', null, 'Gulberg', 'House 1',
                                        'Kamra (Attock)', kamra_attock, 'Cantt', 'Street 9');
  v1 := pg_temp.rows_now();
  select city, city_id, area into m from public.permanent_addresses where user_id = auth.uid();
  if split_part(v1, ' ', 2) <> split_part(v0, ' ', 2)
     or (m.city, m.city_id, m.area) is distinct from ('Kamra'::text, kamra_attock, 'Cantt'::text) then
    raise exception 'FAIL: the permanent address change stored %/%/%', m.city, m.city_id, m.area;
  end if;
  v0 := v1;
  perform pg_temp.refused(format('select public.update_profile_details(%L, %L, %L::date, %L, null, %L, %L, %L, %s, %L, %L)',
    'Changed', '03339876543', dob, 'Lahore', 'Gulberg', 'House 1', 'Atlantis', -1, 'Cantt', 'Street 9'),
    '23514', 'permanent_city_id must be an active city');
  perform pg_temp.refused(format('select public.update_profile_details(%L, %L, %L::date, %L, null, %L, %L, %L, null, %L, %L)',
    'Changed', '03339876543', dob, 'Multan', 'Cantt', 'House 2', 'Kamra', 'Cantt', ' '),
    '23514', 'permanent_addresses.address must be 1–500 characters (constraint "permanent_addresses_address_check")');
  perform pg_temp.refused(format('select public.update_profile_details(%L, %L, %L::date, %L, null, %L, %L, %L, null, %L, %L)',
    'Changed', '03339876543', dob, 'Multan', 'Cantt', 'House 2', 'Kamra', '', 'Street 9'),
    '23514', 'permanent_addresses.area must be 1–150 characters (constraint "permanent_addresses_area_check")');
  perform pg_temp.refused(format('select public.update_profile_details(%L, %L, %L::date, %L, null, %L, %L, %L, null, %L, %L)',
    'Changed', '03339876543', dob, 'Multan', 'Cantt', 'House 2', repeat('p', 101), 'Cantt', 'Street 9'),
    '23514', 'permanent_addresses.city must be 1–100 characters (constraint "permanent_addresses_city_check")');
  perform public.update_profile_details('Test Editor Three', '03339876543', dob, 'Lahore', null, 'Gulberg', 'House 1',
                                        null, null, null, null);
  if pg_temp.rows_now() <> v0 or (select full_name from public.profiles where id = auth.uid()) <> 'Test Editor Three' then
    raise exception 'FAIL: NULL permanent arguments must leave the permanent address alone';
  end if;
  raise notice 'PASSED: a separate permanent address: kept, changed, refused, left alone';

  -- U11: never profile_completed, role or permanent_same_as_current.
  select profile_completed, role, permanent_same_as_current into pr from public.profiles where id = auth.uid();
  if not pr.profile_completed or pr.role is not null or pr.permanent_same_as_current then
    raise exception 'FAIL: profile_completed / role / permanent_same_as_current changed (% / % / %)',
      pr.profile_completed, pr.role, pr.permanent_same_as_current;
  end if;
  raise notice 'PASSED: profile_completed, role and permanent_same_as_current untouched';
end $$;

-- U12: not signed in → 42501 "not authenticated".
select set_config('request.jwt.claims', '{}', true);
select set_config('request.jwt.claim.sub', '', true);
do $$
begin
  if auth.uid() is not null then
    raise exception 'UNSAFE: still signed in';
  end if;
  perform pg_temp.refused(
    'select public.update_profile_details(''Nobody'', null, null, ''Lahore'', null, ''Gulberg'', ''House 1'')',
    '42501', 'not authenticated');
  raise notice 'PASSED: not signed in → not authenticated';
end $$;

-- U13: anon can't execute it at all. The refusal must be the privilege
-- error itself: the function's own "not authenticated" is also SQLSTATE
-- 42501 (insufficient_privilege), so the message is checked too.
set local role anon;
do $$
begin
  perform public.update_profile_details('Nobody', null, null, 'Lahore', null, 'Gulberg', 'House 1');
  raise exception 'FAIL: anon executed update_profile_details';
exception when insufficient_privilege then
  if sqlerrm <> 'permission denied for function update_profile_details' then
    raise exception 'FAIL: anon was refused with "%" — not the missing execute privilege', sqlerrm;
  end if;
  raise notice 'PASSED: anon has no execute privilege (permission denied for function update_profile_details)';
end $$;

-- U14: USER_B (no Profile Setup, no address rows): the name is saved, no address row is created.
select set_config('request.jwt.claims', json_build_object('sub', 'USER_B', 'role', 'authenticated')::text, true);
set local role authenticated;
do $$
begin
  if current_user <> 'authenticated' or auth.uid() is distinct from 'USER_B'::uuid then
    raise exception 'UNSAFE: not running as test user USER_B — stopping (nothing written)';
  end if;
  if not exists (select 1 from public.profiles where id = auth.uid()
                  and full_name is null and role is null and profile_completed is not true)
     or exists (select 1 from public.current_addresses) or exists (select 1 from public.permanent_addresses)
     or exists (select 1 from public.player_profiles) then
    raise exception 'UNSAFE: USER_B is not a fresh test user (named, role set, Profile Setup done, or rows exist) — stopping';
  end if;
  perform public.update_profile_details('Tester Bee', null, null, 'Lahore', (select id from g where k = 'lahore'), 'Gulberg', 'House 1');
  if (select full_name from public.profiles where id = auth.uid()) <> 'Tester Bee'
     or exists (select 1 from public.current_addresses) or exists (select 1 from public.permanent_addresses)
     or (select profile_completed from public.profiles where id = auth.uid()) then
    raise exception 'FAIL: without address rows only the profile details may change';
  end if;
  raise notice 'PASSED: no address rows → none created, profile details saved';
end $$;

-- ===================== PART 3 — as the database owner =====================
reset role;
do $$
begin
  if (select (full_name, profile_completed) from public.profiles where id = 'USER_A')::text
       is distinct from row('Test Editor Three', true)::text
     or (select city_id from public.current_addresses where user_id = 'USER_A')
       <> (select id from g where k = 'lahore') then
    raise exception 'FAIL: USER_A''s rows changed by USER_B''s calls';
  end if;
  if (select h from others_before) <> (
    select md5(coalesce(string_agg(r, '|' order by r), '')) from (
      select 'p' || id || coalesce(full_name, '') || coalesce(phone, '') || coalesce(date_of_birth::text, '')
             || coalesce(profile_completed::text, '') || coalesce(role, '') || coalesce(last_updated_at::text, '') as r
        from public.profiles where id not in ('USER_A', 'USER_B')
      union all
      select 'c' || user_id || city || coalesce(city_id::text, '') || area || address || last_updated_at
        from public.current_addresses where user_id not in ('USER_A', 'USER_B')
      union all
      select 'm' || user_id || city || coalesce(city_id::text, '') || area || address || last_updated_at
        from public.permanent_addresses where user_id not in ('USER_A', 'USER_B')) x) then
    raise exception 'FAIL: another user''s rows changed';
  end if;
  raise notice 'PASSED: only the caller''s own rows were written (other users unchanged)';
end $$;

rollback;
