#!/usr/bin/env bash
# CricEco · LOCAL TEST ONLY — migration 24 (official results): concurrent
# sessions, which a single SQL file can't test.
# Run after migration 24 on a disposable local test database that has the
# auth stub (tests/local/00_auth_stub.sql) and migrations 1–23.
#
# Usage:  PSQL='docker exec -i criceco-m17-test psql -U postgres -d <local_db>' \
#           bash supabase/tests/local/19b_result_write_lockdown_concurrency.sh
# $PSQL must run SQL read from stdin as the database owner. The script
# refuses to run on a real Supabase project. It commits synthetic accounts,
# clubs, matches and scorer clients (ids ef…) and always deletes them again
# on exit (the audit logs they produced too — with triggers off, locally).
# Prints PASS / FAIL lines; exits with the number of failures.
#
# Session 1 does its step inside a transaction and then sleeps, holding its
# locks; session 2 starts only once session 1 is CONFIRMED sleeping, and its
# result only counts once it is CONFIRMED waiting on a lock
# (pg_stat_activity). No fixed sleep decides a result.
#   K1 the same request (client + key) twice at once: the second waits, then
#      replays the first outcome — one version, one record;
#   K2 a verification while the scorer replaces the result: the verification
#      waits, then is rejected ("version changed"); the new version waits;
#   K3 two verifiers approve at once: the second waits, then "not pending";
#      one official result, decided by the first;
#   K4 an account deleted while an official scorecard naming that player is
#      being ingested: the deletion waits, then the new rows say
#      "Deleted player" (name and link gone, rows kept, the change recorded).
set -u
: "${PSQL:?set PSQL to a psql command for the LOCAL test database (see the header)}"
fails=0
T=$(mktemp -d)
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; fails=$((fails+1)); }
one() { echo "$1" | $PSQL -X -At -q 2>&1; }
MINE="datname = current_database() and application_name like 'm24k\\_%' and pid <> pg_backend_pid()"
uid() { printf 'ef000000-0000-4000-8000-%012d' "$1"; }
mid() { printf 'ef0000aa-0000-4000-8000-%012d' "$1"; }
cid() { printf 'ef0c0000-0000-4000-8000-%012d' "$1"; }
A=$(uid 1)
B=$(uid 2)
S=$(cid 1)
V=$(cid 2)
W=$(cid 3)

