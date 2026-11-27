# M7 club discovery, availability slots and rankings (database half)

Migration 32 `supabase/migrations/20261126090200_m7_club_discovery.sql`. **Not applied to production.** It needs migrations 1–31.

| File | Purpose |
| --- | --- |
| `supabase/migrations/20261126090200_m7_club_discovery.sql` | The migration (one transaction, guards, self-check). Purely additive |
| `supabase/rollback/20261126_rollback_m7_club_discovery.sql` | Drops everything it added, including every posted slot |
| `supabase/tests/32_m7_club_discovery_postcheck.sql` | Read-only post-check (10 PASS rows + 2 INFO) |
| `supabase/tests/local/27_m7_club_discovery_local_check.sql` | Local behaviour test (121 checks, one transaction, rolled back) |

## What it adds

1. **Public club profile and directory.** Another club's public fields, its active member count and its official record from confirmed results. Any signed-in user can read them.
2. **Availability slots.** The table `public.club_match_slots` and four functions. They cover Create Availability Slot, Your Open Slot and Find Opponent's "Teams Looking for Opponents".
3. **Player rankings.** The leaderboard's inputs, taken from the official career statistics of migration 22.
4. **Applicant statistics.** A pending join-request applicant's career figures, for the owner of the club they applied to.

Migration 32 changes no existing table, column, function, policy or grant. Before 32, the record of a club (`club_results` / `club_record`, migration 20) was visible to its members only. With 32, anyone signed in can see the club's **counts and last 5 results** through the new functions. The match list stays members-only.

## App contract

All of the functions below:
- are called through `rpc('<name>', params)`;
- are SECURITY DEFINER;
- can be executed by `authenticated` only (anon gets `42501 permission denied for function …`);
- take the caller from `auth.uid()`.

PostgREST JSON types: `uuid`, `text`, `date` → string (`"2026-11-27"`); `time` → string (`"14:00:00"`); `timestamptz` → ISO string; `integer` / `smallint` / `numeric` → number; `text[]` → array of strings; `boolean` → bool. Format values everywhere: `test | t20 | odi | t10 | custom` (as migration 17).

### 1. `club_public_profile(p_club_id uuid)` → one row

| Column | Type | Notes |
| --- | --- | --- |
| `club_id` | uuid | |
| `name` | text | |
| `short_name` | text | NULL when the club has none |
| `city` | text | |
| `club_type` | text | `professional` \| `college_university` \| `corporate` |
| `established_year` | integer | NULL when not listed |
| `home_ground_id` | text | The app's ground-directory id, NULL = none |
| `logo_path` | text | `club-logos` object name (migration 31), NULL = default badge |
| `member_count` | integer | Active members, owner included |
| `played` | integer | Confirmed results only |
| `won` / `lost` / `tied` / `no_result` / `abandoned` | integer | From this club's side; they add up to `played` |
| `recent_form` | text[] | The last ≤ 5 results, **newest first**: `won` \| `lost` \| `tied` \| `no_result` \| `abandoned`; `[]` when none |
| `played_formats` | text[] | Formats of its confirmed results, most played first; `[]` when none |
| `is_own` | boolean | The caller owns this club |

Errors: `42501 club: not authenticated` · `P0002 club: not found`.

### 2. `club_directory(p_search text = null, p_city text = null, p_limit integer = 50, p_offset integer = 0)` → rows

It returns the same columns as `club_public_profile`, in the same order, **without `is_own`**.
- It never lists a club the caller owns. Every other club is listed, for players too.
- `p_search`: a case-insensitive substring of the name or the short name. Spaces are collapsed. At most 100 characters.
- `p_city`: the city exactly, ignoring case and outer spaces. At most 60 characters.
- Rows are ordered by name (case-insensitive), then id.
- `p_limit` is clamped to 1–100 and `p_offset` to 0–10000.

Errors: `42501 club: not authenticated` · `22023 club: invalid` (search or city too long).

**Mapping to `ClubSummary`.** The server has no captain, key players, "about", colour, coach or owner name. Those fields stay app-side or empty, and are never invented:
- `id` = `club_id`, `name`, `city`.
- `abbr` = `short_name`, or initials from the name.
- `level` = the label of `club_type`.
- `meta` = `"<city> · <type label>"`.
- `established` = `established_year` (0 or hidden when NULL).
- `squadSize` = `member_count`.
- `formats` = the labels of `played_formats` joined with `" / "`.
- `homeGround` = the ground name for `home_ground_id`.
- `recentForm` = `recent_form`.
- `wins` / `losses` / `played` = `won` / `lost` / `played`.
- `winRate` = `played > 0 ? round(won * 100 / played) : 0`.
- `ownerName` and `coachName` = `null` (the UI shows "Not listed").
- `captain`: none (never a phone).
- `keyPlayers`: `[]`.

