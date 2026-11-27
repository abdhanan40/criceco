#!/usr/bin/env bash
# CricEco · LOCAL TEST ONLY — migration 30 (M4): the device-move limit of
# register_push_device under concurrent sessions, which a single SQL file
# can't test.
# Run after migration 30 on a disposable local test database (plain
# PostgreSQL with tests/local/00_auth_stub.sql, or the "postgres" database of
# a throwaway container of the real Supabase image).
#
# Usage:  PSQL='docker exec -i criceco-m4-test psql -U postgres -d <local_db>' \
#           bash supabase/tests/local/25b_m4_push_moves_concurrency.sh
# $PSQL must run SQL read from stdin as the database owner. The script
# refuses to run where any auth user has a password or a non-test e-mail. It
# commits synthetic accounts (ids ef900000-…) and always deletes them (with
# their devices and moves) again on exit.
# Prints PASS / FAIL lines; exits with the number of failures.
#   C1 a brand-new token registered by two people at once: the second waits
#      (on a row, not an advisory lock), then the token is theirs AND it
#      counts as one of their moves;
#   C2 one person moving two tokens at once with 2 moves already recorded:
#      the second waits for the first, then is refused (P0001) — never 4.
# Session 1 does its step inside a transaction and then waits at a GATE (an
# advisory lock the driver holds), so it keeps its locks for as long as the
# driver needs. Session 2's result only counts once it is CONFIRMED waiting
# on a lock other than the gate; only then is the gate opened.
set -u
: "${PSQL:?set PSQL to a psql command for the LOCAL test database (see the header)}"
fails=0
T=$(mktemp -d)
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; fails=$((fails+1)); }
one() { echo "$1" | $PSQL -X -At -q 2>&1; }
MINE="datname = current_database() and application_name like 'm30k\\_%' and pid <> pg_backend_pid()"
uid() { printf 'ef900000-0000-4000-8000-%012d' "$1"; }
tok() { printf 'fcm_m30k_%s_%s' "$1" "$(printf 'd%.0s' $(seq 40))"; }

cleanup() {
  local rc=$? i left
  trap - EXIT INT TERM
  one "select pg_cancel_backend(pid) from pg_stat_activity where $MINE" >/dev/null
  for i in $(seq 50); do
    left=$(one "select count(*) from pg_stat_activity where $MINE")
    [ "$left" = "0" ] && break; sleep 0.1
  done
  one "delete from auth.users where id::text like 'ef900000%'" >/dev/null
  if [ "$(one "select count(*) from public.profiles where id::text like 'ef900000%'")" != "0" ] \
     || [ "$(one "select count(*) from public.device_tokens where token like 'fcm\\_m30k\\_%'")" != "0" ] \
     || [ "$(one "select count(*) from public.push_token_moves where user_id::text like 'ef900000%'")" != "0" ]; then
    echo "FAIL  cleanup: synthetic data ef9… was not deleted"; rm -rf "$T"; exit $(( (rc == 0 ? 0 : rc) + 1 ))
  fi
  rm -rf "$T"
  exit $(( fails > 0 ? fails : rc ))
}
trap cleanup EXIT
trap 'fails=$((fails+1)); echo "FAIL  interrupted"; exit 130' INT TERM

if [ "$(one "select to_regclass('public.push_token_moves') is not null")" != "t" ]; then
  echo "run migration 30 first"; exit 99
fi
guard=$(one "do \$\$
declare v_pw boolean := false;
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password') then
    execute 'select exists (select 1 from auth.users where coalesce(encrypted_password, '''') <> '''')' into v_pw;
  end if;
  if v_pw or exists (select 1 from auth.users where email is null or email not like '%@local.test') then
    raise exception 'real users';
  end if;
end \$\$;")
if [ -n "$guard" ]; then echo "LOCAL ONLY: this database has real users — stopping ($guard)"; exit 99; fi

# Both claim spellings: the real image's auth.uid() reads request.jwt.claim.sub.
claims() { printf "set role authenticated;\nset request.jwt.claims = '{\"sub\": \"%s\", \"role\": \"authenticated\"}';\nset request.jwt.claim.sub = '%s';\n" "$(uid "$1")" "$(uid "$1")"; }
session() { # name user sql
  { printf "set application_name = 'm30k_%s';\n" "$1"; claims "$2"; printf "%s\n" "$3"; } | $PSQL -X -At -q >"$T/$1.out" 2>&1 &
}
GATE_KEY=30100025
GATE_MAX=120
WAIT_MAX=60
wait_until() {
  local deadline=$((SECONDS + WAIT_MAX))
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ "$(one "$1")" = "t" ] && return 0; sleep 0.2
  done
  return 1
}
gate_close() {
  printf "set application_name = 'm30k_gate';\nselect pg_advisory_lock(%s);\nselect pg_sleep(%s);\n" "$GATE_KEY" "$GATE_MAX" \
    | $PSQL -X -At -q >/dev/null 2>&1 &
  wait_until "select exists (select 1 from pg_locks l where l.locktype = 'advisory' and l.objid = $GATE_KEY and l.granted
                 and l.pid in (select pid from pg_stat_activity where $MINE and application_name = 'm30k_gate'))"
}
gate_open() { one "select count(pg_terminate_backend(pid)) from pg_stat_activity where $MINE and application_name = 'm30k_gate'" >/dev/null; }
GATE="select pg_advisory_lock($GATE_KEY);"
at_gate() { wait_until "select exists (select 1 from pg_stat_activity where $MINE and application_name = 'm30k_$1'
                          and wait_event_type = 'Lock' and wait_event = 'advisory')"; }
