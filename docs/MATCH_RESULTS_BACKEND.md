# Match results backend — migrations 20–23 (M2, P1–P2)

**Status (2026-11-21):**
- **Migration 20** (results, P1): committed in `d0358cb`.
- **Migrations 21–23** (scorecards, player statistics, `my_matches`, P2): written and validated on a disposable PostgreSQL 17; not committed. See [P2](#p2--scorecards-21-statistics-22-and-my_matches-23).

**None of them is applied to production.** No app code uses them yet: the Flutter data layer (M2 P3) comes later, behind a new `CRICECO_RESULTS` switch (off by default).

## Purpose and scope
Migration 20 adds the server side of match results:
- one **result** per played match: the outcome, the innings totals and the Player of the Match;
- a two-club **workflow**: one owner submits, the other confirms or disputes;
- an **audit trail**: every version is kept, with who submitted and who decided, and when;
- read functions for one match, a club's results and a club's record.

Batting and bowling scorecards, player statistics and `my_matches()` are migrations 21–23 (M2 P2).

It follows the approved M2 decisions (2026-11-21):

| # | Decision | Here |
|---|---|---|
| 1 | Submit, then the other club's owner confirms or disputes | `submit_` / `confirm_` / `dispute_match_result` |
| 2 | Innings totals and outcome first; scorecards later | `match_innings`; scorecards in migration 21 |
| 3 | Extras breakdown, no fall of wickets | byes, leg byes, wides, no balls, penalty per innings |
| 5 | The submitting owner enters both innings | one call carries every innings |
| 7 | Locked once confirmed; a correction is a new submit/confirm, audited | immutable versions, statuses only move forward |
| 8 | Account deletion: "Deleted player", the rows stay | `club_members_forget_match_results` |
| 12 | Limited overs first; Test stored in the schema | Test allows 4 innings and declarations; entry UI later |

Decisions 4, 6, 9, 10 and 11 apply to migrations 21–23. Existing tables are not altered; migration 20 only adds a trigger on `club_members` and moves `matches.status` from `confirmed` to `completed`, which migration 17's guard already allows.

## Tables

```
matches ──< match_results (match_id, version) ──< match_innings (match_id, version, innings_no)
```

### `match_results` — one row per submitted version
| Column | Rules |
|---|---|
| `match_id`, `version` | Primary key. FK `matches`, `ON DELETE CASCADE`. Versions count up from 1 per match |
| `status` | `submitted` → `confirmed` / `disputed` / `superseded`; `confirmed` → `superseded` (by a confirmed correction). Nothing else |
| `outcome` | `club_a_won` / `club_b_won` / `tie` / `no_result` / `abandoned` |
| `margin_runs`, `margin_wickets`, `innings_victory` | Computed from the innings, never typed. At most one margin, only for a win |
| `player_of_match_member_id` | Optional. FK `club_members`, `ON DELETE SET NULL`; a member of either club |
| `player_of_match_name` | Snapshot of the player's name when submitted (1–100 characters) |
| `player_of_match_deleted` | True once that player's account (or membership row) is deleted; the name is then `NULL` |
| `submitted_by_club_id`, `submitted_by`, `submitted_at` | Who submitted. `submitted_by` FK `profiles`, `ON DELETE SET NULL` |
| `decided_by_club_id`, `decided_by`, `decided_at` | Who confirmed, disputed or replaced it, and when. Set exactly when the status leaves `submitted` |
| `dispute_reason` | 1–300 characters, only on `disputed` |

**Indexes:** at most **one waiting** (`submitted`) and **one confirmed** version per match (unique partial indexes); look-ups on the three people columns.

### `match_innings` — the innings of one version
| Column | Rules |
|---|---|
| `match_id`, `version`, `innings_no` | Primary key; FK to the version, `ON DELETE CASCADE`. `innings_no` 1–4 in batting order |
| `batting_club_id`, `bowling_club_id` | The match's two clubs, different (the bowling club is derived) |
| `runs` 0–2000, `wickets` 0–10, `balls` 0–3000 | Legal balls; within the format's maximum (T10 60, T20 120, ODI 300, custom overs × 6, Test unlimited) |
| `byes`, `leg_byes`, `wides`, `no_balls`, `penalty` | 0 or more; together at most `runs` |
| `declared` | Test only, and not with 10 wickets down |

Innings rows never change after insert.

## Lifecycle

```
submit (owner of A or B) ──► submitted ──confirm (owner of the OTHER club)──► confirmed  ── match → completed
                                 │ ├──dispute (other club, reason)──► disputed
                                 │ └──a new submission (either club)──► superseded
confirmed ──a confirmed correction──► superseded   (the confirmed result stands until then)
```

- **When:** only for a `confirmed` or `completed` match whose start time has passed. Pending, cancelled and future matches: `result: match not played`.
- **Replacing:** a new submission while one waits supersedes it (recorded as decided by the submitting club). Either club may submit.
- **Disputes:** a disputed version stays as history; either club then submits a corrected version.
- **Corrections after confirmation:** a new submission waits while the confirmed one still counts. Once the other club confirms it, the old version becomes `superseded` and keeps who confirmed it.
- **Completed matches** can't be cancelled or rescheduled (migration 17's functions say `match: not open`).

