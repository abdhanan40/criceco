# M10 tournaments (database half)

Migration 35 `supabase/migrations/20261126090500_m10_tournaments.sql`. **Not applied to production.** It needs migrations 1–31 and 33, is independent of 32 and 34, and was tested on top of 1–34.

| File | Purpose |
| --- | --- |
| `supabase/migrations/20261126090500_m10_tournaments.sql` | The migration (one transaction, guard, self-check) |
| `supabase/rollback/20261126_rollback_m10_tournaments.sql` | Reverses it. It drops the 4 tables (every tournament, entry, squad and fixture is lost; the counts are printed) and the tournament notifications, then restores migration 33's type list and `notification_category` verbatim |
| `supabase/tests/35_m10_tournaments_postcheck.sql` | Read-only post-check (14 PASS rows + 1 INFO) |
| `supabase/tests/local/30_m10_tournaments_local_check.sql` | Local behaviour test (240 checks, one transaction, rolled back) |
| `supabase/functions/push-dispatch/templates.ts` (+ `templates_test.ts`) | Push wording for the 5 new types |

What the app has today: `InMemoryTournamentRepository` (empty in Supabase builds), `TournamentsController` / `TournamentRegistrationsController` and `FixtureEngine`. Migration 35 gives each of these a server counterpart. Results stay **read-only**: there is no organizer or app result entry. A fixture gets a winner only from the trusted scorer's service_role function. There are no payments: the entry fee and the prize are display data only.

## App contract

Every app function is `SECURITY DEFINER` with `search_path = ''` and is executable by `authenticated` only. For anon, PostgREST returns `42501 permission denied for function …`. Every message starts with `tournament:`. "Club owner" means `clubs.owner_id = auth.uid()`. "Today" is the **Asia/Karachi** date on the server.

### Codes (the Dart enum names in snake_case)

| Dart | Server |
| --- | --- |
| `MatchFormat.test / t20 / odi / t10 / custom` | `test`, `t20`, `odi`, `t10`, `custom` |
| `TournamentType.knockout / league` | `knockout`, `league` |
| `TournamentStatus.registrationOpen / registrationFull / registrationClosed / completed` | `registration_open`, `registration_full`, `registration_closed`, `completed` |
| `RegistrationStatus.pending / approved / rejected` | `pending`, `approved`, `rejected`, plus **`removed`** (the organizer removed a confirmed team; the app currently writes "rejected" for this, so show it under the Rejected tab) |
| `FixtureMatch.bye` (`__BYE__`) | `home_bye` / `away_bye` / `winner_bye` = true |

`status` in every tournament row is the **effective** status (`Tournament.statusAt`). An open tournament whose deadline day has passed reads as `registration_closed`; the stored row is not rewritten.

### Row shapes

**T: a tournament.** Returned by `create_tournament`, `my_hosted_tournaments`, `browse_tournaments` and `tournament_detail` (all identical):

`TABLE(tournament_id uuid, organizer_club_id uuid, organizer_name text, organizer_short_name text, organizer_city text, organizer_logo_path text, name text, city text, ground text, format text, custom_overs integer, tournament_type text, start_date date, end_date date, registration_deadline date, entry_fee integer, prize integer, max_teams integer, description text, rules text[], status text, approved_count integer, pending_count integer, available_slots integer, accepts_registrations boolean, fixtures_generated boolean, fixtures_generated_at timestamptz, winner_registration_id uuid, winner_name text, is_organizer boolean, my_registration_id uuid, my_registration_status text, created_at timestamptz)`

| Column | Meaning |
| --- | --- |
| `approved_count` | `joined.length` |
| `pending_count` | Shown to the organizer's owner only; NULL for everyone else |
| `available_slots` | `max_teams − approved_count` (never below 0) |
| `accepts_registrations` | `acceptsRegistrationsAt(now)`: effective status open, not full, no fixtures |
| `winner_name` | The champion club's name |
| `is_organizer` | The caller owns the organizer club |
| `my_registration_id` / `my_registration_status` | The caller's club's **live** (pending or approved) entry (`activeRegistrationProvider`), else NULL |
| `entry_fee`, `prize` | NULL = not set (shown as "—") |

