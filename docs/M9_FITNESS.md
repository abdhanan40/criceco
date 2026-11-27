# M9 fitness (database half)

Migration 34 `supabase/migrations/20261126090400_m9_fitness.sql`. **Not applied to production.** It needs migrations 1–31 and is independent of migrations 32 and 33.

| File | Purpose |
| --- | --- |
| `supabase/migrations/20261126090400_m9_fitness.sql` | The migration (one transaction, guard, self-check) |
| `supabase/rollback/20261126_rollback_m9_fitness.sql` | Reverses it: drops the table (the logged workouts are lost) and the seven functions |
| `supabase/tests/34_m9_fitness_postcheck.sql` | Read-only post-check (14 PASS rows + 1 INFO) |
| `supabase/tests/local/29_m9_fitness_local_check.sql` | Local behaviour test (98 checks, one transaction, rolled back) |

What the app has today (`lib/core/models/fitness.dart`, `lib/features/fitness/`): workouts live in memory per session, and a club member's Fitness Meter is worked out from `memberActivity(clubId)`, which the Supabase repository leaves empty. Migration 34 stores the workouts and gives the club owner both inputs of the meter for the squad.

## App contract

All functions are `SECURITY DEFINER`, `search_path = ''`, executable by `authenticated` only (anon gets `42501 permission denied`). Every error message starts with `fitness:`.

### Codes (exactly the Dart enum names)

| Dart | Server code |
| --- | --- |
| `WorkoutType.training / gym / running / nets / other` | `training`, `gym`, `running`, `nets`, `other` |
| `WorkoutIntensity.light / moderate / high` | `light`, `moderate`, `high` |

Codes are lower case; `Training` is refused.

### Table `public.player_workouts`

| Column | Type | Rule |
| --- | --- | --- |
| `id` | uuid | primary key, `gen_random_uuid()` |
| `user_id` | uuid | → `profiles(id)` **ON DELETE CASCADE** |
| `workout_date` | date | today or earlier in **Asia/Karachi**, at most 365 days back (both relative to `created_at`) |
| `workout_type` | text | one of the type codes |
| `minutes` | integer | 1–600 (`WorkoutEntry.maxMinutes`) |
| `intensity` | text | one of the intensity codes |
| `notes` | text | NULL, or 1–120 characters (`WorkoutEntry.notesMaxLength`) with no leading / trailing spaces |
| `created_at` | timestamptz | `now()` |

- RLS on. One policy: `SELECT` of the caller's own rows, for `authenticated`. No direct `INSERT` / `UPDATE` / `DELETE` grant: writes go through the RPCs. anon and service_role have no table grant.
- The rules are also `CHECK` constraints, so they hold for any writer.

### `log_workout(p_workout_date date, p_workout_type text, p_minutes integer, p_intensity text, p_notes text default null)`

Returns **one row** `TABLE(id uuid, workout_date date, workout_type text, minutes integer, intensity text, notes text, created_at timestamptz)`: the stored workout. `p_notes` is trimmed; blank or NULL is stored as NULL.

Limits: at most **10 workouts on one date** and **30 logged in any 24 hours** per person. Both count the rows that exist now (a deleted workout no longer counts). The caller's profile row is locked `FOR NO KEY UPDATE` first, so two calls at the same moment are counted one after the other.

### `my_workouts(p_from date, p_to date)`

Returns `TABLE(id uuid, workout_date date, workout_type text, minutes integer, intensity text, notes text, created_at timestamptz)`: the caller's workouts with `p_from <= workout_date <= p_to`, **oldest first** (`workout_date`, `created_at`, `id`) — the app's "newest last". Both dates are required, `p_from <= p_to`, at most 366 days (`p_to - p_from <= 365`). The direct `select` on `player_workouts` also works (own rows only).

### `delete_workout(p_id uuid)`

Returns `void`. Deletes one of the caller's workouts. Someone else's workout, an unknown id and NULL all give `P0002 fitness: workout not found`.

