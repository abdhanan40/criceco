#!/usr/bin/env bash
# CricEco · LOCAL TEST ONLY — migration 26 (notification preferences):
# concurrent sessions, which a single SQL file can't test.
# Run after migration 26 on a disposable local test database that has the
# auth stub (tests/local/00_auth_stub.sql) and migrations 1–25.
#
# Usage:  PSQL='docker exec -i criceco-m17-test psql -U postgres -d <local_db>' \
#           bash supabase/tests/local/21b_notification_preferences_concurrency.sh
# $PSQL must run SQL read from stdin as the database owner. The script
# refuses to run on a real Supabase project. It commits synthetic accounts and
# clubs (ids ef3…) and always deletes them again on exit.
# Prints PASS / FAIL lines; exits with the number of failures.
#
# Session 1 does its step inside a transaction and then sleeps; session 2
# starts only once session 1 is CONFIRMED sleeping, and where it must wait its
# result only counts once it is CONFIRMED waiting on a lock.
#   P1 a challenge sent while the challenged owner is turning challenges off:
#      the challenge does not wait; it follows the setting as committed then
#      (told), and the next one after the commit is not told;
#   P2 two saves of the same person's first preferences at once: the second
#      waits on the first, then its whole choice is the one kept (no mix).
set -u
: "${PSQL:?set PSQL to a psql command for the LOCAL test database (see the header)}"
fails=0
T=$(mktemp -d)
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; fails=$((fails+1)); }
one() { echo "$1" | $PSQL -X -At -q 2>&1; }
MINE="datname = current_database() and application_name like 'm26k\\_%' and pid <> pg_backend_pid()"
uid() { printf 'ef300000-0000-4000-8000-%012d' "$1"; }
O1=$(uid 1)
O2=$(uid 2)

