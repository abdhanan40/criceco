# CricEco — Screen Consolidation Audit

**Status:** audit only. No screen, route, test or navigation code was changed.
**Audited:** the current Flutter app after Phase 9. Every screen was read in full: the router (`lib/app/router/app_router.dart`), route constants, all feature screens, shared sheets and the tests. Supporting sources: `CRICECO_REVISED_ARCHITECTURE.md`, `CRICECO_FLUTTER_MIGRATION_AUDIT.md`, `FOUNDATION_PHASE.md` and `DEV_SETUP.md`.
**Principle:** *navigate less, interact more*. The aim is fewer screens, never less functionality. No journey, role rule, state transition, business rule or data model changes. Where only presentation changes, this document says so.

---

## 1. Executive summary

- The app has **74 screen destinations**: 73 page routes plus the router's Not Found page. There is also one legacy redirect.
- **About 23 of them do not need to be standalone screens.** Each falls into one of four groups:
  - a secondary view of the screen before it (Scorecard, Match History, Tournament Dashboard, Manage Teams);
  - a detail that reads better as a panel over its list (join-request profile, opponent club profile, tournament request);
  - a small edit (Edit Profile, Privacy);
  - a fragment of a multi-step form (club creation, the booking setup, registration summary).
- **Recommended result: about 51 standalone screens.** No functionality is removed.
- **No route needs to be deleted, and none strictly needs a redirect.** The recommended strategy is **"route = workspace state"**:
  - every existing path keeps resolving, but renders its parent workspace in the right tab, mode or sheet;
  - deep links, notification targets, Back behaviour and the route smoke test keep working unchanged;
  - because paths are nested, today's Back behaviour stays as it is.
- **What stays standalone:** the high-risk money path. That covers Payment, Waiting for Opponent, Opponent Payment (demo), Booking Confirmed and Reservation Expired, plus the auth/onboarding redirect structure. None of it should be restructured before a backend exists.
- **Biggest wins:**
  - Profile inline edit.
  - Performance workspace (with a runs-per-match chart backed by real data).
  - Match workspace (Details and Scorecard).
  - Tournament host workspace (Details, Dashboard and Manage Teams merged).
  - Requests master–detail.
  - Challenges workspace.
  - Squad edit mode.
  - Line-up build mode with a team-picker sheet.
  - Booking setup presented as one stepper.

---

## 2. Current screen count

| Area | Screens | Routes |
|---|---|---|
| Public / auth | 5 | `/login`, `/signup`, `/signup/account`, `/onboarding/profile`, `/onboarding/playing-style` |
| Shared (role-aware) | 6 | `/continue-as`, `/role-setup`, `/notifications`, `/settings`, `/settings/privacy`, `/settings/security` |
| Club setup and membership | 6 | `/setup/club`, `/setup/club/create`, `/setup/club/create/details`, `/join`, `/join/waiting`, `/join/approved` |
| Player (shell) | 10 | `/player` plus availability, open-matches, matches, matches/:id, matches/:id/scorecard, performance, performance/history, profile, profile/edit |
| Club Owner (shell) | 6 | `/club`, `/club/teams`, `/club/teams/:id`, `/club/teams/:id/add-players`, `/club/members`, `/club/my-club`. Also `/club/teams/new` (redirect, P17) |
| Club Owner full routes | 9 | requests, requests/:id, player-hunt, challenges, challenges/mine, challenges/find, challenges/slots/new, challenges/:id/accepted, clubs/:id |
| Matches and booking | 14 | matches, :id/setup, …/ground, …/ground/:groundId, …/schedule, …/summary, :id/payment, :id/waiting, :id/opponent-payment, :id/confirmed, :id/expired, :id/lineup, …/build, …/pick |
| Tournaments | 17 | hub, new, :id/published, hosted, hosted/:id, …/dashboard, …/teams, …/teams/requests/:rid, browse, browse/:id, …/team, …/team/build, …/team/pick, …/team/summary, registrations, registrations/:rid, …/success |
| Error | 1 | Not Found (`errorBuilder`) |
| **Total** | **74** | 73 page routes, 1 error page, 1 legacy redirect |

**Overlays that are already not routes (not counted):**
- The role drawer (both roles).
- The Player Stats sheet.
- The Active-profile action sheet (Settings).
- Every `CeSelectField` sheet: city, type, reason, role.
- The Home Ground sheet (Club Details).
- Player Hunt's Location and Budget action sheets and its Date sheet.
- The time and date-of-birth pickers.
- The inline calendars.

**Chip tabs already in `?tab=`:** My Matches, Match Management, Requests, Player Hunt, My Registrations, Tournament Details and the Match History filter.

---

## 3. Screen-by-screen classification

**Legend**

| Code | Meaning |
|---|---|
| **R-keep** | Route and screen unchanged |
| **R-state** | The route is kept; it renders its parent workspace in the matching tab or mode |
| **R-sheet** | The route is kept; it renders as a modal sheet page on top of its parent route |
| **Risk** | LOW / MED / HIGH, as defined in §18 |
| **Tests (route)** | Route-based tests keep passing because the location does not change. Only widget finders (titles, buttons) need updating. |

### 3.1 Public / auth / shared

| # | Screen | Route | Role | Parent | Purpose | Standalone justification | Action | Pattern | New workspace | Route strategy | State impact | Back impact | Deep link | Testing | Risk | Notes |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | Login | /login | — | initial | Sign in | Entry point; redirect target | KEEP | — | — | R-keep | none | none | none | none | — | — |
| 2 | Sign Up | /signup | — | Login | Choose create / Google | Auth landing with its own PopScope | KEEP | — | — | R-keep | none | none | none | none | — | Could become a Login tab state, but that is auth-model risk for little gain |
| 3 | Create Account | /signup/account | — | Sign Up | Register | 5-field form | KEEP | — | — | R-keep | — | — | — | — | — | — |
| 4 | Complete Profile | /onboarding/profile | — | Create Account | Onboarding step 2/3 | Redirect target for onboarding sessions | KEEP (D) | already a visual stepper | — | R-keep | — | — | — | — | — | `onboardingRoutes` drives redirects; do not merge before backend auth |
| 5 | Playing Style | /onboarding/playing-style | — | Complete Profile | Step 3/3 | Same as above | KEEP (D) | — | — | R-keep | — | — | — | — | — | — |
| 6 | Continue As | /continue-as | shared | Login | Pick active role | Role-switch architecture | KEEP | — | — | R-keep | — | — | — | — | — | — |
| 7 | Role Setup | /role-setup | shared | Drawer switch / Settings | "Become a Club Owner" prompt | One message, two buttons | **CONSOLIDATE** | Bottom sheet (partial) | Over the current screen | R-sheet over role home | none | ✕/scrim/Back close; "Set Up" → `go(chooseOption)` | Role home plus sheet | Update 2 finders | MED | Role-switch entry; the role itself does not change |
| 8 | Notifications | /notifications | shared | Bell / drawer / Settings | Role inbox | Cross-role destination, growing list, read state, deep targets | KEEP | — | — | R-keep | — | — | — | — | — | Justified in §12 |
| 9 | Settings | /settings | shared | Drawer | Settings hub | Workspace | KEEP (host) | Expandable sections | — | R-keep | — | — | — | Finders | LOW | Gains Privacy and Sign-in sections |
| 10 | Privacy | /settings/privacy | shared | Settings | 3 toggles | Only 3 toggles | **CONSOLIDATE** | Expandable section | Settings | R-state (Settings, Privacy open and scrolled) | none: account state | Back → where Settings was opened from | Unchanged | 3 tests: finders | LOW | — |
| 11 | Password & security | /settings/security | shared | Settings | Change password + 2 toggles | Sensitive keyboard form with validation | KEEP (narrowed) | Toggles move into a Settings section | — | R-keep | none | none | none | Finders for the toggles | LOW | The password form stays full-screen for clarity and security |
| 74 | Not Found | errorBuilder | — | — | Unknown location | Error page | KEEP | — | — | — | — | — | — | — | — | — |

