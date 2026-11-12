# CricEco — Supabase schema (ERD v8)

## Live status (2026-11-09)

| Item | Live state |
|---|---|
| Migrations 1–4 | **Applied** to the live project (PostgreSQL 17.11) on 2026-10-28, manually in the SQL Editor, one file per query in filename order, each wrapped in `begin;` / `set local lock_timeout = '5s';` / `commit;` |
| Verification (1–4) | Preflight and `01_verify_schema` passed; `02_rls_check` and `03_constraints_check` passed with two temporary test users, which were deleted afterwards; the 5 pre-existing profiles stayed unchanged (fingerprint matched before and after) |
| Migration 5 (`clubs`) | **Applied** to the live project in the SQL Editor, the same way (`begin;` / `set local lock_timeout = '5s';` / `commit;`) |
| Verification (5) | `00d_preflight_clubs` passed beforehand (all 15 checks); afterwards `public.clubs`, its 4 functions and 3 policies were present; `04_clubs_rls_check` and `05_clubs_constraints_check` passed with two temporary test users, which were deleted afterwards; the 9 existing profiles stayed unchanged (fingerprint matched before and after) |
| `review/…_REVIEW.sql` | **Not applied** — the guard is still in place; a separate, later decision |
| `rollback/…` | **Never run** on the live project (the clubs rollback was tested locally only) |
| Flutter app | Uses `profiles`, the address tables, `player_profiles` and `save_profile_setup()` in Supabase mode; `clubs` from Stage 3 |
| Migration 6 (`locations`, Stage 4.2) | **Not applied.** Tested locally only (PostgreSQL 17.11: apply → tests → rollback → clean → re-apply) |
| Location seed (D1) | **Not loaded on the live project.** Data review approved for local testing; loaded locally (twice: idempotent, stable ids) and checked with `07` |
| Migration 7 (`user_roles`, Stage 4.2) | **Not applied.** Tested locally only (fixture → apply → `06b` / `08` → regression → rollback → re-apply) |
| Migration 8 (address `city_id`, Stage 4.3.3) | **Not applied.** Tested locally only (fixture → `00f` preview → apply → `09` / `07b` → regression → rollback → re-apply) |
| Migration 9 (`update_profile_details`, Stage 4.3.6a) | **Not applied.** Tested locally only (refused without 8 → apply → guard → `10` / `local/08` / `local/08b` (two-session locking) → regression 01–09 → rollback → re-apply) |

The migration files are kept exactly as applied — their `NOT APPLIED` header
lines predate the live runs and are left unchanged. Applied versions
(SHA-256 prefix): `eb0cd25cdd55d447`, `d92c8c1275d9ab0f`, `13468f9a1258cb01`,
`b0f23f215fb7a54a`; migration 5: `dead73a7e9a8c1e6`. The SQL Editor stored
the function bodies of 1–4 with CRLF line endings; with line endings
normalised they are identical to these files.

When running `02`–`05` again, copy the test users' UUIDs from Dashboard →
Authentication → Users (copy button) rather than retyping them: a mistyped
UUID points the tests at a user that doesn't exist and they fail misleadingly.
`04` needs two fresh test users (Profile Setup not done, role NULL); `05`
needs one (user A can be reused after `04`, which rolls everything back).

The live project already has `public.profiles` (5 rows). The migrations
**adopt** it: the table, its rows, columns, policies and grants are kept;
migrations 1–4 only add columns, tables, functions and triggers.