### Validation of a submission
- **Shape:** an array of objects with integer `runs`, `wickets`, `balls`; optional integer extras and boolean `declared`; `batting_club_id` must be one of the match's clubs.
- **Innings count:** limited overs at most 2, by different clubs; Test at most 4, each club batting at most twice.
- **Consistency:**
  - `abandoned`: no innings;
  - `tie`: at least 2 innings, equal totals;
  - a win: at least 2 innings, and the winner scored more;
  - `no_result`: anything valid.
- **Margin:** if the winner batted last, wickets (10 − wickets lost in its last innings); otherwise runs (the difference). In Test, "an innings and N runs" when the winner batted once and the loser twice.
- DLS-adjusted results are not supported: use `no_result`.

## Functions
All are `SECURITY DEFINER` with `search_path = ''`, identify the caller by `auth.uid()`, and are executable by `authenticated` only.

| Function | Who | Returns |
|---|---|---|
| `submit_match_result(match_id, outcome, innings jsonb, player_of_match_member_id default null)` | Owner of either club | The new `match_results` row |
| `confirm_match_result(match_id, version)` | Owner of the other club | The confirmed row |
| `dispute_match_result(match_id, version, reason)` | Owner of the other club | The disputed row |
| `match_result(match_id)` | Owners: every version. Active members: confirmed only | Versions newest first, with `summary`, `submitted_by_me` and the innings as JSON |
| `club_results(club_id)` | Owner and active members of that club | Confirmed results: opponent, date, format, `won` / `lost` / `tied` / `no_result` / `abandoned`, margin, summary |
| `club_record(club_id)` | Same | played, won, lost, tied, no result, abandoned |

`summary` reads like "Result Lions won by 24 runs", "… by 6 wickets", "… by an innings and 30 runs", "Match tied", "No result", "Match abandoned", with the clubs' current names.

Internal (not callable by app roles): `match_format_max_balls`, `match_result_summary`, and the three trigger functions.

### Example (Flutter, later)
```dart
await client.rpc('submit_match_result', params: {
  'p_match_id': matchId,
  'p_outcome': 'club_a_won',
  'p_innings': [
    {'batting_club_id': clubA, 'runs': 186, 'wickets': 6, 'balls': 120, 'wides': 7, 'byes': 1, 'leg_byes': 2},
    {'batting_club_id': clubB, 'runs': 162, 'wickets': 8, 'balls': 120},
  ],
  'p_player_of_match_member_id': memberId, // optional
});
```

## Row level security
SELECT only, for `authenticated`; `anon` and `PUBLIC` have nothing.
- `match_results`: owners of either club see every version; active members of either club see confirmed versions.
- `match_innings`: the same, through its version.

No INSERT / UPDATE / DELETE for app roles: all writes go through the functions.