**R: an entry.** Returned by `tournament_teams`, `submit_tournament_registration`, `decide_tournament_registration` and `remove_tournament_team` (all identical):

`TABLE(registration_id uuid, tournament_id uuid, club_id uuid, club_name text, club_short_name text, club_city text, club_logo_path text, team_id uuid, team_name text, status text, submitted_at timestamptz, decided_at timestamptz, player_count integer, is_my_club boolean)`

- Mapping: `TournamentEntrant(id: registration_id, displayName: club_name, clubId: club_id)` and `TournamentRegistration(id, tournamentId, clubId, teamId, teamName, status, submittedAt, decidedAt)`.
- The entrant id used in fixtures and the points table is `registration_id`.

### Hosting

**`create_tournament(p_club_id uuid, p_name text, p_city text, p_ground text, p_format text, p_custom_overs integer, p_tournament_type text, p_start_date date, p_end_date date, p_registration_deadline date, p_max_teams integer, p_entry_fee integer default null, p_prize integer default null, p_description text default null, p_rules text[] default null)` → T (one row)**

Mirrors `validateTournamentInput`:
- name, city and ground: 1–60 characters each, trimmed, inner runs of spaces collapsed;
- format: one of the codes. `p_custom_overs` is used only with `custom` (1–50) and is ignored otherwise;
- start date: not before today; end date ≥ start; deadline: not before today and ≤ start;
- `max_teams`: 2–32;
- fee: 0–9,999,999; prize: 0–99,999,999;
- description: ≤ 500 characters, trimmed (line breaks kept);
- rules: ≤ 20, each ≤ 200 characters; blank rules are dropped.

Server-only limits:
- the start date is at most today + 365, and the end date at most start + 180;
- a club can have at most **20** tournaments that are not completed, and create at most **5** in 24 hours.

A new tournament starts as `registration_open`.

**`my_hosted_tournaments(p_club_id uuid)` → T.** The club's own tournaments, newest first. Owner only.

**`browse_tournaments(p_city text default null)` → T.** Other clubs' tournaments: those hosted by any club the caller owns are excluded, as `browseTournamentsProvider` does. Soonest start first, at most 200 rows.
- `p_city` is matched case-insensitively with outer spaces ignored (≤ 60 characters).
- NULL lists every city, so the app can build `browseCitiesProvider` from the rows.

**`tournament_detail(p_tournament_id uuid)` → T.** Any signed-in user.

**`tournament_hub_stats(p_club_id uuid)` → `TABLE(hosted integer, open integer, registered integer, approved integer, pending integer)`.** `TournamentHubStats`; owner only.
- `open` counts browse tournaments that are accepting registrations.
- `registered` counts all of the club's entries, in every status.

### Entries

