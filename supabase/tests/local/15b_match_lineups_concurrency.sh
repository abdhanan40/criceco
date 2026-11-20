#!/usr/bin/env bash
# CricEco · LOCAL TEST ONLY — migration 18 (match lineups): concurrent
# sessions, which a single SQL file can't test.
# Run after migration 18 (19 optional) on a disposable local test database
# that has the auth stub (tests/local/00_auth_stub.sql) and migrations 1–17.
#
# Usage:  PSQL='docker exec -i criceco-m17-test psql -U postgres -d <local_db>' \
#           bash supabase/tests/local/15b_match_lineups_concurrency.sh
# $PSQL must run SQL read from stdin as the database owner. The script
# refuses to run on a real Supabase project. It commits synthetic accounts
# and clubs (ids e81…; other sessions must see them) and always deletes them
# again on exit. Prints PASS / FAIL lines; exits with the number of failures.
#
# Session 1 does its step inside a transaction and then sleeps, holding its
# locks; session 2 starts only once session 1 is CONFIRMED sleeping, and its
# result only counts once it is CONFIRMED waiting on a lock
# (pg_stat_activity). No fixed sleep decides a result.
#   L1 a member removed while a lineup with them is being saved: the removal
#      waits for the save, then takes the member out of the saved lineup;
#   L2 a lineup saved while one of its players is being removed: the save
#      waits for the removal, then refuses ("player not in club") and the
#      previous lineup stays;
#   L3 two saves of the same lineup at once: the second waits, both succeed,
#      the second one's lineup is what remains (15 players, never a mix);
#   L4 a cancellation while a lineup is being saved: the cancellation waits
#      for the save, then the match is cancelled with the lineup kept.
set -u
: "${PSQL:?set PSQL to a psql command for the LOCAL test database (see the header)}"
fails=0
T=$(mktemp -d)
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; fails=$((fails+1)); }
one() { echo "$1" | $PSQL -X -At -q 2>&1; }
MINE="datname = current_database() and application_name like 'm18k\\_%' and pid <> pg_backend_pid()"
uid() { printf 'e8100000-0000-4000-8000-%012d' "$1"; }
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
  one "delete from public.clubs where owner_id::text like 'e8100000%'" >/dev/null
  one "delete from auth.users where id::text like 'e8100000%'" >/dev/null
  if [ "$(one "select count(*) from public.profiles where id::text like 'e8100000%'")" != "0" ]; then
    echo "FAIL  cleanup: synthetic accounts e81… were not deleted"; rm -rf "$T"; exit $(( (rc == 0 ? 0 : rc) + 1 ))
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
if [ "$(one "select to_regclass('public.match_lineups') is not null")" != "t" ]; then
  echo "run migration 18 first"; exit 99
fi

