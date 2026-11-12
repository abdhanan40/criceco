#!/usr/bin/env bash
# CricEco · LOCAL TEST ONLY — migration 9 (update_profile_details): row
# locking, which needs concurrent sessions (so it can't be a single SQL file).
# Run after migration 9 with the location data (D1), on a local test database
# that has the auth stub (tests/local/00_auth_stub.sql).
#
# Usage:  PSQL='docker exec -i criceco-sql-test17 psql -U postgres -d <local_db>' \
#           bash supabase/tests/local/08b_update_profile_details_locking.sh
# $PSQL must run SQL read from stdin as the database owner. The script
# refuses to run on a real Supabase project. It commits ONE local test user
# (a second session must see its rows) and always deletes it again on exit.
# Prints PASS / FAIL lines; exits with the number of failures.
#
# Every step waits for a CONFIRMED state in pg_stat_activity (a session
# holding its locks, another blocked on a Lock) — no fixed sleeps decide a
# result; a check that can't confirm its state FAILS (never passes).
#   K1 an unchanged save holds exactly FOR NO KEY UPDATE on the caller's
#      profile, current and permanent rows: another session's FOR NO KEY
#      UPDATE NOWAIT and FOR SHARE NOWAIT are refused on all three (so it
#      holds more than FOR SHARE), and the locks end with its transaction;
#   K2 ... while FOR KEY SHARE NOWAIT succeeds on all three (so it holds less
#      than FOR UPDATE: a foreign-key check is not blocked), and an insert
#      into player_profiles completes (lock_timeout 1s) meanwhile;
#   K3 a save that is blocked by a concurrent writer — of the profile row, and
#      of the current address row — compares against the newly committed
#      values once it gets the lock: it writes nothing to that row (the row
#      keeps the writer's xmin), and its wait is measured inside SQL;
#   K4 compatibility smoke test with save_profile_setup_v2 (either one first):
#      the second really waits for the first, and both commit. This shows the
#      two run side by side; it is not a proof of deadlock-freedom, which
#      rests on both functions locking profile → current → permanent. Test 10
#      checks only the explicit FOR clauses' textual order (not implicit
#      locks from UPDATE / INSERT / DELETE, nor locks in called functions).
set -u
: "${PSQL:?set PSQL to a psql command for the LOCAL test database (see the header)}"
fails=0
U=""
T=$(mktemp -d)
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; fails=$((fails+1)); }
sql() { $PSQL -X -At -v ON_ERROR_STOP=1 -q 2>&1; }          # SQL on stdin
one() { echo "$1" | $PSQL -X -At -q 2>&1; }                  # one statement; errors come back as text
# This database's own test sessions only (several runs may share a server).
MINE="datname = current_database() and application_name like 's436\\_%' and pid <> pg_backend_pid()"
cleanup() {
  local rc=$? left out i
  trap - EXIT INT TERM
  # 1. Stop this run's test sessions first (a session still holding the
  #    user's rows would make the delete wait), and wait until they are gone.
  one "select pg_cancel_backend(pid) from pg_stat_activity where $MINE" >/dev/null
  for i in $(seq 50); do
    left=$(one "select count(*) from pg_stat_activity where $MINE")
    [ "$left" = "0" ] && break; sleep 0.1
  done
  [ "$left" = "0" ] || one "select pg_terminate_backend(pid) from pg_stat_activity where $MINE" >/dev/null
  # 2. Delete the committed test user (its rows go with it) — and say so if that fails.
  if [[ "$U" =~ $UUID_RE ]]; then
    out=$(one "delete from auth.users where id = '$U' returning 'deleted'")
    if [ "$out" != "deleted" ] || [ "$(one "select count(*) from public.profiles where id = '$U'")" != "0" ]; then
      echo "FAIL  cleanup: the local test user $U was not deleted: $out"
      rm -rf "$T"; exit $(( (rc == 0 ? 0 : rc) + 1 ))
    fi
  fi
  rm -rf "$T"
  exit $rc
}
# Set before anything is committed; also on Ctrl-C / kill.
trap cleanup EXIT
trap 'fails=$((fails+1)); echo "FAIL  interrupted"; exit 130' INT TERM

# Local only: no Supabase admin role, and auth.users without Supabase's
# password column (pg_attribute shows it whatever the caller's privileges).
if [ "$(one "select exists (select 1 from pg_roles where rolname = 'supabase_admin')
                 or exists (select 1 from pg_attribute where attrelid = to_regclass('auth.users')
                             and attname = 'encrypted_password' and not attisdropped)")" != "f" ]; then
  echo "LOCAL ONLY: this looks like a real Supabase project — stopping"; exit 99
fi
if [ "$(one "select to_regprocedure('public.update_profile_details(text, text, date, text, integer, text, text, text, integer, text, text)') is not null")" != "t" ]; then
  echo "run migration 9 first"; exit 99
fi
LAHORE=$(one "select id from public.cities where geonames_id = 1172451")
[[ "$LAHORE" =~ ^[0-9]+$ ]] || { echo "the location data (D1) must be loaded"; exit 99; }