## Errors
| Message | SQLSTATE | When |
|---|---|---|
| `result: not authenticated` | 42501 | No session |
| `result: not allowed` | 42501 | Not an owner of the right club; a member or outsider reading |
| `result: not found` | P0002 | Unknown match (an unknown club gets `not allowed`) |
| `result: match not played` | P0001 | Pending, cancelled or not yet started |
| `result: invalid` | 22023 | Unknown outcome |
| `result: invalid innings` | 22023 | Shape, count, limits, extras, declarations |
| `result: inconsistent result` | 22023 | Outcome doesn't fit the totals |
| `result: invalid player` | 22023 | Player of the Match not a member of either club |
| `result: invalid reason` | 22023 | Dispute reason blank or over 300 characters |
| `result: not pending` | P0001 | Nothing waits for an answer |
| `result: version changed` | P0001 | The waiting version is not the one answered |
| `result: invalid transition` | 23514 | A direct change to a locked version or an innings (guard triggers) |

## Concurrency safeguards
- Submit, confirm and dispute lock the match row `FOR UPDATE` first (then the waiting version), as migration 17's cancel and schedule functions do, so writes to one match run one at a time.
- Confirm and dispute name the version they answer: a replaced version gets `version changed`, an answered one `not pending`.
- Unique partial indexes: never two waiting or two confirmed versions.
- The guard triggers refuse any change to a version's content, even by the database owner.

## Account deletion (decision 8)
Deleting an account cascades its `club_members` rows. A `BEFORE DELETE` trigger on `club_members` first clears `player_of_match_name` and `player_of_match_member_id` and sets `player_of_match_deleted`; the app shows "Deleted player". `submitted_by` / `decided_by` become `NULL`; the club columns stay. Results are never deleted, except with the match (club deletion).

## Local tests (disposable database only, never production)
| File | Covers |
|---|---|
| `supabase/tests/20_match_results_postcheck.sql` | Read-only, 12 rows; safe before (FAIL/ABSENT) and after |
| `supabase/tests/local/17_match_results_local_check.sql` | 87 checks: who may submit/answer/read, validation, margins, workflow, corrections, Test, RLS, guards, club results/record, account deletion, cleanup |
| `supabase/tests/local/17b_match_results_concurrency.sh` | 4 two-session races, each confirmed waiting on a lock |

### Validation (2026-11-21, PostgreSQL 17, migrations 1–19 + 20)
| Step | Result |
|---|---|
| Post-check before migration 20 | 12 FAIL / ABSENT, as expected |
| Apply migration 20 (`-1`, `lock_timeout 5s`) | OK |
| Apply again | Refused by the guard, nothing changed |
| Post-check after | 12 / 12 PASS |
| Local check 17 | 87 / 87 PASS, cleanup confirmed |
| Concurrency 17b | 4 / 4 PASS (R1 double confirm, R2 confirm vs replacement, R3 two submissions, R4 cancel vs confirm) |
| Regression with 20 applied | local 14: 146, 15: 75, 16: 48 PASS; 14b and 15b: 4 / 4 each; post-checks 17: 13, 18: 12, 19: 10 PASS |
| Rollback guards | Refuses when 20 is absent, and when a migration-21 table exists |
| Rollback | Catalogue identical to the 1–19 baseline: 935 objects, md5 `39a0e2e9c03e532d899fd67b2a526db4` |
| Re-apply after rollback | Post-check 12 / 12 PASS |