### 3. Availability slots

A slot is one time range on one **Asia/Karachi** day.
- **Date:** from **tomorrow** (Karachi) to 365 days ahead. The same rule as `send_challenge`.
- **Times:** start before end, whole minutes, ending by 23:59 (so no `24:00`). `TimeSlot(8, 10)` → `p_start_time: '08:00'`, `p_end_time: '10:00'`.
- **Limit:** at most **10 open slots per club**.
- **Overlap:** a club's open slots never overlap (`[start, end)`, so back-to-back slots are fine). Other clubs may post the same time.
- **Expiry:** a slot stops being open when it starts. Every read decides this by time, so expired slots never appear as open. The row is marked `expired` on the club's next post.
- **Statuses:** `open | withdrawn | expired | taken`. `taken` is reserved: nothing sets it yet.
- **Access:** only the club's **owner** posts, withdraws and lists the club's slots. The table has RLS on with no policy and no grant.

**Slot row** (returned by `post_match_slot`, `withdraw_match_slot` and `my_club_slots`):

| Column | Type | Notes |
| --- | --- | --- |
| `slot_id` | uuid | `AvailabilitySlot.id` |
| `club_id` | uuid | |
| `format` | text | |
| `custom_overs` | smallint | Only for `custom` (1–50), else NULL |
| `city` | text | Trimmed, spaces collapsed |
| `ground_id` | text | `AvailabilitySlot.groundId`, NULL = any ground |
| `venue_name` | text | Free text, NULL = none |
| `slot_date` | date | Karachi date (`AvailabilitySlot.date`) |
| `start_time` | time | Karachi wall clock, e.g. `"14:00:00"` |
| `end_time` | time | Karachi wall clock |
| `starts_at` | timestamptz | The same instant as `slot_date` + `start_time` in Asia/Karachi |
| `ends_at` | timestamptz | |
| `notes` | text | NULL = none (`AvailabilitySlot.notes` = `''`) |
| `status` | text | `open` \| `withdrawn` \| `expired` \| `taken`. `my_club_slots` reports `expired` for an open slot that has started |
| `created_at` | timestamptz | |
| `closed_at` | timestamptz | When withdrawn or marked expired; NULL while open |

**`post_match_slot(p_club_id uuid, p_format text, p_custom_overs integer, p_city text, p_slot_date date, p_start_time time, p_end_time time, p_ground_id text = null, p_venue_name text = null, p_notes text = null)`** → one slot row.
- `p_format` is case-insensitive. `p_custom_overs` is required (1–50) for `custom` and ignored otherwise.
- `p_city`: 1–60 characters after trimming. Use the city name, as for matches.
- `p_ground_id`: ≤ 64 characters, trimmed; blank = NULL.
- `p_venue_name`: ≤ 100 characters; blank = NULL.
- `p_notes`: ≤ 200 characters after trimming; blank = NULL.

**`withdraw_match_slot(p_slot_id uuid)`** → one slot row (`status = 'withdrawn'`).
- Calling it again on a withdrawn slot returns the slot unchanged.

**`my_club_slots(p_club_id uuid, p_include_closed boolean = false)`** → slot rows, ordered by `starts_at`.
- By default: the club's open slots that haven't started (Your Open Slot).
- `p_include_closed = true` also returns slots withdrawn in the last 30 days, and expired or taken slots that started in the last 30 days.

**`open_match_slots(p_city text = null, p_format text = null, p_from_date date = null, p_to_date date = null, p_limit integer = 50, p_offset integer = 0)`** → rows, soonest first.
- It lists **other** clubs' open slots that haven't started. It never includes the caller's own clubs.
- It is for signed-in club owners only, as `match_club_directory` is.
- `p_city` matches exactly, ignoring case and outer spaces.
- `p_from_date` / `p_to_date` are inclusive Karachi dates.
- `p_limit` is clamped to 1–100.

| Column | Type | Notes |
| --- | --- | --- |
| `slot_id` | uuid | |
| `club_id` | uuid | `MatchSeekerListing.clubId` |
| `club_name` | text | |
| `club_short_name` | text | NULL when none |
| `club_city` | text | |
| `club_type` | text | |
| `club_logo_path` | text | |
| `club_played` / `club_won` / `club_lost` | integer | The club's official record (the card's "W… L…") |
| `format` | text | |
| `custom_overs` | smallint | |
| `city` | text | |
| `ground_id` | text | |
| `venue_name` | text | |
| `slot_date` | date | |
| `start_time` | time | |
| `end_time` | time | |
| `starts_at` | timestamptz | `MatchSeekerListing.startsAt` |
| `ends_at` | timestamptz | |
| `notes` | text | |
| `created_at` | timestamptz | |