blocked() { wait_until "select exists (select 1 from pg_stat_activity where $MINE and application_name = 'm30k_$1'
                          and wait_event_type = 'Lock' and wait_event <> 'advisory')"; }
owner() { one "select coalesce(string_agg(right(user_id::text, 2), ','), '-') from public.device_tokens where token = '$(tok "$1")'"; }
moves() { one "select count(*) from public.push_token_moves where user_id = '$(uid "$1")'"; }

# --- Synthetic people 1–6 (complete profiles); tokens t2 (person 3), t3 (person 4).
one "do \$\$
declare n int; v uuid;
begin
  foreach n in array array[1, 2, 3, 4, 5, 6] loop
    v := ('ef900000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid;
    insert into auth.users (id, email) values (v, format('m30k%s@local.test', n));
    insert into public.profiles (id) values (v) on conflict (id) do nothing;
    insert into public.current_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
    insert into public.permanent_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
    update public.profiles set full_name = format('Race Move %s', n),
           phone = format('+923%s', lpad((720000000 + n)::text, 9, '0')),
           date_of_birth = date '2000-05-01', profile_completed = true
     where id = v;
  end loop;
  insert into public.device_tokens (user_id, token, platform) values
    ('ef900000-0000-4000-8000-000000000003', '$(tok t2)', 'android'),
    ('ef900000-0000-4000-8000-000000000004', '$(tok t3)', 'android');
  -- Person 5 has moved 2 tokens already today.
  insert into public.push_token_moves (user_id) values
    ('ef900000-0000-4000-8000-000000000005'), ('ef900000-0000-4000-8000-000000000005');
end \$\$;" >"$T/setup.err" 2>&1
[ "$(owner t2)/$(owner t3)/$(moves 5)" = "03/04/2" ] || { fail "setup: $(cat "$T/setup.err")"; exit 1; }

# --- C1 a brand-new token registered by two people at once ---------------------
if ! gate_close; then fail "C1 the gate could not be closed"; fi
session c1a 1 "begin; select public.register_push_device('$(tok t1)'); $GATE commit;"
if at_gate c1a; then
  session c1b 2 "select public.register_push_device('$(tok t1)');"
  if blocked c1b; then
    gate_open
    wait
    if [ "$(owner t1)" = "02" ] && [ "$(moves 2)" = "1" ] && [ "$(moves 1)" = "0" ] \
       && ! grep -q ERROR "$T/c1a.out" "$T/c1b.out"; then
      pass "C1 the second registration waits, then the token is theirs and counts as their move (1)"
    else
      fail "C1 owner=$(owner t1) moves2=$(moves 2) moves1=$(moves 1) a=$(tr '\n' ' ' <"$T/c1a.out") b=$(tr '\n' ' ' <"$T/c1b.out")"
    fi
  else
    fail "C1 session 2 did not wait: $(tr '\n' ' ' <"$T/c1b.out")"; gate_open; wait
  fi
else
  fail "C1 session 1 never reached the gate: $(cat "$T/c1a.out")"; gate_open; wait
fi

# --- C2 one person moving two tokens at once (2 moves already) -----------------
if ! gate_close; then fail "C2 the gate could not be closed"; fi
session c2a 5 "begin; select public.register_push_device('$(tok t2)'); $GATE commit;"
if at_gate c2a; then
  session c2b 5 "select public.register_push_device('$(tok t3)');"
  if blocked c2b; then
    gate_open
    wait
    if [ "$(owner t2)" = "05" ] && [ "$(owner t3)" = "04" ] && [ "$(moves 5)" = "3" ] \
       && ! grep -q ERROR "$T/c2a.out" && grep -q 'push: too many device moves' "$T/c2b.out"; then
      pass "C2 the second move waits for the first, then is refused — 3 moves, never 4"
    else
      fail "C2 t2=$(owner t2) t3=$(owner t3) moves5=$(moves 5) a=$(tr '\n' ' ' <"$T/c2a.out") b=$(tr '\n' ' ' <"$T/c2b.out")"
    fi
  else
    fail "C2 session 2 did not wait: $(tr '\n' ' ' <"$T/c2b.out")"; gate_open; wait
  fi
else
  fail "C2 session 1 never reached the gate: $(cat "$T/c2a.out")"; gate_open; wait
fi
