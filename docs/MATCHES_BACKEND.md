# Matches backend — migration 17 (M1, P1)

**Status (2026-11-20):** implemented and validated on a disposable PostgreSQL 17.11. **Not applied to production.** No app code uses it yet. The Flutter data layer (P3) and UI (P4–P6) come later, behind a new `CRICECO_MATCHES` switch (off by default).

## Purpose and scope
Migration 17 adds the server side of the challenge → match flow:
- a restricted **club directory**, so clubs can find opponents;
- **challenges** between clubs;
- **matches** created from accepted challenges;
- two-sided **schedule agreement**;
- **cancellation**.

It follows the approved M1 decisions:

| # | Decision |
|---|---|
| 1 | Clubs are discoverable by public fields only: id, name, short name, city, type |
| 2 | Accepting a challenge creates exactly one **pending** match. Both clubs then propose and confirm the schedule |
| 3 | Ground booking and payments stay demo-only and gated (M7) |
| 4 | Opponent line-ups stay hidden (P2) |
| 5 | Only club **owners** manage challenges and matches |
| 6 | Per-match player availability replies: deferred |
| 7 | Cross-club shared availability listings: deferred |

Existing tables (`clubs`, `club_members`, `teams`, `profiles`, …) are not altered.

## Tables

```
clubs ──< match_challenges (from_club_id, to_club_id) ──1:1── matches (challenge_id)
clubs ──< matches (club_a_id = challenger, club_b_id)
```

### `match_challenges`
| Column | Rules |
|---|---|
| `from_club_id`, `to_club_id` | FK `clubs`, `ON DELETE CASCADE`. The two must differ |
| `format`, `custom_overs` | Format is `test` / `t20` / `odi` / `t10` / `custom`. Overs (1–50) for `custom` only; ignored for other formats, as in teams |
| `proposed_date` | From tomorrow up to one year ahead, Asia/Karachi |
| `venue_name` | 1–100 characters, spaces normalised |
| `message` | Optional, at most 280 characters. A blank message is stored as `NULL` |
| `status` | `pending` → `accepted` / `declined` / `expired`, once |
| `expires_at` | Whichever is sooner: 7 days after sending, or the start of the proposed date (Asia/Karachi) |
| `decided_at`, `decided_by` | Set on the decision. `decided_by` is an FK to `profiles`, `ON DELETE SET NULL` |
| `match_id` | Unique; set only when accepted. FK `matches`, `ON DELETE SET NULL` |

**Indexes:**
- **One pending challenge per club pair, in either direction:** unique `(least(from,to), greatest(from,to)) where status = 'pending'`.
- Look-ups by `(to_club_id, status, created_at)` and `(from_club_id, status, created_at)`.

### `matches`
| Column | Rules |
|---|---|
| `challenge_id` | Unique, nullable. FK `match_challenges`, `ON DELETE SET NULL` |
| `club_a_id`, `club_b_id` | The challenger and the challenged club. FK `clubs`, `ON DELETE CASCADE`. The two must differ |
| `format`, `custom_overs` | Copied from the challenge; never change |
| `status` | `pending` / `confirmed` / `completed` (reserved for M2) / `cancelled` |
| `starts_at`, `venue_name`, `city` | The **agreed** schedule. Required once confirmed |
| `proposed_starts_at`, `proposed_venue_name`, `proposed_city`, `proposed_by_club_id`, `proposal_version` | The **open proposal**. Time, venue and proposer are all set or all `NULL`; the city is optional. The proposer must be one of the two clubs. Allowed only on pending or confirmed matches |
| `cancelled_at`, `cancelled_by_club_id`, `cancel_reason` | All set exactly when the match is cancelled. The cancelling club must be one of the two |
| `created_at`, `last_updated_at` | `last_updated_at` is set by the trigger `set_last_updated_at` |

**Indexes:** `(club_a_id, status, starts_at)` and `(club_b_id, status, starts_at)`.

**Teams:** P1 references no teams. P2 line-ups will reference `teams` with `ON DELETE RESTRICT`. Teams are only ever archived, never deleted.

## Lifecycle

```
challenge: pending ──accept──▶ accepted (+ 1 pending match)
                   ──decline─▶ declined
                   ──time────▶ expired   (marked lazily)

match:     pending ──B accepts A's proposal (or A accepts B's)──▶ confirmed
           pending / confirmed (before start) ──cancel──▶ cancelled
           confirmed ──(M2 results)──▶ completed
```