| File | Purpose | Safe? |
|---|---|---|
| `tests/00_preflight.sql` | Read-only: same-named tables / functions / triggers | read-only |
| `tests/00b_inspect_existing_profiles.sql` | Read-only: existing profiles columns, constraints, policies, grants, triggers; data counts (no personal data) | read-only |
| `tests/00c_profiles_fingerprint.sql` | Read-only: count + hash of the existing rows — run before and after | read-only |
| `migrations/20261027090000_create_profiles.sql` | Adopt profiles: +3 columns (+ a CHECK on the new date_of_birth), validation / timestamp triggers, sign-up trigger | additive |
| `migrations/20261027090100_create_addresses.sql` | `current_addresses`, `permanent_addresses` (+ RLS); completion needs both | additive |
| `migrations/20261027090200_create_player_profiles.sql` | `player_profiles` (+ RLS, role rules) | additive |
| `migrations/20261027090300_create_save_profile_setup.sql` | `save_profile_setup()` — Profile Setup in one transaction | additive |
| `review/20261027090400_profiles_hardening_REVIEW.sql` | A: CHECKs on existing columns, each added only if every existing row already complies (phone rule accepts legacy 03… spellings); B: grant tightening. **Guarded: aborts until reviewed** | review |
| `tests/01_verify_schema.sql` | Read-only catalog checks | read-only |
| `tests/02_rls_check.sql` | RLS behaviour (one transaction, rolled back) | rolled back |
| `tests/03_constraints_check.sql` | Constraints, triggers, phone normalisation, all-or-nothing save (rolled back) | rolled back |
| `tests/local/*` | **Local PostgreSQL only** (auth stub, legacy-table fixture + `02b` variant with a nullable `profile_completed`, cascade and adoption checks; `04_clubs_local_check`: 300 clubs, unique join codes, role precedence, cascade) — refuse to run on Supabase | local |
| `rollback/20261027_rollback_profile_schema.sql` | Removes only what the migrations added; never drops `profiles` | destructive for added data |
| `tests/00d_preflight_clubs.sql` | Read-only: no clubs table / functions / policies yet; migration 5's prerequisites present | read-only |
| `migrations/20261109090000_create_clubs.sql` | Migration 5: `clubs` (one per owner, RLS own-row, column-level write grants); database-generated join code; Profile Setup required; `profiles.role` → `club_owner` (over `player`, never downgraded); `create_club()` in one transaction | additive |
| `tests/04_clubs_rls_check.sql` | Clubs RLS, grants, protected columns, `create_club()` and retry, role precedence (one transaction, rolled back) | rolled back |
| `tests/05_clubs_constraints_check.sql` | Every clubs value rule, `create_club()` inputs, boundary values, timestamps (rolled back) | rolled back |
| `rollback/20261109_rollback_clubs.sql` | Removes only what migration 5 added (every club); leaves `profiles.role` as it is | destructive for club data |
| `tests/00e_preflight_stage42.sql` | Read-only: Stage 4.2 objects absent, `pg_trgm` / schema `extensions` ready, prerequisites; reports city text values in use and `profiles.role` against the data rows (aggregates only) | read-only |
| `migrations/20261110090000_create_locations.sql` | Migration 6: `provinces`, `districts`, `cities`, `city_districts` (a city may span districts), `city_aliases`; `pg_trgm`; `location_search_key()`, `v_city_options` (security invoker), `search_cities()`; RLS: signed-in users read, no API writes. Starts empty | additive |
| `tests/06_locations_check.sql` | Location schema, keys, indexes, function properties and access rules; needs no test users (rolled back) | rolled back |
| `tests/local/05_locations_local_check.sql` | Local only: constraints and search behaviour on made-up rows (rolled back) | local |
| `seed/locations/` | GeoNames-derived location seed and its data script `apply_locations.sql` — see `seed/locations/README.md` | data (reviewed) |
| `rollback/20261110_rollback_locations_data.sql` | Deletes every location row (keeps the schema); refuses while other tables reference the location tables | destructive for location data |
| `rollback/20261110_rollback_locations.sql` | Removes only what migration 6 added (leaves `pg_trgm`); refuses while other tables reference the location tables | destructive for location data |
| `tests/07_locations_data_check.sql` | After the D1 load: counts, provenance, province names, the 20 featured cities, reviewed exclusions, search as a signed-in user (read-only, rolled back) | rolled back |
| `migrations/20261110090100_create_user_roles.sql` | Migration 7: `app_role`, `user_roles` (read own; no client writes); roles granted / removed by triggers on `player_profiles` and `clubs`; backfill from those rows (not from `profiles.role`, which is kept unchanged) | additive |
| `tests/08_user_roles_check.sql` | Part 1 read-only (schema, privileges, backfill = rows); part 2 with two fresh test users (grants, `create_club`, no role writes, RLS) — rolled back | rolled back |
| `tests/local/06a_user_roles_fixture.sql`, `tests/local/06b_user_roles_local_check.sql` | Local only: accounts in every role state before migration 7, then backfill, triggers, cascades and `create_club` | local |
| `rollback/20261110_rollback_user_roles.sql` | Removes only what migration 7 added; `profiles.role` untouched (roll back the app build that reads `user_roles` first) | drops the derived roles |
| `tests/00f_preflight_address_cities.sql` | Read-only: migration 6 + location data present, migration 8 objects absent; backfill **preview** per distinct city text (aggregates: rows, rule, city id) | read-only |
| `tests/00g_address_fingerprint.sql` | Read-only: count + md5 of every address row's city text, area, address, `created_at` and `last_updated_at` — run immediately before and after migration 8; the two must match | read-only |
| `migrations/20261110090200_add_address_city_id.sql` | Migration 8: nullable `city_id` (FK → `cities`, RESTRICT, indexed) on both address tables; `resolve_city_match()` / `resolve_city_id()` (featured → unique name → unique "Name (Qualifier)" → unique alias; else NULL); backfill (city text and `last_updated_at` untouched); two sync triggers per table — `address_city_sync_from_id()` (a written id, even unchanged, sets the plain name and wins; a cleared id with new text resolves the text) then `address_city_sync_from_text()` (text alone keeps the id while it still names that city, else re-resolves); `save_profile_setup_v2()` with city ids. v1 unchanged | additive |
| `tests/09_address_city_check.sql` | Part 1 read-only (schema, privileges, every id consistent with its text, report of NULL ids); part 2 with one fresh test user (v2 incl. "same as current", v1, both sync directions, the review cases: same id + plain or other-city text, label ↔ name, cleared id + new text; refusals; no write to another user's address) — rolled back | rolled back |
| `tests/local/07a_address_city_fixture.sql`, `tests/local/07b_address_city_local_check.sql` | Local only: address texts of every kind before migration 8, then the exact backfill, untouched text / timestamps, sync on insert, ambiguous alias, inactive city | local |
| `rollback/20261110_rollback_address_city_id.sql` | Removes only what migration 8 added (columns, triggers, functions); the address rows and their city text stay | drops the city ids |
| `migrations/20261111090000_create_update_profile_details.sql` | Migration 9: `update_profile_details()` — Edit Profile's save (full name, phone, date of birth, the existing current / permanent address rows) in ONE transaction, SECURITY INVOKER (RLS applies). Reads and locks the caller's rows (`FOR NO KEY UPDATE` — the lock an UPDATE takes — profile → current → permanent, as v1 / v2; a concurrent save waits and compares against the committed values; a foreign-key check on the profile — inserting a player profile or a user role — is not blocked; creating a club may wait: its trigger updates `profiles.role` only for a profile whose role is NULL or `player`, and that update waits for the save, without a deadlock; for a profile already `club_owner` nothing waits); no profile row → `profile not found` (P0002; the app shows its generic "couldn't save"). Checks and writes only what changed (an unchanged legacy phone / name is never re-checked; unchanged rows keep `last_updated_at`); every check before the first write. The phone may be cleared (blank; dashes alone are refused); the date of birth may be cleared (NULL, approved); the name can't. A supplied city id always wins (stored with its plain name, whatever text came with it); a NEWLY picked id must be an active city, the id a row already has is kept even if deactivated since; without an id, text only (migration 8 keeps / re-resolves the id). "Same as current" = the stored flag: the permanent row becomes a copy of the current row as stored after the save — exactly its city id (picked, kept or re-resolved; also NULL), its Area and Address, and its text (the city's plain name instead when migration 8 would not keep that text with that id, e.g. an alias of a city deactivated since); rows already in step are not written — so a drifted permanent row is brought back in step on the text-only path and with an id alike, never a reason to refuse. The stored phone is compared in the same canonical form as the one sent (values without digits with all whitespace removed: "- -" = "--"): a stored value sent back unchanged never blocks a save and is never rewritten. Never changes `profile_completed`, `role`, `permanent_same_as_current`; creates no address rows. No existing object changes | additive |
| `tests/10_update_profile_details_check.sql` | Part 1 read-only (function properties, privileges, the row locks (a TEXT check of the function's definition, `pg_temp.lock_clause_problem`, self-tested first on 33 crafted cases — 5 valid, 28 invalid, each invalid one reaching its own refusal: exactly the three `FOR NO KEY UPDATE` locks, in order, and no other `FOR UPDATE` / `FOR SHARE` / `FOR KEY SHARE`, `NOWAIT`, `SKIP LOCKED`, `LOCK [TABLE]`, advisory lock or dynamic SQL (`EXECUTE`); string literals and comments (a `--` comment ending at a line feed or carriage return, as in PostgreSQL) are replaced by a space in one left-to-right pass first, then matched whitespace-tolerantly; forms it does not parse are refused: E-strings, dollar quotes besides the body's own `$function$` pair (any tag, also with digits or letters beyond a–z), nested block comments and quoted identifiers. Limits: it checks only explicit `SELECT … FOR …` clauses and their textual order — it does not inspect the implicit row locks every `UPDATE` / `INSERT` / `DELETE` takes, nor locks acquired inside functions the body calls, nor whether a lock clause actually runs — and being strict it can refuse harmless code such as a `$x$` inside a comment; the actual row-lock behaviour is verified by the two-session test `local/08b`, locally only), the UPDATE privilege / policy on `profiles` the locks need, address grants / RLS / policies, v1 / v2 kept); part 2 with two fresh test users — checked fresh (bare sign-up profile: no name, no role, not completed, no rows) before anything is written — (unchanged → nothing written, name-only, phone clear / blank / dashes refused, date of birth saved / cleared, every refusal with the function's own message, new / same-named / text-only city, a supplied id wins over its text, separate permanent address, NULL address arguments, not signed in, anon refused by the missing execute privilege itself, no address rows, other users unchanged) — rolled back | rolled back |
| `tests/local/08_update_profile_details_local_check.sql` | Local only (psql, stops at the first error; its guard runs inside the transaction): no write is attempted before any check refuses (a counting trigger; current id and text paths, separate permanent address, name, phone, date of birth), inactive cities refused, `last_updated_at` kept / moved, legacy phone values neither rewritten nor blocking a name-only save, no profile row → `profile not found`, a drifted "same as current" permanent row never blocking a save and copied with exactly the current row's city id (also for a stale alias or the label of a deactivated city, and a NULL id whose text now resolves); digit-less phones compared without whitespace; each refusal by its exact message | local |
| `tests/local/08b_update_profile_details_locking.sh` | Local only, two concurrent sessions (`PSQL='docker exec -i … psql -U postgres -d <db>' bash …`): each step waits for a confirmed state in `pg_stat_activity` (no fixed sleeps decide a result). K1: while an unchanged save runs, another session's `FOR NO KEY UPDATE NOWAIT` and `FOR SHARE NOWAIT` are refused on all three rows (the save holds more than `FOR SHARE`), and the locks end with its transaction; K2: `FOR KEY SHARE NOWAIT` succeeds on all three rows (the save holds less than `FOR UPDATE`) and a `player_profiles` insert completes — together: exactly `FOR NO KEY UPDATE`; K3: a save blocked by a concurrent writer of the profile row or of the current address row compares against the committed value and writes nothing to that row (xmin; wait measured in SQL); K4: a compatibility smoke test with `save_profile_setup_v2` in either order (the second waits, both commit) — not a proof of deadlock-freedom, which rests on both functions locking profile → current → permanent (`10` checks only the explicit `FOR` clauses' textual order). Refuses on a real Supabase project (and on the Supabase CLI's local stack); only this database's sessions are used; commits one local test user and always deletes it again — test sessions are stopped first, a failed delete is reported as a failure, also after Ctrl-C | local |
| `rollback/20261111_rollback_update_profile_details.sql` | Removes only `update_profile_details()`; no data touched. Roll back the app build that calls it first, and run it **before** migration 8's rollback | removes the function |

Order: `00_preflight` → `00b` → `00c` (note the result) → migrations 1–4 in
filename order → `00c` again (must match) → `01` → `02` / `03` with test
users. Then, for migration 5: `00d` → `00c` (note the result) → migration 5
→ `00c` again (must match) → `04` / `05` with test users. The review
migration is a separate, later decision.

Stage 4.2 (each step separately approved):
1. `00e_preflight_stage42` (every check OK) and `00c` (note the result).
2. Migration 6.
3. `06_locations_check`.
4. The location seed `seed/locations/apply_locations.sql`, then `07`.
5. Migration 7, then `08`.
6. `00c` again (must match).
7. Only then, an app build that reads `user_roles`.

Rollback order, if ever needed: the data rollback, then `rollback/20261110_rollback_locations.sql`.

Stage 4.3.3, after Stage 4.2 is live (each step separately approved):
1. `00f_preflight_address_cities` (every check OK; note the backfill preview) and `00g_address_fingerprint` (note the result).
2. Migration 8 (its NOTICEs are the backfill report).
3. `00g_address_fingerprint` again, straight away — must equal step 1 (the backfill changed no city text, area, address or timestamp).
4. `09_address_city_check` with one fresh test user.
5. Only then, an app build that calls `save_profile_setup_v2` or reads `city_id`.

To roll back, run `rollback/20261110_rollback_address_city_id.sql` first; Stage 4.2's rollbacks refuse while `city_id` references `cities`. If migration 9 is applied, roll it back **before** this (below).

Stage 4.3.6a, after migration 8 (each step separately approved):
1. Migration 9 (it refuses without migration 8, and if the function already exists). Run it inside `begin;` / `commit;` — in the SQL Editor its guard then stops everything; with psql use `-v ON_ERROR_STOP=1`.
2. `10_update_profile_details_check` with two fresh test users.
3. Only then, an app build that calls `update_profile_details`.

**Rollback order: migration 9 FIRST — before the rollback of migration 8 (`rollback/20261110_rollback_address_city_id.sql`), of migration 6 (`rollback/20261110_rollback_locations.sql`, which itself needs migration 8 rolled back) and of migrations 1–4 (`rollback/20261027_rollback_profile_schema.sql`).** Roll back the app build that calls `update_profile_details`, then run `rollback/20261111_rollback_update_profile_details.sql`, and only then any of those. The reverse order does not fail — a plpgsql function records no dependency on the tables and columns it uses — but leaves `update_profile_details()` in place, failing on every Edit Profile save (e.g. `column "city_id" does not exist`, or a missing address table).

Rollback order, if ever needed: `rollback/20261109_rollback_clubs.sql`
**before** `rollback/20261027_rollback_profile_schema.sql` — `clubs` uses
`set_last_updated_at()` from migration 1, so the older rollback stops (and
changes nothing) while `clubs` still exists.

Run every file **whole** — never a highlighted part. If a file stops with an
error, run `rollback;` on its own before anything else. Tests 02–05 stop
by themselves unless they are running as the signed-in test user, and only
ever write the test users' rows.

Identity, email, phone sign-in, passwords and Google/Apple identities stay
in Supabase Auth. Only the project URL and the publishable (anon) key may
ever be used in the app.
