# M8 — Player Hunt / Playing Opportunities (database, migration 33)

Status: **written and tested locally, NOT applied to production.** Applying it needs separate approval, a fresh backup, and `begin; set local lock_timeout = '5s'; <file> commit;`.

| File | Purpose |
|---|---|
| `supabase/migrations/20261126090300_m8_player_hunt.sql` | migration 33 |
| `supabase/rollback/20261126_rollback_m8_player_hunt.sql` | rollback |
| `supabase/tests/33_m8_player_hunt_postcheck.sql` | read-only post-check (12 PASS + 1 INFO) |
| `supabase/tests/local/28_m8_player_hunt_local_check.sql` | local check (disposable DB only) |
| `supabase/functions/push-dispatch/templates.ts` (+ `templates_test.ts`) | push wording for the 3 new types |

Requires migrations 1–31. **Independent of migration 32** (club discovery): it neither uses nor touches anything of 32. If a later migration also replaces `notifications_type_check` or `notification_category`, it must start from migration 33's versions (md5 below), and the 33 guard refuses to run on top of a different version.

## What the UI needs, and how the server provides it

The source of truth is the current UI (`player_hunt_screen.dart`, `open_matches_screen.dart`, `availability_screen.dart`, `player_status_sheet.dart`, `player_hunt_controller.dart`, `player_providers.dart`) and `InMemoryHuntRepository`.

| UI | Server |
|---|---|
| "List me as available to other clubs" / "Available for Playing Opportunities" / "Open for Matches" (`setOpenToOffers`) | `set_my_hunt_listing`, `my_hunt_listing` |
| Find Players → "Post Player Requirement" (role, format, players 1–11, location or All, date or Flexible, time or Anytime, budget) | `publish_hunt_post` |
| "Your Published Slots" / "Remove Slot" | `club_hunt_posts`, `close_hunt_post` |
| Playing Opportunities list (role chips, search by club / location) | `hunt_open_posts` (search stays client-side) |
| "I'm Interested" → "Interest Sent" | `express_hunt_interest` (+ `withdraw_hunt_interest`) |
| The owner sees who is interested (new; the club is notified) | `club_hunt_interests` |
| Available Players (City + Role) | `hunt_open_players` |
| "Invite" → "Invited" (`invitedPlayerIds`) | `invite_hunt_player`, `club_hunt_invites` (or `invite_status` in `hunt_open_players`) |
| The player's invites and answer (new) | `my_hunt_invites`, `respond_hunt_invite` |

Decisions taken here (documented deviations / interpretations):
- **Accepting an invite never joins the club.** Accept means "I'm interested, contact me": the owner is told, and the club sees the phone if the player shares it with clubs. Joining stays the existing join-by-code flow. Decline tells nobody.
- **Posts of the caller's own club are included** in `hunt_open_posts` (flag `is_my_club`), as the in-memory repository did (the owner's "Your Published Slots" filtered the same list). The owner cannot express interest in their own club's post.
- **"expired" is derived**, not stored, for posts (stored status: `open` / `closed`). For invites, a pending invite past `expires_at` reads as `expired`, and is stored as `expired` when the club invites the same player again.
- **Available Players never returns a phone.** The phone (with `share_phone_with_clubs`) reaches a club only when the player reached out: interest (`club_hunt_interests`) or an accepted invite (`club_hunt_invites`).
- **Only listed players with a public profile** (`public_profile = true`, migration 31) appear in Available Players and can be invited — or players who showed interest in one of that club's posts. Official figures only with `show_stats = true`.
- **A player needs a cricket profile** (`player_profiles` row) to list themselves or express interest. An owner with a cricket profile may list too (`is_me` in the search).
- The post `notes` field is stored and returned (the model has it), but the post form does not collect it today; it never goes into notifications.

## Codes

| Field | Codes | App enum |
|---|---|---|
| role | `batsman`, `bowler`, `all_rounder`, `wicket_keeper` | `HuntRole.batsman / bowler / allRounder / wicketKeeper` |
| format | `t20`, `t10`, `odi`, `test`, `custom` | `MatchFormat.hunt` (`t20`, `t10`, `odi`, `test`, `custom`; no overs stored) |
| budget | `any`, `under_2000`, `from_2000_to_5000`, `over_5000` | `HuntBudget.any / under2000 / from2000to5000 / over5000` |
| post status | `open`, `closed`, `expired` (derived) | |
| invite status | `pending`, `accepted`, `declined`, `expired` | |