cleanup() {
  local rc=$? i left
  trap - EXIT INT TERM
  one "select pg_cancel_backend(pid) from pg_stat_activity where $MINE" >/dev/null
  for i in $(seq 50); do
    left=$(one "select count(*) from pg_stat_activity where $MINE")
    [ "$left" = "0" ] && break; sleep 0.1
  done
  one "delete from public.clubs where owner_id::text like 'ef300000%'" >/dev/null
  one "delete from auth.users where id::text like 'ef300000%'" >/dev/null
  if [ "$(one "select count(*) from public.profiles where id::text like 'ef300000%'")" != "0" ] \
     || [ "$(one "select count(*) from public.notification_preferences where user_id::text like 'ef300000%'")" != "0" ]; then
    echo "FAIL  cleanup: synthetic data ef3… was not deleted"; rm -rf "$T"; exit $(( (rc == 0 ? 0 : rc) + 1 ))
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
if [ "$(one "select to_regclass('public.notification_preferences') is not null")" != "t" ]; then
  echo "run migration 26 first"; exit 99
fi

claims() { printf "set role authenticated;\nset request.jwt.claims = '{\"sub\": \"%s\", \"role\": \"authenticated\"}';\n" "$(uid "$1")"; }
session() { # name user sql
  { printf "set application_name = 'm26k_%s';\n" "$1"; claims "$2"; printf "%s\n" "$3"; } | $PSQL -X -At -q >"$T/$1.out" 2>&1 &
}
as_user() { { claims "$1"; printf "%s\n" "$2"; } | $PSQL -X -At -q 2>&1 | tail -n 1; }
wait_until() {
  local i
  for i in $(seq 100); do
    [ "$(one "$1")" = "t" ] && return 0; sleep 0.1
  done
  return 1
}
sleeping() { wait_until "select exists (select 1 from pg_stat_activity where $MINE and application_name = 'm26k_$1'
                           and state = 'active' and query like '%pg_sleep%')"; }
blocked()  { wait_until "select exists (select 1 from pg_stat_activity where $MINE and application_name = 'm26k_$1'
                           and wait_event_type = 'Lock')"; }
cnt() { one "select count(*) from public.notifications where recipient_id = '$(uid "$1")' and type = '$2'"; }
prefs() { one "select join_requests || '/' || challenges || '/' || matches || '/' || results || '/' || announcements
                 from public.notification_preferences where user_id = '$(uid "$1")'"; }

# --- Synthetic data: owners 1 (club A) and 2 (club B); person 3 in no club.
one "do \$\$
declare n int; v uuid;
begin
  foreach n in array array[1, 2, 3] loop
    v := ('ef300000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid;
    insert into auth.users (id, email) values (v, format('m26k%s@local.test', n));
    insert into public.current_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
    insert into public.permanent_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
    update public.profiles set full_name = format('Race Pref %s', n),
           phone = format('+923%s', lpad((640000000 + n)::text, 9, '0')),
           date_of_birth = date '2000-05-01', profile_completed = true
     where id = v;
  end loop;
  insert into public.clubs (owner_id, name, city, club_type) values ('$O1', 'Race Pref A', 'Lahore', 'corporate'),
                                                                  ('$O2', 'Race Pref B', 'Karachi', 'corporate');
end \$\$;" >"$T/setup.err" 2>&1 || true
CA=$(one "select id from public.clubs where owner_id = '$O1'")
CB=$(one "select id from public.clubs where owner_id = '$O2'")
[ -n "$CA" ] && [ -n "$CB" ] || { fail "setup: clubs not created: $(cat "$T/setup.err")"; exit 1; }
CHALLENGE="select (public.send_challenge('$CA', '$CB', 't20', null, current_date + 10, 'Race Ground', null)).status;"
LAST="(select id from public.match_challenges where from_club_id = '$CA' order by created_at desc limit 1)"

# --- P1 a challenge while the owner is turning challenges off ----------------
session p1a 2 "begin; select challenges from public.set_notification_preferences(true, false, true, true, true);
               select pg_sleep(3); commit;"
if sleeping p1a; then
  sent=$(as_user 1 "$CHALLENGE")
  during=$(cnt 2 challenge_received)
  still=$(one "select exists (select 1 from pg_stat_activity where $MINE and application_name = 'm26k_p1a')")
  wait
  as_user 2 "select (public.respond_to_challenge($LAST, false)).status;" >/dev/null
  as_user 1 "$CHALLENGE" >/dev/null
  if [ "$sent" = "pending" ] && [ "$during" = "1" ] && [ "$still" = "t" ] && [ "$(cnt 2 challenge_received)" = "1" ] \
     && [ "$(prefs 2)" = "true/false/true/true/true" ]; then
    pass "P1 the challenge does not wait; it follows the setting committed then; after the commit it is muted"
  else
    fail "P1 sent=$sent during=$during still=$still after=$(cnt 2 challenge_received) prefs=$(prefs 2)"
  fi
else
  fail "P1 session 1 never started sleeping: $(cat "$T/p1a.out")"; wait
fi

# --- P2 two first saves at once ------------------------------------------------
session p2a 3 "begin; select matches from public.set_notification_preferences(true, true, false, true, true);
               select pg_sleep(3); commit;"
if sleeping p2a; then
  session p2b 3 "select results from public.set_notification_preferences(true, true, true, false, true);"
  if blocked p2b; then
    wait
    if [ "$(head -n 1 "$T/p2a.out")" = "f" ] && [ "$(tail -n 1 "$T/p2b.out")" = "f" ] \
       && [ "$(prefs 3)" = "true/true/true/false/true" ] \
       && [ "$(one "select count(*) from public.notification_preferences where user_id = '$(uid 3)'")" = "1" ]; then
      pass "P2 the second save waits, then its whole choice is kept (one row, no mix)"
    else
      fail "P2 a=$(tr '\n' ' ' <"$T/p2a.out") b=$(tr '\n' ' ' <"$T/p2b.out") prefs=$(prefs 3)"
    fi
  else
    fail "P2 session 2 did not wait: $(tr '\n' ' ' <"$T/p2b.out")"; wait
  fi
else
  fail "P2 session 1 never started sleeping: $(cat "$T/p2a.out")"; wait
fi
