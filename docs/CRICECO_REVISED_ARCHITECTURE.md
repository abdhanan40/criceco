# CricEco — Revised Flutter Architecture (v2, post-review)

**Status:** blueprint only; no Flutter code yet. This document supersedes the navigation, state and route sections of `CRICECO_FLUTTER_MIGRATION_AUDIT.md` (§4, §6, §22, §26, §29, §31–34). The rest of the audit (screen inventory, forms, states, tokens, widgets) stays valid as the parity checklist.

**Governing rules (approved):**
- Keep intended behaviour; do not reproduce confirmed bugs.
- No screen is removed or merged without approval.
- Role architecture: single account → Continue As → Player / Club Owner → role-specific navigation → in-app switching.
- Player and Club Owner data and navigation stay separate.
- System Back never undoes a role switch.
- Logout clears authenticated navigation.
- Typed models and enums replace globals.

---

## 1. Revised route map

**Conventions**
- Paths carry every entity id. There is no hidden "current X" state (see §10).
- Flow steps use `context.go()`, so the page stack always equals the path hierarchy. Back therefore returns to the logical parent.
- **Shell** routes show the role bottom nav. **Full** routes use `parentNavigatorKey: rootKey`: they have no bottom nav but keep the role's parent pages underneath.
- **Guard** means role-prefix redirects (§4.4).
- 🆕 marks a new route; ✎ marks a route whose behaviour changed from the prototype.

### 1.1 Public / auth (guard: unauthenticated only, except onboarding)

| Name | Path | Back | Notes |
|---|---|---|---|
| login | `/login` | exit app | root |
| signup | `/signup` | → `/login` | |
| createAccount | `/signup/account` | pop | |
| completeProfile | `/onboarding/profile` | pop · Skip → `/continue-as` | requires the authenticated-but-onboarding state |
| roleDetails | `/onboarding/playing-style` | pop · Skip → `/continue-as` | |

### 1.2 Shared (guard: authenticated)

| Name | Path | Nav | Back | Notes |
|---|---|---|---|---|
| continueAs | `/continue-as` | none | exit app | clears the active role before a role is chosen |
| roleSetup | `/role-setup` | none | → active role home | |
| notifications | `/notifications` | none | pop (fallback: role home) | content comes from the active role |
| settings | `/settings` | none | pop (fallback: role home) | |
| privacySettings | `/settings/privacy` | none | → `/settings` | |
| securitySettings | `/settings/security` | none | → `/settings` | |

The drawer is **not a route** (§4).

### 1.3 Club setup and membership onboarding (guard: authenticated; no role prefix)

