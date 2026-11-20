#!/usr/bin/env bash
# CricEco · LOCAL TEST ONLY — migration 17 (match challenges and matches):
# concurrent sessions, which a single SQL file can't test.
# Run after migration 17 on a disposable local test database that has the
# auth stub (tests/local/00_auth_stub.sql) and migrations 1–16.
#
# Usage:  PSQL='docker exec -i criceco-m17-test psql -U postgres -d <local_db>' \
#           bash supabase/tests/local/14b_matches_concurrency.sh
# $PSQL must run SQL read from stdin as the database owner. The script
# refuses to run on a real Supabase project. It commits four synthetic
# accounts and clubs (ids e71…; other sessions must see them) and always
# deletes them again on exit. Prints PASS / FAIL lines; exits with the
# number of failures.
#
# Session 1 does its step inside a transaction and then sleeps, holding its
# locks; session 2 is started only once session 1 is CONFIRMED to be
# sleeping (pg_stat_activity), and its result only counts once it is
# CONFIRMED to be waiting on a lock. No fixed sleep decides a result; a
# check that can't confirm its state FAILS.
#   K1 two answers to one challenge at once: one match; the second answer
#      waits on the challenge row, then gets "not pending";
#   K2 crossed challenges (A→C and C→A at once): the second waits on the
#      clubs' advisory lock, then gets "already pending"; one pending row;
#   K3 two confirmations at the same time for club A (A–B and A–C): the
#      second waits on club A's advisory lock, then gets "schedule clash";
#      exactly one is confirmed;
#   K4 a confirmation racing a new proposal: it waits on the match row, then
#      gets "proposal changed"; the new proposal stays open.
set -u
: "${PSQL:?set PSQL to a psql command for the LOCAL test database (see the header)}"
fails=0
T=$(mktemp -d)
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; fails=$((fails+1)); }
one() { echo "$1" | $PSQL -X -At -q 2>&1; }      # one statement as the owner; errors come back as text
MINE="datname = current_database() and application_name like 'm17k\\_%' and pid <> pg_backend_pid()"
A=e7100000-0000-4000-8000-000000000001
B=e7100000-0000-4000-8000-000000000002
C=e7100000-0000-4000-8000-000000000003
D=e7100000-0000-4000-8000-000000000004

cleanup() {
  local rc=$? i left
  trap - EXIT INT TERM
  one "select pg_cancel_backend(pid) from pg_stat_activity where $MINE" >/dev/null
  for i in $(seq 50); do
    left=$(one "select count(*) from pg_stat_activity where $MINE")
    [ "$left" = "0" ] && break; sleep 0.1
  done
  one "delete from public.clubs where owner_id::text like 'e7100000%'" >/dev/null
  one "delete from auth.users where id::text like 'e7100000%'" >/dev/null
  if [ "$(one "select count(*) from public.profiles where id::text like 'e7100000%'")" != "0" ]; then
    echo "FAIL  cleanup: synthetic accounts e71… were not deleted"; rm -rf "$T"; exit $(( (rc == 0 ? 0 : rc) + 1 ))
  fi
  rm -rf "$T"
  exit $rc
}
trap cleanup EXIT
trap 'fails=$((fails+1)); echo "FAIL  interrupted"; exit 130' INT TERM

if [ "$(one "select exists (select 1 from pg_roles where rolname = 'supabase_admin')
                 or exists (select 1 from pg_attribute where attrelid = to_regclass('auth.users')
                             and attname = 'encrypted_password' and not attisdropped)")" != "f" ]; then
  echo "LOCAL ONLY: this looks like a real Supabase project — stopping"; exit 99
fi
if [ "$(one "select to_regclass('public.matches') is not null")" != "t" ]; then
  echo "run migration 17 first"; exit 99
fi

