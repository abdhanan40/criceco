# Production vs demo data

## The problem this fixes
Before this change, a Supabase (production) build still filled every module without a backend from `SeedData`. `CRICECO_DEMO=false` only hid the prototype controls in Settings. So real users saw invented matches, grounds, tournaments, challenges, notifications, player-hunt posts, opponent clubs, player statistics and a wallet balance. Anything they changed there vanished on restart.

## The rule now
| Build | Modules with a backend | Modules without one |
|---|---|---|
| **Memory mode (demo)**, `CRICECO_BACKEND` unset | n/a: everything runs on the demo's seeded data, as before | — |
| **Supabase mode** | Real data: account, profile, own club, locations; club memberships and teams **with `CRICECO_MEMBERSHIPS=true`** | Repositories are created **empty** (never seeded), and their screens show **"Not available yet"** instead of their content |

"Not available yet" is deliberately different from an empty list:
- **an empty list** means the module is connected and there's nothing there yet;
- **"Not available yet"** means the module isn't connected, so nothing can be shown or created.

## How it's wired
- **`lib/app/config/backend_modules.dart`:**
  - `BackendModule` lists the areas that need a backend.
  - `BackendModules.of(config, memberships:)` says which have real data. Memory mode: all of them (`isDemo`). Supabase: memberships and teams with the switch, nothing else.
  - `backendModulesProvider`, plus the switch `membershipsEnabledProvider` (`CRICECO_MEMBERSHIPS`, off by default).
- **`lib/app/providers/core_providers.dart`:**
  - **match, ground, reservation, wallet, challenge, hunt, tournament and notification** repositories: `InMemory…Repository(seed)` in the demo, `InMemory…Repository.empty()` in Supabase. The wallet starts at 0 with an empty ledger.
  - **team:** demo `InMemoryTeamRepository(seed)`; Supabase with the switch `SupabaseTeamRepository`; without it `UnavailableTeamRepository` (no teams, and creating one says "not available").
  - **club:** `SupabaseClubRepository` uses migration 11's functions with the switch. Other clubs (`otherClubs` / `clubSummary`) are **always empty** in Supabase: the demo's opponent clubs never appear.
  - **`playerStatsProvider` / `squadPlayerStatsProvider`:** in Supabase, `PlayerStats.unrecorded(...)`: 0 matches, rating "—", no form, not verified, **no skill level** (`skill` is now nullable and screens hide it). Never generated numbers.
- **`lib/shared/widgets/backend_pending.dart`:** `BackendPendingNotice`, `BackendModuleGate` and `BackendModuleScreen`.
- **`lib/app/router/app_router.dart`:** `_gate(module, title, back, screen)` wraps the module screens, so deep links are covered too:

| Module | Screens |
|---|---|
| matches | Upcoming Matches, Match Setup, My Matches, Match workspace, Playing Opportunities |
| playerStats | My Performance |
| challenges | Challenges, Create Slot, Challenge Status, Club Profile |
| playerHunt | Find Player |
| tournaments | every tournament route |
| notifications | Notifications |
| memberships | Members, Member Profile, Join Requests, Request Profile |
| teams | Teams, Team Squad, Add Players |

## Fixed in the security review (2026-11-16)
- **Rankings** used the demo club's roster (`playerPool(SeedData.ownClubId)`). Now: the demo keeps it; Supabase ranks only the signed-in owner's own club, and nothing when there is no club.
- **My Profile's club** (`playerClubProvider`) fell back to the demo club "KRC001 · Islamabad · EST. 2023". Now: the player's real club, or "No club yet".
- **The drawer** showed "Club KRC001" for a player without a club. Now: "No club yet" in Supabase builds.

## What still shows in Supabase builds (by design)
- **Dashboards:** the Club Owner and Player dashboards still render. Sections fed by unbacked modules (next match, recent results, notifications) are empty; no data is invented.
- **Availability:** player availability is still kept on the account locally. It isn't a backend module, and it doesn't fabricate data.

## Tests
`test/production_demo_mode_test.dart` checks:
- the repositories each mode selects;
- that every unbacked repository is empty in Supabase and seeded in the demo;
- player stats are "not recorded";
- the module matrix and the `joinByCode` switch;
- the gate panel versus the real screen.

`test/supabase_club_repository_test.dart` covers other clubs being empty. That test used to assert the old D-3A-4 behaviour ("opponent clubs stay the demo data"), which this change supersedes.

## Known limitations
- Dashboards don't show the "Not available yet" panel per section. They show empty sections.
- Booking, payment and line-up screens below Match Management are reachable only from gated screens. Only Match Setup is gated directly.
