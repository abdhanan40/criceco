#!/usr/bin/env bash
# CricEco · LOCAL TEST ONLY — migration 21 (scorecards): concurrent sessions,
# which a single SQL file can't test.
# Run after migrations 21 (22–23 optional) on a disposable local test
# database that has the auth stub (tests/local/00_auth_stub.sql) and
# migrations 1–20.
#
# Usage:  PSQL='docker exec -i criceco-m17-test psql -U postgres -d <local_db>' \
#           bash supabase/tests/local/18b_match_scorecards_concurrency.sh
# $PSQL must run SQL read from stdin as the database owner. The script
# refuses to run on a real Supabase project. It commits synthetic accounts,
# clubs and matches (ids ee…; other sessions must see them) and always
# deletes them again on exit. Prints PASS / FAIL lines; exits with the
# number of failures.
#
# Session 1 does its step inside a transaction and then sleeps, holding its
# locks; session 2 starts only once session 1 is CONFIRMED sleeping, and its
# result only counts once it is CONFIRMED waiting on a lock
# (pg_stat_activity). No fixed sleep decides a result.
#   K1 an account deleted while a scorecard naming that player is being
#      submitted: the deletion waits for the submission, then turns the
#      player into "Deleted player" on the new cards (name and link gone,
#      rows kept) — never a failed deletion or a dangling name;
#   K2 both clubs submit a result with cards at once: the second waits,
#      becomes version 2 with its own cards; version 1 keeps its cards.
set -u
: "${PSQL:?set PSQL to a psql command for the LOCAL test database (see the header)}"
fails=0
T=$(mktemp -d)
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; fails=$((fails+1)); }
one() { echo "$1" | $PSQL -X -At -q 2>&1; }
MINE="datname = current_database() and application_name like 'm21k\\_%' and pid <> pg_backend_pid()"
uid() { printf 'ee000000-0000-4000-8000-%012d' "$1"; }
mid() { printf 'ee0000aa-0000-4000-8000-%012d' "$1"; }
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
  one "delete from public.clubs where owner_id::text like 'ee000000%'" >/dev/null
  one "delete from auth.users where id::text like 'ee000000%'" >/dev/null
  if [ "$(one "select count(*) from public.profiles where id::text like 'ee000000%'")" != "0" ] \
     || [ "$(one "select count(*) from public.match_batting where match_id::text like 'ee0000aa%'")" != "0" ]; then
    echo "FAIL  cleanup: synthetic data ee… was not deleted"; rm -rf "$T"; exit $(( (rc == 0 ? 0 : rc) + 1 ))
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
if [ "$(one "select to_regclass('public.match_batting') is not null")" != "t" ]; then
  echo "run migration 21 first"; exit 99
fi

session() { # name uid sql   (as that signed-in user)
  printf "set application_name = 'm21k_%s';\nselect set_config('request.jwt.claims', '{\"sub\":\"%s\",\"role\":\"authenticated\"}', false);\nset role authenticated;\n%s\n" \
    "$1" "$2" "$3" | $PSQL -X -At -q >"$T/$1.out" 2>&1 &
}
owner_session() { # name sql   (as the database owner, e.g. account deletion)
  printf "set application_name = 'm21k_%s';\n%s\n" "$1" "$2" | $PSQL -X -At -q >"$T/$1.out" 2>&1 &
}
wait_until() {
  local i
  for i in $(seq 100); do
    [ "$(one "$1")" = "t" ] && return 0; sleep 0.1
  done
  return 1
}
sleeping() { wait_until "select exists (select 1 from pg_stat_activity where $MINE and application_name = 'm21k_$1'
                           and state = 'active' and query like '%pg_sleep%')"; }
blocked()  { wait_until "select exists (select 1 from pg_stat_activity where $MINE and application_name = 'm21k_$1'
                           and wait_event_type = 'Lock')"; }