# Run [sql] as user [uid] (authenticated) in a background session named [name].
session() { # name uid sql
  printf "set application_name = 'm17k_%s';\nselect set_config('request.jwt.claims', '{\"sub\":\"%s\",\"role\":\"authenticated\"}', false);\nset role authenticated;\n%s\n" \
    "$1" "$2" "$3" | $PSQL -X -At -q >"$T/$1.out" 2>&1 &
}
as_user() { # uid sql — one call in the foreground
  printf "select set_config('request.jwt.claims', '{\"sub\":\"%s\",\"role\":\"authenticated\"}', false);\nset role authenticated;\n%s\n" \
    "$1" "$2" | $PSQL -X -At -q 2>&1 | tail -n 1
}
wait_until() { # sql-boolean, up to 10 s
  local i
  for i in $(seq 100); do
    [ "$(one "$1")" = "t" ] && return 0; sleep 0.1
  done
  return 1
}
sleeping() { wait_until "select exists (select 1 from pg_stat_activity where $MINE and application_name = 'm17k_$1'
                           and state = 'active' and query like '%pg_sleep%')"; }
blocked()  { wait_until "select exists (select 1 from pg_stat_activity where $MINE and application_name = 'm17k_$1'
                           and wait_event_type = 'Lock' and wait_event in ($2))"; }

# --- Synthetic accounts and clubs A, B, C, D (committed) ---------------------
one "do \$\$
declare v uuid; i int := 0;
begin
  foreach v in array array['$A', '$B', '$C', '$D']::uuid[] loop
    i := i + 1;
    insert into auth.users (id, email) values (v, format('m17k%s@local.test', i));
    insert into public.current_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
    insert into public.permanent_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
    update public.profiles set full_name = format('Race Person %s', i),
           phone = format('+923%s', lpad((510000000 + i)::text, 9, '0')),
           date_of_birth = date '2000-05-01', profile_completed = true where id = v;
    insert into public.player_profiles (user_id, player_role, batting_style, bowling_style, is_wicketkeeper)
    values (v, 'all_rounder', 'right_handed', 'right_arm_fast', false);
    insert into public.clubs (owner_id, name, city, club_type) values (v, format('Race Club %s', i), 'Lahore', 'corporate');
  end loop;
end \$\$;" >/dev/null
CA=$(one "select id from public.clubs where owner_id = '$A'")
CB=$(one "select id from public.clubs where owner_id = '$B'")
CC=$(one "select id from public.clubs where owner_id = '$C'")
[ -n "$CA" ] && [ -n "$CB" ] && [ -n "$CC" ] || { fail "setup: clubs not created"; exit 1; }
DAY="((now() at time zone 'Asia/Karachi')::date + 5)"

# --- K1 two answers to one challenge at once --------------------------------
CH=$(as_user "$A" "select id from public.send_challenge('$CA', '$CB', 't20', null, $DAY, 'Race Ground')")
session k1a "$B" "begin; select status from public.respond_to_challenge('$CH', true); select pg_sleep(4); commit;"
if sleeping k1a; then
  session k1b "$B" "select status from public.respond_to_challenge('$CH', true);"
  if blocked k1b "'tuple', 'transactionid'"; then
    wait
    if grep -q '^accepted$' "$T/k1a.out" && grep -q 'challenge: not pending' "$T/k1b.out" \
       && [ "$(one "select count(*) from public.matches where challenge_id = '$CH'")" = "1" ]; then
      pass "K1 concurrent accepts: the second waited, got 'not pending'; exactly one match"
    else fail "K1 concurrent accepts: $(cat "$T/k1a.out" "$T/k1b.out" | tr '\n' ' ')"; fi
  else wait; fail "K1 the second answer was never seen waiting on the challenge row"; fi
else wait; fail "K1 session 1 never reached its sleep: $(cat "$T/k1a.out")"; fi

