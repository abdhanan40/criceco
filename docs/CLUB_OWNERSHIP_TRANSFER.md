# Club ownership transfer (migration 16)

**Status (2026-11-18):** implemented and tested; **not applied to production.** It was validated on a disposable PostgreSQL 17.11. The app uses it only with `CRICECO_MEMBERSHIPS=true` **and** `CRICECO_ACCOUNT_PRIVACY=true`, the account-controls release (migrations 13–16 and the `delete-account` function). Apply migration 15 first.

## Rules
| Rule | Where it is enforced |
|---|---|
| Only the club's **current owner** offers the club | `offer_club_ownership`: `clubs.owner_id = auth.uid()` under a row lock |
| The recipient is an **active member of that club**, not the owner, **owns no club** (one club per owner), with a **completed profile** | `ownership_recipient_problem`, checked on offer **and again** on accept |
| **Nothing changes until the recipient accepts** | Only `accept_ownership_transfer` writes `clubs`, `club_members` or `user_roles` |
| One open offer per club; no self-transfer | Unique partial index `club_ownership_transfers_one_pending_key`; the eligibility check; `club_ownership_transfers_not_self` |
| Decline (recipient), cancel (owner), expiry after 7 days | `reject_…` / `cancel_…`; expiry is marked lazily, and an expired offer accepted returns `expired` and changes nothing |
| Atomic hand-over | One transaction. Locks: both profiles (by id, the same first step as account deletion), then the offer, the club and the membership. Then the old owner's membership becomes the role they chose (manager, coach or player; manager by default), the recipient's becomes owner, `clubs.owner_id` and `owner_name` move, and `user_roles` follow |
| Permissions move with it | Every owner check reads `clubs.owner_id` (`is_club_owner`, the clubs, members, requests and teams policies, all owner functions) |
| Club data is kept | Members, join requests, teams, squads, captains, and future matches keep their ids; nothing is copied or deleted |
| History | `club_ownership_transfers` (who, to whom, role, status, when). Readable by the club's current owner and by the two people of each offer. If a person later deletes their account, their reference becomes `NULL` and the row stays |

Every function is `SECURITY DEFINER` with an empty `search_path`, checks `auth.uid()`, and is executable by `authenticated` only. App roles have no INSERT, UPDATE or DELETE on the table, and still no UPDATE on `clubs.owner_id`.

## Account deletion
- After a successful transfer the former owner owns nothing, so migration 15 lets them delete their account; the new owner is now the protected one.
- The club, its teams and the transfer history stay.
- The Delete Account screen sends owners to **Transfer Ownership**.

## App
| Who | Where | What |
|---|---|---|
| Owner | My Club → **Transfer Ownership** (`/club/my-club/transfer`) | Pick a member and your role afterwards; **Send Offer** (with a confirmation). The open offer shows with **Cancel Offer**; History lists every offer. If the offer was accepted while you were signed in: "*X* is now the owner" → **Continue** (switches to Player and re-reads the account) |
| Member | Player Dashboard banner → **Club Ownership Offers** (`/player/ownership-offers`) | **Accept** (with a confirmation): the club becomes theirs, the account is re-read, and they continue as Club Owner. **Decline** leaves everything unchanged |
| Owner, Delete Account | "Transfer your club first" | Button to Transfer Ownership |

Each screen has loading, error-with-retry and empty states. Refusals show the database's reason (`OwnershipTransferException`): an open offer already exists, the member owns a club, the profile is incomplete, the offer was already answered, and so on.

**Code:**
- `lib/features/club/ownership/` (controller and both screens);
- `OwnershipTransferRepository`, with `SupabaseOwnershipTransferRepository` and `UnavailableOwnershipTransferRepository`;
- `OwnershipGateway` / `SupabaseOwnershipGateway`;
- `ownershipTransferAvailableProvider`;
- `SessionController.reloadAccount()`.

## Files
| Area | Files |
|---|---|
| Migration | `supabase/migrations/20261118090300_create_club_ownership_transfers.sql` |
| Rollback | `supabase/rollback/20261118_rollback_club_ownership_transfers.sql`. Removes the feature **and its history**; accepted transfers stay in effect |
| Read-only check | `supabase/tests/16_ownership_transfer_postcheck.sql` (10 rows) |
| Local test | `supabase/tests/local/13_ownership_transfer_local_check.sql` (53 checks, synthetic accounts) |
| App tests | `test/ownership_transfer_test.dart` (13), `test/ownership_fakes.dart` |
| Production package | `C:\Users\NEW TECH\CricEco-Backups\migration-16\` (preflight, apply, verify, rollback, checklist) |

## Validation (2026-11-18, PostgreSQL 17.11, migrations 1–15)
- **Migration 16:** post-check 10/10 PASS. Post-checks 15 (10/10), 13 (10/10) and 12 (11/11) unchanged.
- **Local tests:** `local/13` 53/53; `local/12` 31/31; `local/10` 110/110.
- **Rollback:** restores the function catalogue exactly (same hash, 45 functions). Re-apply works, and a second apply is refused.
- **Package rehearsal:** preflight 5/5, verify 10/10; after the rollback the preflight was identical.

## Known limits
- **No push notification:** the recipient sees the offer on the Player Dashboard the next time it loads.
- **Stale session:** the former owner's open session keeps showing the club until it is re-read (the Transfer Ownership screen offers Continue; a restart also does it). Owner actions are refused by the server meanwhile.
- **Old acceptances:** an offer accepted before migration 16 is rolled back stays in effect; only the feature and the history go.
