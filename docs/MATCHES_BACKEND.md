# Matches backend — migrations 17–19 (M1, P1–P2)

**Status (2026-11-20):** implemented and validated on a disposable PostgreSQL 17.11.
- **Migration 17** (challenges and matches, P1): committed in `930640c`.
- **Migrations 18 and 19** (lineups and player availability, P2): written and validated; see [P2](#p2--lineups-migration-18-and-player-availability-migration-19).

**None of them is applied to production.** No app code uses them yet. The Flutter data layer (P3) and UI (P4–P6) come later, behind a new `CRICECO_MATCHES` switch (off by default).

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

**Teams:** migration 17 references no teams. Lineups (migration 18) reference `teams` with `ON DELETE RESTRICT`. Teams are only ever archived, never deleted.

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
2. Run the post-checks before applying: expect FAIL/ABSENT.
3. Apply migrations 17, 18 and 19 in that order, each in its own transaction.
4. Run the post-checks again: 17 (13/13), 18 (12/12) and 19 (10/10) PASS.
5. Later: the app build with `CRICECO_MATCHES=true`, then end-to-end tests with two approved test club-owner accounts.

## Deferred (not in migrations 17–19)
| Item | Where |
|---|---|
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

---

## P2 — lineups (migration 18) and player availability (migration 19)

**Order:** 17 → 18 → 19 to apply, and 19 → 18 → 17 to roll back. Every script refuses the wrong order.

Migration 19 depends on 18: the rule "no injured or unavailable player in a lineup" needs the availability table, so 19 adds that check to `match_lineup_players` as a trigger. Until 19 is applied, lineups don't check availability. Deploy them together.

### Tables
```
matches ──< match_lineups (match_id, club_id)  ──< match_lineup_players (match_id, club_id, member_id)
clubs ──< match_lineups        teams ──< match_lineups.source_team_id (RESTRICT)
club_members ──< match_lineup_players.member_id, match_lineups.captain/vice_captain_member_id
profiles ──1:1── player_availability (user_id)
```

**`match_lineups`**
| Column | Rules |
|---|---|
| Key | Primary key `(match_id, club_id)`: one lineup per club per match |
| `match_id`, `club_id` | FK `matches` and FK `clubs`, both `ON DELETE CASCADE`. Trigger `match_lineups_validate`: the club must be one of the match's two clubs |
| `name` | 1–40 characters, spaces normalised |
| `source_team_id` | Optional. FK `teams`, `ON DELETE RESTRICT`: a team used by a lineup can't be hard-deleted. Deleting a whole club still works and removes its lineups too (tested) |
| `captain_member_id`, `vice_captain_member_id` | Optional, must differ. FK `club_members`, `ON DELETE SET NULL` |
| `saved_at`, `saved_by` | `saved_by` is an FK to `profiles`, `ON DELETE SET NULL` |

**`match_lineup_players`**
| Column | Rules |
|---|---|
| Key | Primary key `(match_id, club_id, member_id)` |
| Position | Unique per lineup, 1–15, in pick order |
| `selection` | `playing` or `sub` |
| `member_id` | FK `club_members`, `ON DELETE CASCADE` |
| `(match_id, club_id)` | FK `match_lineups`, `ON DELETE CASCADE` |
| Trigger `match_lineup_players_validate` | Only an ACTIVE member of that same club |

**`player_availability`**
| Column | Rules |
|---|---|
| `user_id` | Primary key; FK `profiles`, `ON DELETE CASCADE` |
| `status` | `available`, `limited`, `unavailable`, `injured` or `other` |
| `reason` | Optional: `injury`, `personal`, `work`, `travel`, `family_emergency`, `rest_day` or `other` (the app's `AvailabilityReason`) |
| `until_date` | Optional |
| `notes` | Optional, 1–200 characters |
| `updated_at` | Set on each save |
| Constraint `player_availability_available_is_plain` | `available` never has a reason or a date |
| No record | Means available |

### Lineup lifecycle and validation
`save_match_lineup(p_match_id, p_name, p_source_team_id, p_players, p_captain_member_id, p_vice_member_id)` returns the saved `match_lineups` row.

`p_players` is a JSON array in pick order: `[{"member_id": "…", "selection": "playing" | "sub"}, …]`. Positions come from the array order, so the function can't produce duplicate positions; the unique key also refuses them on direct writes.

| Rule | Error |
|---|---|
| Caller signed in | `lineup: not authenticated` (42501) |
| Caller is the **owner** of one of the match's clubs; the lineup saved is that club's | `lineup: not allowed` (42501) |
| Match exists | `lineup: not found` (P0002) |
| Match is **confirmed** (pending, cancelled and completed are refused) | `lineup: match not confirmed` (P0001) |
| Match has not started | `lineup: match started` (P0001) |
| Name 1–40 characters | `lineup: invalid name` (22023) |
| Well-formed array; no player twice | `lineup: invalid` (22023) |
| **Exactly 11 playing + 4 sub** | `lineup: invalid squad` (23514) |
| Captain: in the Playing XI; not the vice-captain | `lineup: invalid captain` (22023) |
| Vice-captain: in the Playing XI | `lineup: invalid vice-captain` (22023) |
| Source team belongs to this club | `lineup: invalid team` (22023) |
| Source team is active | `lineup: team archived` (P0001) |
| Every player is an **active member of this club** (never another club's) | `lineup: player not in club` (23514) |
| No player is **injured or unavailable** on the match day (migration 19) | `lineup: player unavailable` (P0001) |

- **Availability on the match day:** a player is blocked when there is no until date, or the until date is on or after the match's date (Asia/Karachi). "Unavailable until Friday" can play on Saturday. `limited` and `other` never block.
- **A later change** to a player's status doesn't alter lineups already saved.
- **Atomic:** every check runs before anything is written. A failure at any point, including inside a trigger, rolls back the whole call, and the previous lineup stays exactly as it was (tested with an injected failure).
- **Saving again replaces** the club's whole lineup: name, team, players, captain and vice-captain.

### Lineup privacy
`match_lineup(p_match_id)` returns the caller's **own club's** lineup only: as its owner, or as an active member. It returns one row per player in pick order, with the player's name and role; no rows if nothing is saved. It works in any match status.

The opponent club, outsiders and removed members get `lineup: not allowed` from the function and no rows from the tables (RLS).

Someone who is an active member of **both** clubs is a member of each, so they see each club's lineup.

### Member removal and history
- **Removal from the club** (`remove_club_member`): trigger `club_members_leave_match_lineups` takes the member out of that club's lineups for every match that is **not completed**, and clears them as captain or vice-captain there. The lineup is then short and must be saved again.
- **Completed matches** keep their lineups and captains.
- **Existing behaviour:** `club_members_leave_teams` (team squads) is unchanged and still runs.
- **Account deletion** deletes the person's memberships and, with them, their lineup rows everywhere, completed matches included: personal data goes, as migration 14 requires. M2 results will keep their own snapshot.

### Availability functions and privacy
| Function | Who | Returns |
|---|---|---|
| `set_my_availability(p_status, p_reason, p_until_date, p_notes)` | Any signed-in person, for **themself only** (`auth.uid()`; no user id parameter) | The saved row |
| `my_availability()` | The caller | Their own record (no rows means available) |
| `club_player_availability(p_club_id)` | That club's **owner** | The club's **active** members: member id, user id, name, role, status (`available` if no record), reason, until date, notes, `updated_at`, and `locks_selection` (injured or unavailable covering today) |

`set_my_availability` normalises its input: status and reason are trimmed and lower-cased; blank notes become `NULL`; `available` clears the reason and date.

Its errors:

| Error | Raised when |
|---|---|
| `availability: invalid status` (22023) | The status is not one of the five values |
| `availability: invalid reason` (22023) | The reason is not one of the seven values |
| `availability: invalid date` (22023) | The until date is before today or more than a year ahead (Asia/Karachi) |
| `availability: invalid notes` (22023) | The notes are over 200 characters |
| `availability: not authenticated` / `not allowed` (42501) | No session, or the caller is not that club's owner (`club_player_availability`) |

**Who can read a record** (RLS):
- the person themself;
- the owner of a club where the person is an **active** member.

That excludes other members, the opponent club, a club the person was removed from, and anonymous users.

Helpers:
- `is_owner_of_active_member(uuid)`: the policy helper, executable by `authenticated`;
- `availability_locks_on(status, until, day)`: internal.

### RLS and permissions (P2)
- All three tables have RLS on, a **SELECT-only** policy, and no INSERT, UPDATE or DELETE grant for `authenticated`. `anon` and `PUBLIC` get nothing.
- All writes go through `save_match_lineup` and `set_my_availability`.
- The API functions are `SECURITY DEFINER` with `search_path = ''` and are executable by `authenticated` only.
- The trigger functions and `availability_locks_on` can't be called by app roles.

### Concurrency (lineups)
`save_match_lineup` locks in a fixed order before writing anything: the match row (`FOR SHARE`), then the selected players' memberships (`FOR SHARE`, in id order), then the lineup row.

| Race | Result |
|---|---|
| A cancellation or reschedule during a save | Waits for the save |
| A member removed during a save | The removal waits, then takes the member out of the saved lineup |
| A save during a removal | The save waits, then refuses the removed player |
| Two saves of one lineup at once | They run one after the other; the second one's lineup remains, never a mix |
| Both clubs saving at the same time | Allowed |

### Files (P2)
| Area | Files |
|---|---|
| Migrations | `supabase/migrations/20261120090100_create_match_lineups.sql`, `…090200_create_player_availability.sql` |
| Rollbacks | `supabase/rollback/20261120_rollback_match_lineups.sql`, `…_rollback_player_availability.sql` |
| Read-only checks | `supabase/tests/18_match_lineups_postcheck.sql` (12 rows), `19_player_availability_postcheck.sql` (10 rows) |
| Local tests | `supabase/tests/local/15_match_lineups_local_check.sql` (75 checks), `15b_match_lineups_concurrency.sh` (4), `16_player_availability_local_check.sql` (48) |

### Local tests (P2)
Prepare the database as for migration 17 (see above), then apply 17, then 18, each in one transaction.

1. `tests/18_match_lineups_postcheck.sql`
2. `psql -X -v ON_ERROR_STOP=1 -f tests/local/15_match_lineups_local_check.sql`
3. `PSQL='docker exec -i <container> psql -U postgres -d <db>' bash tests/local/15b_match_lineups_concurrency.sh`
4. Apply 19.
5. `tests/19_player_availability_postcheck.sql` and `tests/local/16_player_availability_local_check.sql`.

Steps 2 and 3 also pass with 19 applied. The scripts refuse a real Supabase project and delete their synthetic accounts (`e8…`, `e81…`, `e9…`).

### Validation (2026-11-20, PostgreSQL 17.11)
- **Applying:**
  - 18 and 19 apply with no errors;
  - a second application is refused;
  - 19 is refused without 18;
  - post-checks: 18 gives 12/12 PASS (1 of 12 before), and 19 gives 10/10 PASS (0 before).
- **Local tests:**
  - `local/15`: 75/75, with 18 only and again with 19;
  - `local/15b`: 4/4, both times;
  - `local/16`: 48/48;
  - every expected error was checked to be the intended one.
- **Regression, with 17–19 applied:**
  - local checks: `local/14` 146/146, `local/14b` 4/4, `local/10` 109/109, `local/12` 31/31, `local/13` 53/53;
  - post-checks: 12 (11/11 OK), 13, 15, 16 (10/10 each), 17 (13/13).
- **Rollback, on fresh databases:**
  - 18 restores the 1–17 catalogue exactly (836 objects, md5 `03744d4f…`);
  - 19 restores the 1–18 catalogue exactly (910 objects, md5 `dbd7dc3c…`);
  - re-applying after a rollback works;
  - each rollback is refused when its migration isn't applied;
  - rollback 18 is refused while 19 is applied, and rollback 17 is refused while 18 is applied.
- **Full chain on the database that ran every test:** rolling back 19 → 18 → 17 returns to the 1–16 catalogue (703 objects, md5 `cbae8676…`). Clubs, members, teams and profiles are unchanged.

### Rollback (P2) — destroys P2 data
Run each rollback only with approval, after a backup and a data dump, inside `begin; set local lock_timeout = '5s'; … commit;`.

| Rollback | Deletes | Then | Order |
|---|---|---|---|
| `20261120_rollback_player_availability.sql` | Every availability record | Lineups stop refusing injured or unavailable players | Run first |
| `20261120_rollback_match_lineups.sql` | Every lineup | Matches, teams and members stay | Refuses while 19 is applied |

Ship an app build without `CRICECO_MATCHES` first.

### Known limits (P2)
- **No "since" timestamp:** availability stores `updated_at` (the last save) rather than when the status began.
- **No re-check after saving:** a lineup isn't checked again when a player later becomes injured, or when the match is rescheduled.
- **Short lineups:** a lineup left with fewer than 11 + 4 by a member removal isn't flagged by the database. The app should count the players.
- **Dual membership:** a person who belongs to both clubs can read both clubs' lineups.

---

## P3 — Flutter data layer

**Status (2026-11-21):** implemented and tested with fakes. The switch is **off**, and no screen or controller uses the new operations yet; that is P4–P6.

**Switch:** `--dart-define=CRICECO_MATCHES=true` (`kMatchesBuild`, `matchesEnabledProvider`; default **false**). The server repositories are used only when Supabase mode, `CRICECO_MEMBERSHIPS` and `CRICECO_MATCHES` are all on (`matchesBackendLiveProvider`); `BackendModules` then also lists matches, challenges and availability. In every other case the earlier repositories stay in use (the demo's seeded ones, or empty / "not available yet"), and the match gateway is never called. **Don't turn the switch on before the P4–P6 screens:** today's controllers still use the demo's `createPendingMatch` / `save`, which the server repositories refuse.

| Layer | Code |
|---|---|
| Gateway | `MatchGateway` (`supabase_gateways.dart`) and `SupabaseMatchGateway` (`supabase_sdk_gateways.dart`): one method per function of migrations 17–19, with the same parameter names |
| Repositories | `SupabaseMatchRepository`, `SupabaseChallengeRepository`, `SupabaseAvailabilityRepository`. The opponent directory is `ClubRepository.searchOpponents()` (`SupabaseClubRepository` with the match gateway). `OwnClubLookup` reads the owner's club id from `clubs` on every call |
| Mapping | `MatchRowMapper` (`match_row_mapper.dart`). A required field that is missing, or an unknown status or format, raises `MatchRowFormatException`, which surfaces as "something went wrong"; no value is guessed |
| Errors | `SupabaseErrorMapper` maps the `challenge:`, `match:`, `lineup:` and `availability:` prefixes to `MatchRuleException` with user-facing text. An unknown reason gets generic text, never the database's message. 42501 means signed out or no permission |
| Models | `MatchStatus.cancelled` (no tab yet); `ClubMatch` gains `challengeId`, `challengedByMe`, `opponentName`, `venueName`, `proposal` (`MatchProposal`) and `cancellation` (`MatchCancellation`); `Challenge` gains `customOvers`, `message` and `opponentName`. New types: `MatchLineup` / `MatchLineupPlayer`, `ClubDirectoryEntry`, `ClubMemberAvailability`. All additions are optional, so the demo is unchanged |
| Contracts | `MatchRepository` gains `proposeSchedule`, `respondToSchedule`, `cancelMatch`, `saveLineup` and `lineup`. `ChallengeRepository` gains `accept` and `decline`, which return the server-created match id; `send` gains `customOvers` and `message`. New `PlayerAvailabilityRepository`. The in-memory versions follow the same rules |

**Dates and times:**
- Timestamps are sent as UTC ISO-8601 and read as instants.
- Challenge and availability dates are Pakistan calendar dates, sent as `YYYY-MM-DD` with no shift. `MatchRowMapper.karachiDate()` gives the server's "today".

**Not covered yet:**
- **Player's own matches:** no server function for them yet (`playerMatches()` is empty in Supabase mode).
- **No server side yet:** scorecards and statistics (M2); availability slots and match seekers (decision 7).
- **Club profiles:** `otherClubs()` / `clubSummary()` stay empty; no statistics are invented.

**Tests:**
- `test/match_supabase_test.dart` (47): mappers, error mapping, the repositories on `FakeMatchDb` (`test/match_fakes.dart`), provider selection and the demo repositories.
- `test/supabase_match_gateway_test.dart` (7): RPC names, parameters and errors on the real `supabase_flutter` client with faked HTTP.

---

## P4 — Challenges screens

**Status (2026-11-21):** the Challenges workspace works on the server when `CRICECO_MATCHES` is on, and is tested with fakes. The switch stays **off**; nothing is in production.

`challengesLiveProvider` (any non-demo build) chooses the server path. The demo keeps its own flow and data unchanged.

| Screen | Server mode |
|---|---|
| **Challenges** tab | The opponent directory (`OpponentDirectoryView`): other clubs' name, short name, city and type only. No record, rating or statistics |
| **Find Opponent** tab | The same directory with a name search and a city filter (250 ms debounce, one request per settled query), with loading, empty, and error-with-Retry states. Availability slots and "Teams Looking for Opponents" are hidden: there is no server side yet (decision 7) |
| **Challenge setup** | Format (Custom with 1–50 overs), **venue** (free text, up to 100 characters), date (Pakistan rule: from tomorrow, up to a year ahead), optional message (up to 280). Review stays disabled until everything is valid. One send at a time. Server refusals are shown as text, e.g. "already an open challenge". No match is created |
| **My Challenges** | Incoming, sent and resolved challenges from `club_challenges()`, showing the opponent's name, city, format and overs, date, venue, message and expiry. Pull down to reload |
| **Accept / Decline** | Server calls (`respond_to_challenge`). Accepting returns the ONE match the server created; the app creates none. Repeated taps are ignored while a call runs. Expired and already-answered challenges show the server's answer and the real status. After accepting, the app stays on My Challenges, because the match screens come in P5 |

**Code:**
- `challenges_controller.dart`: `ChallengeRules`, `ChallengeOpponent`, `opponentDirectoryProvider`, `respondingChallengesProvider`, and the live/demo split in `ChallengesController`.
- Screens and widgets: `challenge_widgets.dart` (setup sheet, `respondToChallenge`), `challenges_hub_screen.dart`, `my_challenges_screen.dart`, `challenge_sheet.dart`.
- `Challenge` gains `opponentShortName` and `opponentCity`, from `club_challenges()`.

**Tests:** `test/challenges_supabase_test.dart` (21): directory, sending, lists, accept/decline, and widget flows on `FakeMatchDb`. The demo tests (`challenges_test.dart` and others) are unchanged and pass.

---

## P5 — Scheduling and cancellation (Match Management)

**Status (2026-11-21):** Match Management works on the server with `CRICECO_MATCHES` on, and is tested with fakes. The switch stays **off**; nothing is in production.

`matchesLiveProvider` (any non-demo build) chooses the server path. The demo keeps its booking-based flow and cards unchanged.

| Part | Server mode |
|---|---|
| **Tabs** | Waiting = pending. Scheduled = confirmed. History = completed and **cancelled**; `MatchTab.history` now includes cancelled for both modes, though the demo has no cancelled matches |
| **Cards** (`_LiveMatchCard`) | The opponent's name, the format, who challenged, and the agreed time and venue. They also show the open proposal ("You proposed…" / "Karachi Kings proposed…") or the cancellation ("Cancelled by …: reason"). Chips: *Time needed*, *Awaiting reply*, *Reply needed*, *Confirmed*, *New time proposed*, *Cancelled*. There is no booking or payment: tapping a card opens the schedule sheet |
| **Schedule sheet** (`match_schedule_sheet.dart`) | Accept or decline the other club's proposal, naming the version it answers. Propose a time with date, start time, venue and optional city: on a pending match, or as a reschedule of a confirmed one, which stays confirmed until accepted. Cancel with a reason (1–200 characters) |
| **Errors** | A refusal stays in the sheet: proposal changed, schedule clash, match closed, no permission. The match is re-read, so a proposal changed meanwhile appears at once. Success closes the sheet with a toast |
| **Guards** | `MatchScheduleRules`: a future time within a year, venue 1–100 characters, city up to 60, reason 1–200. A started match can't change. `busyMatchesProvider` sends one request per match; a second tap does nothing. The server remains the authority |
| **Hand-off** | Accepting a challenge now goes to Match Management → Waiting, as in the demo |
| **Dashboard** | "Next Match" shows the server match's opponent name and agreed venue |

**Not yet:** line-ups on server matches (P6), results (M2), and the player's own match list.

**Tests:** `test/match_schedule_supabase_test.dart` (13): rules, controller flows (propose, accept, decline, a stale version, a clash, cancel, repeated taps, no permission) and screen flows on `FakeMatchDb`. The demo booking tests are unchanged.

---

## P6 — Line-ups and player availability

**Status (2026-11-21):** works on the server with `CRICECO_MATCHES` on, and is tested with fakes. The switch stays **off**; nothing is in production. The demo's line-up and availability flows are unchanged.

| Part | Server mode |
|---|---|
| **Line-up loading** | `ClubMatchesController` reads each confirmed or played match's saved line-up (`match_lineup`, our club's only), so the existing line-up sheet and screens show it as `ClubMatch.lineup` |
| **Saving** | Builder ("Confirm Team") and "Select Existing Team" save through `save_match_lineup`: exactly 11 + 4 in pick order. A team keeps its captain and vice-captain when both are in the XI |
| **Team snapshot** | A team that isn't a complete 11 + 4 after leaving out injured or unavailable players is refused before saving, with the counts |
| **Refusals** | A player who left, or is injured or unavailable on the match day, comes back as the server's reason. The builder keeps the picks |
| **Match Management** | A confirmed card shows "Line-up needed" or "Line-up: name", and its **Select Your Playing XI** / **View / Edit Line-up** action opens the same line-up sheet as the demo |
| **Squad pool** | For the owner, each member's availability comes from `club_player_availability`. Injured or unavailable today is locked; an injury whose end date has passed is not. If availability can't be read, the pool still loads, and the server refuses such a player on save |
| **Player availability** | `PlayerAvailabilityController` reads the player's own record (`my_availability`) and saves through `set_my_availability`, which never sends a user id. The new status is shown once stored; a refusal is shown and the record stays. One save at a time. The Availability screen, the Match Availability sheet and the dashboard pill all wait for the answer. The demo still saves at once |

**Not yet:**
- **Player's own match list:** needs a server function (`my_matches()`), which means a new migration that isn't approved. "My Matches" stays empty on the server.
- **Results:** M2.

**Kept on the device only:** the availability "until" shortcut (Today / Tomorrow / Weekend) and "Open to offers" (Player Hunt).

**Tests:** `test/lineups_availability_supabase_test.dart` (14) covers:
- loading, building, refusal, team snapshot (complete, and with an injured player) and closed line-ups;
- pool locks and the fallback when availability can't be read;
- player read, save, refusal and duplicate save, plus the demo's immediate save;
- the Match Management line-up entry.

`FakeMatchDb` applies the injured/unavailable rule on save, as migration 19 does.
