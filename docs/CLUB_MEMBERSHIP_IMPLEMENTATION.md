# Club memberships (migration 11)

**Status:** the code is done, tested against fakes, and **validated on a disposable PostgreSQL 17.11** (see below). **The migration isn't applied to production or the local stack.** The app uses it only when built with `CRICECO_MEMBERSHIPS=true`, after the migration is live.

## Database
`supabase/migrations/20261116090000_create_club_memberships.sql`. Rollback: `supabase/rollback/20261116_rollback_club_memberships.sql` (run it after the teams rollback).

### Tables
| Table | Columns | Rules |
|---|---|---|
| `club_members` | `id`, `club_id → clubs` (cascade), `user_id → profiles` (cascade), `member_role` (`owner` / `player` / `coach` / `manager`), `status` (`active` / `removed`), `joined_at`, `removed_at`, `removed_by`, timestamps | `unique (club_id, user_id)`: one row per club and person, re-activated on re-approval. Exactly one `owner` row per club (partial unique index). Owner rows are always active. `removed_at` is set exactly when removed |
| `join_requests` | `id`, `club_id`, `user_id`, `status` (`pending` / `approved` / `rejected` / `cancelled`), `message`, `assigned_role`, `decline_reason` (≤120), `decided_at`, `decided_by`, timestamps | At most **one pending request per person, across all clubs** (partial unique index on `user_id`), matching the app's single Waiting for Approval flow. `decided_at` is set exactly when not pending. `assigned_role` is set exactly when approved. A reason only on rejection |
| `club_code_attempts` | `id`, `user_id`, `attempted_at` | Failed join-code attempts for the brute-force throttle. RLS on with **no policy and no grants**: only the functions read or write it. Rows older than a day are deleted as new ones arrive |

**Indexes:** member lookups by user and by (club, status); requests by (club, status, created_at) and by (user, created_at desc); plus the foreign-key columns.

**Owner rows:** a new trigger on `clubs` (`clubs_add_owner_member`, AFTER INSERT) adds the owner's row, and the migration backfills the existing clubs. This trigger is the only change to an existing table.

### Lifecycle
- **A request:**
  - `pending` → `approved`: the owner approves; the membership is created or re-activated.
  - `pending` → `rejected`: the owner declines.
  - `pending` → `cancelled`: the applicant withdraws it.
- **A membership:** `active` → `removed` (the owner removes the member). A removed person may apply again.

### Security model
- **RLS:**
  - **SELECT:** a person sees their own rows; a club owner sees their club's rows (`is_club_owner()`).
  - **INSERT / UPDATE / DELETE:** none for `anon` or `authenticated`.
- **Writes:** only through `SECURITY DEFINER` functions with `search_path = ''`. Each takes the caller from `auth.uid()`; no client-supplied user id or role is ever trusted.

