#!/usr/bin/env bash
# CricEco · LOCAL TEST ONLY — migration 20 (match results): concurrent
# sessions, which a single SQL file can't test.
# Run after migration 20 on a disposable local test database that has the
# auth stub (tests/local/00_auth_stub.sql) and migrations 1–19.
#
# Usage:  PSQL='docker exec -i criceco-m17-test psql -U postgres -d <local_db>' \
#           bash supabase/tests/local/17b_match_results_concurrency.sh
# $PSQL must run SQL read from stdin as the database owner. The script
# refuses to run on a real Supabase project. It commits synthetic accounts,
# clubs and matches (ids ec…; other sessions must see them) and always
# deletes them again on exit. Prints PASS / FAIL lines; exits with the
# number of failures.
#
# Session 1 does its step inside a transaction and then sleeps, holding its
# locks; session 2 starts only once session 1 is CONFIRMED sleeping, and its
# result only counts once it is CONFIRMED waiting on a lock
# (pg_stat_activity). No fixed sleep decides a result.
#   R1 two confirmations of the same result at once: the second waits, then
#      gets "not pending"; one confirmed version, the match completed once;
#   R2 a confirmation while the submitter replaces the result: the
#      confirmation waits, then gets "version changed"; version 2 waits;
#   R3 both clubs submit at once: the second waits, then becomes version 2
#      and supersedes version 1; exactly one version waits;
#   R4 a cancellation while the result is being confirmed: the cancellation
#      waits, then gets "not open" (the match is completed).
set -u
: "${PSQL:?set PSQL to a psql command for the LOCAL test database (see the header)}"
fails=0
T=$(mktemp -d)
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; fails=$((fails+1)); }
one() { echo "$1" | $PSQL -X -At -q 2>&1; }
MINE="datname = current_database() and application_name like 'm20k\\_%' and pid <> pg_backend_pid()"
uid() { printf 'ec000000-0000-4000-8000-%012d' "$1"; }
mid() { printf 'ec0000aa-0000-4000-8000-%012d' "$1"; }
A=$(uid 1)
B=$(uid 2)

cleanup() {
  local rc=$? i left
  trap - EXIT INT TERM
  one "select pg_cancel_backend(pid) from pg_stat_activity where $MINE" >/dev/null
  for i in $(seq 50); do
    left=$(one "select count(*) from pg_stat_activity where $MINE")
    [ "$left" = "0" ] && break; sleep 0.1
  done
  one "delete from public.clubs where owner_id::text like 'ec000000%'" >/dev/null
  one "delete from auth.users where id::text like 'ec000000%'" >/dev/null
  if [ "$(one "select count(*) from public.profiles where id::text like 'ec000000%'")" != "0" ] \
     || [ "$(one "select count(*) from public.match_results where match_id::text like 'ec0000aa%'")" != "0" ]; then
    echo "FAIL  cleanup: synthetic data ec… was not deleted"; rm -rf "$T"; exit $(( (rc == 0 ? 0 : rc) + 1 ))
  fi
  rm -rf "$T"
  exit $(( fails > 0 ? fails : rc ))
}
trap cleanup EXIT
trap 'fails=$((fails+1)); echo "FAIL  interrupted"; exit 130' INT TERM

if [ "$(one "select exists (select 1 from pg_roles where rolname = 'supabase_admin')
                 or exists (select 1 from pg_attribute where attrelid = to_regclass('auth.users')
                             and attname = 'encrypted_password' and not attisdropped)")" != "f" ]; then
  echo "LOCAL ONLY: this looks like a real Supabase project — stopping"; exit 99
fi
if [ "$(one "select to_regclass('public.match_results') is not null")" != "t" ]; then
  echo "run migration 20 first"; exit 99
fi

