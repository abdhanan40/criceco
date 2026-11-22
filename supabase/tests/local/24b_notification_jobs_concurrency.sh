#!/usr/bin/env bash
# CricEco · LOCAL TEST ONLY — migration 29 (notification jobs hardening):
# two reminder runs at the same time (a slow run still going when pg_cron
# starts the next), which a single SQL file can't test.
# Run after migration 29 on a disposable local test database that has the
# auth stub (tests/local/00_auth_stub.sql) and migrations 1–28.
#
# Usage:  PSQL='docker exec -i criceco-m17-test psql -U postgres -d <local_db>' \
#           bash supabase/tests/local/24b_notification_jobs_concurrency.sh
# $PSQL must run SQL read from stdin as the database owner. The script
# refuses to run on a real Supabase project. It commits synthetic accounts,
# clubs, a match, a challenge and an offer (ids ef5…) and always deletes them
# (and the job runs it caused) again on exit.
# Prints PASS / FAIL lines; exits with the number of failures.
#   J1 run 2 starts while run 1 has sent but not committed: run 2 waits on
#      run 1's reminders, then sends nothing twice — 6 reminders, one each;
#      run 1 counts 6, run 2 counts 0, and both are logged ok.
# Session 1 does its step inside a transaction and then waits at a GATE (an
# advisory lock the driver holds), so it keeps its locks for as long as the
# driver needs — not for a fixed time. Session 2's result only counts once it
# is CONFIRMED waiting on a row lock; only then is the gate opened.
set -u
: "${PSQL:?set PSQL to a psql command for the LOCAL test database (see the header)}"
fails=0
T=$(mktemp -d)
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; fails=$((fails+1)); }
one() { echo "$1" | $PSQL -X -At -q 2>&1; }
MINE="datname = current_database() and application_name like 'm29k\\_%' and pid <> pg_backend_pid()"
uid() { printf 'ef500000-0000-4000-8000-%012d' "$1"; }
MATCH='ef5000aa-0000-4000-8000-000000000001'
RUN0=""

cleanup() {
  local rc=$? i left
  trap - EXIT INT TERM
  one "select pg_cancel_backend(pid) from pg_stat_activity where $MINE" >/dev/null
  for i in $(seq 50); do
    left=$(one "select count(*) from pg_stat_activity where $MINE")
    [ "$left" = "0" ] && break; sleep 0.1
  done
  [ -n "$RUN0" ] && one "delete from public.notification_job_runs where id > $RUN0" >/dev/null
  one "delete from public.clubs where owner_id::text like 'ef500000%'" >/dev/null
  one "delete from public.matches where id::text like 'ef5000aa%'" >/dev/null
  one "delete from auth.users where id::text like 'ef500000%'" >/dev/null
  if [ "$(one "select count(*) from public.profiles where id::text like 'ef500000%'")" != "0" ] \
     || [ "$(one "select count(*) from public.notifications where recipient_id::text like 'ef500000%'")" != "0" ]; then
    echo "FAIL  cleanup: synthetic data ef5… was not deleted"; rm -rf "$T"; exit $(( (rc == 0 ? 0 : rc) + 1 ))
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
if [ "$(one "select to_regclass('public.notification_job_runs') is not null")" != "t" ]; then
  echo "run migration 29 first"; exit 99
fi
if [ "$(one "select exists (select 1 from public.matches m where m.status = 'confirmed' and m.starts_at > now()
                                and m.starts_at <= now() + interval '24 hours')
                 or exists (select 1 from public.match_challenges c where c.status = 'pending'
                                and c.expires_at <= now() + interval '24 hours' and c.expires_at > now())
                 or exists (select 1 from public.club_ownership_transfers x where x.status = 'pending'
                                and x.expires_at <= now() + interval '24 hours' and x.expires_at > now())")" != "f" ]; then
  echo "LOCAL ONLY: this database has reminders of its own due — use a fresh copy"; exit 99
fi
RUN0=$(one "select coalesce(max(id), 0) from public.notification_job_runs")

session() { # name sql
  printf "set application_name = 'm29k_%s';\n%s\n" "$1" "$2" | $PSQL -X -At -q >"$T/$1.out" 2>&1 &
}
# ---- Synchronisation: an explicit gate, no fixed sleep decides a result ------
GATE_KEY=29100024
GATE_MAX=120
WAIT_MAX=60
wait_until() { # SQL answering t — polled until true, or WAIT_MAX seconds pass
  local deadline=$((SECONDS + WAIT_MAX))
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ "$(one "$1")" = "t" ] && return 0; sleep 0.2
  done
  return 1
}
gate_close() {
  printf "set application_name = 'm29k_gate';\nselect pg_advisory_lock(%s);\nselect pg_sleep(%s);\n" "$GATE_KEY" "$GATE_MAX" \
    | $PSQL -X -At -q >/dev/null 2>&1 &
  wait_until "select exists (select 1 from pg_locks l where l.locktype = 'advisory' and l.objid = $GATE_KEY and l.granted
                 and l.pid in (select pid from pg_stat_activity where $MINE and application_name = 'm29k_gate'))"
}
gate_open() { one "select count(pg_terminate_backend(pid)) from pg_stat_activity where $MINE and application_name = 'm29k_gate'" >/dev/null; }
GATE="select pg_advisory_lock($GATE_KEY);"
at_gate() { wait_until "select exists (select 1 from pg_stat_activity where $MINE and application_name = 'm29k_$1'
                          and wait_event_type = 'Lock' and wait_event = 'advisory')"; }
