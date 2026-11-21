# Match results backend — migration 20 (M2, P1)

**Status (2026-11-21):** written and validated on a disposable PostgreSQL 17 only. **Not committed. Not applied to production.** No app code uses it yet: the Flutter data layer (M2 P3) comes later, behind a new `CRICECO_RESULTS` switch (off by default).

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