U=$(one "insert into auth.users (email) values ('locking-$(date +%s%N)@s436.local.test') returning id" | head -1)
[[ "$U" =~ $UUID_RE ]] || { echo "could not create the local test user: $U"; U=""; exit 99; }
as_user() { printf "select set_config('request.jwt.claims', json_build_object('sub', '%s', 'role', 'authenticated')::text, true);\nset local role authenticated;\n" "$U"; }
SAVE="select public.update_profile_details('Lock Tester', '03001234567', date '2000-05-01', 'Lahore', null, 'Gulberg', 'House 1');"
V2="select public.save_profile_setup_v2('Lock Tester', '0300 1234567', date '2000-05-01', $LAHORE, 'Gulberg', 'House 1', true);"
setup=$({ echo "begin;"; as_user; echo "$V2"; echo "commit;"; } | sql)
echo "$setup" | grep -q ERROR && { echo "setup failed: $setup"; exit 99; }

# Waits (up to ~15 s) until session $1 is in state $2: "sleeping" (its
# pg_sleep runs, so every earlier statement — and lock — is done) or
# "blocked" (waiting on a Lock). Echoes yes / no.
wait_for() {
  local cond i
  case "$2" in
    sleeping) cond="state = 'active' and query like '%pg_sleep%'";;
    blocked)  cond="wait_event_type = 'Lock'";;
  esac
  for i in $(seq 150); do
    [ "$(one "select count(*) from pg_stat_activity where datname = current_database() and application_name = '$1' and $cond")" = "1" ] && { echo yes; return; }
    sleep 0.1
  done
  echo no
}
stop_session() { one "select pg_cancel_backend(pid) from pg_stat_activity where datname = current_database() and application_name = '$1'" >/dev/null; }
# NOWAIT lock attempt from another session: locked / free / error:<text>.
try_lock() {
  local col=user_id out; [ "$1" = profiles ] && col=id
  out=$(one "select 1 from public.$1 where $col = '$U' $2 nowait")
  if echo "$out" | grep -q "could not obtain lock on row"; then echo locked
  elif [ "$out" = "1" ]; then echo free
  else echo "error:$out"; fi
}
# 32-bit transaction id of the session (comparable with xmin, any epoch).
XID="mod(pg_current_xact_id()::text::numeric, 4294967296)::bigint"

# ---- K1 / K2: an unchanged save holds its locks (until it is stopped).
{ echo "set application_name = 's436_hold';"; echo "begin;"; as_user; echo "$SAVE"; echo "select pg_sleep(60);"; echo "rollback;"; } | sql > "$T/hold" &
bg=$!
held=0; other=""
if [ "$(wait_for s436_hold sleeping)" = yes ]; then
  # Which lock the save holds, from what another session can take (NOWAIT):
  #   FOR NO KEY UPDATE refused → the save holds FOR SHARE or stronger;
  #   FOR SHARE refused         → it holds FOR NO KEY UPDATE or FOR UPDATE
  #                               (FOR SHARE would allow another FOR SHARE);
  #   FOR KEY SHARE taken       → it doesn't hold FOR UPDATE.
  # All three together: exactly FOR NO KEY UPDATE, on each of the rows.
  shared=0; sother=""; kshare=0; kother=""
  for t in profiles current_addresses permanent_addresses; do
    r=$(try_lock $t 'for no key update'); [ "$r" = locked ] && held=$((held+1)) || other="$other $t=$r"
    r=$(try_lock $t 'for share');         [ "$r" = locked ] && shared=$((shared+1)) || sother="$sother $t=$r"
    r=$(try_lock $t 'for key share');     [ "$r" = free ] && kshare=$((kshare+1)) || kother="$kother $t=$r"
  done
  ins=$({ echo "begin;"; echo "set local lock_timeout = '1s';"; echo "insert into public.player_profiles (user_id, player_role, batting_style) values ('$U', 'batsman', 'right_handed');"; echo "select 'inserted';"; echo "rollback;"; } | sql)
  [ "$held" = 3 ] && pass "K1 an unchanged save locks profile, current and permanent rows (FOR NO KEY UPDATE NOWAIT refused on 3 of 3)" \
                  || fail "K1 locks held on $held of 3 rows:$other"
  [ "$shared" = 3 ] && pass "K1 FOR SHARE NOWAIT is refused on 3 of 3 rows (the save holds more than FOR SHARE)" \
                    || fail "K1 FOR SHARE NOWAIT was not refused on $((3 - shared)) row(s) (the save holds FOR SHARE or less):$sother"
  [ "$kshare" = 3 ] && pass "K2 FOR KEY SHARE (a foreign-key check) is not blocked on 3 of 3 rows (the save holds less than FOR UPDATE)" \
                    || fail "K2 FOR KEY SHARE blocked or failed:$kother"
  if echo "$ins" | grep -q "^inserted$" && ! echo "$ins" | grep -q ERROR; then
    pass "K2 an insert into player_profiles completed while the save held its locks"
  else fail "K2 the insert into player_profiles did not complete: $(echo "$ins" | grep ERROR | head -1)"; fi