# --- Synthetic accounts: owners 1 (club A), 2 (club B); players 11, 12 of A;
# 21–24 of B; two played T20s; no line-ups (the pools are the active members).
one "do \$\$
declare n int; v uuid;
begin
  foreach n in array array[1, 2, 11, 12, 21, 22, 23, 24] loop
    v := ('ee000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid;
    insert into auth.users (id, email) values (v, format('m21k%s@local.test', n));
    insert into public.current_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
    insert into public.permanent_addresses (user_id, city, area, address) values (v, 'Lahore', 'Gulberg', 'Street 1');
    update public.profiles set full_name = format('Race Card %s', n),
           phone = format('+923%s', lpad((590000000 + n)::text, 9, '0')),
           date_of_birth = date '2000-05-01', profile_completed = true
     where id = v;
    insert into public.player_profiles (user_id, player_role, batting_style, bowling_style, is_wicketkeeper)
    values (v, 'all_rounder', 'right_handed', 'right_arm_fast', false);
  end loop;
  insert into public.clubs (owner_id, name, city, club_type) values ('$A', 'Race Card A', 'Lahore', 'corporate'),
                                                                  ('$B', 'Race Card B', 'Karachi', 'corporate');
  insert into public.club_members (club_id, user_id, member_role, status)
  select c.id, ('ee000000-0000-4000-8000-' || lpad(g.k::text, 12, '0'))::uuid, 'player', 'active'
    from public.clubs c, unnest(array[11, 12]) as g(k) where c.owner_id = '$A';
  insert into public.club_members (club_id, user_id, member_role, status)
  select c.id, ('ee000000-0000-4000-8000-' || lpad(g.k::text, 12, '0'))::uuid, 'player', 'active'
    from public.clubs c, unnest(array[21, 22, 23, 24]) as g(k) where c.owner_id = '$B';
  insert into public.matches (id, club_a_id, club_b_id, format, status, starts_at, venue_name)
  select ('ee0000aa-0000-4000-8000-' || lpad(g.k::text, 12, '0'))::uuid, a.id, b.id, 't20', 'confirmed',
         now() - make_interval(days => g.k), 'Race Ground'
    from public.clubs a, public.clubs b, generate_series(1, 2) as g(k)
   where a.owner_id = '$A' and b.owner_id = '$B';
end \$\$;" >"$T/setup.err" 2>&1 || true
CA=$(one "select id from public.clubs where owner_id = '$A'")
CB=$(one "select id from public.clubs where owner_id = '$B'")
[ -n "$CA" ] && [ -n "$CB" ] && [ "$(one "select count(*) from public.matches where id::text like 'ee0000aa%'")" = "2" ] \
  || { fail "setup: clubs or matches not created: $(cat "$T/setup.err")"; exit 1; }
mem() { one "select id from public.club_members where user_id = '$(uid "$1")'"; }
# A wins by 10 runs: A 20/1 in 12 balls ($1 15 c $3 b $4, $2 5*; $4 bowls 2-0-20);
# B 10/0 in 6 balls ($3 6*, $5 4*; $1 bowls 1-0-10).
card() {
  local a1 a2 bf bb b3
  a1=$(mem "$1"); a2=$(mem "$2"); bf=$(mem "$3"); bb=$(mem "$4"); b3=$(mem "$5")
  echo "'[{\"batting_club_id\": \"$CA\", \"runs\": 20, \"wickets\": 1, \"balls\": 12,
     \"batting\": [{\"member_id\": \"$a1\", \"runs\": 15, \"balls\": 8, \"dismissal\": \"caught\",
                    \"bowler_member_id\": \"$bb\", \"fielder_member_id\": \"$bf\"},
                   {\"member_id\": \"$a2\", \"runs\": 5, \"balls\": 4, \"dismissal\": \"not_out\"}],
     \"bowling\": [{\"member_id\": \"$bb\", \"balls\": 12, \"runs\": 20}]},
    {\"batting_club_id\": \"$CB\", \"runs\": 10, \"wickets\": 0, \"balls\": 6,
     \"batting\": [{\"member_id\": \"$bf\", \"runs\": 6, \"balls\": 3, \"dismissal\": \"not_out\"},
                   {\"member_id\": \"$b3\", \"runs\": 4, \"balls\": 3, \"dismissal\": \"not_out\"}],
     \"bowling\": [{\"member_id\": \"$a1\", \"balls\": 6, \"runs\": 10}]}]'::jsonb"
}
CARD1=$(card 11 12 21 22 23)
CARD2=$(card 11 12 23 22 24)

# --- K1 account deletion during a scorecard submission ------------------------
session k1a "$A" "begin; select version from public.submit_match_result_with_scorecard('$(mid 1)', 'club_a_won', $CARD1); select pg_sleep(4); commit;"
if sleeping k1a; then
  owner_session k1b "delete from auth.users where id = '$(uid 21)'; select 'gone';"
  if blocked k1b; then
    wait
    state=$(one "select count(*) || '|' || count(*) filter (where player_deleted and player_name is null and member_id is null)
                        || '|' || count(*) filter (where fielder_deleted and fielder_name is null and fielder_member_id is null)
                   from public.match_batting where match_id = '$(mid 1)'")
    if grep -q '^1$' "$T/k1a.out" && grep -q '^gone$' "$T/k1b.out" && [ "$state" = "4|1|1" ]; then
      pass "K1 account deletion during a submission: waited, then 'Deleted player' on the new cards (4 rows kept)"
    else fail "K1 account deletion during a submission: $(cat "$T/k1a.out" "$T/k1b.out" | tr '\n' ' ') rows=$state"; fi
  else wait; fail "K1 the deletion was never seen waiting"; fi
else wait; fail "K1 session 1 never reached its sleep: $(cat "$T/k1a.out")"; fi

# --- K2 two submissions with cards at once --------------------------------------
session k2a "$A" "begin; select version from public.submit_match_result_with_scorecard('$(mid 2)', 'club_a_won', $CARD2); select pg_sleep(4); commit;"
if sleeping k2a; then
  session k2b "$B" "select version from public.submit_match_result_with_scorecard('$(mid 2)', 'club_a_won', $CARD2);"
  if blocked k2b; then
    wait
    state=$(one "select string_agg(r.version || ':' || r.status || ':' ||
                                   (select count(*) from public.match_batting b where b.match_id = r.match_id and b.version = r.version) || '/' ||
                                   (select count(*) from public.match_bowling w where w.match_id = r.match_id and w.version = r.version),
                                   ',' order by r.version)
                   from public.match_results r where r.match_id = '$(mid 2)'")
    if grep -q '^1$' "$T/k2a.out" && grep -q '^2$' "$T/k2b.out" && [ "$state" = "1:superseded:4/2,2:submitted:4/2" ]; then
      pass "K2 two submissions with cards: the second waited, became version 2 with its own cards; version 1 kept its cards"
    else fail "K2 two submissions with cards: $(cat "$T/k2a.out" "$T/k2b.out" | tr '\n' ' ') state=$state"; fi
  else wait; fail "K2 the second submission was never seen waiting"; fi
else wait; fail "K2 session 1 never reached its sleep: $(cat "$T/k2a.out")"; fi

echo "failures: $fails"
exit "$fails"