Listing role when not given: the cricket profile's role, and `wicket_keeper` when `is_wicketkeeper` is on. Listing city when not given: the saved one, else the current address's city.

Dates are `date` (`YYYY-MM-DD`), times are `text` `HH:MM` (24 h), timestamps are `timestamptz` (ISO 8601). Numeric figures come as JSON numbers (2 decimals).

## App contract (RPCs)

All are `SECURITY DEFINER`, `search_path = ''`, **signed-in only** (`authenticated`; anon has no `EXECUTE`). Without a signed-in user each raises `42501 hunt: not authenticated`. Owner checks use `clubs.owner_id = auth.uid()`. Error messages are exact (`sqlerrm`); the SQLSTATE is in brackets.

### Listing

**`my_hunt_listing()`** → one row: `listed boolean, role text, city text, listed_at timestamptz, updated_at timestamptz, visible boolean`
- Always one row, also before anything was saved (`listed = false`; role/city from the cricket profile and current address, each may be NULL).
- `visible` = listed **and** the profile is public: clubs can see the player now.
- Errors: `[P0002] hunt: profile not found`.

**`set_my_hunt_listing(p_listed boolean, p_role text default null, p_city text default null)`** → the same one row (`my_hunt_listing()` after the change)
- `p_role` / `p_city` NULL = keep the saved value (first time: from the profile / address). City trimmed, inner spaces collapsed.
- Turning off keeps role, city and `listed_at`. `listed_at` is set when the listing goes from off to on.
- Errors: `[22023] hunt: invalid listing` (p_listed NULL), `[22023] hunt: invalid role`, `[22023] hunt: invalid city` (> 100), `[22023] hunt: city required` (listing on, no city anywhere), `[P0001] hunt: player profile required` (listing on without a cricket profile), `[P0002] hunt: profile not found`.

### Posts

Post row (returned by `publish_hunt_post`, `club_hunt_posts`, `hunt_open_posts` — identical columns):

`post_id uuid, club_id uuid, club_name text, club_short_name text, club_city text, club_logo_path text, role text, format text, players_needed integer, city text, match_date date, match_time text, budget text, notes text, status text, created_at timestamptz, expires_at timestamptz, is_my_club boolean, interested boolean, interest_count integer`

- `city` NULL = any location ("All"); `match_date` NULL = Flexible; `match_time` NULL = Anytime.
- `club_logo_path`: object name in Storage bucket `club-logos` (migration 31), NULL = none.
- `interested`: the caller expressed interest. `interest_count`: only on the caller's own club's posts, NULL otherwise.
- App display name: `club_short_name ?? club_name` (as `displayShortName`).

**`publish_hunt_post(p_club_id uuid, p_role text, p_format text, p_players_needed integer, p_city text default null, p_match_date date default null, p_match_time text default null, p_budget text default 'any', p_notes text default null)`** → the new post (one row)
- Owner of `p_club_id` only. A dated post expires at the end of that day (Pakistan time); an undated one after 30 days.
- Limits per club: at most **10 open** posts, at most **20 new posts per 24 hours**. The same open requirement (role, format, players, city, date, time, budget) twice is refused.
- Errors: `[42501] hunt: not allowed` (not the owner / unknown club), `[22023] hunt: invalid role`, `hunt: invalid format`, `hunt: invalid players needed` (not 1–11), `hunt: invalid city` (> 100), `hunt: invalid date` (before today or more than 180 days ahead, Pakistan date), `hunt: invalid time` (not `HH:MM`), `hunt: invalid budget`, `hunt: invalid notes` (> 280), `[P0001] hunt: duplicate post`, `[P0001] hunt: too many open posts`, `[P0001] hunt: too many posts`.