`MatchSeekerListing.venue` = `venue_name`, else the ground name for `ground_id`, else "Any ground in `<city>`". `MatchSeekerListing.rating` has **no server value** (no rating on the server, M2 decision 10). Show none, or "—".

**Slot errors:**

| Error | Meaning |
| --- | --- |
| `42501 slot: not authenticated` | No signed-in user |
| `42501 slot: not allowed` | Not the club's owner. `my_club_slots`: also an unknown club. `open_match_slots`: the caller owns no club |
| `P0002 slot: club not found` | `post_match_slot`: no such club |
| `P0002 slot: not found` | `withdraw_match_slot`: no such slot |
| `22023 slot: invalid` | Unknown format, missing or out-of-range custom overs, a bad filter, or `p_to_date < p_from_date` |
| `22023 slot: invalid date` | Not from tomorrow to 365 days ahead (Asia/Karachi), or missing |
| `22023 slot: invalid time` | Missing, start ≥ end, seconds, or an end past 23:59 |
| `22023 slot: invalid city` / `invalid ground` / `invalid venue` / `invalid notes` | Length rules above |
| `23P01 slot: overlaps` | Overlaps one of the club's own open slots |
| `P0001 slot: too many open` | The club already has 10 open slots |
| `P0001 slot: not open` | Withdrawing a slot that has started (expired) or is taken |

### 4. `player_rankings(p_role text = null, p_club_id uuid = null, p_search text = null, p_limit integer = 100)` → rows

**Who is listed.** A player is listed only if all of these hold:
- they have a player profile and a non-blank name;
- they are an **active member of some club** (of `p_club_id`, when it is given);
- they allow it, with **`show_stats` AND `public_profile`** (migration 31).

The **caller's own row is always included** when it meets the first two rules, with `is_me = true`.

**Filters and order.**
- `p_role`: `batsman | bowler | all_rounder`, case-insensitive.
- `p_search`: a case-insensitive substring of the name, ≤ 100 characters.
- Rows are ordered by `matches`, `runs` and `wickets` (all descending), then by name.
- `p_limit` is clamped to 1–200.

The server does not compute a score. The app ranks the rows with `PlayerRankingMath`.