- **Accepting a challenge.** The challenge's date and venue become the challenger's proposal on the new match: version 1, start at **10:00 Asia/Karachi** on the proposed date. A challenge carries only a date, so 10:00 is the default start; either club can counter-propose an exact time.
- **Proposals.** Either owner may propose. A new proposal replaces the open one and increments `proposal_version`. Only the **other** club's owner can answer, naming the version they are answering. Declining clears the proposal; the match keeps its status.
- **Rescheduling.** A confirmed match can be rescheduled the same way before it starts. It stays confirmed at the old time until the new proposal is accepted.
- **Guard triggers.** `match_challenges_guard_update` and `matches_guard_update` enforce the transitions above for everyone, including the database owner. They also keep clubs, format and challenge terms unchanged. The only exception is the foreign keys' own `SET NULL` actions.

## Functions
All of them are `SECURITY DEFINER` with `search_path = ''`. They take the caller from `auth.uid()` and check ownership in the database; no client-supplied user id or role is trusted. Only `authenticated` can execute them.

| Function | Who | Returns |
|---|---|---|
| `match_club_directory(p_search, p_city)` | Signed-in **club owners** | Up to 50 **other** clubs: `club_id, name, short_name, city, club_type`. Never owner, phone, email, address or join code. Search is a case-insensitive substring of name or short name; city is an exact, case-insensitive match |
| `send_challenge(p_from_club_id, p_to_club_id, p_format, p_custom_overs, p_proposed_date, p_venue_name, p_message)` | Owner of the sending club | The new `match_challenges` row |
| `respond_to_challenge(p_challenge_id, p_accept)` | Owner of the **receiving** club | The challenge: `accepted` (with `match_id`), `declined`, or `expired` if it had run out. In that last case nothing else changes and no error is raised |
| `club_challenges(p_club_id)` | That club's owner | Sent and received challenges: `direction`, the opponent's public name, short name and city, terms, **effective** status (`expired` once a pending challenge has run out), `match_id` |
| `propose_match_schedule(p_match_id, p_starts_at, p_venue_name, p_city)` | Owner of either club | The match. The time must be in the future and at most a year ahead |
| `respond_to_match_schedule(p_match_id, p_proposal_version, p_accept)` | Owner of the **other** club (not the proposer) | The match: `confirmed` at the proposed time, or the proposal cleared |
| `cancel_match(p_match_id, p_reason)` | Owner of either club | The match, now `cancelled`. Allowed while pending, or while confirmed and before the start. A reason of 1–200 characters is required |
| `club_matches(p_club_id)` | That club's owner | One-sided rows: opponent's public fields, `challenged_by_me`, agreed schedule, open proposal, `proposed_by_me`, `proposal_version`, cancellation and `cancelled_by_me`. Open matches come first, by start time |

**Internal helpers** (not callable by `anon` or `authenticated`):
- `match_lock_clubs(uuid, uuid)`: transaction advisory locks, taken in uuid order.
- `match_duration(text, integer)`: T10 3 h, T20 4 h, ODI 8 h, Test 5 days, custom = overs × 8 minutes (at least 1 hour).
- The two guard trigger functions.

**Policy helper:** `is_active_club_member(uuid)` (executable by `authenticated`).

## Row level security
| Table | SELECT for `authenticated` | INSERT / UPDATE / DELETE |
|---|---|---|
| `match_challenges` | Owners of either club | Nobody, directly; only the functions |
| `matches` | Owners **and active members** of either club. Removed members see nothing | Nobody, directly; only the functions |

`anon` and `PUBLIC` have no table privileges and cannot execute any function.

## Errors
The message prefix is `challenge:` or `match:`; the app will map it in `supabase_error_mapper.dart` (P3).

| Message | SQLSTATE |
|---|---|
| `not authenticated`, `not allowed` | 42501 |
| `club not found`, `not found` | P0002 |
| `invalid`, `invalid date`, `invalid venue`, `invalid message`, `invalid time`, `invalid city`, `invalid reason` | 22023 |
| `challenge: already pending` | 23505 |
| `challenge: own club`, `too many pending`, `not pending`; `match: not open`, `already started`, `no proposal`, `proposal changed` | P0001 |
| `match: schedule clash` | 23P01 |
| `invalid transition` (guard triggers) | 23514 |