**`close_hunt_post(p_post_id uuid)`** → void ("Remove Slot")
- Owner only. Players no longer see it; interests stay for the owner. Closing a closed post does nothing.
- Errors: `[42501] hunt: not allowed` (not the owner / unknown post).

**`club_hunt_posts(p_club_id uuid)`** → post rows: open ones and every post of the last 90 days, newest first (max 200).
- Errors: `[42501] hunt: not allowed`.

**`hunt_open_posts(p_role text default null, p_city text default null)`** → post rows: every club's **open, unexpired** posts, newest first (max 200). `p_city`: case-insensitive; a post for any location matches every city.
- Errors: `[22023] hunt: invalid role`.

### Interest

**`express_hunt_interest(p_post_id uuid)`** → void
- A player with a cricket profile; not on their own club's post. Already interested: nothing happens (no error, no second notification).
- At most **30 interests per player per 24 hours**. The owner is notified once per post and player (`hunt_interest_received`), also after withdraw + re-express.
- Errors: `[P0002] hunt: post not found`, `[P0001] hunt: own club`, `[P0001] hunt: post closed` (closed or expired), `[P0001] hunt: player profile required`, `[P0001] hunt: too many interests`.

**`withdraw_hunt_interest(p_post_id uuid)`** → void. Nothing when there is none.

**`club_hunt_interests(p_club_id uuid, p_post_id uuid default null)`** → `interest_id uuid, post_id uuid, user_id uuid, full_name text, avatar_path text, role text, city text, phone text, created_at timestamptz, stats_visible boolean, matches integer, runs integer, batting_average numeric, strike_rate numeric, wickets integer, economy numeric` (newest first, max 500)
- Owner only; all of the club's posts, or one. `role` / `city`: the listing's, else the profile's / address's.
- `phone` only when `share_phone_with_clubs`. Figures only when `stats_visible` (= `show_stats`); otherwise NULL.
- `avatar_path`: object in bucket `avatars` (migration 31).
- Errors: `[42501] hunt: not allowed`.

### Available Players

**`hunt_open_players(p_city text default null, p_role text default null)`** → `user_id uuid, full_name text, avatar_path text, role text, city text, listed_at timestamptz, is_me boolean, is_member boolean, invite_id uuid, invite_status text, stats_visible boolean, matches integer, runs integer, batting_average numeric, strike_rate numeric, wickets integer, economy numeric` (newest listing first, max 200)
- **Club owners only** (the caller owns a club). Listed players with a public profile and a name. **No phone.**
- `is_member`: active member of the caller's club (the owner's own row too). `invite_id` / `invite_status`: the caller's club's latest invite to that player (`pending` / `accepted` / `declined` / `expired`), NULL if none.
- Figures only when `stats_visible`. Official figures = migration 22's career statistics (confirmed results, every membership).
- City filter case-insensitive and trimmed. The app derives the City options from the unfiltered list (as today).
- Errors: `[42501] hunt: not allowed` (caller owns no club), `[22023] hunt: invalid role`.
- Mapping to `OpenPlayer`: `id = user_id`, `name = full_name`, `role` (code → `HuntRole`), `city`, `isMe = is_me`, `availabilityLabel` stays the app's "Available Now".

### Invites

**`invite_hunt_player(p_club_id uuid, p_user_id uuid, p_post_id uuid default null)`** → `invite_id uuid, status text, created_at timestamptz, expires_at timestamptz` (one row)
- Owner only. The player must be listed with a public profile, **or** have shown interest in one of this club's posts. Not yourself, not an active member.
- One pending invite per club and player. After an answer: not again for 30 days. An invite waits **14 days**. At most **20 invites per club per 24 hours**. `p_post_id`: optional, a post of this club.
- The player is notified (`hunt_invite_received`).
- Errors: `[42501] hunt: not allowed`, `[22023] hunt: invalid player` (NULL), `[22023] hunt: cannot invite yourself`, `[22023] hunt: invalid post`, `[P0001] hunt: already a member`, `[P0001] hunt: player not available` (not listed / private / unknown user — indistinguishable), `[P0001] hunt: already invited` (pending, or accepted in the last 30 days), `[P0001] hunt: invite declined recently`, `[P0001] hunt: too many invites`.