cleanup() {
  local rc=$? i left
  trap - EXIT INT TERM
  one "select pg_cancel_backend(pid) from pg_stat_activity where $MINE" >/dev/null
  for i in $(seq 50); do
    left=$(one "select count(*) from pg_stat_activity where $MINE")
    [ "$left" = "0" ] && break; sleep 0.1
  done
  one "delete from public.clubs where owner_id::text like 'ef000000%'" >/dev/null
  one "delete from auth.users where id::text like 'ef000000%'" >/dev/null
  one "set session_replication_role = replica;
       delete from public.result_submission_log where client_id::text like 'ef0c0000%';
       delete from public.result_change_log where match_id::text like 'ef0000aa%';
       delete from public.scorer_clients where id::text like 'ef0c0000%';" >/dev/null
  if [ "$(one "select count(*) from public.profiles where id::text like 'ef000000%'")" != "0" ] \
     || [ "$(one "select count(*) from public.scorer_clients where id::text like 'ef0c0000%'")" != "0" ]; then
    echo "FAIL  cleanup: synthetic data ef… was not deleted"; rm -rf "$T"; exit $(( (rc == 0 ? 0 : rc) + 1 ))
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
if [ "$(one "select to_regclass('public.scorer_clients') is not null")" != "t" ]; then
  echo "run migration 24 first"; exit 99
fi

session() { # name sql   (as service_role: the future Edge Function)
  printf "set application_name = 'm24k_%s';\nset role service_role;\n%s\n" "$1" "$2" | $PSQL -X -At -q >"$T/$1.out" 2>&1 &
}
owner_session() { # name sql   (as the database owner, e.g. account deletion)
  printf "set application_name = 'm24k_%s';\n%s\n" "$1" "$2" | $PSQL -X -At -q >"$T/$1.out" 2>&1 &
}
as_service() { printf "set role service_role;\n%s\n" "$1" | $PSQL -X -At -q 2>&1 | tail -n 1; }
wait_until() {
  local i
  for i in $(seq 100); do
    [ "$(one "$1")" = "t" ] && return 0; sleep 0.1
  done
  return 1
}
sleeping() { wait_until "select exists (select 1 from pg_stat_activity where $MINE and application_name = 'm24k_$1'
                           and state = 'active' and query like '%pg_sleep%')"; }
blocked()  { wait_until "select exists (select 1 from pg_stat_activity where $MINE and application_name = 'm24k_$1'
                           and wait_event_type = 'Lock')"; }
# "outcome|version|reason|replayed" of a scorer function call.
F="outcome || '|' || coalesce(version::text, '-') || '|' || coalesce(reason, '-') || '|' || replayed"
ingest() { echo "select $F from public.ingest_official_result('$S', '$1', '$(mid "$2")', $3);"; }
verify() { echo "select $F from public.verify_official_result('$1', '$2', '$(mid "$3")', $4, true);"; }
history() {
  one "select coalesce(string_agg(version || ':' || status, ',' order by version), '-')
         from public.match_results where match_id = '$(mid "$1")'"
}

# --- Synthetic data: owners 1 (club A), 2 (club B); players 11, 12 of A and
# 21, 22, 23 of B; four played T20s; scorer S, verifiers V and W, assigned.
one "do \$\$
declare n int; v uuid;
begin
  foreach n in array array[1, 2, 11, 12, 21, 22, 23] loop
    v := ('ef000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid;
    insert into auth.users (id, email) values (v, format('m24k%s@local.test', n));
    insert into public.current_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
    insert into public.permanent_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
    update public.profiles set full_name = format('Race Official %s', n),
           phone = format('+923%s', lpad((610000000 + n)::text, 9, '0')),
           date_of_birth = date '2000-05-01', profile_completed = true
     where id = v;
    insert into public.player_profiles (user_id, player_role, batting_style, bowling_style, is_wicketkeeper)
    values (v, 'all_rounder', 'right_handed', 'right_arm_fast', false);
  end loop;
  insert into public.clubs (owner_id, name, city, club_type) values ('$A', 'Race Official A', 'Lahore', 'corporate'),
                                                                  ('$B', 'Race Official B', 'Karachi', 'corporate');
  insert into public.club_members (club_id, user_id, member_role, status)
  select c.id, ('ef000000-0000-4000-8000-' || lpad(g.k::text, 12, '0'))::uuid, 'player', 'active'
    from public.clubs c, unnest(array[11, 12]) as g(k) where c.owner_id = '$A';
  insert into public.club_members (club_id, user_id, member_role, status)
  select c.id, ('ef000000-0000-4000-8000-' || lpad(g.k::text, 12, '0'))::uuid, 'player', 'active'
    from public.clubs c, unnest(array[21, 22, 23]) as g(k) where c.owner_id = '$B';
  insert into public.matches (id, club_a_id, club_b_id, format, status, starts_at, venue_name)
  select ('ef0000aa-0000-4000-8000-' || lpad(g.k::text, 12, '0'))::uuid, a.id, b.id, 't20', 'confirmed',
         now() - make_interval(days => g.k), 'Race Ground'
    from public.clubs a, public.clubs b, generate_series(1, 4) as g(k)
   where a.owner_id = '$A' and b.owner_id = '$B';
  insert into public.scorer_clients (id, name, key_id) values
    ('$S', 'Race Scorer', 'race.scorer.k1'), ('$V', 'Race Verifier', 'race.verifier.k1'),
    ('$W', 'Race Verifier Two', 'race.verifier.k2');
end \$\$;" >"$T/setup.err" 2>&1 || true
CA=$(one "select id from public.clubs where owner_id = '$A'")
CB=$(one "select id from public.clubs where owner_id = '$B'")
[ -n "$CA" ] && [ -n "$CB" ] && [ "$(one "select count(*) from public.matches where id::text like 'ef0000aa%'")" = "4" ] \
  || { fail "setup: clubs or matches not created: $(cat "$T/setup.err")"; exit 1; }
for k in 1 2 3 4; do
  as_service "select public.assign_match_official('$(mid $k)', '$S', 'scorer'),
                     public.assign_match_official('$(mid $k)', '$V', 'verifier'),
                     public.assign_match_official('$(mid $k)', '$W', 'verifier');" >/dev/null
done
[ "$(one "select count(*) from public.match_officials where client_id::text like 'ef0c0000%'")" = "12" ] \
  || { fail "setup: officials not assigned"; exit 1; }
mem() { one "select id from public.club_members where user_id = '$(uid "$1")'"; }
TOTALS="jsonb_build_object('outcome', 'club_a_won', 'innings', jsonb_build_array(
          jsonb_build_object('batting_club_id', '$CA', 'runs', 150, 'wickets', 3, 'balls', 120),
          jsonb_build_object('batting_club_id', '$CB', 'runs', 120, 'wickets', 10, 'balls', 110)))"