# --- K2 crossed challenges --------------------------------------------------
session k2a "$A" "begin; select status from public.send_challenge('$CA', '$CC', 't20', null, $DAY, 'Race Ground'); select pg_sleep(4); commit;"
if sleeping k2a; then
  session k2b "$C" "select status from public.send_challenge('$CC', '$CA', 'odi', null, $DAY, 'Other Ground');"
  if blocked k2b "'advisory'"; then
    wait
    if grep -q '^pending$' "$T/k2a.out" && grep -q 'challenge: already pending' "$T/k2b.out" \
       && [ "$(one "select count(*) from public.match_challenges where status = 'pending'
                     and least(from_club_id, to_club_id) = least('$CA'::uuid, '$CC'::uuid)
                     and greatest(from_club_id, to_club_id) = greatest('$CA'::uuid, '$CC'::uuid)")" = "1" ]; then
      pass "K2 crossed challenges: the second waited on the clubs' lock, got 'already pending'; one pending challenge"
    else fail "K2 crossed challenges: $(cat "$T/k2a.out" "$T/k2b.out" | tr '\n' ' ')"; fi
  else wait; fail "K2 the crossed challenge was never seen waiting on the advisory lock"; fi
else wait; fail "K2 session 1 never reached its sleep: $(cat "$T/k2a.out")"; fi

# --- K3 two confirmations at the same time for club A ------------------------
M1=$(one "select match_id from public.match_challenges where id = '$CH'")
CH2=$(one "select id from public.match_challenges where from_club_id = '$CA' and to_club_id = '$CC' and status = 'pending'")
M2=$(as_user "$C" "select match_id from public.respond_to_challenge('$CH2', true)")
AT="(date_trunc('minute', now()) + interval '2 days')"
V1=$(as_user "$A" "select proposal_version from public.propose_match_schedule('$M1', $AT, 'Race Ground')")
V2=$(as_user "$A" "select proposal_version from public.propose_match_schedule('$M2', $AT, 'Race Ground')")
session k3a "$B" "begin; select status from public.respond_to_match_schedule('$M1', $V1, true); select pg_sleep(4); commit;"
if sleeping k3a; then
  session k3b "$C" "select status from public.respond_to_match_schedule('$M2', $V2, true);"
  if blocked k3b "'advisory'"; then
    wait
    if grep -q '^confirmed$' "$T/k3a.out" && grep -q 'match: schedule clash' "$T/k3b.out" \
       && [ "$(one "select count(*) from public.matches where id in ('$M1', '$M2') and status = 'confirmed'")" = "1" ]; then
      pass "K3 simultaneous confirmations for club A: the second waited on A's lock, got 'schedule clash'; one confirmed"
    else fail "K3 simultaneous confirmations: $(cat "$T/k3a.out" "$T/k3b.out" | tr '\n' ' ')"; fi
  else wait; fail "K3 the second confirmation was never seen waiting on the advisory lock"; fi
else wait; fail "K3 session 1 never reached its sleep: $(cat "$T/k3a.out")"; fi

# --- K4 a confirmation racing a new proposal ---------------------------------
session k4a "$A" "begin; select proposal_version from public.propose_match_schedule('$M2', $AT + interval '1 day', 'New Ground'); select pg_sleep(4); commit;"
if sleeping k4a; then
  session k4b "$C" "select status from public.respond_to_match_schedule('$M2', $V2, true);"
  if blocked k4b "'tuple', 'transactionid'"; then
    wait
    if grep -q "^$((V2 + 1))\$" "$T/k4a.out" && grep -q 'match: proposal changed' "$T/k4b.out" \
       && [ "$(one "select status || '/' || proposal_version || '/' || proposed_venue_name from public.matches where id = '$M2'")" = "pending/$((V2 + 1))/New Ground" ]; then
      pass "K4 confirmation racing a new proposal: it waited on the match row, got 'proposal changed'; the new proposal is open"
    else fail "K4 confirmation vs proposal: $(cat "$T/k4a.out" "$T/k4b.out" | tr '\n' ' ')"; fi
  else wait; fail "K4 the confirmation was never seen waiting on the match row"; fi
else wait; fail "K4 session 1 never reached its sleep: $(cat "$T/k4a.out")"; fi

echo "concurrency: $((4 - fails)) of 4 passed"
exit $fails
