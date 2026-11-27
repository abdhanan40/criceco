# M5 media uploads and M6 privacy visibility (database half)

Migration 31 `supabase/migrations/20261126090100_m5_m6_media_and_visibility.sql`. **Not applied to production.** It needs migrations 1–30 and Supabase Storage.

| File | Purpose |
| --- | --- |
| `supabase/migrations/20261126090100_m5_m6_media_and_visibility.sql` | The migration (one transaction, guards, self-check) |
| `supabase/rollback/20261126_rollback_m5_m6_media_and_visibility.sql` | Reverses it; restores the three earlier function bodies verbatim; never deletes files |
| `supabase/tests/31_m5_m6_media_postcheck.sql` | Read-only post-check (13 PASS rows + 2 INFO) |
| `supabase/tests/local/26_m5_m6_media_local_check.sql` | Local behaviour test (118 checks, one transaction, rolled back) |
| `supabase/tests/local/26_m5_m6_media_local_check.sh` | `stub`: installs the local Storage stand-in; `check`: runs the SQL check |

## App contract

**Buckets**
- `avatars` and `club-logos`.
- Both private (`public = false`), 2 MiB, `image/jpeg`, `image/png` or `image/webp`.
- Read through the authenticated download or signed URLs. Public URLs don't work.

**Object names**
- The shape is `<folder>/<uuid>.<ext>`.
- `<folder>` is the user's id (avatars) or the club's id (club logos).
- `<uuid>` is a **lowercase** UUID.
- `<ext>` is `jpg`, `jpeg`, `png` or `webp`, also **lowercase**.
- Any other name is refused by the policies, the RPCs and the CHECK constraints.

**Storage policies** (signed-in users only; anon gets nothing)
- Any signed-in user may read both buckets.
- Insert, update and delete are allowed only:
  - in `avatars/<auth.uid()>/`;
  - in `club-logos/<club id>/` of a club the caller owns (`is_club_owner`).

**Setting the paths**
- `set_my_avatar(p_path text)`: NULL clears.
- `set_club_logo(p_club_id uuid, p_path text)`: NULL clears.
- A non-NULL path must be in the right folder and must already exist in its bucket.

| Error | Meaning |
| --- | --- |
| `42501 media: not authenticated` | No signed-in user |
| `42501 media: not allowed` | Another person's folder, another club's folder, or a club that is not the caller's (or doesn't exist) |
| `22023 media: invalid path` | Wrong shape or extension |
| `22023 media: file not found` | Not uploaded to that bucket |
| `P0002 media: profile not found` | `set_my_avatar` only: a signed-in user without a profile row |

**Columns**
- `profiles.avatar_path` and `clubs.logo_path` are readable through the existing selects.
- Neither is writable directly:
  - `clubs.logo_path` has no column grant, so a write fails with `42501 permission denied`.
  - `profiles.avatar_path` is guarded by the trigger `profiles_guard_avatar_path`, which raises `42501 media: avatar_path is set through set_my_avatar` for anon and authenticated.

**Privacy**
- `profiles.public_profile` and `profiles.show_stats` are `boolean NOT NULL default true`.
- They can be written directly on the user's own row, or through `set_profile_visibility(p_public_profile, p_show_stats)`. NULL leaves a value unchanged. Errors are `42501 privacy: not authenticated` and `P0002 privacy: profile not found`.
- Read them through the new `my_profile_visibility()`. It returns **one row** (`public_profile`, `show_stats`) for the caller's own profile, with the same two errors. anon has no access.
- `my_privacy_settings()` is **unchanged** (migration 13: a boolean, the phone consent). Installed app builds read it with `rpc(...) == true`. The guard, the self-check, post-check row 15 and local check E10 confirm that its body is still migration 13's.

**Extra last column**
- `club_member_list` and `club_join_requests` gain `avatar_path`. `club_join_requests` keeps migration 30's 30-day rule.
- `my_club_memberships` gains `club_logo_path`.
- Grants are unchanged: authenticated yes, anon no.

## Known effects and notes

