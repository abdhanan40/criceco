#!/usr/bin/env bash
# CricEco · LOCAL TEST ONLY — migration 27 (push delivery): concurrent
# sessions, which a single SQL file can't test.
# Run after migration 27 on a disposable local test database that has the
# auth stub (tests/local/00_auth_stub.sql) and migrations 1–26.
#
# Usage:  PSQL='docker exec -i criceco-m17-test psql -U postgres -d <local_db>' \
#           bash supabase/tests/local/22b_push_delivery_concurrency.sh
# $PSQL must run SQL read from stdin as the database owner. The script
# refuses to run on a real Supabase project. It commits synthetic accounts and
# a club (ids ef4…) and always deletes them again on exit.
# Prints PASS / FAIL lines; exits with the number of failures.
#   D1 two dispatchers claim at once: the second does NOT wait and gets only
#      what the first didn't take — no delivery is sent twice;
#   D2 the same phone registered by two people at once: the second waits,
#      then the token is theirs — one row, never two owners.
set -u
: "${PSQL:?set PSQL to a psql command for the LOCAL test database (see the header)}"
fails=0
T=$(mktemp -d)
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; fails=$((fails+1)); }
one() { echo "$1" | $PSQL -X -At -q 2>&1; }
MINE="datname = current_database() and application_name like 'm27k\\_%' and pid <> pg_backend_pid()"
uid() { printf 'ef400000-0000-4000-8000-%012d' "$1"; }
O1=$(uid 1)
TOKEN="fcm_shared_$(printf 'b%.0s' $(seq 40))"