| Column | Type | → `RankingInput` |
| --- | --- | --- |
| `user_id` | uuid | `playerId` |
| `full_name` | text | `name` |
| `avatar_path` | text | (avatar) |
| `club_id` | uuid | Club filter key |
| `club_name` | text | `club` (or `club_short_name ?? club_name`). The club is `p_club_id`, else the player's earliest active membership |
| `club_short_name` | text | |
| `player_role` | text | `role` (`batsman` / `bowler` / `all_rounder` → `SquadCategory`) |
| `is_wicketkeeper` | boolean | |
| `matches` | integer | `completedMatches` (confirmed matches played) |
| `bat_innings`, `not_outs`, `runs`, `balls_faced` | integer | `runs` |
| `batting_average`, `strike_rate` | numeric | `battingAverage`, `strikeRate` (NULL when the divisor is 0) |
| `highest` | integer | |
| `highest_not_out` | boolean | |
| `fifties`, `hundreds`, `wickets`, `balls_bowled`, `runs_conceded` | integer | `wickets` |
| `bowling_average`, `economy` | numeric | `bowlingAverage`, `economy` |
| `best_wickets`, `best_runs`, `catches`, `stumpings`, `player_of_match` | integer | |
| `recent_played`, `recent_wins` | integer | `recentPlayed`, `recentWins` (the last ≤ 5 confirmed matches; wins of the player's club) |
| `rating` | numeric | Always NULL → `rating: null` |
| `is_me` | boolean | `isMe` |

The figures are career figures over every membership, any club and any status, exactly as `player_stats` gives them (migration 22).

Errors: `42501 ranking: not authenticated` · `22023 ranking: invalid` (unknown role, or a search that is too long).

### 5. `club_applicant_stats(p_request_id uuid)` → one row

The caller must own the club of a **pending** request.

| Column | Type |
| --- | --- |
| `request_id` | uuid |
| `stats_visible` | boolean |
| `matches`, `bat_innings`, `not_outs`, `runs`, `balls_faced` | integer |
| `batting_average`, `strike_rate` | numeric |
| `highest` | integer |
| `highest_not_out` | boolean |
| `fifties`, `hundreds`, `wickets`, `balls_bowled`, `runs_conceded` | integer |
| `bowling_average`, `economy` | numeric |
| `best_wickets`, `best_runs`, `catches`, `run_outs`, `stumpings`, `player_of_match` | integer |

- If the applicant set `show_stats = false`: `stats_visible = false` and **every figure is NULL**. The app shows no performance.
- Otherwise, the figures are career figures (as `player_stats`). An applicant who never played gets zeros, with NULL averages.
- `JoinRequestPerformance(matches, runs, average: batting_average formatted (or "—"), wickets)`. Use `null` performance when `stats_visible` is false or `matches = 0`.

Errors (as `decide_join_request`):

| Error | Meaning |
| --- | --- |
| `42501 club_join: not authenticated` | No signed-in user |
| `P0002 club_join: not found` | No such request |
| `42501 club_join: not allowed` | Not the owner of that request's club (members and the applicant included) |
| `P0001 club_join: not pending` | The request was already decided or cancelled |

## Decisions and deviations

- **No owner or coach names, ever.** "Never expose owner personal data" wins over `ClubSummary.ownerName` / `coachName`. They stay `null` and the UI shows "Not listed". No phone, e-mail, address, join code, owner id or `created_by` is in any result. The self-check, post-check row 09 and local P1/P2 check this.
- **Rankings also need `public_profile`,** not only `show_stats`. A leaderboard row shows the player's name and club. A player who hides their profile is not listed to others, but always sees their own row.
- **No rating on the server** (M2 decision 10): `rating` is NULL and seekers have no rating.
- **Slots start from tomorrow.** Create Slot currently enables today's date, so the app must disable today and map `slot: invalid date`. The notes limit (200) matches the UI.
- **The slot directory is for owners only** (Find Opponent is an owner screen). The club directory and profiles are open to any signed-in user.
- `taken` is reserved, and nothing sets it: sending a match request doesn't touch the slot. No notification is sent for slots.

## Known effects and notes

- **What deletions do:**
  - Deleting a club deletes its slots.
  - Deleting an account sets `created_by` to NULL. The slots stay with the club.
  - After an ownership transfer (migration 16), the new owner manages the slots.
- **Posts take a lock.** `post_match_slot` takes a transaction advisory lock per club (`criceco.slot.club:<id>`), so the cap and the overlap check are decided one post at a time. This was checked with two sessions: the second overlapping post waited, then failed with `slot: overlaps`.
- **Cost per row:**
  - Directory rows compute the record per club (`club_public_stats`, internal).
  - Ranking rows compute `member_stats` and the recent form per candidate.
  - This is fine at the current size. Caching may be needed later.
- **Rollback:**
  1. First roll back any app build that calls these functions.
  2. Then run the rollback. It drops `club_match_slots` **with its rows** and prints how many.
- **The guard refuses in three cases:**
  - it is already applied, or a name is taken;
  - 1–31 are missing;
  - `member_stats` (22) or `is_club_owner` (11) differs from its migration (body md5, line endings ignored).
- **Historical checks:** local 25 J3 still fails after migration 31, as before (see `docs/M5_M6_MEDIA_AND_VISIBILITY.md`). Migration 32 doesn't change that.

## Local verification

**Containers.** One throwaway container, `criceco-m7-test` (`public.ecr.aws/supabase/postgres:17.11.0.018`, tmpfs, no ports). It has been removed. It held:
- the `postgres` database, with the legacy fixture copied without its auth guard;
- a plain database `m7plain` (template0, with `00_auth_stub.sql` and the original fixture) for the checks that refuse Vault / pg_net.

**Steps.**
1. On both databases: migrations 1–31, applied **explicitly by name**, with D1 after 6 and the Storage stand-in (`26_…sh stub`) before 31.
2. The guards refused in four cases: with 31's function missing, with `profiles.show_stats` missing, with a drifted `is_club_owner`, and with a name taken.
3. Migration 32, then local check 27: **121/121** on both databases.
4. Post-check 32: **10 PASS + 2 INFO**. Before 32 it runs without error and shows 8 FAIL.
5. Regression with 32 applied:
   - local 26: 118/118;
   - local 25: 81/81 with J3 updated to the migration-31 column (as the M5 agent did). As-is, it stops at J3, as accepted;
   - on `m7plain`: local 22 (44), 23 (22) and 24 (30), all passing.
6. The rollback:
   - the catalogue (public and storage functions with body md5 and ACL, tables, columns, constraints, indexes, triggers, policies, column ACLs) is **identical to the 1–31 state**;
   - a second rollback refuses.
7. Re-applying 32 gives a catalogue identical to the first apply, and 27 passes again.
8. A two-session race on `post_match_slot` (overlap) was serialised as expected.