session() { # name uid sql
  printf "set application_name = 'm20k_%s';\nselect set_config('request.jwt.claims', '{\"sub\":\"%s\",\"role\":\"authenticated\"}', false);\nset role authenticated;\n%s\n" \
    "$1" "$2" "$3" | $PSQL -X -At -q >"$T/$1.out" 2>&1 &
}
as_user() { # uid sql
  printf "select set_config('request.jwt.claims', '{\"sub\":\"%s\",\"role\":\"authenticated\"}', false);\nset role authenticated;\n%s\n" \
    "$1" "$2" | $PSQL -X -At -q 2>&1 | tail -n 1
}
wait_until() {
  local i
  for i in $(seq 100); do
    [ "$(one "$1")" = "t" ] && return 0; sleep 0.1
  done
  return 1
}
sleeping() { wait_until "select exists (select 1 from pg_stat_activity where $MINE and application_name = 'm20k_$1'
                           and state = 'active' and query like '%pg_sleep%')"; }
blocked()  { wait_until "select exists (select 1 from pg_stat_activity where $MINE and application_name = 'm20k_$1'
                           and wait_event_type = 'Lock')"; }
# A T20 result: club $1 bats first and scores $2 for 6; club $3 makes 150 for 8 → $1 wins.
innings() {
  echo "jsonb_build_array(jsonb_build_object('batting_club_id', '$1', 'runs', $2, 'wickets', 6, 'balls', 120),
                          jsonb_build_object('batting_club_id', '$3', 'runs', 150, 'wickets', 8, 'balls', 120))"
}
history() { # match n → "1:status,2:status" | match status
  one "select coalesce(string_agg(version || ':' || status, ',' order by version), '-') || '|'
              || (select status from public.matches where id = '$(mid "$1")')
         from public.match_results where match_id = '$(mid "$1")'"
}