### The club owner's view

Three functions, each `(p_club_id uuid, p_from date, p_to date)`:
- only the **owner** of `p_club_id` (`clubs.owner_id = auth.uid()`); an unknown club, another person's club and a club where the caller is only a member all give `42501 fitness: not allowed`;
- only **active** members (`club_members.status = 'active'`); removed members and non-members never appear;
- a member whose `profiles.show_stats` is **false** is hidden: listed by `club_member_fitness` with `fitness_visible = false` and every figure NULL, and absent from the other two. The owner's own row is always visible;
- the range: both dates required, `p_from <= p_to`, at most 31 days (`p_to - p_from <= 30`). For the Fitness Meter pass `p_from = today − 6`, `p_to = today` (today in Asia/Karachi; `FitnessReport.window = 7`);
- workout notes are never returned to the owner.

**`club_member_fitness`** returns one row per active member, the owner first, then by joined date:

`TABLE(member_id uuid, user_id uuid, member_role text, fitness_visible boolean, workout_sessions integer, workout_minutes integer, training_load numeric, last_workout_date date, matches integer, last_match_date date)`

- `workout_sessions` = `FitnessReport.trainingSessions`;
- `training_load` = Σ minutes / 60 × (light 0.5, moderate 1, high 1.5), as `FitnessMeter.workoutLoad`, rounded to 2 places (= `FitnessReport.trainingLoad`);
- `matches` and `last_match_date` count the confirmed matches of `club_member_match_activity` in the range;
- a visible member with nothing in the range gets 0s and NULL dates.

**`club_member_workouts`** returns the visible members' workouts in the range, by member, then oldest first:

`TABLE(member_id uuid, workout_id uuid, workout_date date, workout_type text, minutes integer, intensity text)`

Use these rows to build the `WorkoutEntry` list for `FitnessMeter.evaluate` (notes `''`).

**`club_member_match_activity`** returns the visible members' **confirmed** matches whose start falls in the range in Asia/Karachi, newest first per member (this is what `memberActivity(clubId)` needs):

`TABLE(member_id uuid, match_id uuid, starts_at timestamptz, club_id uuid, club_name text, opponent_club_id uuid, opponent_name text, result text, bat_runs integer, bat_balls integer, bowl_balls integer, bowl_runs integer, bowl_wickets integer)`

