#!/usr/bin/env bash
# CricEco · LOCAL TEST ONLY — migration 25 (notifications): concurrent
# sessions, which a single SQL file can't test.
# Run after migration 25 on a disposable local test database that has the
# auth stub (tests/local/00_auth_stub.sql) and migrations 1–24.
#
# Usage:  PSQL='docker exec -i criceco-m17-test psql -U postgres -d <local_db>' \
#           bash supabase/tests/local/20b_notifications_concurrency.sh
# $PSQL must run SQL read from stdin as the database owner. The script
# refuses to run on a real Supabase project. It commits synthetic accounts,
# clubs and a match (ids ef2…) and always deletes them again on exit.
# Prints PASS / FAIL lines; exits with the number of failures.
#
# Session 1 does its step inside a transaction and then sleeps, holding its
# locks (and its uncommitted rows); session 2 starts only once session 1 is
# CONFIRMED sleeping. Where session 2 must wait, its result only counts once
# it is CONFIRMED waiting on a lock (pg_stat_activity). No fixed sleep decides
# a result.
#   N1 "mark all read" while a notification is being written: it does not
#      wait, and the new one stays unread;
#   N2 marking one notification read while "mark all read" holds it: waits,
#      then changes nothing (no double read);
#   N3 two announcements at once at the daily limit: the second waits on the
#      club, then "too many" — 20, never 21, each member told once;
#   N4 two line-up saves at once: the second waits, then its players are told
#      only what changed against the FIRST (committed) line-up;
#   N5 a member removed while a line-up naming them is being saved: the save
#      waits, then is refused; the member hears of the removal only;
#   N6 an account deleted while a join request naming them is being written:
#      the deletion waits, then the owner's notification forgets the name.
set -u
: "${PSQL:?set PSQL to a psql command for the LOCAL test database (see the header)}"
fails=0
T=$(mktemp -d)
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; fails=$((fails+1)); }
one() { echo "$1" | $PSQL -X -At -q 2>&1; }
MINE="datname = current_database() and application_name like 'm25k\\_%' and pid <> pg_backend_pid()"
uid() { printf 'ef200000-0000-4000-8000-%012d' "$1"; }
MX='ef2000aa-0000-4000-8000-000000000001'
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
  one "delete from public.clubs where owner_id::text like 'ef200000%'" >/dev/null
  one "delete from public.matches where id::text like 'ef2000aa%'" >/dev/null
  one "delete from auth.users where id::text like 'ef200000%'" >/dev/null
  if [ "$(one "select count(*) from public.profiles where id::text like 'ef200000%'")" != "0" ] \
     || [ "$(one "select count(*) from public.notifications where recipient_id::text like 'ef200000%'")" != "0" ]; then
    echo "FAIL  cleanup: synthetic data ef2… was not deleted"; rm -rf "$T"; exit $(( (rc == 0 ? 0 : rc) + 1 ))
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
if [ "$(one "select to_regclass('public.notifications') is not null")" != "t" ]; then
  echo "run migration 25 first"; exit 99
fi

claims() { printf "set role authenticated;\nset request.jwt.claims = '{\"sub\": \"%s\", \"role\": \"authenticated\"}';\n" "$(uid "$1")"; }
session() { # name user sql   (signed in as person <user>)
  { printf "set application_name = 'm25k_%s';\n" "$1"; claims "$2"; printf "%s\n" "$3"; } | $PSQL -X -At -q >"$T/$1.out" 2>&1 &
}
owner_session() { # name sql   (as the database owner, e.g. account deletion)
  printf "set application_name = 'm25k_%s';\n%s\n" "$1" "$2" | $PSQL -X -At -q >"$T/$1.out" 2>&1 &
}
as_user() { { claims "$1"; printf "%s\n" "$2"; } | $PSQL -X -At -q 2>&1 | tail -n 1; }
wait_until() {
  local i
  for i in $(seq 100); do
    [ "$(one "$1")" = "t" ] && return 0; sleep 0.1
  done
  return 1
}
sleeping() { wait_until "select exists (select 1 from pg_stat_activity where $MINE and application_name = 'm25k_$1'
                           and state = 'active' and query like '%pg_sleep%')"; }