# --- Synthetic accounts: owners 1 (club A), 2 (club B); four played T20s -----
one "do \$\$
declare n int; v uuid;
begin
  foreach n in array array[1, 2] loop
    v := ('ec000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid;
    insert into auth.users (id, email) values (v, format('m20k%s@local.test', n));
    insert into public.current_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
    insert into public.permanent_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
    update public.profiles set full_name = format('Race Result %s', n),
           phone = format('+923%s', lpad((570000000 + n)::text, 9, '0')),
           date_of_birth = date '2000-05-01', profile_completed = true
     where id = v;
    insert into public.player_profiles (user_id, player_role, batting_style, bowling_style, is_wicketkeeper)
    values (v, 'all_rounder', 'right_handed', 'right_arm_fast', false);
  end loop;
  insert into public.clubs (owner_id, name, city, club_type) values ('$A', 'Race Result A', 'Lahore', 'corporate'),
                                                                  ('$B', 'Race Result B', 'Karachi', 'corporate');
  insert into public.matches (id, club_a_id, club_b_id, format, status, starts_at, venue_name)
  select ('ec0000aa-0000-4000-8000-' || lpad(g.k::text, 12, '0'))::uuid, a.id, b.id, 't20', 'confirmed',
         now() - make_interval(days => g.k), 'Race Ground'
    from public.clubs a, public.clubs b, generate_series(1, 4) as g(k)
   where a.owner_id = '$A' and b.owner_id = '$B';
end \$\$;" >"$T/setup.err" 2>&1 || true
CA=$(one "select id from public.clubs where owner_id = '$A'")
CB=$(one "select id from public.clubs where owner_id = '$B'")
[ -n "$CA" ] && [ -n "$CB" ] && [ "$(one "select count(*) from public.matches where id::text like 'ec0000aa%'")" = "4" ] \
  || { fail "setup: clubs or matches not created: $(cat "$T/setup.err")"; exit 1; }
submit() { # owner uid, match n, batting-first club, runs, other club → version
  as_user "$1" "select version from public.submit_match_result('$(mid "$2")', 'club_a_won', $(innings "$3" "$4" "$5"))"
}
# club_a_won with A batting first needs A ahead: A scores $4 > 150.
[ "$(submit "$A" 1 "$CA" 180 "$CB")" = "1" ] && [ "$(submit "$A" 2 "$CA" 180 "$CB")" = "1" ] \
  && [ "$(submit "$A" 4 "$CA" 180 "$CB")" = "1" ] || { fail "setup: results not submitted"; exit 1; }

# --- R1 two confirmations at once ---------------------------------------------
session r1a "$B" "begin; select status from public.confirm_match_result('$(mid 1)', 1); select pg_sleep(4); commit;"
if sleeping r1a; then
  session r1b "$B" "select status from public.confirm_match_result('$(mid 1)', 1);"
  if blocked r1b; then
    wait
    if grep -q '^confirmed$' "$T/r1a.out" && grep -q 'not pending' "$T/r1b.out" && [ "$(history 1)" = "1:confirmed|completed" ]; then
      pass "R1 two confirmations: the second waited, then 'not pending'; one confirmed version, match completed"
    else fail "R1 two confirmations: $(cat "$T/r1a.out" "$T/r1b.out" | tr '\n' ' ') history=$(history 1)"; fi
  else wait; fail "R1 the second confirmation was never seen waiting"; fi
else wait; fail "R1 session 1 never reached its sleep: $(cat "$T/r1a.out")"; fi

# --- R2 a confirmation while the result is replaced -----------------------------
session r2a "$A" "begin; select version from public.submit_match_result('$(mid 2)', 'club_a_won', $(innings "$CA" 190 "$CB")); select pg_sleep(4); commit;"
if sleeping r2a; then
  session r2b "$B" "select status from public.confirm_match_result('$(mid 2)', 1);"
  if blocked r2b; then
    wait
    if grep -q '^2$' "$T/r2a.out" && grep -q 'version changed' "$T/r2b.out" && [ "$(history 2)" = "1:superseded,2:submitted|confirmed" ]; then
      pass "R2 confirm vs replacement: the confirmation waited, then 'version changed'; version 2 waits"
    else fail "R2 confirm vs replacement: $(cat "$T/r2a.out" "$T/r2b.out" | tr '\n' ' ') history=$(history 2)"; fi
  else wait; fail "R2 the confirmation was never seen waiting"; fi
else wait; fail "R2 session 1 never reached its sleep: $(cat "$T/r2a.out")"; fi

# --- R3 both clubs submit at once -------------------------------------------------
session r3a "$A" "begin; select version from public.submit_match_result('$(mid 3)', 'club_a_won', $(innings "$CA" 180 "$CB")); select pg_sleep(4); commit;"
if sleeping r3a; then
  session r3b "$B" "select version from public.submit_match_result('$(mid 3)', 'club_a_won', $(innings "$CA" 181 "$CB"));"
  if blocked r3b; then
    wait
    if grep -q '^1$' "$T/r3a.out" && grep -q '^2$' "$T/r3b.out" && [ "$(history 3)" = "1:superseded,2:submitted|confirmed" ] \
       && [ "$(one "select submitted_by_club_id = '$CB' from public.match_results where match_id = '$(mid 3)' and version = 2")" = "t" ]; then
      pass "R3 two submissions: the second waited, became version 2 (B's) and superseded version 1"
    else fail "R3 two submissions: $(cat "$T/r3a.out" "$T/r3b.out" | tr '\n' ' ') history=$(history 3)"; fi
  else wait; fail "R3 the second submission was never seen waiting"; fi
else wait; fail "R3 session 1 never reached its sleep: $(cat "$T/r3a.out")"; fi

# --- R4 a cancellation while the result is confirmed ------------------------------
session r4a "$B" "begin; select status from public.confirm_match_result('$(mid 4)', 1); select pg_sleep(4); commit;"
if sleeping r4a; then
  session r4b "$A" "select status from public.cancel_match('$(mid 4)', 'Rain');"
  if blocked r4b; then
    wait
    if grep -q '^confirmed$' "$T/r4a.out" && grep -q 'not open' "$T/r4b.out" && [ "$(history 4)" = "1:confirmed|completed" ]; then
      pass "R4 cancel vs confirm: the cancellation waited, then 'not open'; the match is completed"
    else fail "R4 cancel vs confirm: $(cat "$T/r4a.out" "$T/r4b.out" | tr '\n' ' ') history=$(history 4)"; fi
  else wait; fail "R4 the cancellation was never seen waiting"; fi
else wait; fail "R4 session 1 never reached its sleep: $(cat "$T/r4a.out")"; fi

echo "failures: $fails"
exit "$fails"