**`club_hunt_invites(p_club_id uuid)`** → `invite_id uuid, user_id uuid, full_name text, avatar_path text, role text, city text, post_id uuid, status text, created_at timestamptz, expires_at timestamptz, responded_at timestamptz, phone text` (pending ones and all of the last 90 days, newest first, max 500)
- Owner only. `phone` only when **accepted** and the player shares it with clubs.
- `invitedPlayerIds(clubId)` = the `user_id`s with status `pending` or `accepted` (and `declined`, if "Invited" should stay shown).
- Errors: `[42501] hunt: not allowed`.

**`my_hunt_invites()`** → `invite_id uuid, club_id uuid, club_name text, club_short_name text, club_city text, club_logo_path text, post_id uuid, post_role text, post_format text, post_match_date date, status text, created_at timestamptz, expires_at timestamptz, responded_at timestamptz` (pending ones and all of the last 90 days, newest first, max 200). `post_*` NULL when the invite names no post (or it was deleted).

**`respond_hunt_invite(p_invite_id uuid, p_accept boolean)`** → `invite_id uuid, status text, responded_at timestamptz` (one row)
- The invited player only, a pending, unexpired invite. Accept → `accepted` and the owner is notified (`hunt_invite_accepted`); decline → `declined`, nobody is told. **Never joins the club.**
- Errors: `[22023] hunt: invalid answer` (NULL), `[P0002] hunt: invite not found` (unknown or someone else's), `[P0001] hunt: invite not pending` (answered or expired).

## Notifications

Through the existing internal `notification_add` (migration 26, unchanged): nobody is told of their own action; a muted category is skipped; one notification per (recipient, dedupe key).

| type | recipient | inbox | category | club_id | subject_id | person_id | params | dedupe key |
|---|---|---|---|---|---|---|---|---|
| `hunt_invite_received` | the invited player | `player` | **membership** (always on) | club | invite id | — | `club_name`, `city` (club's), `hunt_role`, `format`, `match_date` (the last three only with a post), `expires_at` | `hunt:invite:<invite id>` |
| `hunt_interest_received` | the club's owner | `club_owner` | **join_requests** | club | post id | the player | `club_name`, `person_name`, `hunt_role`, `format`, `players_needed`, `match_date` (if dated) | `hunt:interest:<post id>:<player id>` |
| `hunt_invite_accepted` | the club's owner | `club_owner` | **join_requests** | club | invite id | the player | `club_name`, `person_name` | `hunt:invite_accepted:<invite id>` |

- Category choice: the two owner types join "Join requests (club owners)" (recruiting, can be muted). The invite is in "membership" (always on, the `else` branch): only players who listed themselves, or showed interest in that club's post, can be invited, and switching the listing off stops new invites. Rate limits bound it.
- Account deletion: `person_id` becomes NULL and `person_name` is replaced by `person_deleted: true` (migration 25), so the app shows "Deleted player".
- Push text (`templates.ts`; the app's inbox rows should read the same):
  - `hunt_invite_received`: title "Playing invite from {club_name}", body "{Role} · {Format} · {d Mon}" (parts present), else "Open Playing Opportunities to answer".
  - `hunt_interest_received`: title "{person_name} is interested in playing" ("A player" / "Deleted player"), body "{Role} · {Format} · {d Mon}", else the club name.
  - `hunt_invite_accepted`: title "{person_name} accepted your invite", body "{club_name} · See Player Hunt".
  - Role labels: Batsman, Bowler, All-Rounder, Wicket-Keeper.
- `notifications_type_check` now has **29 types** (26 + 3). `notification_category` is migration 28's body plus the two `join_requests` mappings.

### Effects on existing tests (app side, not changed here)

- `test/notifications_supabase_test.dart` asserts `migrationTypeCodes()` `hasLength(26)` and that every type maps to a `ServerNotificationType`; `test/notification_preferences_test.dart` compares `NotificationCategory.of` with the last `notification_category` in the migrations. Both read migration 33 now: the app must add the 3 types (and their inbox wording, categories: interest / accepted → join requests, invite → membership) and change 26 → 29.
- `templates_test.ts` was updated here (26 → 29, plus a Player Hunt wording test).
- **The deployed `push-dispatch` function needs a redeploy (separate approval)** for the new wording; until then the 3 types push the generic text "CricEco · You have a new notification".

## Database objects

- Tables `hunt_listings` (PK `user_id`), `hunt_posts`, `hunt_interests` (unique `post_id, user_id`), `hunt_invites` (partial unique `club_id, user_id` where pending). RLS on, **no policy, no grant** to anon / authenticated / service_role.
- Foreign keys: profile deleted → listing, interests, invites deleted; club deleted → posts (and their interests) and invites deleted; post deleted → interests deleted, `hunt_invites.post_id` NULL; `created_by` / `invited_by` NULL. `delete_account_data` is unchanged.
- Internal helpers `hunt_role_of`, `hunt_player_stats`, `hunt_post_list`: `search_path = ''`, not callable by any API role.
- Serialization: publish and invite lock the club row (limits, one pending invite); interest takes a per-player advisory lock (daily limit).
- Guard refuses: already applied / a name taken; 1–31 missing; the type list, `notification_category`, `notification_add` or `notification_muted` differ from migrations 26 / 28 (md5 `6e21473f…` constraint, `7945e3ba…`, `a6fc6bc7…`, `c436f7cc…`). After 33: category `99866e27…`, constraint `d6c0cf7d…`.

## Known limitations

- Old closed / expired posts and answered invites are not cleaned up (the read functions show 90 days). A later cleanup job can delete them.
- `hunt_open_players` computes figures per row (migration 22's `member_stats`), capped at 200 rows.
- Avatars stay readable by any signed-in user (migration 31's contract); `public_profile` here only controls listing visibility.
- Concurrency rests on row / advisory locks; it was not exercised with two sessions.

## Rollback

`20261126_rollback_m8_player_hunt.sql`: first roll back any app build that calls the hunt functions. It **deletes the notifications of the 3 hunt types** (with their push records; count in a NOTICE), drops the functions and the four tables (all listings, posts, interests and invites are lost), and restores migration 28's type list and `notification_category` verbatim. It refuses unless the current versions are migration 33's.

## Local verification (2026-11-26)

Disposable container `criceco-m8-test` (`public.ecr.aws/supabase/postgres:17.11.0.018`), removed afterwards: the `postgres` database (real Supabase auth; fixture copy without its auth guard) and a plain database `m8plain` in the same container (`00_auth_stub.sql` + `02_legacy_profiles_fixture.sql`). Both got migrations 1–31 applied **one by one from an explicit list** (D1 seed after migration 6, the Storage stand-in `26_…sh stub` before 31), then 33.

| Check | Result |
|---|---|
| Migration 33 | applied on both; self-check passed |
| Guards | refused: already applied; without migration 31; over a drifted `notification_category` |
| Local 28 (new) | **152 PASS** on both databases (access / anon / unauthenticated for every RPC; listing; posts, limits, duplicates, expiry, close; interest, idempotency, muting, daily limit; consent filtering of phone and figures; Available Players; invites, eligibility, rate limit, uniqueness, expiry, accept / decline; notification rows, inbox, category, muted preferences, membership always on; account and club deletion cascades) |
| Post-check 33 | 12 PASS + 1 INFO |
| Regression | local 22 (44), 23 (22), 24 (30) pass on `m8plain` before and after 33; local 20 (92) and 21 (27) pass after 33; local 26: 118 PASS (`postgres`); local 25: stops at J3 (historical: asserts the pre-31 `club_join_requests` columns, as documented for 31) — with J3 updated to the post-31 columns, 81 PASS on both |
| Rollback | 1 hunt notification deleted; catalogue (public + storage functions with body md5 / ACL / result, tables, columns, constraints, indexes, triggers, policies, column ACLs) **identical to 1–31** (0 diff lines) |
| Re-apply | catalogue identical to the first apply; local 28 and post-check pass again |
| `node --test supabase/functions/push-dispatch/*_test.ts` | 28 pass, 0 fail, 2 skipped (live FCM checks need `FCM_LIVE_SERVICE_ACCOUNT_FILE`) |