## Rollback
`supabase/rollback/20261121_rollback_match_results.sql`, inside `begin; set local lock_timeout = '5s'; … commit;`, only with approval and after a backup.
- **Destroys every result version and innings total.** Take a data dump first if they must be kept.
- Matches already `completed` stay completed (migration 17's table): they then show as played without a result.
- Roll back migration 21 first; the script refuses otherwise.
- Ship an app build without `CRICECO_RESULTS` before rolling back.

## Production (not done; separate approval for each step)
1. Fresh backup.
2. Apply migration 20 inside a transaction with `lock_timeout`.
3. Run the read-only post-check (12 / 12 PASS; row counts 0/0/0).

## Known limits
- No DLS / adjusted targets; no super overs (a tie stays a tie).
- A disputed result has no deadline or escalation; the clubs resolve it by a new submission.
- Club names in summaries are current names, not names at match time.
- Removing a member (status `removed`) keeps their Player of the Match name; only deleting the row clears it.
- Results for matches cancelled after being played are not possible (a cancelled match can't take a result).

## P2 — scorecards (21), statistics (22) and `my_matches` (23)

### Decisions
Approved M2 decisions 2, 4, 5, 6, 8, 9, 10 and 11, plus three P2 decisions (2026-11-21):

| # | P2 decision |
|---|---|
| a | **Player pool** of a club in a match: its saved line-up (Playing XI bat and bowl; the 4 substitutes may only field), or, with no line-up, any **active** member of that club |
| b | Once a match has **started**, the owners of **both** clubs may read both pools (names and member ids only) to enter the cards. Before the start, an owner sees only their own club's pool, as in M1 |
| c | Scorecards are **optional and all-or-nothing**: a result is totals-only, or every innings carries its batting **and** bowling card, which must add up to the innings totals |

### Tables (migration 21)
```
match_innings ──< match_bowling (match_id, version, innings_no, bowler_no)
match_innings ──< match_batting (match_id, version, innings_no, position) ──> match_bowling (bowler_no)
```

**`match_bowling`**, in bowling order (`bowler_no` 1–11):

| Column | Rules |
|---|---|
| `member_id` | FK `club_members`, `ON DELETE SET NULL`; a playing member of the fielding club; once per innings |
| `player_name`, `player_deleted` | Name snapshot at submission. On account deletion: name and link `NULL`, `player_deleted` true |
| `balls`, `maidens`, `runs`, `wides`, `no_balls` | Legal balls; maidens × 6 ≤ balls; wides + no balls ≤ runs |
| `wickets` | **Computed** from the dismissals credited to this bowler |

**`match_batting`**, in batting order (`position` 1–11):

| Column | Rules |
|---|---|
| `member_id`, `player_name`, `player_deleted` | As for bowling, from the batting club; never a substitute |
| `runs`, `balls`, `fours`, `sixes` | fours × 4 + sixes × 6 ≤ runs |
| `dismissal` | `not_out`, `did_not_bat`, `retired_hurt`, `retired_out`, `bowled`, `caught`, `lbw`, `run_out`, `stumped`, `hit_wicket`, `obstructing_field`, `hit_ball_twice`, `timed_out` |
| `bowler_no` | The credited bowler's row in this innings (FK). Required for bowled / caught / lbw / stumped / hit wicket, never otherwise |
| `fielder_member_id`, `fielder_name`, `fielder_deleted` | Required for caught / stumped, optional for run out, never otherwise; any player of the fielding club's pool |
| `fielder_substitute` | Set when the fielder is one of the line-up's substitutes |
| `direct_hit` | Run outs only |

`did_not_bat` rows have no runs or balls. Rows never change after insert (guard trigger), except account deletion. They can only be added to a version that is still waiting for an answer.

### Submitting with cards
`submit_match_result_with_scorecard(match_id, outcome, innings, player_of_match_member_id)` takes the same arguments as `submit_match_result`. Each innings object may also carry `batting` and `bowling` arrays. It runs migration 20's function first (same checks, same lock on the match), then validates and stores the cards in the **same transaction**: one invalid card refuses everything, including the result.

The cards must add up:
- batters' runs + extras = the innings runs;
- dismissals (everything except not out, did not bat, retired hurt) = the innings wickets;
- at least wickets + 1 batted, and at most two not out;
- bowlers' balls = the innings balls, and each bowler stays within the format's limit (T10 2 overs, T20 4, ODI 10, custom a fifth of the overs rounded up, Test unlimited);
- bowlers' runs = innings runs − byes − leg byes − penalty;
- bowlers' wides and no balls = the innings';
- a bowler's `wickets`, when sent, = the dismissals credited to them.

Calling `submit_match_result` with `batting` / `bowling` keys stores **no** cards (they are ignored): the app uses the new function.

### Read functions
| Function | Who | Returns |
|---|---|---|
| `match_player_pool(match_id)` | Owners of either club | `club_id`, `member_id`, `full_name`, `selection` (`playing` / `sub` / `member`), `pick_order`. Own club always; the other club once the match has started |
| `match_scorecard(match_id, version default null)` | Owners: any version. Active members: the confirmed one | One row per innings: `batting` and `bowling` as JSON, with `dismissal_text` ("c Ali b Khan", "c & b Khan", "c sub (Ali) b Khan", "st Ali b Khan", "run out (Ali)", …; "Deleted player" for a deleted account). `null` = the confirmed version |
| `player_stats(user_id default null)` | The player; owners and active members of a club the player is an active member of | Career figures (every club). `null` = the caller |
| `club_member_stats(club_id)` | Owner and active members | One row per active member: figures in that club's matches |
| `player_match_log(user_id default null, limit default 50)` | As `player_stats` | Confirmed matches, newest first: club, opponent, result from the player's side, the player's own figures, Player of the Match |
| `my_matches()` | Any signed-in user | The caller's scheduled matches in every club they are an active member of (see below) |

### Statistics (migration 22)
Computed on read from **confirmed** results only: waiting, disputed and superseded versions never count, and a confirmed correction changes the figures at once. Totals-only results add no player figures.

| Group | Figures |
|---|---|
| Batting | matches, innings, not outs, runs, balls, average, strike rate, highest (and whether not out), 50s, 100s, ducks, 4s, 6s |
| Bowling | innings, balls, maidens, runs, wickets, average, economy, strike rate, best (most wickets, then fewest runs), five-wicket hauls |
| Fielding | catches (caught and bowled counts for the bowler), run outs, direct hits, stumpings |
| Other | Player of the Match awards |

- **Innings and not outs:** "did not bat" isn't an innings; "not out" and "retired hurt" are not outs.
- **Averages and rates** are rounded to 2 places, and `NULL` when the divisor is 0.
- **Not on the server:** rating, skill and "verified" (decision 10).
- **Errors:** `stats: not authenticated` / `stats: not allowed` (42501). An unknown player is `not allowed`.

### `my_matches()` (migration 23)
- **Which matches:** those of every club where the caller is an **active** member, once scheduled (confirmed, completed, or cancelled after being scheduled). Pending proposals never appear.
- **Per row:**
  - the club and opponent, format, status, time, venue, city and cancel reason;
  - whether the club saved a line-up, the caller's own `selection` (`playing` / `sub` / none) and captaincy;
  - the confirmed result from the club's side, with its summary and version.
- **Never shown:** the opponent's line-up.
- **Order:** newest start first. The app splits the rows into the prototype's Upcoming / Past / Cancelled tabs.
- **Errors:** `match: not authenticated` (42501).

### RLS and privileges
- **Tables:** `match_batting` and `match_bowling` are SELECT-only, with the same rule as `match_innings`: owners of both clubs see every version, active members only the confirmed one. `anon` and `PUBLIC` have nothing.
- **Functions:** all are `SECURITY DEFINER` with an empty `search_path`. The API functions are executable by `authenticated` only.
- **Internal helpers** (not callable by app roles): `match_scorecards_guard`, `club_members_forget_match_scorecards`, `match_bowler_max_balls`, `match_dismissal_text`, `match_club_player_pool`, `member_stats`, `can_view_player_stats`.

### Account deletion
A `BEFORE DELETE` trigger on `club_members` clears the name and link on every batting, fielding and bowling row and sets the `deleted` flags. The rows and every other player's figures stay: a bowler keeps the wicket of a deleted batter. The deleted player's own figures leave every statistic.

### Concurrency
- Submissions with cards take migration 20's lock on the match row, so two submissions run one at a time.
- Inserting a card row takes a key-share lock on the member's `club_members` row. An account deletion therefore **waits** for a submission in progress, then marks the new rows "Deleted player". It never fails, and never leaves a name behind (checked in 18b, K1).

### Files (P2)
| File | Purpose |
|---|---|
| `supabase/migrations/20261121090100_create_match_scorecards.sql` | Migration 21 |
| `supabase/migrations/20261121090200_create_player_stats.sql` | Migration 22 |
| `supabase/migrations/20261121090300_create_my_matches.sql` | Migration 23 |
| `supabase/rollback/20261121_rollback_match_scorecards.sql`, `…_player_stats.sql`, `…_my_matches.sql` | Rollbacks |
| `supabase/tests/21_match_scorecards_postcheck.sql` (12), `22_player_stats_postcheck.sql` (6), `23_my_matches_postcheck.sql` (3) | Read-only post-checks |
| `supabase/tests/local/18_match_scorecards_stats_local_check.sql` | 96 checks across migrations 21–23 |
| `supabase/tests/local/18b_match_scorecards_concurrency.sh` | 2 two-session races |

The local check covers:
- the pools, including before and after the start;
- 33 kinds of invalid card;
- a valid card with its computed figures and dismissal texts;
- totals-only results, access and RLS, and the guards;
- the statistics, and a correction counting only once confirmed;
- `my_matches`, and account deletion.

### Validation (2026-11-21, PostgreSQL 17, migrations 1–20 + 21–23)
| Step | Result |
|---|---|
| Migration 22 without 21 | Refused |
| Post-checks before 21–23 | 21: 12 FAIL; 22: 5 FAIL (the "no rating" row passes trivially); 23: 3 FAIL |
| Apply 21, 22, 23 (`-1`, `lock_timeout 5s`) | OK; a second apply of each is refused by its guard |
| Post-checks after | 21: 12/12, 22: 6/6, 23: 3/3 PASS |
| Local check 18 | 96/96 PASS, cleanup confirmed |
| Concurrency 18b | 2/2 PASS (K1 account deletion during a submission, K2 two submissions with cards) |
| Regression with 21–23 applied | local 17: 87, 14: 146, 15: 75, 16: 48 PASS; 17b, 14b, 15b: 4/4 each; post-checks 17: 13, 18: 12, 19: 10, 20: 12 PASS |
| Rollback order | Rollbacks 20, 21 and 22 each refuse while the next migration is applied |
| Rollback 23 | Identical to a fresh 1–22 build (1,166 objects, md5 `ee33c2c0…`) |
| Rollback 22 | Identical to a fresh 1–21 build (1,161 objects, md5 `554c4156…`) |
| Rollback 21 | Identical to the 1–20 baseline (1,042 objects, md5 `07e364ce22193a67a9966711ba4354ca`) |
| Rollback 20 | Identical to the 1–19 baseline (935 objects, md5 `39a0e2e9…`) |
| Re-apply 20–23 | Post-checks 12 / 12 / 6 / 3 PASS; 1–23 is 1,167 objects, md5 `0e286b2d176db892fb450c097fe8ea22` |

### Rollback (P2)
Reverse order only: **23 → 22 → 21** (→ 20). Each runs inside `begin; set local lock_timeout = '5s'; … commit;`, with approval and after a backup.
- **23 and 22** remove read functions only; no data is touched.
- **21 destroys every batting and bowling row.** Results and innings totals stay, so results with cards become totals-only. Take a data dump first.
- Ship an app build without `CRICECO_RESULTS` first.

### Production (not done; separate approval for each step)
1. Fresh backup.
2. Apply 21, 22 and 23 in order, each in its own transaction with `lock_timeout` (after migration 20).
3. Run the read-only post-checks (12 / 6 / 3 PASS).

### Known limits (P2)
- **Pools:** a member removed after the match (with no line-up) can no longer appear in a later correction. A completed match's line-up keeps them.
- **Balls faced** are checked per batter (at most the innings' balls + no balls), not summed.
- **Not stored:** wicketkeeper and captain marks on the card, and fall of wickets (decision 3).
- **Statistics** are computed on each read. A cache can come later if needed.
- **Visibility:** an owner reads the opponent's whole active-member list when the opponent saved no line-up (P2 decision b).

## P3 — Flutter data layer (`CRICECO_RESULTS`)

**Status (2026-11-21):** implemented, not committed. No screen uses it yet (P4 entry, P5 display), so nothing visible changes in any build.

### The switch
- `--dart-define=CRICECO_RESULTS=true` (`kResultsBuild`, `resultsEnabledProvider`), **off by default**.
- The results data layer is used only with Supabase plus the memberships, matches **and** results switches (`BackendModules.resultsLive`, `resultsBackendLiveProvider`). Turn it on only after migrations 20–23 are live, and only with the P4–P5 screens.
- It adds no screen module: `BackendModule.playerStats` stays "not available yet" in Supabase builds until P5.

### Layers
| Layer | File | Role |
|---|---|---|
| Models | `lib/core/models/match_result.dart` | `ResultVersion`, `InningsTotals`, `ResultReceipt`, `ClubResultRow`, `ClubRecord`, `PoolPlayer`, `InningsCard`, `CardBattingRow`, `CardBowlingRow`, `CricketStats`, `ClubMemberStats`, `PlayerMatchLogRow`, `MyMatch`; inputs `ResultSubmission`, `InningsInput`, `BattingInput`, `BowlingInput`; enums `ResultOutcome`, `ResultStatus`, `ClubResultKind`, `DismissalKind`, `PoolSelection` |
| Gateway | `ResultsGateway` (`supabase_gateways.dart`), `SupabaseResultsGateway` (`supabase_sdk_gateways.dart`) | One RPC per database function; `resultsGatewayProvider`, set in `backend_bootstrap.dart` |
| Mapper | `lib/data/supabase/result_row_mapper.dart` | Strict reading of rows; request building (`submitParams`) |
| Repository | `ResultsRepository` and `UnavailableResultsRepository` (`repositories.dart`); `SupabaseResultsRepository` | `resultsRepositoryProvider` (`core_providers.dart`) |
| Errors | `supabase_error_mapper.dart` | `result:` refusals → `MatchRuleException` with what to do next |

- **Players** are referenced by club membership id everywhere. The name-keyed demo models (`Scorecard`, `PlayerStats`, …) are untouched; P5 moves the screens to the id-keyed ones.
- **Submitting** always goes through `submit_match_result_with_scorecard`. A totals-only result sends no `batting` / `bowling` keys; a result with cards sends them on every innings. Optional fields (bowler, fielder, direct hit) are sent only when set. The server computes margins and bowlers' wickets.
- **Reading is strict:** a missing field, a wrong type or an unknown code (status, outcome, dismissal, selection, format) is a generic "something went wrong" (`BackendOperationException`), never a guessed value. Averages and rates are read from a JSON number or a numeric string; `null` stays `null`.
- **Errors:**
  - `result: not allowed`, `stats: not allowed` (42501) → `PermissionDeniedException`;
  - `… not authenticated` → `NotSignedInException`;
  - other `result:` reasons → `MatchRuleException`, with a generic text for an unknown reason (never the database text);
  - network failures → `BackendUnavailableException`.
- **Without the results switch, and in the demo:** `UnavailableResultsRepository` lists nothing, counts zeros, refuses every change with `ModuleUnavailableException`, and makes no network call. The demo's own sample screens are unchanged.

### Tests (P3)
| File | Covers |
|---|---|
| `test/results_supabase_test.dart` (23) | Mapping of every row shape; request building with and without cards; strict reading; every `result:` refusal text; 42501 and network errors; the switch and provider selection (the gateway is never read when results aren't live) |
| `test/supabase_results_gateway_test.dart` (7) | Every RPC name and parameter on the real `supabase_flutter` client with faked HTTP; one-row functions; error translation |

**Results:** `flutter analyze` reports no issues, and all **1,386** tests pass (30 new).
