# Phone privacy and account deletion

**Status (2026-11-18):**
- Migrations 13 (phone sharing consent) and 14 (account deletion data) are **applied to production**, as reported by the project owner after the read-only checks.
- **Migration 15 (club-owner protection and deletion throttle) is prepared, not applied.** It was validated on disposable PostgreSQL 17.11.
- The **`delete-account` Edge Function is not deployed.**
- The app uses all of this only when built with `--dart-define=CRICECO_ACCOUNT_PRIVACY=true` (default off).

> **Order matters.** Deploy the Edge Function only **after** migration 15. Migration 14's data step deletes the clubs an owner owns, and the function's own ownership check alone is not race-proof.

## Phone number privacy (migration 13)

### Before
Club owners always received the phone number of every member (`club_member_list`) and every applicant (`club_join_requests`). The app's "Show phone number" switch was stored on the device only, so it changed nothing.

### Policy (secure default)
| Rule | Decision |
|---|---|
| Consent | `profiles.share_phone_with_clubs`, **default `false`**. Existing users started at `false` |
| Who sees a shared number | Only the owner of a club the user belongs to, or has asked to join, through the owner-only functions |
| The owner's own row | Always shows the owner's own phone |
| Other applicant details | Name, age, city and cricket details stay visible to the club owner; only the phone needs consent |
| Changing it | `set_phone_sharing(p_share)` and `my_privacy_settings()`: `SECURITY DEFINER`, empty `search_path`, `auth.uid()` only, not executable by `anon` |
| Enforcement | In the database functions. The app shows "Not shared" when a number is hidden |

| Build | Settings → Privacy |
|---|---|
| Demo (memory) | "Share my phone number" switch, kept on the device |
| Supabase **with** `CRICECO_ACCOUNT_PRIVACY` | The switch, read from and saved to the server |
| Supabase **without** the switch | A note instead of a switch. **Since migration 13 is live, that note is no longer true; ship a build with the switch** |

## Account deletion

### Approved policy (2026-11-18)
- **Club ownership must be transferred before an account can be deleted.**
- An owner's club, its memberships, teams and other club data are **never** deleted as a side effect.
- Ownership transfer is migration 16 (docs/CLUB_OWNERSHIP_TRANSFER.md, not applied yet): until it is live, club owners can't delete their accounts. That is intended.

### Where it is enforced (defence in depth)
| Layer | What it does |
|---|---|
| App | The Delete Account screen shows "Transfer your club first" and no password form when the account owns a club. A server refusal switches to the same state. The repositories refuse owners before any request is sent |
| Edge Function | Checks for owned clubs **before** asking for the password and answers `409 {"error":"CLUB_OWNERSHIP_TRANSFER_REQUIRED"}` |
| `delete_account_data` (migration 15) | Takes `FOR UPDATE` on the profile row, then refuses (`P0001 account_delete: CLUB_OWNERSHIP_TRANSFER_REQUIRED`) if the user owns a club or holds an active owner membership. It **never deletes a club** |
| Trigger `profiles_protect_club_owner` (migration 15) | `BEFORE DELETE` on `profiles`: no club owner's profile can be deleted at all, including by deleting the Auth user in the Dashboard (the cascade fails). Without it, `clubs.owner_id … ON DELETE CASCADE` would silently delete the club |

**Race safety.**
- Creating a club for the user, or a future transfer **to** them, needs a `KEY SHARE` lock on the profile row (foreign key), so it waits for the deletion's `FOR UPDATE` and then fails.
- A transfer **away** from them that commits first is seen by the check, which runs after the lock.

**Direct API calls.**
- `delete_account_data`, `account_deletion_throttled` and `account_deletion_failed` are executable by `service_role` only.
- Signed-in users have no DELETE privilege on `profiles`.
- The local test checks direct calls, impersonation and direct deletes.

### Flow (non-owners)
1. Settings → **Delete account**. The screen lists what is deleted, then asks for the **password** and the word **DELETE**.
2. The app calls `delete-account` with the user's session:
   1. **Session:** identify the user from the session. An id in the body is ignored.
   2. **Ownership:** refuse club owners (409).
   3. **Throttle:** refuse after 5 wrong passwords in 15 minutes (429).
   4. **Password:** check it with a throwaway sign-in, then end only that session (`scope: "local"`).
   5. **Data:** call `delete_account_data`. It is idempotent and refuses owners under the lock.
   6. **Auth user:** call `auth.admin.deleteUser`, only after step 5 succeeded.
3. The app shows "deleted" only after the function returns `{deleted: true}`. It then forgets the session, local photo and settings and the saved role, and opens Login.

