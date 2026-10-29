# CricEco — Supabase schema (ERD v8)

## Live status (2026-10-28)

| Item | Live state |
|---|---|
| Migrations 1–4 | **Applied** to the live project (PostgreSQL 17.11) on 2026-10-28, manually in the SQL Editor, one file per query in filename order, each wrapped in `begin;` / `set local lock_timeout = '5s';` / `commit;` |
| Verification | Preflight and `01_verify_schema` passed; `02_rls_check` and `03_constraints_check` passed with two temporary test users, which were deleted afterwards; the 5 pre-existing profiles stayed unchanged (fingerprint matched before and after) |
| `review/…_REVIEW.sql` | **Not applied** — the guard is still in place; a separate, later decision |
| `rollback/…` | **Never run** |
| Flutter app | Does not use these tables yet |

The migration files are kept exactly as applied — their `NOT APPLIED` header
lines predate the live run and are left unchanged. Applied versions
(SHA-256 prefix): `eb0cd25cdd55d447`, `d92c8c1275d9ab0f`, `13468f9a1258cb01`,
`b0f23f215fb7a54a`. The SQL Editor stored the function bodies with CRLF line
endings; with line endings normalised they are identical to these files.

When running `02` / `03` again, copy the test users' UUIDs from Dashboard →
Authentication → Users (copy button) rather than retyping them: a mistyped
UUID points the tests at a user that doesn't exist and they fail misleadingly.

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
| `tests/local/*` | **Local PostgreSQL only** (auth stub, legacy-table fixture + `02b` variant with a nullable `profile_completed`, cascade and adoption checks) — refuse to run on Supabase | local |
| `rollback/20261027_rollback_profile_schema.sql` | Removes only what the migrations added; never drops `profiles` | destructive for added data |

Order: `00_preflight` → `00b` → `00c` (note the result) → migrations 1–4 in
filename order → `00c` again (must match) → `01` → `02` / `03` with test
users. The review migration is a separate, later decision.

Run every file **whole** — never a highlighted part. If a file stops with an
error, run `rollback;` on its own before anything else. Tests 02 / 03 stop
by themselves unless they are running as the signed-in test user, and only
ever write the test users' rows.

Identity, email, phone sign-in, passwords and Google/Apple identities stay
in Supabase Auth. Only the project URL and the publishable (anon) key may
ever be used in the app.