- `member_id` is the membership in **this** club (the key of the app's map); `club_id` / `club_name` is the club they played for. Matches for any of the person's clubs count (workload is per person), with the same rules as `player_match_log` (migration 22): only the confirmed version, figures summed over a Test's two innings.
- `result` from the member's side: `won`, `lost`, `tied`, `no_result`, `abandoned` (as `player_match_log`).
- Mapping to `MatchLogEntry`: `date` = `starts_at`, `runs` = `bat_runs`, `balls` = `bat_balls`, `wickets` = `bowl_wickets`, `overs` = `bowl_balls` written as overs (`balls ~/ 6`.`balls % 6`), `opponentName` = `opponent_name`.

Availability for the meter still comes from `club_player_availability` (migration 19).

### Errors

| SQLSTATE · message | When |
| --- | --- |
| `42501 permission denied for function …` | anon |
| `42501 fitness: not authenticated` | no signed-in user (every function) |
| `42501 fitness: not allowed` | the owner views: not the club's owner, or the club doesn't exist |
| `22023 fitness: invalid date` | `log_workout`: no date |
| `22023 fitness: future date` | `log_workout`: after today in Asia/Karachi |
| `22023 fitness: date too old` | `log_workout`: more than 365 days back |
| `22023 fitness: invalid type` | `log_workout`: not a type code |
| `22023 fitness: invalid minutes` | `log_workout`: NULL or outside 1–600 |
| `22023 fitness: invalid intensity` | `log_workout`: not an intensity code |
| `22023 fitness: notes too long` | `log_workout`: more than 120 characters after trimming |
| `22023 fitness: invalid range` | `my_workouts` (> 366 days) and the owner views (> 31 days): a NULL date, `p_from > p_to` |
| `P0001 fitness: too many workouts on that day` | `log_workout`: 10 already on that date |
| `P0001 fitness: too many workouts logged, try later` | `log_workout`: 30 logged in the last 24 hours |
| `P0002 fitness: profile not found` | `log_workout`: signed-in user without a profile row |
| `P0002 fitness: workout not found` | `delete_workout` |

The checks run in that order: authentication, then (owner views) ownership, then input.

## Known effects and notes

- **"Today" is Pakistan time.** The device's local date can differ near midnight for a user abroad; the server's answer then is `fitness: future date`.
- **`show_stats` is enforced here only.** `player_match_log`, `club_member_stats` and `player_stats` (migration 22) still ignore it, as migration 31 documented. A hidden member's matches can still be read through those.
- **Another club's matches.** The owner sees the club name and opponent of a member's matches for other clubs, as `player_match_log` already allows (`can_view_player_stats`).
- **Account deletion.** `delete_account_data` and the `delete-account` Edge Function are unchanged; the profile's cascade removes the workouts (local check D1, D2).
- **The limits** count existing rows, so logging and deleting repeatedly is not limited (nothing accumulates).
- **Rollback:** first roll back any app build that calls the new functions. The rollback deletes every logged workout (it prints how many) and touches nothing else.
- The internal helper `fitness_member_matches(uuid, date, date)` has no access check and is closed to anon and authenticated.

## Local verification

One throwaway container, `criceco-m9-test` (`public.ecr.aws/supabase/postgres:17.11.0.018`), removed afterwards. Two databases in it:
- `postgres` (real Supabase auth): the legacy profiles fixture (without its auth guard), migrations 1–6, D1, 7–30, the Storage stand-in (`26_…sh stub`), 31, then 34 — each file applied explicitly, no glob;
- `m9plain`: `00_auth_stub.sql`, `02_legacy_profiles_fixture.sql`, the same sequence.

Results (both databases unless stated):
1. Migration 34 applies; applying it again is refused by the guard; it is refused when 1–31 are incomplete (no `set_profile_visibility`, or no `show_stats`).
2. Local check 29: **98/98**. It covers anon and no-session calls, direct table writes, every input bound, the two limits, own rows only, someone else's workout undeletable, the owner rules (owner only, active only, removed member, non-member, unknown club, hidden member, the owner's own hidden row, show_stats switched back on), confirmed-only matches and the confirmed version, both sides' results, and the deletion cascade.
3. Post-check 34: **14 PASS + 1 INFO**. Before the migration (and after the rollback) it runs and shows FAIL.
4. Regression with 34 applied:
   - local 22 (44), 23 (22), 24 (30): pass on `m9plain` (they refuse on the Supabase database by design);
   - local 25: 71 checks pass, then J3 fails — the accepted historical failure after migration 31 (see M5_M6 doc). With J3 updated to the migration-31 columns (scratch copy, not committed): 81/81;
   - local 25b: C1 and C2 pass on `m9plain`;
   - local 26: 118/118 on `postgres`. On `m9plain` it stops at the stand-in's own foreign key (`permission denied for schema storage`, an artefact of the stand-in in a second database), unrelated to migration 34;
   - local 22b and 24b refuse to run on the Supabase image (they detect `supabase_admin`); not run.
5. An ad-hoc two-session run on `m9plain`: with 9 workouts on one date, two simultaneous `log_workout` calls for that date — the second waited for the first, then got `too many workouts on that day` (10 rows, never 11).
6. Rollback, twice: the catalogue (public and storage functions with body md5, ACL, SECURITY DEFINER and settings; relations with RLS flag and ACL; columns; constraints; indexes; triggers; policies) is identical to the 1–31 state on both databases. Re-applying gives a catalogue identical to the first apply; check 29 and the post-check pass again.