else
  fail "K1/K2 could not confirm the save holding its locks: $(cat "$T/hold")"
fi
stop_session s436_hold; wait $bg
# The release is only meaningful once all three locks were seen held; each
# row must then come back "free" (a lock taken and returned) — an error or
# "locked" is not a release.
if [ "$held" = 3 ]; then
  free=0; notfree=""
  for t in profiles current_addresses permanent_addresses; do
    r=$(try_lock $t 'for no key update'); [ "$r" = free ] && free=$((free+1)) || notfree="$notfree $t=$r"
  done
  [ "$free" = 3 ] && pass "K1 the locks end with the save's transaction (3 of 3 rows free again)" \
                  || fail "K1 after the save ended, $free of 3 rows free:$notfree"
else
  fail "K1 lock release not checked: the save was not seen holding all three locks"
fi

# ---- K3: blocked by a concurrent writer of row $1 (profiles / current_addresses).
k3() {
  local table="$1" set_sql="$2" save_sql="$3" label="$4" col=user_id
  [ "$table" = profiles ] && col=id
  { echo "set application_name = 's436_writer';"; echo "begin;"; echo "$set_sql"; echo "select 'A:' || $XID;"; echo "select pg_sleep(4);"; echo "commit;"; } | sql > "$T/a" &
  local pa=$!
  if [ "$(wait_for s436_writer sleeping)" != yes ]; then
    fail "K3 ($label) could not confirm the writer holding its lock"; wait $pa; return
  fi
  { echo "set application_name = 's436_save';"; echo "begin;"; as_user
    echo "select set_config('s436.t0', clock_timestamp()::text, true);"
    echo "$save_sql"
    echo "select 'W:' || round(extract(epoch from clock_timestamp() - current_setting('s436.t0')::timestamptz)::numeric, 1);"
    echo "reset role;"; echo "select 'B:' || $XID;"; echo "commit;"; } | sql > "$T/b" &
  local pb=$!
  local blocked; blocked=$(wait_for s436_save blocked)
  wait $pb; wait $pa
  local xa xb w xmin
  xa=$(grep -o '^A:[0-9]*' "$T/a" | cut -d: -f2); xb=$(grep -o '^B:[0-9]*' "$T/b" | cut -d: -f2)
  w=$(grep -o '^W:[0-9.]*' "$T/b" | cut -d: -f2)
  xmin=$(one "select xmin::text from public.$table where $col = '$U'")
  if grep -q ERROR "$T/a" "$T/b" || [ -z "$xa" ] || [ -z "$xb" ] || [ -z "$w" ]; then
    fail "K3 ($label) a session failed or produced no result: $(grep -h ERROR "$T/a" "$T/b" | head -1)"; return
  fi
  [ "$blocked" = yes ] && pass "K3 ($label) the save was blocked by the writer (seen waiting on a Lock; ${w}s measured in SQL)" \
                       || fail "K3 ($label) the save was never seen blocked (waited ${w}s)"
  [ "$xmin" = "$xa" ] && [ "$xmin" != "$xb" ] \
    && pass "K3 ($label) after the wait the save compared against the committed value and wrote nothing to that row (xmin = writer)" \
    || fail "K3 ($label) stale comparison: row xmin $xmin; writer $xa; save $xb"
}
k3 profiles "update public.profiles set full_name = 'Concurrent' where id = '$U';" \
   "select public.update_profile_details('Concurrent', '03001234567', date '2000-05-01', 'Lahore', null, 'Gulberg', 'House 1');" \
   "profile row"
k3 current_addresses "update public.current_addresses set area = 'Concurrent Area' where user_id = '$U';" \
   "select public.update_profile_details('Concurrent', '03001234567', date '2000-05-01', 'Lahore', null, 'Concurrent Area', 'House 1');" \
   "current address row"

# ---- K4: compatibility smoke test with save_profile_setup_v2, in both orders.
for order in v2-first save-first; do
  if [ $order = v2-first ]; then first="$V2"; second="$SAVE"; else first="$SAVE"; second="$V2"; fi
  { echo "set application_name = 's436_first';"; echo "begin;"; as_user; echo "$first"; echo "select pg_sleep(3);"; echo "commit;"; } | sql > "$T/k1" &
  p1=$!
  if [ "$(wait_for s436_first sleeping)" != yes ]; then fail "K4 ($order) could not confirm the first save"; wait $p1; continue; fi
  { echo "set application_name = 's436_second';"; echo "begin;"; as_user; echo "$second"; echo "select 'done';"; echo "commit;"; } | sql > "$T/k2" &
  p2=$!
  w2=$(wait_for s436_second blocked); wait $p2; wait $p1
  if grep -q ERROR "$T/k1" "$T/k2" || ! grep -q '^done$' "$T/k2"; then
    fail "K4 ($order) $(grep -h ERROR "$T/k1" "$T/k2" | head -1)"
  elif [ "$w2" != yes ]; then fail "K4 ($order) the second save was never seen waiting for the first"
  else pass "K4 ($order) smoke test: the second save waited for the first, both committed"; fi
done

echo "locking checks: $fails failure(s)"
exit $fails