| Name | Path | Back | Notes |
|---|---|---|---|
| chooseOption | `/setup/club` | none (hamburger opens the current role's drawer; Logout) | |
| createClub | `/setup/club/create` | pop | |
| clubDetails | `/setup/club/details` | pop | submit: creates the club, grants the Club Owner profile, sets role = club, `go('/club')` |
| enterClubCode ✎ | `/join?from=clubSetup` | → `/setup/club` (prototype went to Continue As) | `from` lets a Player entry be added later with no refactor |
| waitingApproval | `/join/waiting` | PopScope → `from` origin | |
| joinApproved ✎ | `/join/approved` | none | CTA always → `/player` (§2, fix C) |

### 1.4 Player (guard: `activeRole == player`) — `StatefulShellRoute`, 4 branches

| Branch (nav item) | Name | Path | Nav | Back |
|---|---|---|---|---|
| **Home** | playerDashboard | `/player` | shell (Home) | exit app / PopScope |
| Home | availability ✎ | `/player/availability` | shell (Home) — "Squad" item removed | → `/player` |
| Home | openMatches | `/player/open-matches` | shell (Home) | → `/player` |
| **Matches** | myMatches | `/player/matches?tab=upcoming\|past\|cancelled` | shell (Matches) | → `/player` |
| Matches | **playerMatchDetails 🆕** | `/player/matches/:matchId` | shell (Matches) | → `/player/matches` |
| Matches | matchScorecard ✎ | `/player/matches/:matchId/scorecard` | shell (Matches) | → match details |
| **Performance** | myPerformance | `/player/performance` | shell (Performance) | → `/player` |
| Performance | matchHistory | `/player/performance/history` | shell (Performance) | → `/player/performance` |
| **Profile** | playerProfile | `/player/profile` | shell (Profile) | → `/player` |
| Profile | editProfile | `/player/profile/edit` | full | → `/player/profile` |

### 1.5 Club Owner (guard: `activeRole == club && hasClubOwnerProfile`) — `StatefulShellRoute`, 4 branches, plus full routes

| Branch | Name | Path | Nav | Back |
|---|---|---|---|---|
| **Home** | clubHome | `/club` | shell (Home) | exit / PopScope |
| **Teams** | teams | `/club/teams` | shell (Teams) | → `/club` |
| Teams | teamSquad | `/club/teams/:teamId` | shell (Teams) | → `/club/teams` |
| Teams | addTeamPlayers | `/club/teams/:teamId/add-players` | full | → team squad |
| Teams | createTeam (legacy) | `/club/teams/new` → **redirect `/club/teams`** (pending P17) | — | — |
| **Members** | members | `/club/members` | shell (Members) | → `/club` |
| **Profile** | myClub | `/club/my-club` | shell (Profile) | → `/club` |
| — | joinRequests | `/club/requests` | full | → `/club` |
| — | joinRequestProfile | `/club/requests/:requestId` | full | → requests |
| — | openPlayers (Player Hunt) | `/club/player-hunt?tab=find\|available` | full | → `/club` |
| — | challenges | `/club/challenges` | full | → `/club` |
| — | myChallenges | `/club/challenges/mine` | full | → `/club` (sibling tab: `go`, replaces) |
| — | findMatch | `/club/challenges/find` | full | → `/club` (sibling tab) |
| — | createAvailabilitySlot | `/club/challenges/slots/new` | full | pop |
| — | clubProfile (opponent) | `/club/clubs/:clubId` | full | pop |
| — | challengeAccepted ✎ | `/club/challenges/:challengeId/accepted` | full | PopScope → `/club/matches?tab=waiting` |
| — | upcomingMatches (Match Management) | `/club/matches?tab=waiting\|scheduled\|history` | full | → `/club` |
| — | matchSetup | `/club/matches/:matchId/setup` | full | → match management |
| — | bookGround | `/club/matches/:matchId/setup/ground` | full | pop |
| — | groundDetails | `…/ground/:groundId` | full | pop |
| — | selectDate | `…/ground/:groundId/schedule` | full | pop |
| — | bookingSummary | `…/schedule/summary` | full | pop |
| — | payment | `/club/matches/:matchId/payment` | full | → match management (the hold stays active) |
| — | waitingForOpponent | `/club/matches/:matchId/waiting` | full | PopScope → match management |
| — | opponentPayment | `/club/matches/:matchId/opponent-payment` | full | PopScope (demo only, §11) |
| — | bookingConfirmed | `/club/matches/:matchId/confirmed` | full | PopScope → scheduled |
| — | reservationExpired | `/club/matches/:matchId/expired` | full | PopScope → waiting tab |
| — | selectTeam (match) | `/club/matches/:matchId/lineup` | full | pop |
| — | teamBuilder (match) | `/club/matches/:matchId/lineup/build` | full | → lineup |
| — | teamPicker (match) | `/club/matches/:matchId/lineup/pick` | full | → lineup |
| — | hostTournament (Hub) ✎ | `/club/tournaments` | full | → `/club` |
| — | createTournament | `/club/tournaments/new` | full | → hub |
| — | tournamentPublished ✎ | `/club/tournaments/:tournamentId/published` | full | none; "View Tournament" **replaces** it with Details |
| — | myTournaments | `/club/tournaments/hosted` | full | → hub |
| — | tournamentDetails | `/club/tournaments/hosted/:tournamentId?tab=overview\|teams\|fixtures\|points` | full | → My Tournaments |
| — | tournamentDashboard | `…/hosted/:tournamentId/dashboard` | full | → details |
| — | tournamentTeamsManage | `…/hosted/:tournamentId/teams` | full | → details |
| — | teamRequestDetail | `…/hosted/:tournamentId/teams/requests/:registrationId` | full | → manage teams |
| — | browseTournaments | `/club/tournaments/browse?city=` | full | → hub |
| — | tournamentRegister | `/club/tournaments/browse/:tournamentId` | full | → browse |
| — | selectTeam (tournament) | `…/browse/:tournamentId/team` | full | pop |
| — | teamBuilder (tournament) | `…/browse/:tournamentId/team/build` | full | → team |
| — | teamPicker (tournament) | `…/browse/:tournamentId/team/pick` | full | → team |
| — | registrationSummary | `…/browse/:tournamentId/summary` | full | → team |
| — | myRegistrations | `/club/tournaments/registrations?tab=pending\|approved\|rejected` | full | → hub |
| — | registrationDetails | `/club/tournaments/registrations/:registrationId` | full | → My Registrations |
| — | registrationSuccess ✎ | `/club/tournaments/registrations/:registrationId/success` | full | PopScope; both CTAs replace |

**Counts:** 71 prototype screens + 1 new (`playerMatchDetails`) = **72 screens**. `menu` is now the drawer widget rather than a route, and `createTeam` is a redirect until P17 is decided, so there are **70 page routes** plus the redirect. Nothing has been removed.

---

## 2. Revised role ownership matrix

| Owner | Screens | Change from audit |
|---|---|---|
| Public / Auth | login, signup, createAccount, completeProfile, roleDetails | — |
| Shared (role-aware) | continueAs, roleSetup, notifications, settings, privacySettings, securitySettings, **drawer (widget)** | drawer is chrome, not a screen |
| Club setup onboarding | chooseOption, createClub, clubDetails | — |
| Membership onboarding (role-neutral; ends in Player) | enterClubCode, waitingApproval, joinApproved | Coach/Manager no longer lands in Club Owner (fix C) |
| **Player (10)** | playerDashboard, availability, openMatches, myMatches, **playerMatchDetails 🆕**, matchScorecard, myPerformance, matchHistory, playerProfile, editProfile | +1 new; `editProfile` explicitly Player |
| **Club Owner (44)** | as in the audit, plus the createTeam redirect | Tournaments drawer item → hub |

### Role-leak fixes

| Leak | Fix |
|---|---|
| **A — Availability "Squad"** | Availability uses the standard Player nav (Home · Matches · Performance · Profile), so the Squad item no longer exists. No Player-side squad screen exists in the prototype, so nothing is invented. Flagged as **P1**. |
| **B — "View Match Details"** | Opens `/player/matches/:matchId` for the dashboard's next match. The Player stays in the Player shell. |
| **C — Coach/Manager approval** | Creates a `ClubMembership{clubId, memberRole: coach\|manager}` on the account. It does **not** set `hasClubOwnerProfile` or `activeRole = club`. CTA → `/player`. The membership role shows on My Profile's Club row. Label: see **P3**. |
| Structural guard | Any `/club/**` location while `activeRole != club` redirects to the active role's home. `/player/**` works the same way. Only explicit actions (Continue As, drawer switch, club creation) change `activeRole`. Navigating can **never** change the role. This replaces the prototype's render hook. |

---

## 3. Player Match Details (new)

- **Route:** `/player/matches/:matchId`, in the Matches branch (nav shows Matches as selected).
- **Entries:**
  - Dashboard → Next Match → "View Match Details" (`go`, so it switches to the Matches branch).
  - My Matches → tap any card: upcoming, past or cancelled (P2).
  - Player notification "Match request…" (optional, P16).
- **Back:** → `/player/matches` (the logical parent). See P24 if Back should return to the dashboard.
- **Content** (from existing `PlayerMatch` data only; no Club Owner actions):

| Section | Source |
|---|---|
| Header card: SC vs opponent badges, "Shalimar CC vs {opponent}", status chip (CONFIRMED / PLAYED / CANCELLED) | `PlayerMatch` |
| Date · time · format (from `DateTime`, formatted) | `PlayerMatch.startsAt`, `format` |
| Ground + "Directions" (external Maps) | `ground` |
| Playing team ("Playing: BS CS XI") | `playingTeamName` |
| Your availability: the current `PlayerAvailability` chip + "Update Availability" → `/player/availability` | player availability state |
| Past: result line + **"View Scorecard"** → `/player/matches/:matchId/scorecard` (only if a scorecard exists) | `result`, `scorecardId` |
| Cancelled: "Reason: Rain" | `cancelReason` |
| Upcoming: countdown "Match starts in …", live from `startsAt` (replaces the static text) | clock provider |

- **Data link:** the dashboard's `nextMatchDemo` becomes a query, "first upcoming `PlayerMatch`" (Falcons CC in the seed). The dashboard stat "Upcoming Matches / Next: Tomorrow" is also derived from it.
- **Scorecard:** now keyed by `matchId` instead of opponent name.

---

## 4. Drawer and back architecture

### 4.1 The drawer is chrome
- A `RoleDrawer` widget is mounted as `Scaffold.drawer` on the screens that show a **hamburger**: `/player`, `/club`, `/setup/club` (same as the prototype).
- It is opened with `Scaffold.of(context).openDrawer()`. It never enters the route stack.
- **Item tap:** `Navigator.pop(context)` (closes the drawer), then `context.go(destination)`. Destinations are declared as children of the role home, so the stack becomes `[roleHome, destination]`. Back then returns to the dashboard, never to the drawer.
- **Active item:** matched from `GoRouterState.uri` prefix. The Settings item stays in the drawer. "Tournaments" opens `/club/tournaments` (the hub).
- **Switch row:** `RoleController.switchTo(role)` (§4.3). **Logout:** `SessionController.logout()`.

### 4.2 AppBar leading rule (one widget, `CeTopBar`)

| Condition | Leading |
|---|---|
| Route is a role home or `/setup/club` | ☰ hamburger |
| Anything else | ← back = `context.pop()` if `canPop`, else `context.go(logicalParent)` |

The logical parent is declared per route in the route table (§1). This covers deep links and a cold start into a nested route. Terminal screens (§1 PopScope rows) intercept system Back and redirect as listed.

### 4.3 Role switch
`RoleController.switchTo(role)`:
1. If the target is club and `!hasClubOwnerProfile` → `go('/role-setup')`.
2. Set `activeRole`.
3. `router.go(lastTopLevelRoute[role] ?? roleHome)`. `go` replaces the stack, and the other role's shell is disposed.
4. 160 ms fade and a SnackBar "Switched to {Role}".

Because `go` rebuilds the stack from the path, system Back at the new role's root exits (Android) and cannot reach the previous role. `lastTopLevelRoute` only records drawer-level destinations (prototype rule).

### 4.4 Router redirect order (`refreshListenable` = session + role)
1. Unauthenticated and not a public route → `/login`.
2. Authenticated with onboarding incomplete and not an onboarding route → `/onboarding/profile`. Skip marks it complete.
3. `/player/**` or `/club/**` with no active role → `/continue-as`.
4. `/club/**` without `hasClubOwnerProfile` → `/setup/club`.
5. `/player/**` while the role is club, or `/club/**` while the role is player → the active role's home.
6. `/login` while authenticated → `/continue-as`.

### 4.5 Logout
`SessionController.logout()`:
1. Clear the session, `activeRole` and `lastTopLevelRoute`.
2. `ref.invalidate` every authenticated feature provider (all are scoped under `sessionScopeProvider`).
3. Redirect to `/login` via the guard, which empties the stack.

Account-level data (`hasClubOwnerProfile`, memberships) lives in the mock account repository, not the session, so it is correct again on next login. Persistence across app restarts: **P21**.

---

## 5. Bottom navigation architecture

| Role | Items (fixed) | Implementation | Where shown |
|---|---|---|---|
| **Player** | Home · Matches · Performance · Profile | `StatefulShellRoute.indexedStack`, 4 branches (§1.4); selected = `navigationShell.currentIndex` | every Player route except `editProfile` |
| **Club Owner** | Home · Teams · Members · Profile (→ My Club) — the prototype's majority set (C-A) | `StatefulShellRoute`, 4 branches (§1.5) | only the 4 branch roots + Team Squad |

**Removed variants:**
- **P-B** (Availability "Squad") is gone; Availability uses the standard Player set.
- **C-B** and **C-C** (the two different "Matches" tabs on Challenges and Match Management) are gone.

The Club Owner's other modules (Requests, Player Hunt, Challenges, Match Management, Tournaments, booking, notifications) are drawer or dashboard destinations. They show as full routes with a back arrow and **no bottom nav**, because the club experience is drawer-driven. As a result, no "Matches" tab exists anywhere in the club nav.

Tapping the current tab pops that branch to its root (standard `goBranch(i, initialLocation: i == current)`). Label of the 4th club item: **P7**.

---

## 6. Booking and reservation state model

### 6.1 Models
```dart
enum BookingStatus { draft, held, awaitingOpponent, confirmed, expired, resolved }
enum HoldStatus    { active, confirmed, expired, released }
enum PaymentStatus { pending, processing, paid, refunded, movedToWallet }

class BookingDraft {           // Match Setup → Summary, editable
  MatchFormat? format; int? customOvers; String? city;
  String? groundId; DateTime? date /* local midnight */; TimeSlot? slot;
}
class TimeSlot { final TimeOfDay start, end; }   // label derived: "8am – 10am"

class ReservationHold {
  final String id, matchId, groundId;
  final DateTime slotStart, slotEnd;             // date + slot → real DateTimes
  final DateTime reservedAt, expiresAt;          // expiresAt = reservedAt + 30 min
  final HoldStatus status;
}
class PaymentRecord { PaymentMethodType method; int amount; PaymentStatus status; DateTime? at; }

class Booking {                                   // one per ClubMatch
  final String matchId, opponentClubId;
  final BookingDraft draft;
  final ReservationHold? hold;
  final int groundCost, shareAmount;              // cost = hourlyRate × 2
  final PaymentRecord? myPayment, opponentPayment;
  final Settlement? settlement;                   // commission 5 %, toGround
  final BookingStatus status;
}
```

### 6.2 Ownership and time
- `bookingProvider(matchId)` is a `NotifierProvider.family`, keepAlive for the session. It owns the draft, the hold, payments and status.
- The `ReservationRepository` holds all holds (including the seeded National Stadium one). `isSlotTaken(groundId, slotStart)` checks active or confirmed holds and ignores the caller's own match.
- `clockProvider` is an injectable `Clock` for tests. `tickerProvider` is a `Stream.periodic(1 s)`, alive only while any hold is active.
- **`ReservationExpiryWatcher`** is started once at the app root (listened in `CricEcoApp`), independent of the current screen. On every tick, for each active hold where `now >= expiresAt`:
  1. hold → `expired`, slot released;
  2. booking → `expired`;
  3. match → `pending` once resolved.
- **UI:** the remaining time is always `expiresAt − clock.now()`. It is shown on Payment, Waiting and the Match Management reserved card (all three, correct after leaving and returning). Screens for that match `ref.listen` for `expired` and `go('/club/matches/:id/expired')`. If the user is elsewhere, the Match Management card shows the "Reservation expired" state and opens the expired screen.
- **Dates:** every label (calendar header, summary "Date", Payment subtitle, Confirmed, Expired copy, match card) uses `DateFormat` on the `DateTime`. Month navigation changes a `visibleMonth` `DateTime` only, and the selected date keeps its own month and year. The mock day-availability function takes a `DateTime`.
- **Conflict:** `reserve()` does a transactional check-and-insert in the repository. On conflict: SnackBar, `draft.slot = null`, `go(…/schedule)`.
- **Idempotency:** re-reserving the same match replaces its own hold instead of adding a second one.
- **Expired resolution:**
  - `resolveExpired(refund | wallet)` → payment refunded or moved to wallet → booking `resolved` → match reset to `pending`.
  - If the hold expires **before** the user paid, there is nothing to refund: the match returns to pending with a SnackBar (**P13**).
- **Gateway:** `PaymentGateway` interface; `SimulatedPaymentGateway` (1.6 s processing → success). The opponent's payment arrives only through the demo action (§11) or, later, a backend event.

---

## 7. Team and squad persistence model

```dart
enum SelectionRole { playing, sub }
class TeamMember { final String playerId; final SelectionRole selection; }

class Team {
  final String id, clubId, name;
  final MatchFormat format; final int? customOvers;   // now stored (fix)
  final TeamCategory? category;                        // modelled, no UI yet (P4)
  final String? captainId, viceCaptainId;              // modelled, no UI yet (P4)
  final TeamStatus status;                             // default active (P4)
  final List<TeamMember> members;                      // XI + subs, order preserved
  final DateTime createdAt;
}

class SquadDraft { final String teamId; final Map<String, SelectionRole> picks; final bool dirty; }
```

- `teamsProvider`: an `AsyncNotifier` over `TeamRepository`, keyed by **id**, not name. `createTeam(name, format, customOvers?)` stores everything that was entered.
- `squadEditorProvider(teamId)`: a keepAlive family.
  1. Opening Add Players seeds it from `team.members` **with their saved selection roles** (fixes the index-based reset).
  2. Every tap updates the draft, which survives leaving and returning.
  3. "Save Squad" commits `members` to the team and clears the draft.
  4. The 11 + 4 caps and the injured/unavailable lock are unchanged. Semantics: **P5**.
- Team Squad reads `team.members`. Rows show a PLAYING XI / SUB badge (same style as Add Players), so the persisted state is visible (P5).
- Player pool: `clubPlayerPoolProvider` (the 20 seeded players). Approved members joining the pool: **P6**.
- Match-day and tournament line-ups:
  - `Lineup{target, sourceTeamId?, members}`, stored on `Booking` (match) or `TournamentRegistration`.
  - "Create New Team" in the Team Builder does **not** add to My Teams, as in the prototype.
  - The Team Builder and Add Players share one `SquadPicker` widget, with scouting stats shown only in Add Players (prototype parity).

---

## 8. Search ranking strategy

**One pure utility:** `List<T> rankedSearch<T>(items, query, {required List<SearchField<T>> fields})`, with `SearchField(getter, weight)` where the primary field is weight 0.

1. **Normalise:** trim, lowercase, collapse whitespace. An empty query returns the original order (no filtering).
2. **Score per field, best score wins:**

   | Tier | Rule |
   |---|---|
   | 0 | exact (whole value equals the query) |
   | 1 | value starts with the query |
   | 2 | any **word** of the value starts with the query (e.g. "raza" → "Ali Raza") — see P12 |
   | 3 | value contains the query |

   Anything else is excluded.
3. **Sort:** by `(tier, fieldWeight, value.length, value alphabetical, original index)`. The sort is stable.
   - Example, query "h": Hamza, Haris, Hassan (tier 1) come before Shahid and Ahmed (tier 3). Within a tier the order is alphabetical, so the brief's example order becomes Hamza, Haris, Hassan.
4. **Debounce:** 150 ms. The utility has unit tests with a table of fixtures.

**Where it applies:**

| Screen | Status | Fields |
|---|---|---|
| Open Matches (Player) | existing input | clubName (primary), location. The role-chip filter still applies first, as in the prototype. |
| Members (Club) | the prototype's static search box becomes a **real input** (fixes a dead control) | name (primary), phone |
| Teams, Available Players, Challenges / Find Match clubs, Browse Tournaments | the utility is ready, but **no search box exists in the prototype** | adding one is new UI → **P11** |

---

## 9. Tournament navigation structure

```
Drawer "Tournaments" ─┐
Dashboard "Tournament"┴─► Tournament Hub  /club/tournaments         (stats · 4 hub cards · Quick Overview)
   ├─ Create Tournament   /new ─► Published (/:id/published) ─ View Tournament ⇒ REPLACE ⇒ Details
   │                                                   └─ Back to Dashboard ⇒ go('/club')
   ├─ Browse              /browse ─► Register /browse/:id ─► Team /team ─► Build | Pick ─► Summary
   │                                  ─ Submit ⇒ REPLACE ⇒ /registrations/:regId/success
   │                                  ─ CTAs ⇒ REPLACE ⇒ Registration Details | My Registrations
   ├─ My Registrations    /registrations ─► /registrations/:regId
   └─ My Tournaments      /hosted ─► /hosted/:id?tab= ─► dashboard · teams ─► requests/:regId
Back from Browse / My Registrations / My Tournaments / Create ─► Hub.   Back from Hub ─► Dashboard.
```

Names are kept exactly: **Browse · My Registrations · My Tournaments** ("Tournament Center" hero).

**Fixes applied:**
- The drawer opens the hub.
- Success screens are replaced, so Back never returns to a success screen or to an emptied create form.
- `Tournament.organizerClubId` is the owner's own club, not the last-viewed club.
- A single `Tournament` model covers hosted and browse tournaments (`maxTeams`, `rules[]`, `organizerClubId`).
- Registrations are keyed by `registrationId` + `teamId`. Pending and joined lists hold registration ids, never a mix of names and abbreviations. Approval moves an entry from pending to joined.
- Knockout brackets auto-advance **BYE** entries, so every bracket can complete.
- The seed duplicate (IU listed twice) is removed.
- Create Tournament also validates end date ≥ start date and deadline ≤ start date. This is a small new validation, revertible if unwanted.

Hub "Venues" → **P8**.

---

## 10. Explicit selected-context state

The rule: **ids live in the route; entities are read through typed providers keyed by those ids.** Nothing is set before navigating.

| Prototype global | Replaced by |
|---|---|
| `currentClubAbbr` (5 jobs) | **selectedClub** = `currentClubProvider` (the owner's own club, from the session). **selectedOpponentClub** = `clubSummaryProvider(clubId)` from `/club/clubs/:clubId`, and `Booking.opponentClubId`. Organizer = `Tournament.organizerClubId`. Captain = `Team.captainId`. |
| `activeMatchId`, `matchesList.find` | **activeMatch** = `clubMatchProvider(matchId)` from `:matchId` |
| `wf` | **activeBooking** = `bookingProvider(matchId).draft` |
| `wf.ground` | **selectedGround** = `groundProvider(groundId)` from `:groundId` + `draft.groundId` |
| `currentTournamentId` / `currentBrowseTournamentId` | **selectedTournament** = `tournamentProvider(tournamentId)` (one id space) |
| `currentRegistrationId` | `registrationProvider(registrationId)` |
| `currentTeamName` | **selectedTeam** = `teamProvider(teamId)` |
| `currentJoinRequestIndex` | `joinRequestProvider(requestId)` (no array indices) |
| `currentScorecardOpponent` | `scorecardProvider(matchId)` |
| `currentTeamRequestAbbr` | `registrationProvider(registrationId)` |
| `teamSelectionContext` | `sealed class LineupTarget { MatchLineup(matchId) \| TournamentEntry(tournamentId) }`, implied by which route tree is used |
| `selectedRegisterTeam`, `agreeToRules` | `registrationDraftProvider(tournamentId)` |
| `upcomingTab`, `tournamentDetailsTab`, `myRegTab`, `openPlayersTab` | `?tab=` query parameters (deep-linkable) |
| `joinClubCode` / requested name / approved role | `outgoingJoinRequestProvider` → `ClubJoinRequest`, and `ClubMembership` on approval |
| `playerAvailable` vs `playerStatus` (they diverged) | one `playerAvailabilityProvider`. The dashboard pill toggles available ↔ unavailable on the same state. |

**Provider scopes:**
- *Global:* `sessionProvider`, `roleControllerProvider`, `currentAccountProvider`, `currentClubProvider`, `demoModeProvider`, `clockProvider`.
- *Feature:* repositories and list notifiers.
- *Flow:* `bookingProvider(id)`, `squadEditorProvider(id)`, `registrationDraftProvider(id)`, `lineupDraftProvider(target)`.
- *Local:* form controllers, filters, dropdown/open flags, carousel index.

---

## 11. Demo Mode architecture

- **Flag:** `const kDemoBuild = bool.fromEnvironment('CRICECO_DEMO', defaultValue: true)`. At runtime, `demoModeProvider` starts from it. When `kDemoBuild` is true, a "Prototype controls" toggle appears in Settings (P25).
- **Isolation:** all simulation lives in `lib/demo/` as `DemoActions` services that call the same repository and controller APIs a backend would:
  - `DemoClubApproval`, `DemoOpponentPayer`, `DemoReservationTools`, `DemoOrganizer`, `DemoMatchResults`, `DemoChallengeResponder`
  - seed data and the `ceStats` hash generator.

  Production widgets never import `lib/demo/`.
- **UI:** one `DemoOnly(child)` gate and one `DemoPanel` look: a dashed amber border, a flask icon, the label "Prototype controls", and secondary-sized buttons. These never use primary-CTA styling.

| Control (prototype) | Screen | Demo ON | Demo OFF |
|---|---|---|---|
| As Player / Coach / Manager | Waiting for Approval | DemoPanel | hidden; approval arrives from the owner side |
| Opponent Pays Now → Opponent Payment | Waiting for Opponent | DemoPanel → `opponentPayment` route | hidden; waits for the opponent payment event |
| Dev: force reservation to expire now | Waiting for Opponent | DemoPanel (sets `expiresAt = now`) | hidden |
| Simulate Organizer Decision (Approve / Reject) | Registration Details | DemoPanel | hidden |
| "Tap to simulate result" | Tournament Details / Dashboard, Registration Details | fixture tap simulates the result | fixtures read-only (**P10**) |
| Instant challenge acceptance | Challenges, Find Match, Club Profile | Send → `accepted` → Challenge Accepted screen (the approved flow) | Send → `ChallengeStatus.pending`; UI for this state → **P9** |
| KRC001 demo hints | Set Up Your Club, Enter Club Code | shown | hidden |
| "Final Year Project — payments are simulated" note | Payment | shown | hidden |
| Random logo / photo pickers | Create Club, Complete Profile | placeholder picker | same until a real image picker is approved |

`Challenge` is modelled fully: `status ∈ {pending, accepted, declined, expired}`, plus `direction ∈ {sent, received}`. My Challenges' Accept and Decline become real state changes: Accept creates **one** pending match and moves the card to Resolved; Decline moves it to Resolved (declined). No duplicates are possible.

---

## 12. Bug fixes applied by default (principle A: don't preserve confirmed bugs)

Role leaks L1–L3 · drawer history · squad XI/Sub loss · team format loss · booking month · screen-bound expiry · unranked search · hosted-tournament organizer · BYE deadlock · duplicate pending matches · My Challenges Decline doing nothing · Enter Club Code back target · open-to-offers invisible (the player's listing now uses the account city) · availability pill / status divergence · dashboard static "Next: Tomorrow", countdown and badge (derived) · Find Match "5 Teams" (derived count) and the Riders/Rams seed mismatch · password eye toggles · dead Members search · Complete Profile and Edit Profile fields bound and saved · "Share with players" copies the code to the clipboard · re-reserve idempotency · registration pending/joined id mixing · Tournament Published / Registration Success back stack · name- and index-keyed entities.

Each will appear as a checklist item in the Foundation and feature phases, so any of them can be reverted individually.

---

## 13. Open product decisions

**Blocking for the Foundation phase** (they affect models, shells or config):

| ID | Question | Default if no answer |
|---|---|---|
| P4 | Team **Category, Captain, Vice-Captain, Status** have no UI in the prototype. Add fields to the Create Team or Team Squad UI, or model only? | model as nullable, no new UI |
| P7 | Label of the 4th Club Owner nav item, which opens My Club | keep "Profile" |
| P21 | Persist the active role and last route across app restarts (the prototype used localStorage)? | yes, `shared_preferences` (cleared on logout) |
| P25 | Demo mode default for release builds | ON for the FYP build; OFF via `--dart-define` |

**Needed before the related feature phase:**

| ID | Question | Default |
|---|---|---|
| P1 | Is a Player-side "Squad / My Team" view wanted? (The Availability "Squad" item is removed.) | no new screen |
| P2 | My Matches: should **all** cards open Match Details, with past-match scorecards reached from there? | yes |
| P3 | Join Approved CTA label for Coach/Manager ("Go to Coach Dashboard" is inaccurate) | "Continue to Dashboard" → `/player` |
| P5 | Squad edits: keep the draft until Save (a draft survives leaving) or autosave on each tap? Show the XI/Sub badge on Team Squad? | draft until Save; badge shown |
| P6 | Should approved members enter the club player pool for Add Players? | no (prototype) |
| P8 | Hub "Venues" (currently starts booking with no match) | read-only ground browse (Book a Ground in view mode, no Continue) |
| P9 | Demo OFF: where does a *sent, pending* challenge appear? | "Sent" section on My Challenges |
| P10 | Demo OFF: how are match results and organizer decisions entered? No UI exists. | out of scope; read-only |
| P11 | Add search boxes to Teams, Available Players, club lists and Browse? | no; only where the prototype has one |
| P12 | Keep the word-prefix tier (tier 2) above "contains"? | yes |
| P13 | Hold expires before the user paid | return to pending + SnackBar; the expired screen is only shown if a payment exists |
| P14 | My Club "Teammates" heading in the owner context | rename to "Members" |
| P15 | Settings "Notifications" row opens the inbox, not preferences | keep → inbox |
| P16 | Player notification "Tournament update" routes to Open Matches (no Player tournament screen) | make that item non-navigating (no Player tournament screen exists); others unchanged |
| P17 | Legacy `createTeam` | redirect to My Teams |
| P18 | Confirmation dialogs for destructive actions (logout, remove, reject, cancel request) | none (prototype) |
| P19 | Availability status grid: 5 across or 3 columns | 3 columns |
| P20 | Include T10 in `MatchFormat` | yes |
| P22 | Unify naming (Player Hunt / Open Player / Open Players; Match Management / Upcoming Matches) | keep the prototype labels per location |
| P23 | Allow duplicate team names? | block with a SnackBar |
| P24 | Back from Match Details opened from the dashboard | → My Matches (branch parent) |

---

## 14. Foundation phase scope (after approval)

1. Project setup: Flutter stable, `flutter_riverpod` + `riverpod_annotation`, `go_router`, `freezed` / `json_serializable`, `intl`, `url_launcher`, `shared_preferences`, `lucide_icons`, `google_fonts` (Manrope), `clock`.
2. `ThemeData` from the tokens: primary `#158447`, deep `#0B3324`, secondary `#105C38`, fresh `#28A85F`, mint `#EAF6EF`. The `#0D3F2A` host override is ignored.
3. Router: all routes from §1 as placeholder pages, both shells, guards (§4.4), the drawer, `CeTopBar` back rules, and PopScope terminals.
4. Models and enums (§6, §7, §10 and audit §20–21) with stable ids.
5. Mock repositories seeded verbatim from the prototype (with the seed fixes from §12).
6. Session and role state: `SessionController`, `RoleController`, `demoModeProvider`, clock, ticker, `ReservationExpiryWatcher`.
7. Shared widgets (audit §23) plus `rankedSearch` with unit tests.
8. Tests: router redirect table, role-switch back behaviour, drawer back behaviour, expiry watcher (fake clock), `rankedSearch` tiers.

No feature screens beyond placeholders will be built in the Foundation phase.