| Function | Who | What |
|---|---|---|
| `lookup_club_by_code(code)` | signed in | name, city, type, member count, and the caller's own status. **Never the owner or the code**. An unknown or malformed code returns no row and counts as a failed attempt |
| `request_to_join_club(code, message?)` | signed in, profile complete | Refuses: own club, already a member, a pending request to any club. An unknown code returns **NULL** (counted; not raised, so the record isn't rolled back). Concurrent duplicates are caught by the unique index |
| `cancel_join_request(id)` | the applicant | pending → cancelled |
| `decide_join_request(id, approve, role, reason?)` | the club's owner | Locks the row (`FOR UPDATE`); an already-decided request comes back unchanged; approval upserts the membership with `player` / `coach` / `manager` |
| `remove_club_member(member_id)` | the club's owner | never the owner row |
| `club_join_requests(club)` / `club_member_list(club)` | the club's owner | the applicant's or member's name, phone, **age** (never the date of birth), city and cricket details |
| `club_code_throttled(uid)` / `club_code_failed(uid)` | internal only (no app-role execute) | the throttle: **at most 10 failed codes per person per 15 minutes**, lookups and requests together; then `club_join: too many attempts` |
| `my_club_memberships()` / `my_join_requests()` | signed in | the caller's own rows, with club name and code |

**No role escalation:** approval never touches `profiles.role` or `user_roles`, and `owner` can't be assigned.

**Errors** start with `club_join:`. `SupabaseErrorMapper` turns them into `ClubCodeNotFoundException`, `ClubMembershipException(message)` or `PermissionDeniedException`, and the raw text is never shown.

## App integration
```
Enter Club Code / Join Club sheet / Waiting / Approved
  → JoinClubController (send, refresh, cancel)      Requests / Members / Member Profile
                         → ClubRepository  ←  JoinRequestsController, removeClubMember()
                           → SupabaseClubRepository (membership: MembershipGateway?)
                             → SupabaseMembershipGateway → rpc(...) → migration 11
```
- **Contract:** `ClubRepository` gained `myJoinRequest()`, `cancelJoinRequest()`, `myMemberships()` and `removeMember()`. The in-memory repository implements them for the demo.
- **Session:** in Supabase with the switch, `SessionController` loads the account's memberships from the database at sign-in and restore (`refreshMemberships()` after an approval). The demo keeps the run's list.
- **`ClubFeatures.joinByCode`:** true in the demo, and in Supabase only with the switch. Otherwise "Joining a club by code is coming soon".
- **Waiting for Approval:**
  - reads the stored request when it opens;
  - **Check Status** re-reads it, and an approval goes on to Request Approved;
  - a declined request shows the owner's reason and an "Enter Another Code" button;
  - Cancel withdraws it in the database first.
- **Join Requests:** an error state (a failed load is never shown as "no requests"); refusals show the database's reason.
- **Stored request at start-up:** with the switch on, the join controller loads the database's latest request when the session starts, so the screens and the one-pending rule hold after a restart.
- **Member Profile:** **Remove from Club** (not on the owner row), with a confirmation that explains the team consequences.
- **Owner adding members directly:** refused with the switch on (`addMember`). People join only by request.

## Activating it (each step needs separate approval)
1. Take a backup (`Backup-CricEcoProduction.ps1`).
2. Apply migration 11, then migration 12, each in `begin; set local lock_timeout='5s'; … commit;`.
3. Run `supabase/tests/12_memberships_teams_postcheck.sql`; every row must read OK.
4. Build with `--dart-define=CRICECO_MEMBERSHIPS=true`, plus the existing production defines.
5. Test on a device with two approved test accounts (each needs approval): send, approve, check status, remove, re-request.

## Tests
`test/club_membership_test.dart` (21), using `test/membership_fakes.dart`:
- valid, unknown and malformed codes;
- duplicate pending requests, own club, incomplete profile;
- cancel, then cancel again;
- the owner sees the applicant; approve once with no duplicate member;
- coach / manager allowed, owner refused;
- decline with a reason;
- non-owners blocked from reading, deciding and removing;
- the player pool; removal and re-activation;
- offline and signed-out failures;
- behaviour without the switch; row mapping.

`test/production_demo_mode_test.dart` runs the join controller end to end: send, approve, refresh, decline, cancel.

**The fakes model the functions' rules. The SQL itself is verified only once the migration is applied** (with the post-check).

## Disposable-database validation (2026-11-16)
Run on a throwaway `postgres:17-alpine` container (**PostgreSQL 17.11**, the production version). Data was held in memory only, with no volume and no published port, and the container was removed afterwards. Production and the local Supabase stack were not touched.

1. **Prerequisites:** `tests/local/00_auth_stub.sql`, `tests/local/02_legacy_profiles_fixture.sql`, then migrations 1–10 and the D1 location seed, each in one transaction.
2. **Migrations 11 and 12** applied in one transaction each: **no errors**. `tests/12_memberships_teams_postcheck.sql`: **11 of 11 OK**, before and after test data.
3. **`tests/local/10_memberships_teams_local_check.sql`:** **109 of 109 checks passed**. Synthetic accounts only; it refuses to run on a real Supabase project. It covers:
   - owner rows; lookups; the throttle (including the 15-minute window and the one-day clean-up);
   - one pending request per person; impersonation and non-owner attempts;
   - approve, decline, cancel; no role escalation; removal and re-joining (the same row is re-activated);
   - direct INSERT / UPDATE / DELETE blocked; internal helpers not callable; anonymous access; no session means "not authenticated";
   - teams: names, formats and overs, 11 + 4, duplicate players and positions, foreign members, captain and vice-captain, edits, non-owners, RLS, archive, and removed members leaving squads.
4. **Rollbacks:**
   - running 11 before 12 is refused; repeating either is refused;
   - after both, the catalog is **identical** to the post-migration-10 baseline (608 objects, zero differences);
   - existing clubs, profiles, player profiles and roles are kept;
   - re-applying after the rollback works and backfills the owner rows;
   - a second application, or 12 before 11, is refused.

## Known limitations
- No push notification when a request is decided. The applicant uses Check Status (notifications have no backend yet).
- **Brute force:** each account can try at most 10 wrong codes per 15 minutes (≈1,000 a day), against 32⁶ ≈ 10⁹ codes. An attacker with many accounts is limited by Supabase Auth's sign-up rate limits. Before a large public launch, also consider an Edge Function or gateway limit per IP (not possible from SQL alone) and watch `club_code_attempts` for abuse.
- Members can't leave a club themselves, and an owner can't change a member's role after approval. Not requested; easy to add as functions.
- Join requests carry no match history (`performance` is null) until match statistics exist.
- Applicants without a player profile appear with the model's default cricket fields (Batsman, right-handed) on the request card, because the model requires them.