blocked()  { wait_until "select exists (select 1 from pg_stat_activity where $MINE and application_name = 'm25k_$1'
                           and wait_event_type = 'Lock')"; }
cnt() { one "select count(*) from public.notifications where recipient_id = '$(uid "$1")' and type = '$2'"; }
typed() { one "select count(*) from public.notifications where recipient_id::text like 'ef200000%' and type = '$1'"; }
mem() { one "select id from public.club_members where user_id = '$(uid "$1")'"; }
# A line-up: playing persons, then substitutes (space-separated numbers).
squad() {
  local out="" n
  for n in $1; do out="$out{\"member_id\": \"$(mem "$n")\", \"selection\": \"playing\"},"; done
  for n in $2; do out="$out{\"member_id\": \"$(mem "$n")\", \"selection\": \"sub\"},"; done
  echo "'[${out%,}]'::jsonb"
}
save() { echo "select (public.save_match_lineup('$MX', 'Race XI', null, $(squad "$1" "$2"), null, null)).name;"; }

# --- Synthetic data: owners 1 (club A), 2 (club B), 3 (club C, for N6); A
# players 11–26; B players 31–45; 50 in no club; match MX A v B, confirmed,
# in 5 days.
one "do \$\$
declare n int; v uuid;
begin
  foreach n in array array[1, 2, 50] || array(select generate_series(11, 26)) || array(select generate_series(31, 45)) loop
    v := ('ef200000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid;
    insert into auth.users (id, email) values (v, format('m25k%s@local.test', n));
    insert into public.current_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
    insert into public.permanent_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
    update public.profiles set full_name = format('Race Note %s', n),
           phone = format('+923%s', lpad((620000000 + n)::text, 9, '0')),
           date_of_birth = date '2000-05-01', profile_completed = true
     where id = v;
    insert into public.player_profiles (user_id, player_role, batting_style, bowling_style, is_wicketkeeper)
    values (v, 'all_rounder', 'right_handed', 'right_arm_fast', false);
  end loop;
  insert into public.clubs (owner_id, name, city, club_type) values ('$O1', 'Race Note A', 'Lahore', 'corporate'),
                                                                  ('$O2', 'Race Note B', 'Karachi', 'corporate');
  insert into public.club_members (club_id, user_id, member_role, status)
  select c.id, ('ef200000-0000-4000-8000-' || lpad(g.k::text, 12, '0'))::uuid, 'player', 'active'
    from public.clubs c, generate_series(11, 26) as g(k) where c.owner_id = '$O1';
  insert into public.club_members (club_id, user_id, member_role, status)
  select c.id, ('ef200000-0000-4000-8000-' || lpad(g.k::text, 12, '0'))::uuid, 'player', 'active'
    from public.clubs c, generate_series(31, 45) as g(k) where c.owner_id = '$O2';
  insert into public.matches (id, club_a_id, club_b_id, format, status, starts_at, venue_name)
  select '$MX', a.id, b.id, 't20', 'confirmed', now() + interval '5 days', 'Race Ground'
    from public.clubs a, public.clubs b where a.owner_id = '$O1' and b.owner_id = '$O2';
end \$\$;" >"$T/setup.err" 2>&1 || true
CA=$(one "select id from public.clubs where owner_id = '$O1'")
CB=$(one "select id from public.clubs where owner_id = '$O2'")
[ -n "$CA" ] && [ -n "$CB" ] && [ "$(one "select count(*) from public.matches where id = '$MX'")" = "1" ] \
  || { fail "setup: clubs or match not created: $(cat "$T/setup.err")"; exit 1; }
as_user 1 "select (public.publish_club_announcement('$CA', 'Race zero', 'Welcome.', 'all')).recipient_count;" >/dev/null
[ "$(cnt 11 announcement)" = "1" ] && [ "$(cnt 12 announcement)" = "1" ] || { fail "setup: first announcement"; exit 1; }

# --- N1 "mark all read" while a notification is being written ---------------
session n1a 1 "begin; select (public.publish_club_announcement('$CA', 'Race one', 'Nets.', 'all')).recipient_count;
               select pg_sleep(3); commit;"
if sleeping n1a; then
  marked=$(as_user 11 "select public.mark_all_notifications_read('player');")
  still=$(one "select exists (select 1 from pg_stat_activity where $MINE and application_name = 'm25k_n1a')")
  wait
  unread=$(as_user 11 "select public.notification_unread_count('player');")
  if [ "$marked" = "1" ] && [ "$still" = "t" ] && [ "$unread" = "1" ] && [ "$(cnt 11 announcement)" = "2" ]; then
    pass "N1 \"mark all read\" does not wait for a notification being written; the new one stays unread"
  else
    fail "N1 marked=$marked during=$still unread_after=$unread ($(cat "$T/n1a.out" | tr '\n' ' '))"
  fi
else
  fail "N1 session 1 never started sleeping: $(cat "$T/n1a.out")"; wait
fi

# --- N2 marking one read while "mark all read" holds it -----------------------
ID12=$(one "select id from public.notifications where recipient_id = '$(uid 12)' and params ->> 'title' = 'Race one'")
session n2a 12 "begin; select public.mark_all_notifications_read('player'); select pg_sleep(3); commit;"
if sleeping n2a; then
  session n2b 12 "select public.mark_notifications_read(array['$ID12']::uuid[]);"
  if blocked n2b; then
    wait
    first=$(head -n 1 "$T/n2a.out")
    if [ "$first" = "2" ] && [ "$(tail -n 1 "$T/n2b.out")" = "0" ] \
       && [ "$(as_user 12 "select public.notification_unread_count('player');")" = "0" ]; then
      pass "N2 marking one read waits for \"mark all read\", then changes nothing (read once)"
    else
      fail "N2 all=$first one=$(tr '\n' ' ' <"$T/n2b.out")"
    fi
  else
    fail "N2 session 2 did not wait: $(tr '\n' ' ' <"$T/n2b.out")"; wait
  fi
else
  fail "N2 session 1 never started sleeping: $(cat "$T/n2a.out")"; wait
fi

# --- N3 two announcements at once at the daily limit -------------------------
one "insert into public.club_announcements (club_id, title, message, audience, created_by)
     select '$CB', 'Old ' || k, 'm', 'staff', '$O2' from generate_series(1, 19) k;" >/dev/null
session n3a 2 "begin; select (public.publish_club_announcement('$CB', 'Race A', 'First.', 'all')).recipient_count;
               select pg_sleep(3); commit;"
if sleeping n3a; then
  session n3b 2 "select (public.publish_club_announcement('$CB', 'Race B', 'Second.', 'all')).recipient_count;"
  if blocked n3b; then
    wait
    total=$(one "select count(*) from public.club_announcements where club_id = '$CB'")
    if [ "$(head -n 1 "$T/n3a.out")" = "15" ] && grep -q 'too many' "$T/n3b.out" && [ "$total" = "20" ] \
       && [ "$(typed announcement)" = "$(( 2 * 16 + 15 ))" ] && [ "$(cnt 31 announcement)" = "1" ]; then
      pass "N3 the second announcement waits on the club, then \"too many\": 20, each member told once"
    else
      fail "N3 a=$(tr '\n' ' ' <"$T/n3a.out") b=$(tr '\n' ' ' <"$T/n3b.out") total=$total ann=$(typed announcement)"
    fi
  else
    fail "N3 session 2 did not wait: $(tr '\n' ' ' <"$T/n3b.out")"; wait
  fi
else
  fail "N3 session 1 never started sleeping: $(cat "$T/n3a.out")"; wait
fi

# --- N4 two line-up saves at once ----------------------------------------------
X_PLAY="11 12 13 14 15 16 17 18 19 20 21"; X_SUBS="22 23 24 25"
Y_PLAY="12 13 14 15 16 17 18 19 20 21 22"; Y_SUBS="11 23 24 26"
# Built before the sessions start (each member lookup is a separate psql call).
SAVE_X=$(save "$X_PLAY" "$X_SUBS"); SAVE_Y=$(save "$Y_PLAY" "$Y_SUBS")
session n4a 1 "begin; $SAVE_X select pg_sleep(3); commit;"
if sleeping n4a; then
  session n4b 1 "$SAVE_Y"
  if blocked n4b; then
    wait
    final=$(one "select string_agg(u.n::text || lp.selection, ',' order by u.n)
                   from public.match_lineup_players lp
                   join public.club_members m on m.id = lp.member_id
                   cross join lateral (select right(m.user_id::text, 2)::int as n) u
                  where lp.match_id = '$MX'")
    state=$(one "select count(*) from public.notification_lineup_state where match_id = '$MX'")
    if [ "$(typed lineup_selected)" = "16" ] && [ "$(typed lineup_changed)" = "2" ] && [ "$(typed lineup_dropped)" = "1" ] \
       && [ "$(cnt 11 lineup_changed)" = "1" ] && [ "$(cnt 22 lineup_changed)" = "1" ] \
       && [ "$(cnt 25 lineup_dropped)" = "1" ] && [ "$(cnt 26 lineup_selected)" = "1" ] && [ "$state" = "15" ] \
       && [ "$final" = "11sub,12playing,13playing,14playing,15playing,16playing,17playing,18playing,19playing,20playing,21playing,22playing,23sub,24sub,26sub" ]; then
      pass "N4 the second save waits, then tells only what changed against the first (16 selected, 2 changed, 1 dropped)"
    else
      fail "N4 sel=$(typed lineup_selected) chg=$(typed lineup_changed) drop=$(typed lineup_dropped) state=$state final=$final b=$(tr '\n' ' ' <"$T/n4b.out")"
    fi
  else
    fail "N4 session 2 did not wait: $(tr '\n' ' ' <"$T/n4b.out") / session 1: $(tr '\n' ' ' <"$T/n4a.out")"; wait
  fi
else
  fail "N4 session 1 never started sleeping: $(cat "$T/n4a.out")"; wait
fi

# --- N5 a member removed while a line-up naming them is being saved ----------
M26=$(mem 26)
session n5a 1 "begin; select public.remove_club_member('$M26') is not null; select pg_sleep(3); commit;"
if sleeping n5a; then
  session n5b 1 "$SAVE_Y"
  if blocked n5b; then
    wait
    if grep -q 'player not in club' "$T/n5b.out" && [ "$(cnt 26 removed_from_club)" = "1" ] \
       && [ "$(cnt 26 lineup_dropped)" = "0" ] && [ "$(typed lineup_dropped)" = "1" ] \
       && [ "$(typed lineup_selected)" = "16" ] && [ "$(typed lineup_changed)" = "2" ] \
       && [ "$(one "select count(*) from public.notification_lineup_state where member_id = '$M26'")" = "0" ]; then
      pass "N5 the save waits for the removal, then is refused; the member hears of the removal only"
    else
      fail "N5 b=$(tr '\n' ' ' <"$T/n5b.out") removed=$(cnt 26 removed_from_club) dropped=$(typed lineup_dropped)"
    fi
  else
    fail "N5 session 2 did not wait: $(tr '\n' ' ' <"$T/n5b.out") / session 1: $(tr '\n' ' ' <"$T/n5a.out")"; wait
  fi
else
  fail "N5 session 1 never started sleeping: $(cat "$T/n5a.out")"; wait
fi

# --- N6 an account deleted while a join request naming them is being written -
CODE=$(one "select code from public.clubs where id = '$CA'")
session n6a 50 "begin; select (public.request_to_join_club('$CODE')).status; select pg_sleep(3); commit;"
if sleeping n6a; then
  owner_session n6b "delete from auth.users where id = '$(uid 50)';"
  if blocked n6b; then
    wait
    row=$(one "select (person_id is null)::text || '|' || coalesce(params ->> 'person_name', '-') || '|'
                      || coalesce(params ->> 'person_deleted', '-')
                 from public.notifications where recipient_id = '$O1' and type = 'join_request_received'")
    if grep -q '^pending$' "$T/n6a.out" && [ "$row" = "true|-|true" ] && [ "$(cnt 50 announcement)" = "0" ] \
       && [ "$(one "select count(*) from public.profiles where id = '$(uid 50)'")" = "0" ]; then
      pass "N6 the deletion waits for the request, then the owner's notification forgets the name (\"Deleted player\")"
    else
      fail "N6 a=$(tr '\n' ' ' <"$T/n6a.out") b=$(tr '\n' ' ' <"$T/n6b.out") row=$row"
    fi
  else
    fail "N6 the deletion did not wait: $(tr '\n' ' ' <"$T/n6b.out")"; wait
  fi
else
  fail "N6 session 1 never started sleeping: $(cat "$T/n6a.out")"; wait
fi