blocked() { wait_until "select exists (select 1 from pg_stat_activity where $MINE and application_name = 'm29k_$1'
                          and wait_event_type = 'Lock' and wait_event <> 'advisory')"; }

# --- Synthetic data: owners 1 (A), 2 (B), 3 (C); A players 11, 12 in the
# line-up of a match A v B in 20 h; a challenge A → C and an offer C → 41,
# both expiring within 24 h. Due: 2 owners + 2 players + 1 + 1 = 6 reminders.
one "do \$\$
declare n int; v uuid;
begin
  foreach n in array array[1, 2, 3, 11, 12, 41] loop
    v := ('ef500000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid;
    insert into auth.users (id, email) values (v, format('m29k%s@local.test', n));
    insert into public.current_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
    insert into public.permanent_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
    update public.profiles set full_name = format('Race Jobs %s', n),
           phone = format('+923%s', lpad((690000000 + n)::text, 9, '0')),
           date_of_birth = date '2000-05-01', profile_completed = true
     where id = v;
  end loop;
  insert into public.clubs (owner_id, name, city, club_type) values
    ('$(uid 1)', 'Race Jobs A', 'Lahore', 'corporate'), ('$(uid 2)', 'Race Jobs B', 'Karachi', 'corporate'),
    ('$(uid 3)', 'Race Jobs C', 'Lahore', 'corporate');
  insert into public.club_members (club_id, user_id, member_role, status)
  select c.id, ('ef500000-0000-4000-8000-' || lpad(g.k::text, 12, '0'))::uuid, 'player', 'active'
    from public.clubs c, unnest(array[11, 12]) as g(k) where c.owner_id = '$(uid 1)';
  insert into public.club_members (club_id, user_id, member_role, status)
  select c.id, '$(uid 41)', 'player', 'active' from public.clubs c where c.owner_id = '$(uid 3)';
  insert into public.matches (id, club_a_id, club_b_id, format, status, starts_at, venue_name)
  select '$MATCH', a.id, b.id, 't20', 'confirmed', now() + interval '20 hours', 'Race Ground'
    from public.clubs a, public.clubs b where a.owner_id = '$(uid 1)' and b.owner_id = '$(uid 2)';
  insert into public.match_lineups (match_id, club_id, name)
  select '$MATCH', c.id, 'Race XI' from public.clubs c where c.owner_id = '$(uid 1)';
  insert into public.match_lineup_players (match_id, club_id, member_id, selection, position)
  select '$MATCH', m.club_id, m.id, 'playing', row_number() over (order by m.user_id)
    from public.club_members m where m.user_id in ('$(uid 11)', '$(uid 12)');
  insert into public.match_challenges (from_club_id, to_club_id, format, proposed_date, venue_name, status, expires_at, created_at)
  select a.id, c.id, 't20', current_date + 5, 'Race Park', 'pending', now() + interval '10 hours', now() - interval '6 days'
    from public.clubs a, public.clubs c where a.owner_id = '$(uid 1)' and c.owner_id = '$(uid 3)';
  insert into public.club_ownership_transfers (club_id, from_user_id, to_user_id, to_member_id, status, expires_at, created_at)
  select c.id, '$(uid 3)', '$(uid 41)', m.id, 'pending', now() + interval '5 hours', now() - interval '6 days'
    from public.clubs c join public.club_members m on m.club_id = c.id and m.user_id = '$(uid 41)'
   where c.owner_id = '$(uid 3)';
end \$\$;" >"$T/setup.err" 2>&1 || true
[ "$(one "select count(*) from public.matches where id = '$MATCH'")" = "1" ] \
  || { fail "setup: data not created: $(cat "$T/setup.err")"; exit 1; }

REMINDERS="type in ('match_reminder', 'challenge_expiring', 'ownership_expiring') and recipient_id::text like 'ef500000%'"

# --- J1 two reminder runs at once ---------------------------------------------
if ! gate_close; then fail "J1 the gate could not be closed"; fi
session j1a "begin; select public.notification_send_reminders(); $GATE commit;"
if at_gate j1a; then
  # Run 1 has sent its 6 reminders but not committed: it waits at the gate.
  session j1b "select public.notification_send_reminders();"
  if blocked j1b; then
    gate_open
    wait
    a=$(head -n 1 "$T/j1a.out"); b=$(tail -n 1 "$T/j1b.out")
    stored=$(one "select count(*) from public.notifications where $REMINDERS")
    dupes=$(one "select count(*) from (select 1 from public.notifications where $REMINDERS
                                         group by recipient_id, dedupe_key having count(*) > 1) d")
    logged=$(one "select string_agg(status || ':' || created || ':' || errors, ',' order by id)
                    from public.notification_job_runs where id > $RUN0 and job = 'reminders'")
    if [ "$a" = "6" ] && [ "$b" = "0" ] && [ "$stored" = "6" ] && [ "$dupes" = "0" ] && [ "$logged" = "ok:6:0,ok:0:0" ]; then
      pass "J1 the second run waits on the first, then sends nothing twice (6 reminders, one each; counted 6 and 0)"
    else
      fail "J1 a=$a b=$b stored=$stored dupes=$dupes logged=$logged"
    fi
  else
    fail "J1 run 2 did not wait: $(tr '\n' ' ' <"$T/j1b.out")"; gate_open; wait
  fi
else
  fail "J1 run 1 never reached the gate: $(cat "$T/j1a.out")"; gate_open; wait
fi