# A 20/1 in 12 balls (11 15 c 21 b 22, 12 5*; 22 bowls 2-0-20); B 10/0 in 6 balls (21 6*, 23 4*; 11 bowls 1-0-10).
A11=$(mem 11); A12=$(mem 12); B21=$(mem 21); B22=$(mem 22); B23=$(mem 23)
CARD="'{\"outcome\": \"club_a_won\", \"innings\": [
   {\"batting_club_id\": \"$CA\", \"runs\": 20, \"wickets\": 1, \"balls\": 12,
    \"batting\": [{\"member_id\": \"$A11\", \"runs\": 15, \"balls\": 8, \"dismissal\": \"caught\",
                   \"bowler_member_id\": \"$B22\", \"fielder_member_id\": \"$B21\"},
                  {\"member_id\": \"$A12\", \"runs\": 5, \"balls\": 4, \"dismissal\": \"not_out\"}],
    \"bowling\": [{\"member_id\": \"$B22\", \"balls\": 12, \"runs\": 20}]},
   {\"batting_club_id\": \"$CB\", \"runs\": 10, \"wickets\": 0, \"balls\": 6,
    \"batting\": [{\"member_id\": \"$B21\", \"runs\": 6, \"balls\": 3, \"dismissal\": \"not_out\"},
                  {\"member_id\": \"$B23\", \"runs\": 4, \"balls\": 3, \"dismissal\": \"not_out\"}],
    \"bowling\": [{\"member_id\": \"$A11\", \"balls\": 6, \"runs\": 10}]}]}'::jsonb"

# --- K1 the same request twice at once ------------------------------------------
session k1a "begin; $(ingest dup 1 "$TOTALS") select pg_sleep(4); commit;"
if sleeping k1a; then
  session k1b "$(ingest dup 1 "$TOTALS")"
  if blocked k1b; then
    wait
    logs=$(one "select count(*) from public.result_submission_log where client_id = '$S' and idempotency_key = 'dup'")
    if grep -q '^accepted|1|-|false$' "$T/k1a.out" && grep -q '^accepted|1|-|true$' "$T/k1b.out" \
       && [ "$(history 1)" = "1:submitted" ] && [ "$logs" = "1" ]; then
      pass "K1 the same request twice: the second waited, then replayed the first — one version, one record"
    else fail "K1 the same request twice: $(cat "$T/k1a.out" "$T/k1b.out" | tr '\n' ' ') history=$(history 1) logs=$logs"; fi
  else wait; fail "K1 the second request was never seen waiting"; fi
else wait; fail "K1 session 1 never reached its sleep: $(cat "$T/k1a.out")"; fi

# --- K2 a verification while the result is replaced --------------------------------
[ "$(as_service "$(ingest k2-first 2 "$TOTALS")")" = "accepted|1|-|false" ] || fail "K2 setup: first version not stored"
session k2a "begin; $(ingest k2-second 2 "$TOTALS") select pg_sleep(4); commit;"
if sleeping k2a; then
  session k2b "$(verify "$V" k2-verify 2 1)"
  if blocked k2b; then
    wait
    if grep -q '^accepted|2|-|false$' "$T/k2a.out" && grep -q '^rejected|-|result: version changed|false$' "$T/k2b.out" \
       && [ "$(history 2)" = "1:superseded,2:submitted" ]; then
      pass "K2 verify vs replacement: the verification waited, then 'version changed'; version 2 waits"
    else fail "K2 verify vs replacement: $(cat "$T/k2a.out" "$T/k2b.out" | tr '\n' ' ') history=$(history 2)"; fi
  else wait; fail "K2 the verification was never seen waiting"; fi
else wait; fail "K2 session 1 never reached its sleep: $(cat "$T/k2a.out")"; fi

# --- K3 two verifiers approve at once ------------------------------------------------
[ "$(as_service "$(ingest k3-first 3 "$TOTALS")")" = "accepted|1|-|false" ] || fail "K3 setup: version not stored"
session k3a "begin; $(verify "$V" k3-v 3 1) select pg_sleep(4); commit;"
if sleeping k3a; then
  session k3b "$(verify "$W" k3-w 3 1)"
  if blocked k3b; then
    wait
    state=$(one "select status || '|' || (decided_by_client_id = '$V') || '|' || (select status from public.matches where id = '$(mid 3)')
                   from public.match_results where match_id = '$(mid 3)' and version = 1")
    if grep -q '^accepted|1|-|false$' "$T/k3a.out" && grep -q '^rejected|-|result: not pending|false$' "$T/k3b.out" \
       && [ "$state" = "confirmed|true|completed" ]; then
      pass "K3 two verifiers at once: the second waited, then 'not pending'; one official result, by the first"
    else fail "K3 two verifiers at once: $(cat "$T/k3a.out" "$T/k3b.out" | tr '\n' ' ') state=$state"; fi
  else wait; fail "K3 the second verifier was never seen waiting"; fi
else wait; fail "K3 session 1 never reached its sleep: $(cat "$T/k3a.out")"; fi

# --- K4 account deletion during an official scorecard ingest -------------------------
session k4a "begin; $(ingest k4-card 4 "$CARD") select pg_sleep(4); commit;"
if sleeping k4a; then
  owner_session k4b "delete from auth.users where id = '$(uid 21)'; select 'gone';"
  if blocked k4b; then
    wait
    state=$(one "select count(*) || '|' || count(*) filter (where player_deleted and player_name is null and member_id is null)
                        || '|' || count(*) filter (where fielder_deleted and fielder_name is null and fielder_member_id is null)
                   from public.match_batting where match_id = '$(mid 4)'")
    logged=$(one "select count(*) from public.result_change_log
                   where match_id = '$(mid 4)' and table_name = 'match_batting' and operation = 'UPDATE'")
    if grep -q '^accepted|1|-|false$' "$T/k4a.out" && grep -q '^gone$' "$T/k4b.out" && [ "$state" = "4|1|1" ] \
       && [ "$logged" -ge 2 ]; then
      pass "K4 account deletion during an official ingest: waited, then 'Deleted player' on the new rows (4 kept, change recorded)"
    else fail "K4 account deletion during an official ingest: $(cat "$T/k4a.out" "$T/k4b.out" | tr '\n' ' ') rows=$state logged=$logged"; fi
  else wait; fail "K4 the deletion was never seen waiting"; fi
else wait; fail "K4 session 1 never reached its sleep: $(cat "$T/k4a.out")"; fi

echo "failures: $fails"
exit "$fails"