## Concurrency safeguards
| Race | Safeguard |
|---|---|
| Two answers to one challenge | The challenge row is locked `FOR UPDATE`; the second sees `not pending`. `matches.challenge_id` is unique as a backstop |
| Crossed challenges (A→B and B→A at once), or the 20-pending cap | `send_challenge` takes both clubs' advisory locks (uuid order) and then re-checks. The unique pending-pair index is the backstop |
| Two confirmations that clash for one club | `respond_to_match_schedule` takes both clubs' advisory locks (uuid order) **before** the match row, then runs the clash check |
| Confirmation versus a new proposal | Match row lock plus `proposal_version`. A stale answer gets `proposal changed` |
| Deadlocks | Every clash-checking path takes the advisory locks first, in one fixed order. Other paths lock a single row and take no advisory lock |

## Local tests (disposable database only, never production)
1. Start a throwaway `postgres:17-alpine` with no published port.
2. Load `tests/local/00_auth_stub.sql`, then `tests/local/02_legacy_profiles_fixture.sql`.
3. Apply migrations 1–16, each in one transaction, with the D1 location seed (`seed/locations/apply_locations.sql`) right after the locations migration.
4. Apply migration 17 inside `begin; set local lock_timeout = '5s'; … commit;` (or `psql -1`).
5. Run:
   - `tests/17_matches_postcheck.sql`: every row should read PASS;
   - `psql -X -v ON_ERROR_STOP=1 -f tests/local/14_matches_local_check.sql`: 146 checks;
   - `PSQL='docker exec -i <container> psql -U postgres -d <db>' bash tests/local/14b_matches_concurrency.sh`: 4 two-session checks.

Both test scripts refuse to run on a real Supabase project, and they delete their synthetic accounts (`e7…`, `e71…`) at the end.

### Validation (2026-11-20, PostgreSQL 17.11, migrations 1–16)
- **Migration 17:** applied with no errors; a second application is refused.
- **Post-check:** before, 12 rows FAIL/ABSENT and check 12 PASS (as expected); after, 13/13 PASS.
- **`local/14`:** 146/146 PASS. Every refusal was checked to come from the intended error.
- **`local/14b`:** 4/4 PASS (K1 concurrent accepts, K2 crossed challenges, K3 simultaneous clashing confirmations, K4 confirmation versus re-proposal). Each was confirmed waiting on the expected lock (row or advisory).
- **Regression with 17 applied:**
  - local checks 10 (109/109), 12 (31/31), 13 (53/53);
  - post-checks 12 (11/11 OK), 13, 15, 16 (10/10 each).
- **Rollback:**
  - The catalog fingerprint is identical to the post-16 baseline (703 objects, same md5) after apply → rollback, twice.
  - The rollback also succeeds after the tests, with clubs, members, teams and profiles unchanged.
  - It is refused when 17 is not applied and when a `match_lineups` table exists.
  - Re-applying after a rollback works.

## Rollback
`supabase/rollback/20261120_rollback_match_challenges_and_matches.sql`
- Run it only with approval, after a backup, inside `begin; set local lock_timeout = '5s'; … commit;`.
- **Destructive to M1 match data:** every challenge and match is deleted. Take a data dump first if any of it must be kept.
- Clubs, members, join requests, teams, squads, profiles and roles are not touched.
- Roll back migration 18 (line-ups) first; the script refuses otherwise.
- Ship an app build without `CRICECO_MATCHES` before rolling back.

## Production (not done; separate approval for each step)
1. Fresh backup.
2. Run the post-check before applying: expect FAIL/ABSENT.
3. Apply migration 17 in one transaction.
4. Run the post-check again: 13/13 PASS.
5. Later: the app build with `CRICECO_MATCHES=true`, then end-to-end tests with two approved test club-owner accounts.

## Deferred (not in migration 17)
| Item | Where |
|---|---|
| Match line-ups (11 + 4, own club only) | P2, migration 18 |
| Player availability | P2, migration 19 |
| Per-match availability replies | Later (decision 6) |
| Shared availability slots / Find Opponent listings | M1.x (decision 7) |
| Results, scorecards, `completed` | M2 |
| Ground booking and payments | M7 (demo-only until then) |
| Push notifications for challenges and schedule changes | M3 |
| Flutter repositories, gateways, UI and the `CRICECO_MATCHES` switch | P3–P6 |

## Known limits
- **Default start time:** an accepted challenge proposes 10:00 Asia/Karachi on its date. Clubs adjust it with a counter-proposal.
- **Clash check:** compares confirmed matches only, using estimated durations by format. Pending matches never block.
- **Lazy expiry:** expired challenges are marked when the pair or the sender next sends, or when someone answers. Reads show the effective status.
- **No pagination:** `club_challenges` and `club_matches` return all rows (fine at the current scale). The directory returns at most 50 rows.
- **Club deletion:** deleting a club (admin only; owners can't delete their account while they own one) removes its challenges and matches, including from the opponent's history.