| Answer | App |
|---|---|
| 403 `invalid_password` | Error under the password field; nothing deleted (a throttle attempt is counted) |
| 409 `CLUB_OWNERSHIP_TRANSFER_REQUIRED` | "Transfer your club first" state; nothing deleted |
| 429 `rate_limited` | "Too many attempts — wait"; nothing deleted |
| 500 `auth_delete_failed` | "Your data was deleted, but closing your sign-in account didn't finish. Please tap Delete again." Still signed in; the retry completes it, because step 5 then does nothing |
| 500 `delete_failed` / offline | Generic error; nothing deleted (the data step is one transaction) |

### Retention (migrations 14 + 15)
| Data | What happens |
|---|---|
| Profile, addresses, player profile, roles, code attempts, deletion attempts | Deleted |
| Memberships of other clubs, join requests | Deleted. The player leaves those squads; a captain or vice-captain role they held is cleared |
| Other people's rows that only recorded this user (`decided_by`, `removed_by`, `granted_by`) | Set to `NULL` |
| **Clubs the user owns** | **Never deleted: deletion is refused while any is owned** |
| Auth user | Deleted by the Edge Function after the data |

## Edge Function security review (2026-11-18)
| Area | Finding |
|---|---|
| Session / JWT | `admin.auth.getUser(jwt)`, and the user id comes only from it. No impersonation: the body's fields other than `password` / `confirm` are ignored |
| Password | Re-checked server-side by `signInWithPassword` on a non-persisting anon client, which must return the same user id |
| **Fixed: sign-out scope** | The check's session was ended with `signOut()`, which defaults to the **global** scope and would have signed the user out of every device even when deletion was refused. It now uses `scope: "local"` |
| **Added: ownership** | 409 before the password is asked for, and authoritative in the database (migration 15) |
| **Added: throttle** | 5 wrong passwords per user per 15 minutes in `account_deletion_attempts` (service-role functions). Supabase Auth's own rate limit applies on top (429 is passed through) |
| Request validation | POST only (OPTIONS for CORS; anything else 405). JSON body; `confirm === "DELETE"`; password 1–72 characters |
| Order / idempotency | Data first (one transaction), then the Auth user; a retry after `auth_delete_failed` is safe |
| Secrets / logs | Only the built-in `SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY`. Nothing is logged; responses carry an error code only, with `Cache-Control: no-store` |
| CORS | `*`: the app is mobile, and the function still needs the user's JWT **and** password |
| Validation | Syntax-checked with Node 24 type stripping. **Types not checked: no Deno here.** `supabase functions deploy` bundles and type-checks it |

## Club ownership transfer (migration 16)
Implemented (not applied): the owner offers the club to an eligible member; only the member's acceptance moves the ownership. After that the former owner can delete their account. See docs/CLUB_OWNERSHIP_TRANSFER.md. The Delete Account screen links owners to Transfer Ownership in builds where it exists.

## Files
| Area | Files |
|---|---|
| Migrations | `supabase/migrations/20261118090000_create_phone_sharing_consent.sql` (13), `…090100_create_account_deletion.sql` (14), **`…090200_protect_club_owners_on_account_deletion.sql` (15)** |
| Rollbacks | 15: `supabase/rollback/20261118_rollback_protect_club_owners.sql` (restores migration 14's function exactly; **disable the function first**). Then 14, then 13 |
| Read-only checks | `supabase/tests/13_account_privacy_postcheck.sql`, **`15_club_owner_protection_postcheck.sql`** |
| Local tests (disposable DB) | `supabase/tests/local/11_account_privacy_local_check.sql` (migration 14 behaviour, run before 15), **`12_club_owner_protection_local_check.sql`** |
| Edge Function | `supabase/functions/delete-account/index.ts` |
| App | `lib/features/settings/delete_account_screen.dart`, `lib/app/config/account_privacy.dart`, `supabase_account_repository.dart`, `supabase_sdk_gateways.dart`, `supabase_gateways.dart`, `supabase_error_mapper.dart`, `account_errors.dart`, `in_memory_repositories.dart` |

## Disposable validation (2026-11-18, PostgreSQL 17.11)
- **Before 15:** migrations 1–14 match production (`delete_account_data` md5 `2162f8e3…63af`); `local/11` passed 33/33.
- **After 15:**
  - Post-check 15: 10/10 PASS. Post-check 13: 10/10 PASS. Post-check 12: 11/11 OK.
  - `local/12`: 31/31. `local/10`: 110/110.
  - Deleting an owner's Auth user is refused.
- **Rollback:** restores migration 14's function byte-identical. Re-apply works, and a second apply is refused.
- **Package rehearsal** (`CricEco-Backups\migration-15`): preflight 7/7, verify 11/11 with data unchanged; after the rollback the preflight was identical.

## Deployment (each step needs separate approval)
See `C:\Users\NEW TECH\CricEco-Backups\migration-15\DEPLOYMENT_CHECKLIST.md`.