cleanup() {
  local rc=$? i left
  trap - EXIT INT TERM
  one "select pg_cancel_backend(pid) from pg_stat_activity where $MINE" >/dev/null
  for i in $(seq 50); do
    left=$(one "select count(*) from pg_stat_activity where $MINE")
    [ "$left" = "0" ] && break; sleep 0.1
  done
  one "delete from public.clubs where owner_id::text like 'ef400000%'" >/dev/null
  one "delete from auth.users where id::text like 'ef400000%'" >/dev/null
  if [ "$(one "select count(*) from public.profiles where id::text like 'ef400000%'")" != "0" ] \
     || [ "$(one "select count(*) from public.device_tokens where token like 'fcm\\_%'")" != "0" ]; then
    echo "FAIL  cleanup: synthetic data ef4… was not deleted"; rm -rf "$T"; exit $(( (rc == 0 ? 0 : rc) + 1 ))
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
if [ "$(one "select to_regclass('public.push_deliveries') is not null")" != "t" ]; then
  echo "run migration 27 first"; exit 99
fi
if [ "$(one "select exists (select 1 from public.push_deliveries where status in ('pending', 'sending'))")" != "f" ]; then
  echo "LOCAL ONLY: this database has open pushes of its own — use a fresh copy"; exit 99
fi

claims() { printf "set role authenticated;\nset request.jwt.claims = '{\"sub\": \"%s\", \"role\": \"authenticated\"}';\n" "$(uid "$1")"; }
session() { # name user|service sql
  if [ "$2" = "service" ]; then
    printf "set application_name = 'm27k_%s';\nset role service_role;\n%s\n" "$1" "$3"
  else
    { printf "set application_name = 'm27k_%s';\n" "$1"; claims "$2"; printf "%s\n" "$3"; }
  fi | $PSQL -X -At -q >"$T/$1.out" 2>&1 &
}
as_user() { { claims "$1"; printf "%s\n" "$2"; } | $PSQL -X -At -q 2>&1 | tail -n 1; }
wait_until() {
  local i
  for i in $(seq 100); do
    [ "$(one "$1")" = "t" ] && return 0; sleep 0.1
  done
  return 1
}
sleeping() { wait_until "select exists (select 1 from pg_stat_activity where $MINE and application_name = 'm27k_$1'
                           and state = 'active' and query like '%pg_sleep%')"; }
blocked()  { wait_until "select exists (select 1 from pg_stat_activity where $MINE and application_name = 'm27k_$1'
                           and wait_event_type = 'Lock')"; }

# --- Synthetic data: owner 1 (club A), members 11–30, each with a device.
one "do \$\$
declare n int; v uuid;
begin
  foreach n in array array[1] || array(select generate_series(11, 30)) loop
    v := ('ef400000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid;
    insert into auth.users (id, email) values (v, format('m27k%s@local.test', n));
    insert into public.current_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
    insert into public.permanent_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
    update public.profiles set full_name = format('Race Push %s', n),
           phone = format('+923%s', lpad((660000000 + n)::text, 9, '0')),
           date_of_birth = date '2000-05-01', profile_completed = true
     where id = v;
    if n > 1 then
      insert into public.device_tokens (user_id, token, platform)
      values (v, 'fcm_member_' || n || '_' || repeat('c', 30), 'android');
    end if;
  end loop;
  insert into public.clubs (owner_id, name, city, club_type) values ('$O1', 'Race Push A', 'Lahore', 'corporate');
  insert into public.club_members (club_id, user_id, member_role, status)
  select c.id, ('ef400000-0000-4000-8000-' || lpad(g.k::text, 12, '0'))::uuid, 'player', 'active'
    from public.clubs c, generate_series(11, 30) as g(k) where c.owner_id = '$O1';
end \$\$;" >"$T/setup.err" 2>&1 || true
CA=$(one "select id from public.clubs where owner_id = '$O1'")
[ -n "$CA" ] || { fail "setup: club not created: $(cat "$T/setup.err")"; exit 1; }
as_user 1 "select (public.publish_club_announcement('$CA', 'Race', 'Twenty pushes.', 'all')).recipient_count;" >/dev/null
[ "$(one "select count(*) from public.push_deliveries where status = 'pending'")" = "20" ] \
  || { fail "setup: 20 pending deliveries expected"; exit 1; }

# --- D1 two dispatchers claim at once ------------------------------------------
session d1a service "begin; select notification_id from public.push_claim(10); select pg_sleep(3); commit;"
if sleeping d1a; then
  printf "set role service_role;\nselect notification_id from public.push_claim(500);\n" | $PSQL -X -At -q >"$T/d1b.out" 2>&1
  still=$(one "select exists (select 1 from pg_stat_activity where $MINE and application_name = 'm27k_d1a')")
  wait
  a=$(grep -cE '^[0-9a-f-]{36}$' "$T/d1a.out"); b=$(grep -cE '^[0-9a-f-]{36}$' "$T/d1b.out")
  both=$(sort "$T/d1a.out" "$T/d1b.out" | grep -E '^[0-9a-f-]{36}$' | uniq -d | wc -l)
  if [ "$still" = "t" ] && [ "$a" = "10" ] && [ "$b" = "10" ] && [ "$both" = "0" ] \
     && [ "$(one "select count(*) from public.push_deliveries where status = 'sending' and attempts = 1")" = "20" ]; then
    pass "D1 the second dispatcher doesn't wait and takes only the other 10 — nothing claimed twice"
  else
    fail "D1 during=$still a=$a b=$b overlap=$both"
  fi
else
  fail "D1 session 1 never started sleeping: $(cat "$T/d1a.out")"; wait
fi

# --- D2 the same phone registered by two people at once -----------------------
session d2a 11 "begin; select public.register_push_device('$TOKEN'); select pg_sleep(3); commit;"
if sleeping d2a; then
  session d2b 12 "select public.register_push_device('$TOKEN');"
  if blocked d2b; then
    wait
    owner=$(one "select string_agg(right(user_id::text, 2), ',') from public.device_tokens where token = '$TOKEN'")
    if [ "$owner" = "12" ] && ! grep -q ERROR "$T/d2a.out" "$T/d2b.out"; then
      pass "D2 the second registration waits, then the phone is theirs — one row, one owner"
    else
      fail "D2 owner=$owner a=$(tr '\n' ' ' <"$T/d2a.out") b=$(tr '\n' ' ' <"$T/d2b.out")"
    fi
  else
    fail "D2 session 2 did not wait: $(tr '\n' ' ' <"$T/d2b.out")"; wait
  fi
else
  fail "D2 session 1 never started sleeping: $(cat "$T/d2a.out")"; wait
fi