### 3.2 Club setup and membership

| # | Screen | Route | Role | Parent | Purpose | Standalone justification | Action | Pattern | New workspace | Route strategy | State impact | Back impact | Deep link | Testing | Risk | Notes |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 12 | Choose Option | /setup/club | — | Continue As | Create or join | Hosts the drawer; PopScope exit rule | KEEP | — | — | R-keep | — | — | — | — | — | — |
| 13 | Create Club | /setup/club/create | — | Choose Option | Step 1 | Stepper host | KEEP (host) | Stepper | "Create Your Club" | R-state (step 1) | Draft already in `clubSetupProvider` | Step Back = today's pop | — | Finders | MED | — |
| 14 | Club Details | …/create/details | — | Create Club | Step 2 + create | A fragment of one form | **CONSOLIDATE** | Stepper step 2 | Create Your Club | R-state (step 2) | none: the draft is provider-held | Back → step 1 (same as today) | Deep link → step 2 (still guarded by step-1 validity) | 3 tests: finders | HIGH | Creates the club and grants the Club Owner role; the logic is untouched, but add regression tests |
| 15 | Enter Club Code | /join | — | Choose Option (push) | Send a join request | Starts the membership flow; `from` param; Waiting/Approved are child routes | KEEP | — | — | R-keep | — | — | — | — | — | A sheet would conflict with the `/join/**` child-route stack |
| 16 | Waiting Approval | /join/waiting | — | Enter Code | Pending status | Status screen with a PopScope rule | KEEP | — | — | R-keep | — | — | — | — | — | — |
| 17 | Join Approved | /join/approved | — | Waiting | Success; enter Player context | Terminal state that changes the role context | KEEP | — | — | R-keep | — | — | — | — | — | — |

### 3.3 Player