- **Account deletion leaves the files.** `delete_account_data` and the `delete-account` Edge Function are unchanged and can't delete Storage objects. The profile goes, but `avatars/<uid>/` stays (local check K1).
  - The app should delete the user's avatar files through Storage before it calls `delete-account`, or a later job must remove them.
  - Replaced or cleared avatars and logos also stay until the app deletes the old file. The delete policy allows that.
- **Nothing enforces `public_profile` and `show_stats` yet.** They are stored preferences only. No current read path shows one player's profile or stats to another player. Any such view must honour them when it is built.
- **Avatars are readable by any signed-in user,** whatever `public_profile` says. This is part of the contract.
- **Historical checks that fail after migration 31, as accepted.** Local 25 J3 and post-check 30 row 14 assert `club_join_requests`'s exact columns from before migration 31. They describe the migration-30 state and are not changed. After migration 31, use local 26 E10 and post-check 31 row 10 instead.
- **Local 11 doesn't run to the end.** It already stops at `CLUB_OWNERSHIP_TRANSFER_REQUIRED` after migration 15, with or without migration 31.
- **Requirements of the applying role** (`postgres` in the SQL Editor):
  - It must bypass RLS and be able to read `storage.objects`. The guard and post-check row 12 check this.
  - It creates the `storage.objects` policies through `supautils.policy_grants`, as on any hosted project. This was checked locally on the real image.
  - `CREATE POLICY` takes a brief exclusive lock on `storage.objects`, covered by `lock_timeout = '5s'`.
- **The guard refuses in three cases:**
  - it is already applied, or a name is taken;
  - Storage is missing, or 1–30 are missing;
  - a function it replaces or uses differs from its migration (md5 of the body for 11, 13 and 30, and `is_club_owner`).
- **An existing bucket is kept.** If a bucket with the same id but a different configuration exists, the self-check refuses the whole migration.
- **Rollback:**
  1. First roll back any app build that uses the new functions.
  2. Then run the rollback. It drops the stored paths and visibility choices.
  3. It deletes a bucket only when the bucket is empty. Otherwise it keeps the bucket, private with no policy, and prints a NOTICE.

## Local verification

**Storage stand-in.** The Supabase image creates the `storage` schema but not its tables, which come from the Storage API service. `26_…sh stub` installs a minimal copy:
- what it includes: `buckets`, `objects` and `foldername` with the Storage API's definitions, owned by `supabase_storage_admin`, with the hosted grants (including `postgres WITH GRANT OPTION`);
- what it leaves out: Storage's own triggers (prefixes, delete protection).

**Containers.** Both were throwaway and have been removed:
- `criceco-m5-test` (`public.ecr.aws/supabase/postgres:17.11.0.018`), the `postgres` database;
- `criceco-m5-plain` (`postgres:17-alpine` 17.11), plain databases with `00_auth_stub.sql`. Local 08 refuses to run on the Supabase image.

**Steps.**
1. Migrations 1–30 and D1, then checks 08 (fixed), 22, 23, 24 and 25: all pass.
2. The guards refused when 31 was applied on top of 1–29, without Storage, over a drifted function, and over a pre-existing public bucket.
3. Migration 31, then local check 26: 118/118.
4. Post-check 31: 13 PASS.
5. Checks 08, 10, 12, 13, 22, 23 and 24, plus 25 with J3 updated to the new column: all pass.
6. The rollback:
   - with a file left in a bucket: that bucket is kept, with a NOTICE;
   - with empty buckets: both are deleted.
   - The catalogue (public and storage functions with body md5 and ACL, tables, columns, constraints, indexes, triggers, policies) was identical to the 1–30 state both times.
7. Re-applying 31 gives a catalogue identical to the first apply, and 26 passes again.

**Check 08 edit.** `tests/local/08_update_profile_details_local_check.sql` L4b–L4d used to seed phones that migration 30 forbids. Its seeds are now valid numbers in other spellings. The profile is un-completed at the L4b seed, so the clear paths of `update_profile_details` are still exercised. It passes 12/12 both on 1–29 and after 30.