**`tournament_teams(p_tournament_id uuid)` → R.**
- Who sees what: everyone sees approved entries; the organizer's owner sees every status; a club owner always sees their own club's entries.
- Order: approved in approval order (the draw's seeding), then pending oldest first (`pendingRequestsProvider`), then rejected and removed, newest decision first.

**`tournament_registration_squad(p_registration_id uuid)` → `TABLE(registration_id uuid, "position" integer, member_id uuid, user_id uuid, full_name text, avatar_path text, member_role text, selection text, is_captain boolean, is_vice_captain boolean, is_wicket_keeper boolean, member_active boolean)`.**
- In pick order: positions 1–11 are the Playing XI, 12–15 the substitutes.
- Only the entering club's owner and the organizer's owner may read it.
- `member_active` is false once the player has left the club; the squad itself is a snapshot.

**`submit_tournament_registration(p_tournament_id uuid, p_club_id uuid, p_team_name text, p_team_id uuid, p_players jsonb, p_captain_member_id uuid, p_vice_member_id uuid, p_keeper_member_id uuid, p_agree_rules boolean)` → R (status `pending`)**

The flow's Submit Registration. Rules:
- the caller owns `p_club_id`, and the club is not the organizer;
- `p_agree_rules` must be true;
- `p_players` is a JSON array in pick order: `[{"member_id": "<club_members.id>", "selection": "playing" | "sub"}, …]`, with **exactly 11 playing + 4 sub** (the Team Builder's `SquadRules`) and no repeats;
- the captain, vice-captain and wicket-keeper are all optional and must be in the Playing XI; the captain and vice-captain must be different people;
- `p_team_id` is NULL (a new squad) or one of the club's **active** teams. A NULL or blank `p_team_name` with a team takes the team's name; otherwise the name is 1–40 characters;
- every player is an **active** member of the club and is not injured or unavailable on the **start date** (migration 19's rule);
- the tournament must be accepting registrations: effective status open (on or before the deadline day), fewer than `max_teams` approved, and no fixtures yet;
- one live (pending or approved) entry per club per tournament. A club whose entry was rejected or removed may enter again;
- one person plays for one live entry per tournament, even across two clubs;
- at most 64 pending entries per tournament, and 20 submissions per club in 24 hours.

The organizer's owner is notified (`tournament_registration_received`).

**`decide_tournament_registration(p_registration_id uuid, p_approve boolean)` → R**
- Organizer's owner only, and only on a pending entry.
- Approve: refused once fixtures exist, or when `max_teams` are already approved. The approval that fills the last slot sets the stored status to `registration_full`.
- Reject: always possible while the entry is pending.
- The tournament row is locked, so two approvals for the last slot run one after the other.
- The entering club's owner is notified (`tournament_registration_approved` or `tournament_registration_rejected`).

**`remove_tournament_team(p_registration_id uuid)` → R (status `removed`)**
- Organizer's owner only, on an approved entry, only **before fixtures**.
- A `registration_full` tournament goes back to `registration_open`.
- The club's owner is notified (`tournament_team_removed`).

The app offers no "withdraw", so the server has none.

**`my_tournament_registrations(p_club_id uuid, p_status text default null)` → `TABLE(registration_id uuid, tournament_id uuid, tournament_name text, organizer_club_id uuid, organizer_name text, tournament_city text, ground text, start_date date, end_date date, tournament_status text, team_id uuid, team_name text, status text, submitted_at timestamptz, decided_at timestamptz, player_count integer)`**
- Owner only; newest first.
- `p_status` is one of `pending`, `approved`, `rejected` or `removed`, or NULL for all.
- `tournament_status` is the effective status.

### The draw, fixtures, points, awards

**`generate_tournament_fixtures(p_tournament_id uuid)` → `TABLE(outcome text, fixture_count integer)`**

A server port of `FixtureEngine.generate`. It needs at least 2 approved teams, seeded in **approval order** (`decided_at`).
- **Knockout:** the draw is padded to the next power of two with BYEs at the end. First-round pairs are (1,2), (3,4) and so on. Round names run, last round first: Final, Semifinal, Quarterfinal, Round of 16, Round of 32. BYE walkovers are resolved at once (`_autoAdvanceByes`, no points); a BYE against a BYE produces a BYE.
- **League:** one round, "League Stage", with every pair once, in the order (i<j).

Effects:
- the stored status becomes `registration_closed`;
- entries still pending are **rejected**, and their owners notified;
- every approved club's owner is notified (`tournament_fixtures_published`).

Outcome is `generated`. A second call changes nothing and returns `already_generated` (`FixturesOutcome.alreadyGenerated`). Organizer's owner only.

**`tournament_fixtures(p_tournament_id uuid)` → `TABLE(fixture_id uuid, round_no integer, round_name text, match_no integer, home_registration_id uuid, home_club_id uuid, home_name text, home_bye boolean, away_registration_id uuid, away_club_id uuid, away_name text, away_bye boolean, winner_registration_id uuid, winner_bye boolean, state text, next_fixture_id uuid, next_slot text, match_id uuid, decided_at timestamptz)`**
- Any signed-in user; in draw order (round, then match).
- A side is an entry, a BYE (`*_bye`), or TBD (id NULL and not a BYE).
- `state` is one of:
  - `tbd`: a side is still unknown;
  - `ready`: both teams are known;
  - `walkover`: a BYE fixture that has been decided (hide these, as `flattenFixtures` does);
  - `completed`: decided by an official result.
- `home_name` and `away_name` are club names (`entrantLabel`).
- Group the rows by `round_no` into `FixtureRound`s.

**`tournament_points_table(p_tournament_id uuid)` → `TABLE("position" integer, registration_id uuid, club_id uuid, club_name text, team_name text, played integer, won integer, lost integer, points integer)`**
- Every approved team, 2 points per win, decided non-BYE fixtures only.
- Ordered by points, then club name (`standingsTable`); zeros before any result.
- Any signed-in user.

**`tournament_awards(p_tournament_id uuid)` → `TABLE(award text, registration_id uuid, club_id uuid, club_name text, member_id uuid, player_name text, value integer, matches_counted integer)`**

Built **only** from the confirmed (official) scorecard of fixtures linked to a match (`match_id`, migrations 20–24). With no linked official result it returns **no rows**: show "Awards will appear once results are official". The app must **not** use `DemoTournamentAwards` in Supabase builds.

There is one row per award whose value is above 0:

| Award | Value |
| --- | --- |
| `top_run_scorer` | Runs |
| `top_wicket_taker` | Wickets |
| `best_keeper` | Catches + stumpings, by a squad-flagged wicket-keeper or anyone with a stumping |
| `best_fielder` | Catches |

- Ties go to the player's name.
- Players with `show_stats = false` are left out.
- Readers: owners and active members of the organizer club or of an approved club. Anyone else gets `42501 not allowed`.

### Trusted scorer only (service_role; never the app)

**`record_tournament_fixture_result(p_fixture_id uuid, p_winner_registration_id uuid, p_match_id uuid default null)` → `TABLE(fixture_id uuid, tournament_status text, champion_registration_id uuid)`**

EXECUTE is granted to service_role only. It is meant for the future scorer Edge Function, the same model as migration 24.
- **Fixture:** it must be `ready`. The winner must be one of its two entries.
- **Optional `p_match_id`:**
  - it must be a match between exactly these two clubs;
  - it must not already be linked to another fixture;
  - it must have a **confirmed** result, and a won result must name the same club.
- **Moving on:** the winner moves to the next fixture. In a knockout, BYEs are resolved again.
- **Completion:** a knockout completes when its Final is decided. A league completes when every fixture is decided, and its champion is the points-table leader. Either way the tournament gets status `completed`, a winner and `completed_at`.
- **Repeats:** the same call again changes nothing. A different winner for a decided fixture is refused.

No table is writable by any API role, service_role included.

### Errors

| SQLSTATE · message | When |
| --- | --- |
| `42501 permission denied for function …` | anon; authenticated calling `record_tournament_fixture_result` |
| `42501 tournament: not authenticated` | no signed-in user (every app function) |
| `42501 tournament: not allowed` | not the club's owner (create, hosted, hub, submit, my registrations); not the organizer's owner (decide, remove, generate); squad of someone else's entry; awards for non-participants |
| `22023 tournament: invalid name / invalid city / invalid ground / invalid format / invalid overs / invalid type` | create (`invalid city` also browse) |
| `22023 tournament: invalid start date / start date in the past / start date too far ahead` | create |
| `22023 tournament: invalid end date / end date before start date / tournament too long` | create |
| `22023 tournament: invalid deadline / deadline in the past / deadline after start date` | create |
| `22023 tournament: invalid max teams / invalid entry fee / invalid prize / invalid description / invalid rules` | create |
| `22023 tournament: rules not agreed / invalid squad / invalid captain / invalid vice-captain / invalid wicket-keeper / invalid team / invalid team name` | submit |
| `22023 tournament: invalid decision / invalid status / invalid winner / invalid match` | decide / my registrations / scorer |
| `23514 tournament: squad must be 11 + 4 / player not in club` | submit |
| `P0001 tournament: too many tournaments / too many tournaments, try later` | create limits |
| `P0001 tournament: own tournament / team archived / registration closed / registration full / already registered / player unavailable / player already registered / too many requests / too many registrations, try later` | submit |
| `P0001 tournament: not pending / registration full / fixtures generated` | decide |
| `P0001 tournament: not approved / fixtures generated` | remove |
| `P0001 tournament: not enough teams` | generate |
| `P0001 tournament: fixture not ready / fixture already decided / match already linked / no official result / winner differs from the official result` | scorer |
| `P0002 tournament: not found / registration not found / fixture not found` | unknown ids |

Checks run in this order: authentication, then ownership, then the tournament's existence, then input, then state.

### Notifications

Five new types, written through the internal `notification_add` (migration 26, unchanged), so muting applies and nobody is told of their own action. All go to the **`club_owner`** inbox. All 29 earlier types are kept, 34 in total.

| Type | Recipient | Category (mutable) | `club_id` / `subject_id` | `params` |
| --- | --- | --- | --- | --- |
| `tournament_registration_received` | organizer's owner | `join_requests` | organizer club / registration | `tournament_id, tournament_name, applicant_name, team_name, start_date` |
| `tournament_registration_approved` | entering club's owner | `challenges` | entering club / registration | `tournament_id, tournament_name, organizer_name, team_name, start_date` |
| `tournament_registration_rejected` | entering club's owner (also when the draw rejects a pending entry) | `challenges` | same | same |
| `tournament_team_removed` | entering club's owner | `challenges` | same | same |
| `tournament_fixtures_published` | each approved club's owner | `matches` | that club / tournament | `…, team_name, start_date, round_name` (first round) |

The dedupe keys are:
- `tournament:registration:<reg>` (received);
- `tournament:decision:<reg>` (approved or rejected);
- `tournament:removed:<reg>`;
- `tournament:fixtures:<tournament>:<reg>`.

The push text (templates.ts) uses these titles:

| Type | Title | Line |
| --- | --- | --- |
| received | "Tournament entry from {applicant}" | tournament · team |
| approved | "Tournament entry approved" | tournament · team |
| rejected | "Tournament entry not accepted" | tournament · team |
| removed | "Team removed from tournament" | tournament · team |
| fixtures | "Tournament fixtures published" | tournament · round · "Starts {date}" |

## Tables (closed: RLS on, no policy, no grant to anon / authenticated / service_role)

- **`tournaments`** holds every form field, with CHECKs that mirror the Dart validation:
  - `organizer_club_id` → clubs, **CASCADE**;
  - `created_by` → profiles, SET NULL;
  - the stored status; `winner_registration_id` (its own entry, SET NULL); `fixtures_generated_at`, `completed_at`;
  - a CHECK that the deadline is not before the creation day (Karachi). `city` is free text like `clubs.city`.
- **`tournament_registrations`:**
  - `tournament_id` and `club_id`, both **CASCADE**;
  - `team_id` → teams, SET NULL; the `team_name` snapshot;
  - the status, `rules_agreed_at`, `submitted_by` / `submitted_at` and `decided_by` / `decided_at`;
  - a partial unique index for one live entry per club; a trigger refusing the organizer's own club and another club's team.
- **`tournament_registration_players`:**
  - `registration_id` and `member_id` → club_members, both **CASCADE**;
  - `selection`, `position` 1–15 and the captain, vice-captain and keeper flags;
  - one of each flag, and only on Playing XI players; a trigger requiring an active member of the entry's club.
- **`tournament_fixtures`:**
  - `round_no`, `round_name`, `match_no`;
  - the home, away and winner entries (composite FK to the same tournament's entries, SET NULL on that column) plus the BYE flags;
  - `next_fixture_id` (CASCADE) and `next_slot`;
  - `match_id` → matches (SET NULL, unique), `decided_at`.

Deletion:
- **Deleting an account** removes that person's squad places; the entries stay.
- **Deleting a club** removes its tournaments and entries. Other tournaments' fixtures keep the slot, now empty. Notifications lose `club_id`.
- **Official matches and results** are never touched.
- `delete_account_data` is unchanged.

## Deviations and notes

- The stored statuses are the UI's four (`registration_open / _full / _closed / completed`). There is no draft, in_progress or cancelled status: the UI has none.
- `removed` is a separate registration status; the app showed removal as "rejected". There is no `withdrawn` status or withdraw RPC: the UI offers neither.
- **The squad must be exactly 11 + 4**, as for server match line-ups (migration 18). "Select Existing Team" therefore needs a team with 11 + 4 available players, the same as `useTeam` for server matches.
- **Generating the draw:**
  - it rejects still-pending entries (the prototype left them hanging);
  - it sets `registration_closed` even from `registration_full` (the Dart engine kept full).
- **Removed members:** a member removed from the club stays in a submitted squad (`member_active = false`). Account deletion removes them.
- **Result corrections:** a recorded fixture winner is final in CricEco. A later official correction of the linked match changes the awards, since they are computed live, but not the bracket.
- **Server-only limits:** the start is within 365 days and the duration at most 180 days.
- **Push text:** `templates_test.ts` now expects 34 types.

## Local verification (2026-11-26)

The container was a throwaway `criceco-m10-test` (`public.ecr.aws/supabase/postgres:17.11.0.018`), removed afterwards. It held two databases:
- `postgres`: real Supabase auth, with the fixture copy without its auth guard;
- `m10plain`: `00_auth_stub.sql` + `02_legacy_profiles_fixture.sql`.

Both got migrations 1–34 from an explicit list (D1 seed after 6, the Storage stand-in before 31), then 35.

| Check | Result |
| --- | --- |
| Migration 35 | Applies on both; self-check passed |
| Guards (on copies of `m10plain`) | Refused when already applied, without migration 33 (`hunt_invites` missing), and over a drifted `notification_category`. Template copies of `postgres` are impossible (open connections), so the guards were not re-run there |
| Local 30 | **240/240** on both databases, before and after the rollback + re-apply. It covers access, anon and no-session calls for every RPC; direct table reads and writes (authenticated and service_role); every create rule and boundary; the limits; browse (own club excluded, city filter) and visibility; the squad rules; availability; one person per tournament; the deadline in Karachi (on the day / after it); capacity; approve, reject and re-enter; remove and re-open; the draw for knockout sizes 2–9, 12, 16, 17, 31 and 32 (count, names, seeding, n−1 real matches, BYE walkovers moved on); exact 3-, 5- and 6-team brackets; leagues of 2–32; idempotent generation; pending entries rejected; scorer-only results; the knockout and league champions; the points tables; match linking rules; awards from an official scorecard (and empty without one; show_stats respected; access); notifications created, categorised and muted; account and club deletion cascades |
| Two-session races (scratch harness, `m10scratch`) | Two approvals for the last slot: the second waited and got `registration full`. A submission during the draw: `registration closed`. The same club submitting twice at once: `already registered`, one row |
| Post-check 35 | **14 PASS + 1 INFO** (before the migration and after the rollback it shows FAIL) |
| Regression with 35 | Local 20 (92), 21 (27), 22 (44), 23 (22), 24 (30) and 25b (2) pass on fresh copies of `m10plain`. Local 26: 118 (`postgres`). Local 27 (121) and 29 (99) pass on both. Local 25: J3 fails (historical since 31); the scratch copy with J3 updated passes 81 on both. Local 28: **I3 now fails**, because it asserts exactly 29 notification types and 35 adds 5 (by design, the same pattern as 25 J3). A scratch copy with I3 = 34 passes 152 on both (not committed) |
| Rollback | Empty and with committed data: it printed "3 tournament(s), 6 entr(y/ies), 15 squad place(s), 1 fixture(s)" and "4 tournament notification(s) deleted". The catalogue (public + storage functions with body md5, ACL and settings; relations with RLS / ACL; columns; constraints; indexes; triggers; policies) is **identical to 1–34 (0 diff lines)** on both databases. A second rollback is refused |
| Re-apply | The catalogue is identical to the first apply (0 diff lines); local 30 and the post-check pass again |
| `node --test supabase/functions/push-dispatch/*_test.ts` | 29 pass, 0 fail, 2 skipped (the live FCM checks need `FCM_LIVE_SERVICE_ACCOUNT_FILE`) |
