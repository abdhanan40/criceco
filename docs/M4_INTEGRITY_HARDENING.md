# M4 — integrity & security hardening (database half)

Migration 30 `supabase/migrations/20261126090000_m4_integrity_hardening.sql`. **Not applied to production.**

| File | Purpose |
| --- | --- |
| `supabase/migrations/20261126090000_m4_integrity_hardening.sql` | The migration (one transaction, guards, self-check) |
| `supabase/rollback/20261126_rollback_m4_integrity_hardening.sql` | Reverses all five parts; restores the earlier function bodies verbatim |
| `supabase/tests/30_m4_integrity_hardening_postcheck.sql` | Read-only post-check (15 PASS rows + 2 INFO) |
| `supabase/tests/local/25_m4_integrity_hardening_local_check.sql` | Local behaviour test (81 checks, one transaction, rolled back) |
| `supabase/tests/local/25b_m4_push_moves_concurrency.sh` | Local two-session test of the device-move limit |

## What changes

1. **profiles field rules** (review file §A), as CHECK constraints added `NOT VALID` and then validated in the same migration. Any existing row that breaks a rule stops the migration, and nothing changes.
   - `profiles_full_name_check`: NULL, or 2–100 characters after trimming.
   - `profiles_phone_check`: NULL, or a Pakistani mobile number in any spelling the app has stored (`03…`, `923…`, `+923…`, with spaces or dashes).
   - `profiles_role_check`: NULL, `player` or `club_owner`.
   - `profiles_validate()` gains one rule: a **completed** profile that has a phone cannot lose it (error 23514 `profile_completed requires phone`). This applies to direct updates and to `update_profile_details`. A legacy completed row that never had a phone stays editable. Table grants are unchanged.
2. **Teams optimistic concurrency.**
   - `teams.version` is an integer, NOT NULL, default 1, with a `>= 1` check.
   - `save_team` gets the optional `p_expected_version integer default null`. The old 7-argument function is dropped, so PostgREST sees one signature.
   - The team row is locked first. A non-NULL value that differs from the current version raises 40001 `team: changed elsewhere`.
   - Every successful save sets `version + 1`. A refused save changes nothing.
   - The order of checks is: not authenticated, not found, not allowed, archived, then version. A non-owner therefore never learns the version.
   - `create_team` and `archive_team` are unchanged (archiving keeps the version).
3. **Device-move limit.**
   - `register_push_device` allows a token that belongs to **another** person to move at most 3 times per caller in 24 hours. The 4th raises P0001 `push: too many device moves`.
   - Moves are recorded in `push_token_moves`. The table has RLS on, no policies, and no grants for anon, authenticated or service_role (its sequence is closed too).
   - New tokens and the caller's own token are never limited.
   - Locking:
     - the token row is locked with `FOR UPDATE`;
     - a token being first-registered by someone else at the same moment is waited for on its unique key, then locked and counted;
     - one caller's moves are counted one at a time, using `FOR NO KEY UPDATE` on their profile row (only on a move).
   - Rows older than 24 hours are pruned by `register_push_device` itself, so `notification_cleanup()` is deliberately not changed.
4. **`club_join_requests`** no longer returns declined requests (`status = 'rejected'`) decided more than 30 days ago. Its signature, columns and grants are identical.
5. **Indexes and keys.**
   - A full index `club_ownership_transfers_to_user_id_idx`.
   - `account_deletion_attempts.id` (`bigint` identity, primary key). Its grants stay closed and the new sequence is revoked.

The migration's guard refuses in two cases:
- It is already applied, or one of its names is taken.
- A function it replaces differs from its migration (2, 12, 13 or 27). It compares an md5 of the body with line endings ignored.

## App contract

- **RPC `save_team`:** takes the same 7 arguments plus `p_expected_version integer`, which is optional.
- **Conflict:** SQLSTATE `40001`, message `team: changed elsewhere`.
- **Version:** `teams.version` is readable through the existing `teams` select and is returned by `save_team`, `create_team` and `archive_team`.
- **Device moves:** `register_push_device` can now fail with P0001 `push: too many device moves`.
- **Phone on a completed profile:** clearing the phone of a completed profile fails with 23514 `profile_completed requires phone`, including through `update_profile_details`.
- **Invalid fields:** a direct write of an invalid name, phone or role fails with 23514, naming the constraint.

## Known effects and notes

- `tests/local/08_update_profile_details_local_check.sql` (L4b–L4d) seeds legacy phones that migration 30 now forbids, such as `+15551234567`, `---` and blanks. After migration 30 it stops at that seed. This is expected: those states can no longer exist.
- Club owners can still read their club's `join_requests` rows directly (RLS from migration 11). That gives ids, message and reason, but no applicant name, phone, age or city. The 30-day rule applies to the RPC, which is where those details are.
- A user can still set `profile_completed = false` and clear the phone in the same update. Un-completing a profile is not restricted.
- Rollback: first roll back any app build that sends `p_expected_version`. After the rollback, that argument no longer exists.

## Local verification

All runs used a throwaway container of `public.ecr.aws/supabase/postgres:17.11.0.018`:
- the `postgres` database, with real Supabase auth and Vault;
- plain databases with `00_auth_stub.sql`.

The steps were:
1. Migrations 1–29, then the regression checks.
2. Migration 30, then local checks 25 and 25b.
3. Post-check 30.
4. The rollback, then a catalogue diff against the 1–29 state (functions with body md5 and ACL, tables, columns, constraints, indexes, triggers, policies): identical.
5. Re-applying migration 30.