| # | Screen | Route | Role | Parent | Purpose | Standalone justification | Action | Pattern | New workspace | Route strategy | State impact | Back impact | Deep link | Testing | Risk | Notes |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 18 | Player Dashboard | /player | P | shell Home | Home | Role home | KEEP | — | — | R-keep | — | — | — | — | — | — |
| 19 | Availability | /player/availability | P | Dashboard | Status form | Long form; 4 entry points; notification target | KEEP | Progressive disclosure already used (reason and until only when unavailable) | — | R-keep | — | — | — | — | — | — |
| 20 | Open Matches | /player/open-matches | P | Dashboard | Browse club requirements | Search, role filter and interest list | KEEP | — | — | R-keep | — | — | — | — | — | — |
| 21 | My Matches | /player/matches | P | shell Matches | Match list with tabs | Branch root | KEEP | Master (tablet: split with #22) | — | R-keep | — | — | — | — | — | — |
| 22 | Match Details | /player/matches/:id | P | My Matches | One match | Notification target; deep-link value | KEEP (host) | Tabbed workspace | "Match" | R-keep (Details tab) | — | — | — | Finders | LOW | Scorecard tab shown only when a scorecard exists |
| 23 | Scorecard | …/:id/scorecard | P | Match Details | Innings tables | Secondary view of the same match | **CONSOLIDATE** | Tab + expandable innings | Match | R-state (Scorecard tab) | none | Back → Details tab (same as today) | Unchanged | 3 tests: finders | LOW | Header duplicates the Details hero today; it is shown once |
| 24 | My Performance | /player/performance | P | shell Performance | Stats overview | Branch root | KEEP (host) | Tabbed workspace + chart | "Performance" | R-keep (Overview tab) | — | — | — | Finders | LOW | — |
| 25 | Match History | …/performance/history | P | My Performance | Full match log | A superset of Overview's "last 5" | **CONSOLIDATE** | Tab + chart | Performance | R-state (History tab) | none: filter is in `historyFilterProvider` | Back → Overview tab (same as today) | Unchanged | 3 tests: finders | LOW | Runs-per-match chart from `matchLog` (§8) |
| 26 | Player Profile | /player/profile | P | shell Profile | Profile | Branch root; Settings Account target | KEEP (host) | Inline edit | — | R-keep | — | — | — | — | — | — |
| 27 | Edit Profile | /player/profile/edit | P | Profile (push) | Edit name, city, phone | Only 3 fields | **CONSOLIDATE** | Inline edit mode | Profile | R-state (Profile in edit mode) | Controllers move into the Profile state | Back = cancel edit (today: pop to Profile) | Unchanged | 4 tests: finders | LOW | Moves from the root navigator into the branch, so the bottom nav stays visible |

### 3.4 Club Owner — shell, requests, hunt

| # | Screen | Route | Role | Parent | Purpose | Standalone justification | Action | Pattern | New workspace | Route strategy | State impact | Back impact | Deep link | Testing | Risk | Notes |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 28 | Club Dashboard | /club | C | shell Home | Home | Role home | KEEP | — | — | R-keep | — | — | — | — | — | — |
| 29 | My Teams | /club/teams | C | shell Teams | Teams list + create form | Branch root | KEEP | Master (tablet: split with #30); optional: collapse the create form behind "+ New Team" | — | R-keep | — | — | — | — | LOW | — |
| 30 | Team Squad | /club/teams/:id | C | My Teams | One team's squad | Team detail; deep link | KEEP (host) | Edit mode | "Team" | R-keep | — | — | — | — | — | Optional: rows open the existing Player Stats sheet |
| 31 | Add Players | …/:id/add-players | C | Team Squad (push) | Edit the XI/subs | Edits the same entity | **CONSOLIDATE** | Inline edit mode ("Edit Squad") | Team | R-state (Squad in edit mode) | none: draft in `squadEditorProvider` | Back leaves edit mode and keeps the draft (as today) | Unchanged | 4 tests: finders | MED | Player Stats stays a sheet; the bottom nav stays visible |
| 32 | Members | /club/members | C | shell Members | Member list + search | Branch root | KEEP | — | — | R-keep | — | — | — | — | — | Rows have no detail data; do not invent a detail view |
| 33 | My Club | /club/my-club | C | shell Profile | Club profile | Branch root; Settings Account target | KEEP | — | — | R-keep | — | — | — | — | — | No edit function exists, so no inline edit is proposed |
| 34 | Requests | /club/requests | C | Dashboard | Requests list (3 tabs) | Workspace | KEEP (host) | Master | "Requests" | R-keep | — | — | — | — | — | — |
| 35 | Request Profile | /club/requests/:id | C | Requests | Requester detail + role + decision | Detail of a list row | **CONSOLIDATE** | Master–detail: full-height sheet (phone), side panel (≥840 dp) | Requests | R-sheet over Requests | none: the tab stays in the URL behind the sheet | Close/Back → Requests on the same tab; after a decision the sheet closes | Notification target unchanged | 9 tests: finders | MED | Membership and role logic untouched; role assignment stays inline |
| 36 | Player Hunt | /club/player-hunt | C | Dashboard | Post + browse (2 tabs) | Complex task; filters already in sheets | KEEP | — | — | R-keep | — | — | — | — | — | — |

### 3.5 Challenges

| # | Screen | Route | Role | Parent | Purpose | Standalone justification | Action | Pattern | New workspace | Route strategy | State impact | Back impact | Deep link | Testing | Risk | Notes |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 37 | Challenges | /club/challenges | C | Dashboard | Clubs to challenge | Workspace | KEEP (host) | Tabbed workspace | "Challenges" | R-keep (Challenges tab) | — | — | — | — | — | It already *looks* tabbed (`ChallengesTabs`) |
| 38 | My Challenges | …/challenges/mine | C | Challenges | Decide / sent / resolved | Same header and tabs as #37 | **CONSOLIDATE** | Tab | Challenges | R-state (My Challenges tab) | none | Back → Challenges tab (same as today: nested path) | Notification target unchanged | 6 tests: finders | MED | Challenge state logic untouched |
| 39 | Find Match | …/challenges/find | C | Challenges | Seekers list | Near-duplicate layout of #37 | **CONSOLIDATE** | Tab | Challenges | R-state (Find Match tab) | none | Same as #38 | Create Slot success lands on this tab | 6 tests: finders | MED | — |
| 40 | Create Availability Slot | …/challenges/slots/new | C | Challenges tabs (push) | 7-field form with calendar | Keyboard + calendar; a sheet would be a page anyway | KEEP | Optional: full-screen dialog presentation | — | R-keep | — | — | — | — | — | — |
| 41 | Club Profile (opponent) | /club/clubs/:id | C | 3 Challenges tabs (push) | Opponent detail + Challenge | Detail of a list card | **CONSOLIDATE** | Master–detail: full-height sheet (phone), side panel (≥840 dp) | Challenges (calling tab) | R-sheet (deep link opens over the dashboard) | none | Close → calling tab; "Challenge This Club" closes the sheet, then routes as today | Unchanged | Finders | MED | Send logic untouched |
| 42 | Challenge Status | …/:id/accepted | C | send (demo) | Accepted / sent result | Terminal state that hands off to Match Management | KEEP | — | — | R-keep | — | — | — | — | — | — |

### 3.6 Match Management, booking, line-up

| # | Screen | Route | Role | Parent | Purpose | Standalone justification | Action | Pattern | New workspace | Route strategy | State impact | Back impact | Deep link | Testing | Risk | Notes |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 43 | Match Management | /club/matches | C | Dashboard | Waiting / Scheduled / History | Main workspace; hand-off target | KEEP | — | — | R-keep | — | — | — | — | — | — |
| 44 | Match Setup | …/:id/setup | C | Match Mgmt | Step 1: format and city | Stepper host | KEEP (host) | Stepper | "Book a Ground" | R-state (step 1) | **Overs text must write through to the draft on change** (today it is written on Continue) | Step Back = today's pop | — | Finders | HIGH | — |
| 45 | Book a Ground | …/setup/ground | C | Setup | Step 2: pick a ground | Form fragment | **CONSOLIDATE** | Stepper step | Book a Ground | R-state (step 2) | none: `draft.groundId` | Back → step 1 | Unchanged | Finders | HIGH | — |
| 46 | Ground Details | …/ground/:groundId | C | Book a Ground | Step 3: review the ground | Detail of the selected card | **CONSOLIDATE** | Full-height sheet whose CTA advances | Book a Ground (step 2) | R-sheet over step 2 | Existing "clear slot when the ground changes" rule kept | Close → step 2; CTA → step 4 (flow identical) | Unchanged | 2 tests: finders | HIGH | Specs and amenities become expandable; the carousel stays |
| 47 | Select Date & Time | …/schedule | C | Ground Details | Step 4: date and slot | Form fragment | **CONSOLIDATE** | Stepper step | Book a Ground | R-state (step 4) | none: draft date and slot | Back → step 3 (sheet over step 2) | Unchanged | 5 tests: finders | HIGH | Calendar month stays local; it is cosmetic |
| 48 | Booking Summary | …/schedule/summary | C | Select Date | Step 5: review + Reserve (commit) | The commit point | **CONSOLIDATE** | Stepper final step | Book a Ground | R-state (step 5) | none | Back → step 4 | Unchanged | 4 tests: finders | HIGH | `reserve()`, the conflict re-check and the Payment hand-off are unchanged |
| 49 | Payment | :id/payment | C | Summary / Waiting card | Pay my share | Transaction, expiry guard, PopScope | KEEP (D) | — | — | R-keep | — | — | — | — | HIGH | — |
| 50 | Waiting for Opponent | :id/waiting | C | Payment | Hold countdown | Terminal status + expiry guard | KEEP (D) | — | — | R-keep | — | — | — | — | HIGH | — |
| 51 | Opponent Payment | :id/opponent-payment | C | Waiting (demo) | Simulated opponent payment | Demo seam for the payment event | KEEP (D) | Later: an in-place state of Waiting | — | R-keep | — | — | — | — | HIGH | Revisit when a real payment event exists |
| 52 | Booking Confirmed | :id/confirmed | C | Waiting | Success + settlement | Major completion state | KEEP | Settlement card optionally expandable | — | R-keep | — | — | — | — | — | — |
| 53 | Reservation Expired | :id/expired | C | Guard | Refund or wallet decision | Money decision; terminal | KEEP (D) | — | — | R-keep | — | — | — | — | HIGH | — |
| 54 | Select Team (line-up) | :id/lineup | C | Scheduled / Confirmed | Line-up overview + options | Workspace host | KEEP (host) | Modes + sheet | "Line-up" | R-keep | — | — | — | — | — | Shared with tournaments (`LineupTarget`) |
| 55 | Build Your Team | …/lineup/build | C | Select Team | Pick 11 + 4 | Edits the same line-up | **CONSOLIDATE** | Inline mode ("Build") | Line-up | R-state (build mode) | none: `lineupDraftProvider` | Back → overview mode (same as today: `go(lineup)`) | Unchanged | Finders | MED | Discard keeps its app-bar action |
| 56 | Select Existing Team | …/lineup/pick | C | Select Team | Radio list + confirm | A short picker | **CONSOLIDATE** | Bottom sheet (partial → full) | Line-up | R-sheet over Select Team | none | Close → overview; confirm → Scheduled (as today) | Unchanged | Finders | MED | — |

### 3.7 Tournaments

| # | Screen | Route | Role | Parent | Purpose | Standalone justification | Action | Pattern | New workspace | Route strategy | State impact | Back impact | Deep link | Testing | Risk | Notes |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 57 | Tournament Hub | /club/tournaments | C | Drawer / Dashboard | Tournament Center menu + stats | Approved Phase 8 entry and names | KEEP | — | — | R-keep | — | — | — | — | — | A tabbed hub was considered; it changes the approved hierarchy (§11.3) |
| 58 | Browse | …/browse | C | Hub | City-filtered list | Approved destination | KEEP | — | — | R-keep | — | — | — | — | — | — |
| 59 | My Registrations | …/registrations | C | Hub | My registrations (tabs) | Approved destination; notification target | KEEP | Master (tablet: split with #72) | — | R-keep | — | — | — | — | — | — |
| 60 | My Tournaments | …/hosted | C | Hub | Hosted list | Approved destination | KEEP | — | — | R-keep | — | — | — | — | — | — |
| 61 | Create Tournament | …/new | C | Hub | 12-field form | Complex independent task | KEEP | Progressive disclosure: "Optional details" (fee, prize, description) collapsed | — | R-keep | — | — | — | — | LOW | A stepper would add taps for one form |
| 62 | Tournament Published | …/:id/published | C | Create | Success | Major completion state | KEEP | — | — | R-keep | — | — | — | — | — | — |
| 63 | Tournament Details (host) | …/hosted/:id | C | My Tournaments | Host workspace (4 tabs) | Workspace | KEEP (host) | Tabs (+1) | "Tournament (host)" | R-keep | — | — | — | — | — | The 9-row summary card collapses to key rows outside the Overview tab |
| 64 | Tournament Dashboard | …/:id/dashboard | C | Details | Upcoming / completed / points / awards | Duplicates the Fixtures and Points tabs | **CONSOLIDATE** | Tab "Dashboard" | Tournament (host) | R-state (Dashboard tab) | none | Back → Overview (same as today) | Unchanged | Finders | MED | — |
| 65 | Manage Teams | …/:id/teams | C | Details | Requests + confirmed teams | Duplicates the Teams tab | **CONSOLIDATE** | Teams tab gains a "Requests" section | Tournament (host) | R-state (Teams tab) | none | Back → Overview (same as today) | Unchanged | Finders | MED | `?tab=teams` and `/teams` now resolve to the same state |
| 66 | Registration Request | …/teams/requests/:rid | C | Manage Teams | Club detail + accept/reject | Detail of a request row | **CONSOLIDATE** | Master–detail sheet / panel | Tournament (host), Teams tab | R-sheet over the Teams tab | none | Close → Teams tab; a decision closes the sheet | Notification target unchanged | Finders | MED | `decide()` untouched |
| 67 | Tournament Details (participant) | …/browse/:id | C | Browse | Tournament + rules + clubs | Deep link; participant view kept separate from the host view | KEEP | Expandable "All details"; participating clubs expand past 4 | — | R-keep | — | — | — | — | LOW | Rules stay visible (critical before registering) |
| 68 | Select Team (tournament) | …/:id/team | C | Tournament Details | Registration workspace host | Workspace host | KEEP (host) | Modes + sheet + disclosure | "Register" | R-keep | — | — | — | — | — | — |
| 69 | Build Your Team (tournament) | …/team/build | C | Select Team | Pick 11 + 4 | As #55 | **CONSOLIDATE** | Inline mode | Register | R-state | none | As #55 | Unchanged | Finders | MED | — |
| 70 | Select Existing Team (tournament) | …/team/pick | C | Select Team | Picker | As #56 | **CONSOLIDATE** | Bottom sheet | Register | R-sheet | none | As #56 | Unchanged | Finders | MED | — |
| 71 | Registration Summary | …/team/summary | C | Select Team | Review + agree + submit | Short confirm step for the chosen squad | **CONSOLIDATE** | Progressive disclosure: the summary, agree box and Submit appear under "Selected Team" once a squad exists | Register | R-state (Select Team with the review section focused) | none: `registrationDraftProvider` | Back → Select Team (same as today) | Unchanged | 3 tests: finders | MED | `submit()`, the guards and the Success hand-off are unchanged |
| 72 | Registration Details | …/registrations/:rid | C | My Registrations | Participant status + fixtures | Notification target; status-driven view | KEEP | Detail (tablet: split with #59); "Your Squad" collapsed by default | — | R-keep | — | — | — | — | — | — |
| 73 | Registration Success | …/:rid/success | C | Summary | Success | Terminal state | KEEP | — | — | R-keep | — | — | — | — | — | — |

---

## 4. Keep / consolidate matrix

| Outcome | Count | Screens |
|---|---|---|
| **KEEP** (standalone) | **51** | 1–6, 8, 9, 11, 12, 13, 15–22, 24, 26, 28–30, 32–34, 36, 37, 40, 42–44, 49–54, 57–63, 67, 68, 72–74 |
| **Tab** | 6 | Scorecard (23), Match History (25), My Challenges (38), Find Match (39), Tournament Dashboard (64), Manage Teams (65) |
| **Master–detail** (sheet on phone, panel ≥840 dp) | 3 | Request Profile (35), Club Profile (41), Registration Request (66) |
| **Bottom sheet** | 4 | Role Setup (7), Ground Details (46), Select Existing Team ×2 (56, 70) |
| **Inline edit / mode** | 4 | Edit Profile (27), Add Players (31), Build Your Team ×2 (55, 69) |
| **Expandable section** | 1 | Privacy (10) |
| **Stepper step** | 4 | Club Details (14), Book a Ground (45), Select Date (47), Booking Summary (48) |
| **Progressive disclosure** | 1 | Registration Summary (71) |
| **Removed routes** | 0 | — |

**Stepper, workspace and mode hosts** (kept standalone, with added capability): Settings, Create Club, Match Details, My Performance, Player Profile, Team Squad, Requests, Challenges, Match Setup, Select Team (match), Tournament Details (host), Select Team (tournament).

---

## 5. Player consolidation plan

### 5.1 Match workspace — Match Details (#22) and Scorecard (#23)

- **Tabs:** Details | Scorecard. The Scorecard tab only appears for a past match with a scorecard; otherwise there is no tab row.
- **Default tab:** Details.
- **Routes absorbed:** `/player/matches/:id/scorecard` → Scorecard tab.
- **Deep links:** both paths keep resolving to their own state.
- **Back:** from the Scorecard tab → Details tab, then → My Matches (both as today).
- **State:** read-only.
- **Other changes:**
  - Innings become expandable sections, both expanded by default.
  - The hero is shown once instead of repeating in the scorecard header.

### 5.2 Performance workspace — My Performance (#24) and Match History (#25)

- **Tabs:** Overview | History. The default is Overview.
- **Overview:** the current summary strip, recent form, stat grid and the last 5 matches. "View All" switches tab.
- **History:** a runs-per-match chart (see §8), the All / Won / Lost filter and the full log.
- **Back:** History → Overview → Dashboard (as today).
- **State:** `performanceTabProvider` and `historyFilterProvider` are unchanged.

### 5.3 Profile inline edit — Profile (#26) and Edit Profile (#27)

| Aspect | Specification |
|---|---|
| Trigger | The existing "Edit" app-bar button, which becomes "Cancel" while editing |
| Editable fields | Full name, City (select sheet), Phone. Exactly the current fields. |
| Save / cancel | Save validates (the same `CeValidators` rules), calls `updateAccount`, refreshes the open-to-offers listing, shows "Profile updated" and leaves edit mode. Cancel restores the values. |
| Validation | Inline on the fields (as today) |
| Persistence | Account state (unchanged) |
| Permissions | Player role only (this is a `/player/**` route) |
| Back | While editing, Back cancels edit mode (today it pops the edit page) |

### 5.4 Kept standalone, and why

- **Dashboard:** the role home.
- **Availability:** a long form with 4 entry points and a notification target.
- **Open Matches:** search plus a feed.
- **My Matches:** the branch root.

---

## 6. Club Owner consolidation plan

### 6.1 Team management — My Teams (#29), Team Squad (#30), Add Players (#31), Player Stats (sheet)

- **Structure:** Teams (master) → Team workspace (Squad view) → **Edit Squad mode** (today's Add Players), with Player Stats staying a sheet.
- **Edit mode behaviour:**
  - Counters, filter, pick rows and Save Squad appear inline.
  - Leaving edit mode keeps the draft (`squadEditorProvider`), exactly as leaving Add Players does today.
- **Kept distinct conceptually:**
  - **Members** = club members.
  - **Team Squad** = assigned team members.
  - **Player Hunt** = external recruitment.
- **Tablet:** Teams list on the left, Team workspace on the right.

### 6.2 Other Club Owner screens (all kept)

- **Dashboard:** the role home.
- **My Club:** the Profile tab and Account target.
- **Members:** a searchable list; its rows have no detail data.
- **Player Hunt:** already tabbed, with sheet filters.
- **Match Management:** the hand-off hub.

---

## 7. Requests consolidation plan

- **Workspace:** Requests (the Pending / Approved / Declined tabs stay in `?tab=`).
- **Detail:**
  - Phone: tapping a row opens a full-height sheet with identity, summary, performance and a Review block (role select inline, Reject / Approve).
  - Tablet (≥840 dp): a side panel.
- **Preserved:**
  - The quick Accept / Decline on rows (always Player).
  - Role assignment only in the detail.
  - `decideJoinRequest` refuses the owner role.
  - Membership only; Club Owner is never granted.
  - Decided requests show the outcome.
- **Route:** `/club/requests/:id` stays. It renders as a sheet page over Requests, so notification `JoinRequestTarget` works unchanged.
- **Back:** sheet close = Back → Requests on the same tab. After a decision the sheet closes and a toast shows (today `_back` pops).

---

## 8. Challenges consolidation plan

| Item | Specification |
|---|---|
| Workspace | Challenges |
| Tabs | Challenges · My Challenges · Find Match (the existing `ChallengesTabs` chips) |
| Routes absorbed | `/club/challenges/mine`, `/club/challenges/find`. Their paths stay and each renders the workspace on that tab. |
| Default tab | Challenges |
| Back | Non-default tab → Challenges tab (today's nested pop), then → Dashboard |
| State retention | `_busy` per card and the pending-sent set (provider); the slots list (provider) |
| Sheet / panel | Opponent Club Profile (#41): full-height sheet on phone, side panel on tablet |
| Kept standalone | Create Availability Slot (long form), Challenge Status (terminal) |
| Logic | send / accept / decline / expire, and one pending match per acceptance: **unchanged** |

---

## 9. Match Management consolidation plan

- **Match Management is kept:** Waiting / Scheduled / History are already tabs.
- **Contextual sub-workspaces opened from cards:**
  - the **Book a Ground stepper** (§10);
  - **Payment** and later states (standalone, D);
  - the **Line-up workspace**, with a Build mode and a team-picker sheet.
- **Challenge hand-offs are unchanged:** Accept → Waiting tab; Challenge Status → Waiting tab.

---

## 10. Ground booking consolidation plan

- **Stepper name:** Book a Ground.
- **Screens it covers:** Match Setup (#44), Book a Ground (#45), Ground Details (#46, as a sheet), Select Date (#47), Booking Summary (#48).

| Step (progress dot) | Current route (kept) | Content | Validation |
|---|---|---|---|
| 1 Format & city | `…/setup` | Format tiles, custom overs (only for Custom), city | Format; overs 1–50; city |
| 2 Ground | `…/setup/ground` | City-first ground list | A ground is selected |
| 3 Ground details (sheet over step 2) | `…/ground/:groundId` | Carousel, price, location, specs/amenities (expandable); CTA "Continue · Pick a Date" | — |
| 4 Date & time | `…/schedule` | Calendar + slot chips | Date; an open slot |
| 5 Review | `…/schedule/summary` | Details, payment split, escrow note; **Reserve Ground for 30 Minutes** | Slot re-check, then `reserve()` |
| 6–7 | Payment / Waiting | **Stay standalone** (D) | — |

- **Presentation:** one persistent stepper shell (header card, 7-dot `WorkflowProgress`, sticky footer CTA). Only the step body changes. Page transitions between steps are suppressed.
- **Back:** step Back = the existing path pop, so it is identical to today. System Back is the same.
- **Save / resume:** the draft already lives in `bookingProvider(matchId).draft`. **Required change:** write custom overs to the draft on change, not on Continue.
- **Final state:** `reserve()` → Payment. This is unchanged: hold, `reservedAt`, `expiresAt`, status, conflict handling (`SlotTakenException` → back to step 4 with a toast), expiry watcher, opponent payment and refunds are all untouched.
- **Risk:** HIGH. It is done last among the B items, with the extra tests in §23.

---

## 11. Tournament consolidation plan

### 11.1 Host workspace — Tournament Details (#63)

- **Tabs:** Overview · Teams · Fixtures · Points Table · **Dashboard**.
- **Teams tab:** absorbs Manage Teams (#65). It gains a "Clubs Requesting Registration" section above the confirmed teams.
- **Request rows:** open the Registration Request sheet (#66).
- **Dashboard tab:** absorbs the Tournament Dashboard (#64): winner, upcoming/completed matches, points and awards.
- **Routes:**
  - `…/:id/teams` and `…/:id/dashboard` keep resolving to their tabs.
  - `…/teams/requests/:rid` renders as a sheet over the Teams tab (the `TournamentRequestTarget` notification still works).
- **Back:** non-Overview tab → Overview → My Tournaments (as today).
- **Summary card:** the 9-row card shows 3 key rows (registered, deadline, status) on non-Overview tabs, with "More details" to expand.

### 11.2 Registration workspace — Select Team (#68)

- **Build and Pick:** Build becomes an inline mode (#69); Pick becomes a sheet (#70).
- **Registration Summary (#71):** becomes a review section under "Selected Team". It holds the rows, the "I agree to the tournament rules" box and **Submit Registration**, and appears once a squad exists. `/team/summary` keeps resolving to this state.
- **Kept standalone:** participant Tournament Details (#67), Registration Success (#73) and Registration Details (#72).
- **Hosting and registration stay separate:** the host and participant guards are unchanged.

### 11.3 Considered and not recommended

- **A tabbed Tournament Hub** (Browse / My Registrations / My Tournaments as tabs):
  - Fewer screens.
  - But it restructures the approved Phase 8 hub and its Back chain (Browse → Hub).
  - The Hub also carries stats and a quick overview.
  - Recommendation: **keep**, and revisit only with explicit approval.
- **A stepper for Create Tournament:** it is one long form. The recommendation is progressive disclosure of the optional fields instead.

---

## 12. Settings / Notifications consolidation plan

### 12.1 Settings

| Section | Content | Presentation |
|---|---|---|
| Account | Account (role-aware), Active profile (sheet) | Unchanged |
| Preferences | Notifications (inbox, P15) | Unchanged |
| **Privacy** (was #10) | Public profile, Show my stats, Show phone number + the note | Expandable section with inline toggles |
| **Sign-in & security** | Two-step verification, Login alerts (inline toggles) + a "Change password" row → `/settings/security` (password form only) | Expandable section; password stays full-screen |
| Prototype controls | Demo Mode (existing `demoModeProvider`) | Unchanged |
| Log out | — | Unchanged |

- **Route:** `/settings/privacy` renders Settings with Privacy expanded and scrolled into view.

### 12.2 Notifications — keep standalone

- **Why it stays standalone:**
  - It is shared by both roles (`/notifications`) and has three entry points: the bell (push), the drawer (go) and Settings (push).
  - The list grows with live events (tournament decisions and requests).
  - Every row opens a different destination in the active role.
  - It has its own read / unread state and Mark all read.
- **Why the alternatives were rejected:**
  - A sheet would hide deep navigation behind a modal.
  - A dashboard section would duplicate it for two roles.
- **Preserved:** read / unread state, role filtering and deep targets.

---

## 13. Route preservation strategy

1. **No route is deleted, and no redirect is required.** Every existing path resolves to one of these:

   | Kind | How it renders | Screens |
   |---|---|---|
   | **R-state** | The workspace widget, with tab, mode or step taken from the route | Scorecard, History, My Challenges, Find Match, Dashboard, Manage Teams, Edit Profile, Add Players, Build ×2, Privacy, Club Details, booking steps, Registration Summary |
   | **R-sheet** | A custom `Page` whose `createRoute` returns a modal bottom-sheet route, stacked on its parent path | Request Profile, Club Profile, Registration Request, Ground Details, Select Existing Team ×2, Role Setup |

2. **Result:**
   - `Routes.*` constants, notification targets (`notificationLocation`), `?tab=` parameters and every `context.go` call site keep working.
   - `navigation_widget_test` ("every declared route builds; location == route") keeps passing unchanged.
3. **Canonical forms:**
   - Tournament Teams: `…/:id/teams` and `…/:id?tab=teams` both resolve to the Teams tab. The tab chips should navigate to the path form.
4. **Removable routes:** none now. `…/opponent-payment` may be retired only after real payment events exist (Priority D).
5. **Implementation note:**
   - If a route-level `redirect` were ever used on a parent path that has children, it would also fire for the children. Guard it with `state.fullPath`.
   - Prefer R-state / R-sheet builders to avoid this entirely.

---

## 14. Back navigation strategy

| Pattern | System Back | App-bar Back | Close | Tab switch |
|---|---|---|---|---|
| Tab that absorbed a child route | Non-default tab → default tab (path pop, as today) | Same | — | `go(tabRoute)`; returning to the default tab pops |
| Original tabs (Match Mgmt, Requests, My Matches, My Registrations) | Leaves the workspace (as today) | Same | — | `go(?tab=)` replaces |
| Sheet (R-sheet) | Closes the sheet | ✕ in the sheet | Scrim tap or drag down closes it; a decision closes it, then a toast | — |
| Inline mode | Leaves the mode (keeps drafts) | Mode's Cancel/Back | — | — |
| Stepper | Previous step (path pop) | Same | — | — |
| Terminal screens | PopScope redirects (unchanged) | Hidden | — | — |
| Role switch | Never undone by Back (stack replaced; unchanged) | — | — | — |

**No new Back loops:**
- Sheets and modes never push another copy of their host.
- Success screens keep replacing.

---

## 15. State preservation strategy

| State | Where it lives | Effect of consolidation |
|---|---|---|
| Selected tabs | URL `?tab=` / route path | Preserved |
| Filters | `historyFilterProvider`, `teamSquadFilterProvider(id)`, `addPlayersFilterProvider(id)`, `lineupFilterProvider(target)`, Browse city, My Registrations tab, Hunt filters | Preserved (providers) |
| Search text | `membersQueryProvider`, `openMatchesQueryProvider` | Preserved |
| Drafts | `squadEditorProvider`, `lineupDraftProvider`, `registrationDraftProvider`, `clubSetupProvider`, `bookingProvider(id).draft`, `huntDraftProvider` | Preserved |
| **Gap** | Match Setup custom-overs text (local until Continue) | **Write through to the draft** before merging |
| Local form state | Edit Profile controllers | Move into the Profile widget's edit-mode state; cancel restores |
| Booking timer | `holdRemainingProvider` (derived from `expiresAt − now`) | Unaffected (Payment and Waiting stay standalone) |
| Role | `roleControllerProvider` | Unaffected |
| Selected entity | Route ids | Preserved (R-state / R-sheet keep the ids in the path) |

---

## 16. Responsive strategy

| Pattern | 320 | 360 | 375 | 390 | 414 | Tablet (≥840 dp) |
|---|---|---|---|---|---|---|
| Tabs (`CeChipRow`) | Horizontal scroll; 5 host tabs scroll | Scroll | Fits 3–4 | Fits 4 | Fits 5 | Chips remain |
| Full-height sheet | `DraggableScrollableSheet`, initial 0.92, max 0.95; internal scroll; sticky action row | Same | Same | Same | Same | Side panel (master–detail) |
| Partial sheet (Role Setup, team picker) | Content height, capped at 0.88 (existing `showCeSheet` cap) | Same | Same | Same | Same | Centered dialog-width sheet |
| Inline edit / mode | Keyboard-safe `ListView` + `viewInsets` padding | Same | Same | Same | Same | Same |
| Stepper | 7-dot progress, 2-line step title, sticky footer CTA (2-line labels allowed) | Same | Same | Same | Same | Content max width ~640 |
| Expandable sections | 48 dp headers; labels wrap | Same | Same | Same | Same | Same |

- Split layouts are **tablet only**. No desktop-style split is forced on phones.
- Every consolidated screen must join the existing width sweep (320–414).

---

## 17. Accessibility considerations

- **Sheets:**
  - `Semantics(scopesRoute, namesRoute)` with a title.
  - Focus moves to the sheet and returns to the row that opened it.
  - A visible ✕ close button (not only drag).
  - Back closes the sheet.
- **Tabs:** chips keep `Semantics(selected)`. The tab count is announced ("Scorecard, tab 2 of 2").
- **Expandable sections:** the header is a button with an expanded / collapsed state and a 48 dp target. Critical actions (Submit, Pay, Accept) are **never** inside a collapsed section.
- **Inline edit:** entering edit mode moves focus to the first field; Save / Cancel sit in the app bar and at the end of the form.
- **Stepper:**
  - Announce "Step N of 7" (already provided by `WorkflowProgress`).
  - Focus goes to the step title on change.
  - Keyboard order: body, then footer.
- **Touch targets:** at least 40 dp (the existing `CeSize.touchTarget`); rows at least 48 dp.
- **Text:** 2-line wrapping retained; no truncation of amounts or dates.
- **Screen-reader order in master–detail:** list first, then detail. The detail is announced as a region.

---

## 18. Risk matrix

**Risk levels:**
- **LOW:** a pure visual consolidation.
- **MED:** navigation or state presentation changes, but contained.
- **HIGH:** touches booking, payments, role, tournaments, challenge state or multi-step forms.

| Proposal | Risk | Why | Extra tests |
|---|---|---|---|
| Privacy / sign-in sections in Settings | LOW | Toggles only | Toggle persists; route renders the section |
| Profile inline edit | LOW | 3 fields | Validate / save / cancel; Back cancels |
| Performance tabs + chart | LOW | Read-only | History filter; chart renders with 0/1/12 entries |
| Match tabs (Scorecard) | LOW | Read-only | Tab hidden without a scorecard |
| Tournament host tabs (Dashboard, Manage Teams) | MED | Tournament screens; actions unchanged | Remove before fixtures; decide via sheet |
| Registration Request sheet | MED | Organizer decision in a sheet | Accept / reject closes the sheet; notification deep link |
| Requests master–detail | MED | Membership decisions | Role safety; notification deep link; tab kept |
| Challenges workspace + Club Profile sheet | MED | Challenge area (logic untouched) | Send from sheet → Status / My Challenges; Back from tabs |
| Squad edit mode | MED | Draft persistence | Leave / return keeps the draft; Save |
| Line-up build mode + picker sheets | MED | Shared by match and tournament | Confirm destinations for both targets |
| Registration summary disclosure | MED | Submit path | Agree required; guards; Success replace |
| Role Setup sheet | MED | Role-switch entry | Switch without a profile → sheet → Choose Option |
| Create Club stepper | HIGH | Grants the Club Owner role | Draft across steps; guard on a step-2 deep link; role set once |
| Booking setup stepper | HIGH | Booking | Full booking regression (§23) |
| Payment / Waiting / Opponent / Expired / Confirmed | — | **Not changed** | — |

---

## 19. Estimated standalone screen count after consolidation

| Measure | Count |
|---|---|
| Current standalone screens | 74 (73 routes + Not Found) |
| **Recommended standalone screens** | **≈ 51** |
| Converted to tabs | 6 |
| Converted to master–detail | 3 |
| Converted to sheets | 4 |
| Converted to inline modes | 4 |
| Converted to expandable sections | 1 |
| Converted to stepper steps | 4 |
| Converted to progressive disclosure | 1 |
| Routes removed | 0 |
| Routes preserved as redirects | 0 needed (all 23 preserved as R-state / R-sheet) |

The count is "≈" because the stepper hosts still render one page per step path internally. Visually each host is one screen.

---

## 20. Priority recommendations

**Priority A — safe, high value**

1. Settings: Privacy and Sign-in sections (#10, part of #11).
2. Profile inline edit (#27).
3. Performance workspace with the History tab and chart (#25).
4. Match workspace with the Scorecard tab (#23).
5. Tournament host workspace: Dashboard tab (#64) and Teams tab with requests (#65).

**Priority B — medium risk (in this order)**

6. Registration Request sheet (#66), pairs with A5.
7. Requests master–detail (#35).
8. Challenges workspace (#38, #39) and Club Profile sheet (#41).
9. Squad edit mode (#31).
10. Line-up build mode and picker sheets for match and tournament, plus the Registration Summary disclosure (#55, #56, #69, #70, #71).
11. Role Setup sheet (#7).
12. Create Club stepper (#14).
13. Booking setup stepper with the Ground Details sheet (#45–#48). HIGH risk, done last.

**Priority C — keep standalone:** every KEEP row in §3 (51 screens).

**Priority D — do not touch before a backend exists:**
- Payment, Waiting for Opponent, Opponent Payment (demo), Reservation Expired and the expiry guards.
- The auth and onboarding redirect structure (Login / Sign Up / Create Account / Complete Profile / Playing Style).
- The notification target contract.

---

## 21. Screens that must remain standalone

- **Auth and onboarding:** Login, Sign Up, Create Account, Complete Profile, Playing Style, Continue As.
- **Club setup and membership:** Choose Option, Enter Club Code, Waiting Approval, Join Approved.
- **Role homes:** Player Dashboard, Club Dashboard.
- **Branch roots and destinations:** Availability, Open Matches, My Matches, Player Profile, My Teams, Members, My Club.
- **Shared:** Notifications, Settings, Password & security.
- **Club modules:** Requests, Player Hunt, Challenges, Create Availability Slot, Challenge Status.
- **Match Management and the money path:** Match Management, Payment, Waiting for Opponent, Opponent Payment, Booking Confirmed, Reservation Expired.
- **Tournaments:** Tournament Hub, Browse, My Registrations, My Tournaments, Create Tournament, Tournament Published, participant Tournament Details, Registration Success, Registration Details.
- **Not Found.**
- **Hosts** that stay standalone and absorb others: Settings, Create Club, Match Details, My Performance, Player Profile, Team Squad, Requests, Challenges, Match Setup, Select Team (match and tournament), Tournament Details (host).

---

## 22. Routes that should resolve to workspace state instead of being deleted

| Route | Resolves to |
|---|---|
| `/settings/privacy` | Settings, Privacy section expanded |
| `/player/profile/edit` | Profile, edit mode |
| `/player/performance/history` | Performance, History tab |
| `/player/matches/:id/scorecard` | Match, Scorecard tab |
| `/club/teams/:id/add-players` | Team Squad, edit mode |
| `/club/requests/:id` | Requests + detail sheet |
| `/club/challenges/mine`, `/club/challenges/find` | Challenges, matching tab |
| `/club/clubs/:id` | Club Profile sheet (over the calling tab, or over the dashboard on a deep link) |
| `/role-setup` | Role home + Role Setup sheet |
| `/setup/club/create/details` | Create Club stepper, step 2 |
| `/club/matches/:id/setup/ground` | Stepper step 2 |
| `…/ground/:groundId` | Ground Details sheet over step 2 |
| `…/schedule` | Stepper step 4 |
| `…/schedule/summary` | Stepper step 5 |
| `/club/matches/:id/lineup/build` | Line-up, build mode |
| `/club/matches/:id/lineup/pick` | Team-picker sheet |
| `/club/tournaments/hosted/:id/dashboard` | Dashboard tab |
| `/club/tournaments/hosted/:id/teams` | Teams tab |
| `…/teams/requests/:rid` | Registration Request sheet |
| `/club/tournaments/browse/:id/team/build` | Build mode |
| `/club/tournaments/browse/:id/team/pick` | Picker sheet |
| `/club/tournaments/browse/:id/team/summary` | Select Team with the review section |

---

## 23. Required regression tests

1. **Route contract:** every one of the 73 routes still resolves to its own location with no error page (existing test, unchanged).
2. **Deep links:** each R-state / R-sheet route opened cold renders the right tab, mode or sheet with its parent underneath.
3. **Notifications:** every target (join request, challenges, registration, tournament request, player match, profile, availability) opens its state inside the active role.
4. **Back:** for every consolidation, the Back sequence matches §14. Sheets close first, tabs return to the default, modes exit.
5. **State:** filters, tabs, search text and all drafts survive tab switches, sheet open/close and mode toggles.
6. **Booking (HIGH):**
   - format/overs/city → ground → details sheet → date/slot → review → reserve → payment;
   - slot conflict → back to step 4 with a toast;
   - hold countdown after returning;
   - expiry while on each step;
   - re-entering after expiry starts a fresh draft;
   - deep link into each step.
7. **Club creation (HIGH):** the draft survives steps; a step-2 deep link without step 1 goes back to step 1; the role is granted exactly once; Back from step 2 → step 1.
8. **Requests:** approve as Coach/Manager keeps the membership only; the owner role is refused; tab counts update after a sheet decision.
9. **Challenges:** send from the Club Profile sheet (Demo on → Status; Demo off → My Challenges); accept creates one pending match.
10. **Tournaments:** host Teams tab Remove only before fixtures; accept from the request sheet respects the full / closed rules; registration submit guards; Success replaces.
11. **Line-up:** build and pick for both the match and tournament targets; locked players are skipped; Confirm destinations.
12. **Responsive:** the width sweep (320–414) for every workspace in each tab, mode and sheet state; a tablet width (e.g. 900 dp) for the master–detail layouts.
13. **Accessibility:** sheet focus and close semantics; expandable header state; tab selected semantics.

---

## 24. Implementation order

1. **A1** Settings sections (Privacy, Sign-in). Establishes the expandable-section widget.
2. **A2** Profile inline edit.
3. **A3** Performance workspace and History chart. Establishes the workspace-tab pattern (R-state) and the chart painter.
4. **A4** Match workspace (Scorecard).
5. **A5 + B6** Tournament host workspace and Registration Request sheet. Establishes the R-sheet page type.
6. **B7** Requests master–detail. Reuses the R-sheet type and adds the tablet panel.
7. **B8** Challenges workspace and Club Profile sheet.
8. **B9** Squad edit mode.
9. **B10** Line-up build mode, picker sheets and Registration Summary disclosure.
10. **B11** Role Setup sheet.
11. **B12** Create Club stepper.
12. **B13** Booking setup stepper (last among the B items; full booking regression).
13. **Final regression QA:** full suite, width sweep, tablet check, emulator pass.

Each step is independently shippable and keeps every route working, so the order can pause after any step.

---

## 25. Final recommendation

- **Approve Priority A** now: pure presentation with high clarity gains.
- **Approve Priority B** step by step in the order above.
- Keep the 51 standalone screens in §21. Leave the money path and auth structure (D) alone until a backend exists.
- The route-preserving approach (R-state / R-sheet) means:
  - **no route is deleted or redirected**;
  - notification targets and deep links keep working;
  - today's Back behaviour is kept.
- **Result:** about **74 → 51** standalone screens, with the same journeys, roles, state transitions and business rules.

### Findings outside consolidation (for awareness; not changed)

- **My Profile's career stats come from a different source.** They use `playerStatsProvider` (demo generator), while the Dashboard and My Performance use `performanceProvider`. Their numbers can differ. Unifying the source is recommended before any Performance/Profile merge is considered.
- **Several Player branch roots send Back straight to the Dashboard.** My Matches, My Performance, Profile, Open Matches and Availability all hard-code Back → Dashboard, even when reached from another branch. This is consistent with the approved design; noted for awareness.
- **No own-club result statistics exist.** The own `Club` model has no win/loss data, so no club win/loss graph is proposed.
- **The Hub's "Venues" row stays informational** until the approved P8 read-only ground browse exists.

---

## Appendix — graph candidates (data-backed only; §8 of the brief)

| Candidate | Data (exact fields) | Chart | Verdict |
|---|---|---|---|
| Performance History | `PerformanceSummary.matchLog`: 12 dated `MatchLogEntry` (`date`, `runs`, `balls`, `wickets`, `result`) | Runs-per-match bars coloured by result; wickets as dots | **Recommended** (History tab) |
| Recent form | `recentForm` (5 × `FormEntry`: `result`, `runs`, `wickets`, no dates) | — | Existing chips are clearer; no chart |
| Scorecard | `Innings.batting` (`runs`, `balls`), `Innings.bowling` (`wickets`, `runs`, `overs`) | Per-batter runs bar | Optional, low priority; tables remain primary |
| Opponent club | `ClubSummary.wins/losses/played/winRate/recentForm` | — | Existing win-rate bar + form dots suffice |
| Tournament standings | `Standing.played/won/lost/points` | — | The table is clearer |
| Own club | none | — | **Not proposed** (no data) |
| Dashboard snapshot / StatTile | `StatTile.value` is a String | — | Not plottable |

**Implementation:** there is no chart package in `pubspec.yaml`. Use a small `CustomPainter` (no new dependency), or get approval for a charting package before adding one.

## Appendix — expandable sections and progressive disclosure

- **Expandable sections (default state):**
  - Settings Privacy / Sign-in (collapsed).
  - Scorecard innings (expanded).
  - Host Tournament summary on non-Overview tabs (key rows + "More details").
  - Participant Tournament Details "All details" and participating clubs past 4.
  - Club Profile sheet: About, Captain, Key Players (collapsed; form, win rate and Challenge stay visible).
  - Ground Details: specs and amenities (collapsed).
  - Registration Details: "Your Squad" (collapsed).
  - Booking Confirmed: settlement (expanded).
- **Progressive disclosure already in the app (kept):**
  - Custom overs appear only for Custom (Match Setup, Create Team, Create Slot, Create Tournament).
  - Availability reason and until-date appear only when you're not Available.
  - Demo panels appear only in Demo Mode.
  - Discard appears only when the draft is dirty.
  - Remove team is offered only before fixtures.
  - "Mark all read" appears only when something is unread.
  - "Your Published Slots" appears only when there are posts.
  - The "previously rejected" note.
- **Proposed:**
  - The registration review section appears once a squad exists.
  - Create Tournament's "Optional details" (entry fee, prize, description) collapse.
  - My Teams: "+ New Team" reveals the create form (optional).
  - Select Date: verify that the slot grid is hidden until a date is chosen; if not, show a hint instead.

## Appendix — expandable table rows (audited)

Few rows benefit, and this is reported honestly:
- Members rows carry no extra data.
- Match History and scorecard rows already show every field.
- Registration and request rows lead to complex detail, which is served better by the master–detail sheets.
- **Only proposal:** Team Squad rows may open the existing Player Stats sheet (read-only). No new data is shown.