session() { # name uid sql
  printf "set application_name = 'm18k_%s';\nselect set_config('request.jwt.claims', '{\"sub\":\"%s\",\"role\":\"authenticated\"}', false);\nset role authenticated;\n%s\n" \
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
sleeping() { wait_until "select exists (select 1 from pg_stat_activity where $MINE and application_name = 'm18k_$1'
                           and state = 'active' and query like '%pg_sleep%')"; }
blocked()  { wait_until "select exists (select 1 from pg_stat_activity where $MINE and application_name = 'm18k_$1'
                           and wait_event_type = 'Lock')"; }
# SQL for a squad of club A from person numbers (first 11 playing, the rest sub).
squad() {
  local ids="" n
  for n in "$@"; do ids="$ids,'$(uid "$n")'"; done
  echo "(select jsonb_agg(jsonb_build_object('member_id', m.id, 'selection', case when x.o <= 11 then 'playing' else 'sub' end) order by x.o)
           from unnest(array[${ids#,}]::uuid[]) with ordinality x(u, o)
           join public.club_members m on m.user_id = x.u and m.club_id = '$CA')"
}
lineup_of() { # → "name|count|has person n"
  one "select l.name || '|' || (select count(*) from public.match_lineup_players lp where lp.match_id = l.match_id and lp.club_id = l.club_id)
              || '|' || exists (select 1 from public.match_lineup_players lp join public.club_members m on m.id = lp.member_id
                                 where lp.match_id = l.match_id and lp.club_id = l.club_id and m.user_id = '$(uid "$1")')
         from public.match_lineups l where l.match_id = '$M' and l.club_id = '$CA'"
}

# --- Synthetic accounts: owners 1 (club A), 2 (club B); players 101–120 of A
one "do \$\$
declare n int;
begin
  foreach n in array array[1, 2] || array(select generate_series(101, 120)) loop
    insert into auth.users (id, email) values (('e8100000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
                                               format('m18k%s@local.test', n));
    update public.profiles set full_name = format('Race Lineup %s', n)
     where id = ('e8100000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid;
  end loop;
  -- The two owners need a completed profile to own a club.
  foreach n in array array[1, 2] loop
    insert into public.current_addresses (user_id, city, area, address)
    values (('e8100000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid, 'Lahore', 'Gulberg', 'Street 1');
    insert into public.permanent_addresses (user_id, city, area, address)
    values (('e8100000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid, 'Lahore', 'Gulberg', 'Street 1');
    update public.profiles set phone = format('+923%s', lpad((540000000 + n)::text, 9, '0')),
           date_of_birth = date '2000-05-01', profile_completed = true
     where id = ('e8100000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid;
    insert into public.player_profiles (user_id, player_role, batting_style, bowling_style, is_wicketkeeper)
    values (('e8100000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid, 'all_rounder', 'right_handed', 'right_arm_fast', false);
  end loop;
  insert into public.clubs (owner_id, name, city, club_type) values ('$A', 'Race Lineup A', 'Lahore', 'corporate'),
                                                                  ('$B', 'Race Lineup B', 'Karachi', 'corporate');
  insert into public.club_members (club_id, user_id, member_role, status)
  select c.id, ('e8100000-0000-4000-8000-' || lpad(g.k::text, 12, '0'))::uuid, 'player', 'active'
    from public.clubs c, generate_series(101, 120) as g(k) where c.owner_id = '$A';
end \$\$;" >"$T/setup.err" 2>&1 || true
CA=$(one "select id from public.clubs where owner_id = '$A'")
CB=$(one "select id from public.clubs where owner_id = '$B'")
[ -n "$CA" ] && [ -n "$CB" ] || { fail "setup: clubs not created: $(cat "$T/setup.err")"; exit 1; }
CH=$(as_user "$A" "select id from public.send_challenge('$CA', '$CB', 't20', null, (now() at time zone 'Asia/Karachi')::date + 4, 'Race Ground')")
M=$(as_user "$B" "select match_id from public.respond_to_challenge('$CH', true)")
[ "$(as_user "$B" "select status from public.respond_to_match_schedule('$M', 1, true)")" = "confirmed" ] \
  || { fail "setup: match not confirmed"; exit 1; }
mem() { one "select id from public.club_members where club_id = '$CA' and user_id = '$(uid "$1")'"; }

# --- L1 removal during a save ------------------------------------------------
session l1a "$A" "begin; select name from public.save_match_lineup('$M', 'One', null, $(squad $(seq 101 115)), null, null); select pg_sleep(4); commit;"
if sleeping l1a; then
  session l1b "$A" "select status from public.remove_club_member('$(mem 105)');"
  if blocked l1b; then
    wait
    if grep -q '^One$' "$T/l1a.out" && grep -q '^removed$' "$T/l1b.out" && [ "$(lineup_of 105)" = "One|14|false" ]; then
      pass "L1 removal during a save: waited, then took the member out of the saved lineup (14 left)"
    else fail "L1 removal during a save: $(cat "$T/l1a.out" "$T/l1b.out" | tr '\n' ' ') lineup=$(lineup_of 105)"; fi
  else wait; fail "L1 the removal was never seen waiting"; fi
else wait; fail "L1 session 1 never reached its sleep: $(cat "$T/l1a.out")"; fi

# --- L2 save during a removal ------------------------------------------------
session l2a "$A" "begin; select status from public.remove_club_member('$(mem 106)'); select pg_sleep(4); commit;"
if sleeping l2a; then
  session l2b "$A" "select name from public.save_match_lineup('$M', 'Two', null, $(squad 101 102 103 104 106 107 108 109 110 111 112 113 114 115 116), null, null);"
  if blocked l2b; then
    wait
    if grep -q '^removed$' "$T/l2a.out" && grep -q 'lineup: player not in club' "$T/l2b.out" && [ "$(lineup_of 106)" = "One|13|false" ]; then
      pass "L2 save during a removal: waited, then refused the removed player; the saved lineup stays (minus the removed)"
    else fail "L2 save during a removal: $(cat "$T/l2a.out" "$T/l2b.out" | tr '\n' ' ') lineup=$(lineup_of 106)"; fi
  else wait; fail "L2 the save was never seen waiting"; fi
else wait; fail "L2 session 1 never reached its sleep: $(cat "$T/l2a.out")"; fi

# --- L3 two saves of one lineup at once --------------------------------------
session l3a "$A" "begin; select name from public.save_match_lineup('$M', 'Three', null, $(squad 101 102 103 104 107 108 109 110 111 112 113 114 115 116 117), null, null); select pg_sleep(4); commit;"
if sleeping l3a; then
  session l3b "$A" "select name from public.save_match_lineup('$M', 'Four', null, $(squad 104 107 108 109 110 111 112 113 114 115 116 117 118 119 120), null, null);"
  if blocked l3b; then
    wait
    if grep -q '^Three$' "$T/l3a.out" && grep -q '^Four$' "$T/l3b.out" && [ "$(lineup_of 101)" = "Four|15|false" ] \
       && [ "$(lineup_of 120)" = "Four|15|true" ]; then
      pass "L3 two saves at once: the second waited; both succeeded; the second's 15 players remain (no mix)"
    else fail "L3 two saves: $(cat "$T/l3a.out" "$T/l3b.out" | tr '\n' ' ') lineup=$(lineup_of 101)"; fi
  else wait; fail "L3 the second save was never seen waiting"; fi
else wait; fail "L3 session 1 never reached its sleep: $(cat "$T/l3a.out")"; fi

# --- L4 cancellation during a save -------------------------------------------
session l4a "$A" "begin; select name from public.save_match_lineup('$M', 'Five', null, $(squad 101 102 103 104 107 108 109 110 111 112 113 114 115 116 117), null, null); select pg_sleep(4); commit;"
if sleeping l4a; then
  session l4b "$B" "select status from public.cancel_match('$M', 'Rain');"
  if blocked l4b; then
    wait
    if grep -q '^Five$' "$T/l4a.out" && grep -q '^cancelled$' "$T/l4b.out" && [ "$(lineup_of 101)" = "Five|15|true" ] \
       && [ "$(one "select status from public.matches where id = '$M'")" = "cancelled" ]; then
      pass "L4 cancellation during a save: waited for the save, then cancelled; the lineup is kept"
    else fail "L4 cancellation during a save: $(cat "$T/l4a.out" "$T/l4b.out" | tr '\n' ' ')"; fi
  else wait; fail "L4 the cancellation was never seen waiting"; fi
else wait; fail "L4 session 1 never reached its sleep: $(cat "$T/l4a.out")"; fi

echo "concurrency: $((4 - fails)) of 4 passed"
exit $fails
