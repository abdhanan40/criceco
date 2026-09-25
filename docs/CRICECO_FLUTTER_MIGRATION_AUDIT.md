# CricEco — Flutter Migration Audit & Blueprint

**Phase:** audit only. No Flutter code written, prototype not modified.
**Source of truth:** `C:\Users\NEW TECH\Desktop\criceco-4\` — `CricEco.dc.html`, `criceco-app.js` (8,279 lines, fully read), `icons.js`.
**Audit date:** 2026-09-23

Line references below are `criceco-app.js:<line>`.

> **Note on the source bundle.** `criceco-app.js` is a generated file (`src/build.js` builds it from `src/criceco-v18.html` + `override.css` + `role-context.js`). As instructed, only the attached bundle was treated as authoritative. The `screenshots/` folder predates the bundle: `01-drawer.png` shows a **Challenges** item in the Player drawer, but the current code has none. The screenshots were not used as evidence.

---

## 0. Conflicts between the audit brief and the prototype (read first)

Per your instruction, conflicts are reported first. In every case below the prototype's behaviour is documented as the baseline; nothing has been changed.

| # | Brief expects | Prototype actually does | Evidence |
|---|---|---|---|
| X1 | Search ranking rule `startsWith(query)` above `contains(query)` | **The rule is not implemented anywhere.** The only working search (Open Matches) is an unranked `includes()` filter on club name and location. The Members search box is a static `<div>`, not an input. | `:3531-3534`, `:5425` |
| X2 | Player **Match Details** screen | **No such screen.** The Player dashboard's "View Match Details" button opens the **Club Owner** Match Management screen (`upcomingMatches`) and silently switches the active role to Club Owner. Past matches open a Scorecard. Upcoming and cancelled matches open nothing. | `:4053`, `:7976-7981` |
| X3 | My Matches tabs: Upcoming / **Completed** / Cancelled | Tabs are **Upcoming / Past / Cancelled**. The chip on completed matches reads "PLAYED". | `:3426-3430` |
| X4 | Challenges → Find Match → Opponent Profile → Send Challenge → Accepted → **Match Setup** | Sending a challenge is **instantly accepted** (toast, then the Challenge Accepted screen). There is no "sent / awaiting opponent" state. "Accepted" does not open Match Setup directly: it adds a *pending* match and opens **Match Management → Waiting**. Tapping that card opens Match Setup. | `:6141-6144`, `:6174`, `:6874` |
| X5 | Tournaments split into Discover / Registered / Hosted | Labels are **Browse Tournaments / My Registrations / My Tournaments**, grouped under a "Tournament Center" hub (`hostTournament`). The drawer's "Tournaments" item skips the hub and opens **My Tournaments**. The hub is reachable only from the dashboard quick action "Tournament". | `:4497-4551`, `:7839` |
| X6 | Login → Continue As → **Player Profile** OR Club Owner | Matches. However, **Join a Club** (club code → approval) sits inside the *Club Owner setup* screen (`chooseOption`). Choosing "Player Profile" goes straight to a dashboard for demo club KRC001 without ever joining a club. | `:3120-3150`, `:8042-8049` |
| X7 | Design tokens (single brand green) | Two conflicting defaults: the bundle CSS sets `--primary` to `#158447`, but `CricEco.dc.html` has a `primaryGreen` prop defaulting to **`#0D3F2A`** that overwrites `--primary`, `--green` and `--primary-600` at runtime. Which value wins depends on style-injection order, which could not be verified: the in-app browser cannot run scripts on a local file. **Decision needed.** | `CricEco.dc.html:24-38`, `:1877` |
| X8 | "Profile Setup / Playing Style" | Matches: `completeProfile` (Step 2 of 3) → `roleDetails` ("Playing Style", Step 3 of 3). Step 1 is Create Account, which is implied rather than labelled. The Google path skips Step 1. | `:3009`, `:3101`, `:2934` |

---

## 1. Total unique screens

**71 screen keys** are defined in `screens.*`, all of them reachable. There are **no undefined navigation targets**: every `go('…')` target exists. This was checked programmatically.

| Category | Count |
|---|---|
| Public / Authentication | 5 |
| Shared (role-aware) | 8 (including `menu`, which is a drawer overlay implemented as a screen) |
| Club Owner onboarding (club setup) | 3 |
| Club membership onboarding (Join a Club) | 3 |
| Player | 8 |
| Club Owner | 44 |
| **Total** | **71** |

Prototype-only chrome that is **not** part of the app and must not be migrated: the phone frame, the notch, the desktop "side panel" screen list (`.side-panel`, `bindNav`), and the DC props host.

Of the 71, **1 is a legacy duplicate** (`createTeam`) and **1 has a dead legacy definition** (the first `screens.menu`, overridden at load). See §24.

---

## 2. Complete screen inventory

**Legend.** Back values: `back()` pops the history stack; `→ X` is a hard-coded destination; "none" means no back control. The **Nav** column refers to the bottom-nav variant, defined in §20 (P-A, P-B, C-A, C-B, C-C). **Drawer** means the item is listed in the role drawer. "Sim" marks a prototype simulation control.

### 2.1 Public / Authentication

| # | Screen · key | Entry | Back | Drawer / Nav | Primary CTA | Secondary actions | Tabs / filters | Form fields | Overlays | Success / Error / Empty | Local state | Depends on |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | Login · `login` (:2898) | App start (`cricecoInit`), Logout, chooseOption Logout pill, links | none (root) | — / none | Login → `continueAs` (no validation) | Sign Up toggle and link → `signup` | Login/Sign Up toggle pill | Phone, Password (eye icon is inert) | — | none | none | — |
| 2 | Sign Up landing · `signup` (:2919) | Login toggle/link | none (Login toggle pushes `login`) | — / none | Create New Account → `createAccount` | Continue with Google → `completeProfile`; Login link | toggle pill | — | — | — | — | — |
| 3 | Create Account · `createAccount` (:2953) | signup | `back()` | — / none | Create Account → `completeProfile` (no validation) | Login link | Segmented control: Phone Number / Email | Full Name (prefilled "Aman Ali", bound), Phone *or* Email (bound), Password, Confirm Password (unbound) | — | none | `accountFullName`, `accountContactMethod`, `accountPhone`, `accountEmail` | — |
| 4 | Complete Profile · `completeProfile` (:3001) | createAccount, Google | `back()`; **Skip** → `continueAs` | — / none | Continue → `roleDetails` | Photo picker (random placeholder icon) | Role pills | Photo (optional), Full Name*, Date of Birth*, Phone* (all static, unbound), Role* | — | Toast: "Please select your role" | `profile.pic`, `profile.role` | — |
| 5 | Playing Style · `roleDetails` (:3064) | completeProfile | `back()`; **Skip** → `continueAs` | — / none | Save Profile → `continueAs` | Wicketkeeper toggle (Batsman only) | Batting pills, Bowling pills | Batting Style*, Bowling Style*, Wicketkeeper (block order varies by role) | — | Toast: "Please select both styles" | `profile.battingStyle`, `profile.bowlingStyle`, `profile.isWicketkeeper` | `profile.role` |

### 2.2 Shared (role-aware)

| # | Screen · key | Entry | Back | Drawer / Nav | Primary CTA | Secondary actions | Content | Overlays | States | Local / global state |
|---|---|---|---|---|---|---|---|---|---|---|
| 6 | Continue As · `continueAs` (:8017) | Login; Skip/Save on onboarding; Cancel join; Waiting "Back to Home"; enterClubCode back | none | — / none | Player Profile card → `playerDashboard` (history reset) | Club Owner card → `clubHome`, or `chooseOption` if no club profile (tag "Setup required") | Two role cards and a note | — | — | `ceRole`, `ceHasClubProfile` |
| 7 | Role Setup · `roleSetup` (:7900) | Drawer switch to Club when there is no club profile | → role home | — / none | "Set Up Club Owner Profile" → `chooseOption` (history reset) | "Not now" → role home | `ceEmptyState` (shield icon) | — | — | `ceRole` |
| 8 | Drawer · `menu` (:7923) | Hamburger (player/club dashboards, chooseOption); dashboard "Quick Actions → View All"; Settings → Active profile | Tap outside or ✕ → origin screen (pushed, not popped) | Is the drawer | Role switch row | Nav items per role, Settings, Logout | Profile header (avatar, name, role pill, club tag) | Overlay | — | reads history for the origin screen; may correct `ceRole` |
| 9 | Notifications · `notifications` (:8105) | Player bell; drawer (both roles); Settings row | → role home | Drawer both / none | Tap row → destination (§13) | — | Role-specific static list | — | Empty state (unreachable: lists are static) | `ceRole` |
| 10 | Settings · `settings` (:8126) | Drawer (both roles) | → role home | Drawer / none | — | Account → `ceGoAccount()`; Active profile → `menu`; Notifications → `notifications`; Privacy; Password & security; Log out | Two grouped cards | — | — | `ceRole` |
| 11 | Privacy · `privacySettings` (:8198) | Settings | → `settings` | — / none | — | 3 toggles | Public profile, Show my stats, Show phone number | — | — | `cePrefs` |
| 12 | Password & Security · `securitySettings` (:8207) | Settings | → `settings` | — / none | Update Password → `settings` + toast | 2 toggles | Current password, New password; Two-step verification, Login alerts | — | Toast: "Password updated" | `cePrefs` |
| 13 | Edit Profile · `editProfile` (:8223) | playerProfile "Edit" | → `playerProfile` | — / none | Save Changes → `playerProfile` + toast | — | Full name (saved), City, Phone (not saved) | — | Toast: "Profile updated" | `accountFullName` |

### 2.3 Club Owner onboarding (club setup)

| # | Screen · key | Entry | Back | Primary CTA | Secondary actions | Fields | Validation (toast) | State |
|---|---|---|---|---|---|---|---|---|
| 14 | Set Up Your Club · `chooseOption` (:3120) | Continue As → Club (no profile); Role Setup CTA | none. Hamburger → `menu`; "Logout" pill → `login` | Create a Club → `createClub` | Join a Club → `enterClubCode`; demo hint "KRC001" | — | — | Name is hard-coded as "ali" |
| 15 | Create Club · `createClub` (:4087) | chooseOption | `back()` | Continue → `clubDetails` | Logo picker (random icon) | Logo (optional), Club Name*, Owner Name (prefilled), Address, City* (inline dropdown, 11 options) | "Please enter a club name", "Please select a city" | `club.*`, `clubCityOpen` |
| 16 | Club Details · `clubDetails` (:4143) | createClub | `back()` | Create Club → `clubHome` (sets the Club Owner profile flag) | Home Ground inline list | Club Email (optional), Club Type* (3 options), Home Ground (optional, 4 grounds) | "Please select a club type" | `club.*`, `clubTypeOpen`, `clubGroundOpen` |

### 2.4 Club membership onboarding (Join a Club)

| # | Screen · key | Entry | Back | Primary CTA | Secondary actions | States | State |
|---|---|---|---|---|---|---|---|
| 17 | Enter Club Code · `enterClubCode` (:3166) | chooseOption "Join a Club" | → `continueAs` (not its parent `chooseOption`) | Send Join Request → `waitingApproval` | — | Toast: "Please enter a club code". Code KRC001 maps to "Karachi Ravians CC"; any other code becomes "Club {CODE}" | `joinClubCode`, `joinClubRequestedName` |
| 18 | Waiting for Approval · `waitingApproval` (:3190) | enterClubCode | none | Cancel Request → toast + `continueAs` | Back to Home → `continueAs`; **Sim:** "As Player / As Coach / As Manager" → `joinApproved` | Pulse animation, 3-step checklist, Pending chip | — |
| 19 | Join Approved · `joinApproved` (:3233) | Sim buttons | none | "Go to {Role} Dashboard" → `playerDashboard` (Player) **or `clubHome` (Coach/Manager)** | — | Success screen and summary | `joinClubApprovedRole`; appends to `membersList` |

### 2.5 Player

| # | Screen · key | Entry | Back | Drawer | Nav | Primary CTA | Secondary actions | Tabs / filters | Empty | Local state |
|---|---|---|---|---|---|---|---|---|---|---|
| 20 | Player Dashboard · `playerDashboard` (:3961) | Continue As, Join Approved, role switch, Home tab, notification/settings back | none (hamburger, bell with static "3" badge) | Dashboard | P-A (Home active) | Quick actions: My Matches, Availability, My Performance, Open Matches | Availability pill toggles `playerAvailable`; "View All" → drawer; **"View Match Details" → `upcomingMatches` (Club Owner)**; Directions (external maps); Snapshot "See All" → `myPerformance` | — | — | `playerAvailable` |
| 21 | My Profile · `playerProfile` (:8052) | Drawer "My Profile", Profile tab, notification, Settings → Account, Edit save | → `playerDashboard` (hard-coded) | My Profile | none | View Full Performance → `myPerformance` | Edit → `editProfile`; Update Availability → `availability` | — | — | derived from `ceStats(name)`; phone, city and availability rows are hard-coded |
| 22 | My Matches · `myMatches` (:3419) | Quick action, drawer, Matches tab, notification | → `playerDashboard` | My Matches | P-A (Matches active) | Past card with scorecard → `matchScorecard` | Directions (external) | Tabs: Upcoming / Past / Cancelled | "No {tab} matches" | `myMatchesTab` |
| 23 | Scorecard · `matchScorecard` (:3345) | Past match card | `back()` | — | P-A (none active) | — | — | — | not-found guard | `currentScorecardOpponent` (keyed by opponent **name**) |
| 24 | My Performance · `myPerformance` (:3906) | Quick action, drawer, Performance tab, profile, snapshot | → `playerDashboard` | My Performance | P-A (Performance active) | Match-by-Match "View All" → `matchHistory` | — | Tabs: Batting / Bowling / Fielding | — | `perfTab` |
| 25 | Match History · `matchHistory` (:3875) | My Performance "View All" | → `myPerformance` | — | P-A (Performance active) | — | — | Tabs: All / Won / Lost | "No matches" | `matchHistoryFilter` |
| 26 | Availability · `availability` (:3673) | Quick action, drawer, profile, notification | → `playerDashboard` | Availability | **P-B** (none active; "Squad" → `teams`, a Club Owner screen) | Update Availability (toast) | Change Status (scrolls to the panel); info button (toast); open-to-offers toggle | Status grid (5), Reason select, "Unavailable Until" quick chips and inline calendar | — | `playerStatus`, `pendingStatus`, `availReason`, `availUntilOption`, `availUntilDate`, `availDatePickerOpen`, `availPickerMonthOffset`, `playerAvailNotes`, `playerOpenToOffers` |
| 27 | Open Matches · `openMatches` (:3528) | Quick action, drawer, notification | → `playerDashboard` | Open Matches | P-A (none active) | "I'm Interested" → toast; button becomes "Interest Sent" | Open-to-offers toggle | Search (club/location, `includes`); role chips All/Batsman/Bowler/All-Rounder/Wicket-Keeper | "Choose a role to get started", "No open requests", `No results for "…"` | `openMatchesSearch`, `openMatchesRoleFilter`, `huntInterest`, `playerOpenToOffers` |

### 2.6 Club Owner

| # | Screen · key | Entry | Back | Drawer | Nav | Primary CTA | Secondary actions | Tabs / filters | Overlays | Empty / states | Local state |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 28 | Club Owner Dashboard · `clubHome` (:4199) | Club Details, Continue As, role switch, Home tab, many backs | none (hamburger) | Dashboard | C-A (Home active) | 7 quick actions: Requests, Members, Teams, Challenges, **Open Player**, Upcoming Matches, Tournament | "Share with players" (toast "Club code copied!"); Next Match "View All" → `upcomingMatches`; Directions | — | — | Next Match block hidden if there is no confirmed match | — |
| 29 | My Club · `myClub` (:3449) | Drawer "My Club", **Profile tab (club)**, Settings → Account (club) | → role home | My Club | none in the club role (the player nav branch is unreachable) | — | — | — | — | "No members listed yet." | — |
| 30 | Members · `members` (:5419) | Quick action, drawer, Members tab | → `clubHome` | Members | C-A (Members active) | — | Search box (**static div**) | — | — | none | — |
| 31 | Requests · `joinRequests` (:5337) | Quick action, drawer, notification | `back()` | Requests | none | Row → `joinRequestProfile` | ✕ decline; "Accept" (as Player) | — | — | "No pending requests" | — |
| 32 | Join Request → Player Profile · `joinRequestProfile` (:5290) | Requests row | → `joinRequests` | — | none | Approve (with the selected role) → `back()` + toast | Reject → `back()` + toast | Role select: Player / Coach / Manager | — | "No performance data available yet."; not-found guard | `currentJoinRequestIndex` (**array index**), `joinRequestRole` |
| 33 | My Teams · `teams` (:5453) | Quick action, drawer "My Teams", Teams tab, hub "Total Teams" | → `clubHome` | My Teams | C-A (Teams active) | Inline "Create Team" | Team row → `teamSquad` | Format pills | — | Toasts: "Please enter a team name", "Please select a format", "Team created!" | `newTeam` |
| 34 | Create Team (legacy) · `createTeam` (:5399) | **Side panel only** (the legacy drawer that linked it is overridden) | `back()` | — | none | "Create Team" → toast + `teams` (**creates nothing**) | — | — | — | — | — |
| 35 | Team Squad · `teamSquad` (:5549) | Team row, Save Squad | → `teams` | — | C-A (Teams active) | Add Players → `addTeamPlayers` | — | Chips with counts: All / Batsman / Bowler / All-Rounder | — | "No {filter} in this squad." | `currentTeamName` (**name key**), `teamSquadFilter` |
| 36 | Add Players · `addTeamPlayers` (:5626) | Team Squad | → `teamSquad` | — | none | Save Squad → `teamSquad` + toast | Row tap cycles Playing → Sub → Unselected; **Stats** → player sheet | Chips with counts | Player Stats sheet | Toasts: "…can't be added", "Playing XI and substitutes are full", "Squad updated!"; "No {filter} available." | `teamPlayerRoles`, `addPlayersFilter` |
| 37 | Player Hunt / Open Players · `openPlayers` (:7500) | Quick action "Open Player", drawer "Player Hunt" | → `clubHome` | Player Hunt | C-A (none active) | "Post Player Requirement" | Remove Slot; Invite (toast) | Underline tabs: Find Players / Available Players; hunt form; City and Role selects | — | Toasts: "Please select the role you need", "Player requirement posted!", "Slot removed", "Invite sent to …"; "Choose a city and role", "No {role} available" | `openPlayersTab`, `newHunt`, `openPlayersCityFilter`, `openFilter` |
| 38 | Challenges · `challenges` (:6994) | Quick action, drawer | `back()` | Challenges | **C-B** (Matches active) | Card "Challenge" → `startChallenge` | Card → `clubProfile`; Create Availability Slot box; Remove slot | Tab row: Challenges / My Challenges / Find Match | — | — | — |
| 39 | My Challenges · `myChallenges` (:7044) | Tab row, notification | → `challenges` | — | C-B | Accept Challenge → pending match + `upcomingMatches` (Waiting) | Decline (toast only) | tab row | — | Sections: Awaiting / Resolved (static) | — |
| 40 | Find Match · `findMatch` (:7104) | Tab row, Post Slot | → `challenges` | — | C-B | "Send Match Request" → `startChallenge` | Card → `clubProfile`; slot box | tab row | — | Header says "5 Teams" but shows 2 | — |
| 41 | Create Availability Slot · `createAvailabilitySlot` (:7188) | Challenges / Find Match box | `back()` | — | none | Post Availability Slot → `findMatch` + toast | inline dropdowns | Format pills; time-slot pills | — | Toasts for format, overs, city, date, slot | `availSlotDraft`, `availSlotCityOpen`, `availSlotGroundOpen` |
| 42 | Club Profile (opponent) · `clubProfile` (:6073) | Challenge and Find Match cards | `back()` | — | none | Challenge This Club → toast → `challengeAccepted` | — | — | — | — | `currentClubAbbr` |
| 43 | Challenge Accepted · `challengeAccepted` (:6160) | `startChallenge` (400 ms) | none | — | none | View in Upcoming Matches → pending match + `upcomingMatches` (Waiting) | — | — | — | Success card | `currentClubAbbr` |
| 44 | Match Management · `upcomingMatches` (:6863) | Quick action, drawer, dashboard Next Match, hub, notification, booking exits, **Player "View Match Details"** | → `clubHome` | Match Management | **C-C** (Matches active) | Waiting card → `openMatchSetup` (→ setup, payment or waiting) | Scheduled: Directions; "Select Your Playing XI" → `selectTeam` | Tabs with counts: Waiting / Scheduled / History | — | "No {tab} matches" + per-tab copy | `upcomingTab` |
| 45 | Match Setup · `matchSetup` (:6187) | Pending card | `back()` | — | none | Continue → `bookGround` | — | Format list (4); Custom overs input; City dropdown (20) | inline dropdown | Toasts: "Please select a format and city", "…number of overs" | `wf`, `setupCityOpen` |
| 46 | Book a Ground · `bookGround` (:6264) | Match Setup; **hub "Venues"** | `back()` | — | none | Continue → `groundDetails` | Ground card select | — | — | "No grounds listed in X yet — showing nearby options."; toast "Please select a ground" | `wf.ground` |
| 47 | Ground Details · `groundDetails` (:6296) | Book a Ground | `back()` (on the carousel) | — | none | "Continue → Pick a Date" → `selectDate` | Carousel prev/next/dots; Google Maps (external) ×2 | — | — | — | `gdPhotoIndex` |
| 48 | Select Date & Time · `selectDate` (:6398) | Ground Details; booking-conflict redirect | `back()` | — | none | "Continue → Booking Summary" | Month navigation | Calendar (available / partial / full); slot chips (open / booked / reserved) | — | Toasts: "fully booked that day", "Please pick a date", "Please pick a time slot" | `calMonthOffset`, `wf.date`, `wf.slot` |
| 49 | Booking Summary · `bookingSummary` (:6490) | Select Date | `back()` | — | none | "Reserve Ground for 30 Minutes" → `payment` | — | — | — | Conflict: toast and back to `selectDate` | — |
| 50 | Payment · `payment` (:6522) | Reserve; reserved card (unpaid) | `back()` (idle stage only) | — | none | "Pay Rs X via {method}" → processing → success → `waitingForOpponent` | Method radio (4) | — | — | Wallet "Insufficient" (disabled + toast); simulation notice | `paymentMethod`, `paymentStage` |
| 51 | Waiting for Opponent · `waitingForOpponent` (:6589) | After payment; reserved card (paid) | none | — | none | **Sim:** "Opponent Pays Now" → `opponentPayment` | **Dev:** "force reservation to expire now" | — | — | Live mm:ss countdown; expiry → `reservationExpired` | countdown interval |
| 52 | Opponent Payment · `opponentPayment` (:6626) | Waiting | none | — | none | auto → success → `bookingConfirmed` | — | — | — | processing / success | `paymentStage` |
| 53 | Booking Confirmed · `bookingConfirmed` (:6654) | finalizeBooking | none | — | none | Select Your Playing XI → `selectTeam` | View in Upcoming Matches → Scheduled | — | — | Settlement summary (commission) | — |
| 54 | Reservation Expired · `reservationExpired` (:6682) | Countdown expiry | none | — | none | Refund to Original Method | Move to CricEco Wallet → both go to Waiting tab | — | — | Toast (refund / wallet) | — |
| 55 | Select Team · `selectTeam` (:6713) | Booking Confirmed; Scheduled card; Tournament Register | `back()` | — | none | Create New Team → `teamBuilder` | Select Existing Team → `teamPicker` | — | — | Copy differs by context (match or tournament) | `teamSelectionContext` |
| 56 | Build Your Team · `teamBuilder` (:6750) | Select Team | → `selectTeam` | — | none | Confirm Team (exactly 11 + 4) → Scheduled matches, **or** Registration Summary | row tap cycles | Chips with counts | — | Toasts: "Select N more…", "Team confirmed!" | `squadRoles`, `squadFilter` |
| 57 | Select Existing Team · `teamPicker` (:6832) | Select Team | → `selectTeam` | — | none | Confirm Team → same as above | radio list | — | — | Toast: "Please select a team" | `selectedExistingTeam` |
| 58 | Tournament Center · `hostTournament` (:4497) | Dashboard quick action "Tournament" | → `clubHome` | — | C-A | Four hub cards (Create / Browse / My Tournaments / My Registrations) | Quick Overview: Upcoming → Match Mgmt, Teams → My Teams, **Venues → `bookGround`** | — | — | Badges: open-tournament count, pending-registration count | — |
| 59 | Create Tournament · `createTournament` (:4582) | Hub; My Tournaments "+ New" and empty CTA | → `hostTournament` | — | C-A | Publish Tournament → `tournamentPublished` | — | Format pills (+ overs), Type pills, City dropdown (20) | inline dropdown | 10 validation toasts, in order | `newTournament`, `createTournamentCityOpen` |
| 60 | Tournament Published · `tournamentPublished` (:4651) | Publish | none | — | none | View Tournament → `tournamentDetails` | Back to Dashboard → `clubHome` | — | — | Success | `currentTournamentId` |
| 61 | My Tournaments · `myTournaments` (:4710) | Hub; **drawer "Tournaments"** | → `hostTournament` | Tournaments | C-A | Card → `tournamentDetails` | "+ New" → `createTournament` | — | — | Empty state with "Host a Tournament" CTA | — |
| 62 | Tournament Details · `tournamentDetails` (:5075) | Published; My Tournaments; action sheet | `back()` | — | C-A | Manage Teams; Generate/View Fixtures; Tournament Dashboard | Share (link icon) → action sheet; ⋮ → action sheet; Remove team; tap fixture → simulate result | Tabs: Overview / Teams / Fixtures / Points Table | 2 action sheets | Tab-level empty states (§16) | `tournamentDetailsTab` |
| 63 | Tournament Dashboard · `tournamentDashboard` (:5118) | Details (Overview and Fixtures), action sheet | → `tournamentDetails` | — | C-A | — | tap fixture → simulate | — | — | Winner banner; "No upcoming matches" etc. | — |
| 64 | Manage Teams · `tournamentTeamsManage` (:5192) | Details, action sheet | → `tournamentDetails` | — | C-A | Pending row → `teamRequestDetail` | Remove (confirmed team) | — | — | "No pending registration requests.", "No teams have joined yet." | — |
| 65 | Registration Request · `teamRequestDetail` (:5229) | Manage Teams row | → `tournamentTeamsManage` | — | C-A | Accept → Manage Teams + toast | Reject → Manage Teams + toast | — | — | Toast: "Tournament is full" | `currentTeamRequestAbbr` |
| 66 | Browse Tournaments · `browseTournaments` (:4667) | Hub | → `hostTournament` | — | C-A | Register Team → `tournamentRegister` | View Registration → `registrationDetails` | City select (required) | — | "Choose a city", "No tournaments in X" | `browseTournamentsCityFilter` |
| 67 | Tournament Register Details · `tournamentRegister` (:7236) | Browse card | → `browseTournaments` | — | C-A | Continue Registration → `selectTeam` (tournament context) | View Registration; "Registration Full" (disabled) | — | — | "No clubs registered yet" | `currentBrowseTournamentId` |
| 68 | Registration Summary · `registrationSummary` (:7289) | Team Builder / Team Picker (tournament) | → `selectTeam` | — | none | Submit Registration → `registrationSuccess` | Agree checkbox | — | — | Toast: "Please agree to the tournament rules" | `agreeToRules`, `selectedRegisterTeam` |
| 69 | Registration Success · `registrationSuccess` (:7325) | Submit | none | — | none | View Registration → `registrationDetails` | My Registrations → `myRegistrations` | — | — | Success | `currentRegistrationId` |
| 70 | My Registrations · `myRegistrations` (:7360) | Hub, Success, notification | → `hostTournament` | — | C-A | View Details → `registrationDetails` | — | Tabs: Pending / Approved / Rejected | — | "No {tab} registrations" | `myRegTab` |
| 71 | Registration Details · `registrationDetails` (:7383) | My Registrations, Success, Browse, Register | → `myRegistrations` | — | C-A | (Pending) **Sim:** Approve / Reject | (Approved) tap fixture → simulate | — | — | Pending / Rejected empty states; Approved: teams, fixtures, points table, upcoming, results | `currentRegistrationId` |

---

## 3. Role ownership matrix

| Role | Screens |
|---|---|
| **Public / Auth** | login, signup, createAccount, completeProfile, roleDetails |
| **Shared (role-aware)** | continueAs, roleSetup, menu (drawer), notifications, settings, privacySettings, securitySettings, editProfile¹ |
| **Club Owner – setup onboarding** | chooseOption, createClub, clubDetails |
| **Club membership onboarding (Join a Club)²** | enterClubCode, waitingApproval, joinApproved |
| **Player** | playerDashboard, playerProfile, myMatches, matchScorecard, myPerformance, matchHistory, availability, openMatches |
| **Club Owner** | clubHome, myClub³, members, joinRequests, joinRequestProfile, teams, createTeam (legacy), teamSquad, addTeamPlayers, openPlayers, challenges, myChallenges, findMatch, createAvailabilitySlot, clubProfile, challengeAccepted, upcomingMatches, matchSetup, bookGround, groundDetails, selectDate, bookingSummary, payment, waitingForOpponent, opponentPayment, bookingConfirmed, reservationExpired, selectTeam, teamBuilder, teamPicker, hostTournament, createTournament, tournamentPublished, myTournaments, tournamentDetails, tournamentDashboard, tournamentTeamsManage, teamRequestDetail, browseTournaments, tournamentRegister, registrationSummary, registrationSuccess, myRegistrations, registrationDetails |
| **Future / Other** | None. "Coach" and "Manager" exist only as membership labels, with no screens. |

¹ `editProfile` edits the account name and always returns to `playerProfile`, so it lives in Player context.
² Ownership is ambiguous in the prototype: the flow is player intent, but its only entry is the Club Owner setup screen. On approval it routes Coach/Manager to the **owner's** dashboard. Recommendation: classify it as Player/membership onboarding, but **do not move it until you decide** (D6).
³ `myClub`'s code comment says "player-facing read-only club info" and its copy says "Teammates", but it is registered in the Club Owner drawer and the club "Profile" tab.

**How the prototype decides role (`ceRoleOf`, :7854).** A screen belongs to a role only if it appears in exactly one role's drawer list. Every other screen (including all nested flow screens) is role-neutral and keeps the current role. Every `render()` reassigns `ceRole` from the target screen (:7976-7981).

**Checks you asked for:**
- Player screens stay in Player context: **no**. Two in-app paths leak into Club Owner (L1, L2 in §6).
- Club Owner screens stay in Club Owner context: **yes**, except that `joinApproved` sends Coach/Manager to `clubHome` (L3).
- Challenges stays under Club Owner: **yes**. It is only in the club drawer and club quick actions.
- Notifications and Settings are shared and role-aware: **yes**. Content, back destination and account target all follow `ceRole`.

---

## 4. Complete route map (go_router input)

Proposed paths keep every screen as its own route; the screen key is kept as the route name. Parent/entry/back columns are the prototype's actual behaviour. "Shell" means the route sits inside the role's `StatefulShellRoute` with a bottom nav.

| Route name | Proposed path | Role | Parent | Entry points | Back destination (prototype) | Top-level / Nested | Auth | Requires role |
|---|---|---|---|---|---|---|---|---|
| login | `/login` | Public | — | start, logout | none | Top | No | — |
| signup | `/signup` | Public | login | login | (login toggle) | Top | No | — |
| createAccount | `/signup/account` | Public | signup | signup | pop | Nested | No | — |
| completeProfile | `/onboarding/profile` | Public | signup | createAccount, Google | pop; Skip → continueAs | Nested | No* | — |
| roleDetails | `/onboarding/playing-style` | Public | completeProfile | completeProfile | pop; Skip → continueAs | Nested | No* | — |
| continueAs | `/continue-as` | Shared | — | login, onboarding exits | none | Top | Yes | — |
| roleSetup | `/role-setup` | Shared | continueAs | drawer switch | role home | Top | Yes | — |
| (drawer) | *not a route* — Scaffold drawer | Shared | — | hamburger | close | Overlay | Yes | any |
| notifications | `/notifications` | Shared | role home | bell, drawer, settings | role home | Top (outside shell) | Yes | any |
| settings | `/settings` | Shared | role home | drawer | role home | Top | Yes | any |
| privacySettings | `/settings/privacy` | Shared | settings | settings | settings | Nested | Yes | any |
| securitySettings | `/settings/security` | Shared | settings | settings | settings | Nested | Yes | any |
| editProfile | `/player/profile/edit` | Shared/Player | playerProfile | profile "Edit" | playerProfile | Nested | Yes | player** |
| chooseOption | `/setup/club` | Club setup | continueAs | continueAs, roleSetup | none | Top | Yes | — |
| createClub | `/setup/club/create` | Club setup | chooseOption | chooseOption | pop | Nested | Yes | — |
| clubDetails | `/setup/club/details` | Club setup | createClub | createClub | pop | Nested | Yes | — |
| enterClubCode | `/join` | Membership | chooseOption | chooseOption | continueAs | Nested | Yes | — |
| waitingApproval | `/join/waiting` | Membership | enterClubCode | submit | none | Nested | Yes | — |
| joinApproved | `/join/approved` | Membership | waitingApproval | approval | none | Nested | Yes | — |
| playerDashboard | `/player` | Player | — | many | none | Shell tab 1 | Yes | player |
| myMatches | `/player/matches` | Player | playerDashboard | nav, drawer | playerDashboard | Shell tab 2 | Yes | player |
| matchScorecard | `/player/matches/:matchId/scorecard` | Player | myMatches | past card | pop | Nested | Yes | player |
| myPerformance | `/player/performance` | Player | playerDashboard | nav, drawer | playerDashboard | Shell tab 3 | Yes | player |
| matchHistory | `/player/performance/history` | Player | myPerformance | View All | myPerformance | Nested | Yes | player |
| playerProfile | `/player/profile` | Player | playerDashboard | Profile tab, drawer | playerDashboard | Shell tab 4 | Yes | player |
| availability | `/player/availability` | Player | playerDashboard | quick action, drawer | playerDashboard | Nested (shell) | Yes | player |
| openMatches | `/player/open-matches` | Player | playerDashboard | quick action, drawer | playerDashboard | Nested (shell) | Yes | player |
| clubHome | `/club` | Club | — | many | none | Shell tab 1 | Yes | club + clubProfile |
| teams | `/club/teams` | Club | clubHome | nav, drawer | clubHome | Shell tab 2 | Yes | club |
| teamSquad | `/club/teams/:teamId` | Club | teams | team row | teams | Nested | Yes | club |
| addTeamPlayers | `/club/teams/:teamId/add-players` | Club | teamSquad | Add Players | teamSquad | Nested | Yes | club |
| createTeam | `/club/teams/new` (legacy — pending D9) | Club | teams | side panel only | pop | Nested | Yes | club |
| members | `/club/members` | Club | clubHome | nav, drawer | clubHome | Shell tab 3 | Yes | club |
| myClub | `/club/my-club` | Club | clubHome | Profile tab, drawer | role home | Shell tab 4 | Yes | club |
| joinRequests | `/club/requests` | Club | clubHome | quick action, drawer | pop | Nested | Yes | club |
| joinRequestProfile | `/club/requests/:requestId` | Club | joinRequests | row | joinRequests | Nested | Yes | club |
| openPlayers | `/club/player-hunt` | Club | clubHome | quick action, drawer | clubHome | Nested | Yes | club |
| challenges | `/club/challenges` | Club | clubHome | quick action, drawer | pop | Nested | Yes | club |
| myChallenges | `/club/challenges/mine` | Club | challenges | tab, notification | challenges | Nested (tab) | Yes | club |
| findMatch | `/club/challenges/find` | Club | challenges | tab, post slot | challenges | Nested (tab) | Yes | club |
| createAvailabilitySlot | `/club/challenges/slot/new` | Club | challenges/findMatch | box | pop | Nested | Yes | club |
| clubProfile | `/club/clubs/:clubId` | Club | challenges/findMatch | card | pop | Nested | Yes | club |
| challengeAccepted | `/club/clubs/:clubId/challenge-accepted` | Club | clubProfile | send challenge | none | Nested | Yes | club |
| upcomingMatches | `/club/matches` | Club | clubHome | quick action, drawer | clubHome | Nested (shell) | Yes | club |
| matchSetup | `/club/matches/:matchId/setup` | Club | upcomingMatches | pending card | pop | Nested | Yes | club |
| bookGround | `/club/matches/:matchId/ground` | Club | matchSetup | setup; hub Venues | pop | Nested | Yes | club |
| groundDetails | `/club/matches/:matchId/ground/:groundId` | Club | bookGround | continue | pop | Nested | Yes | club |
| selectDate | `/club/matches/:matchId/schedule` | Club | groundDetails | continue; conflict | pop | Nested | Yes | club |
| bookingSummary | `/club/matches/:matchId/summary` | Club | selectDate | continue | pop | Nested | Yes | club |
| payment | `/club/matches/:matchId/payment` | Club | bookingSummary | reserve; reserved card | pop (idle only) | Nested | Yes | club |
| waitingForOpponent | `/club/matches/:matchId/waiting` | Club | payment | paid; reserved card | none | Nested | Yes | club |
| opponentPayment | `/club/matches/:matchId/opponent-payment` | Club | waitingForOpponent | sim | none | Nested | Yes | club |
| bookingConfirmed | `/club/matches/:matchId/confirmed` | Club | — | finalize | none | Nested | Yes | club |
| reservationExpired | `/club/matches/:matchId/expired` | Club | — | timer | none | Nested | Yes | club |
| selectTeam | `/club/matches/:matchId/team` · `/club/tournaments/browse/:tId/team` | Club | confirmed / register | 3 entries | pop | Nested (2 contexts) | Yes | club |
| teamBuilder | `…/team/build` | Club | selectTeam | card | selectTeam | Nested | Yes | club |
| teamPicker | `…/team/pick` | Club | selectTeam | card | selectTeam | Nested | Yes | club |
| hostTournament | `/club/tournaments` | Club | clubHome | quick action | clubHome | Nested | Yes | club |
| createTournament | `/club/tournaments/new` | Club | hostTournament | hub, + New | hostTournament | Nested | Yes | club |
| tournamentPublished | `/club/tournaments/:tId/published` | Club | createTournament | publish | none | Nested | Yes | club |
| myTournaments | `/club/tournaments/hosted` | Club | hostTournament | hub, drawer | hostTournament | Nested | Yes | club |
| tournamentDetails | `/club/tournaments/hosted/:tId` | Club | myTournaments | card, published | pop | Nested | Yes | club |
| tournamentDashboard | `/club/tournaments/hosted/:tId/dashboard` | Club | tournamentDetails | button, sheet | tournamentDetails | Nested | Yes | club |
| tournamentTeamsManage | `/club/tournaments/hosted/:tId/teams` | Club | tournamentDetails | button, sheet | tournamentDetails | Nested | Yes | club |
| teamRequestDetail | `/club/tournaments/hosted/:tId/requests/:clubId` | Club | tournamentTeamsManage | row | tournamentTeamsManage | Nested | Yes | club |
| browseTournaments | `/club/tournaments/browse` | Club | hostTournament | hub | hostTournament | Nested | Yes | club |
| tournamentRegister | `/club/tournaments/browse/:tId` | Club | browseTournaments | card | browseTournaments | Nested | Yes | club |
| registrationSummary | `/club/tournaments/browse/:tId/summary` | Club | selectTeam | confirm team | selectTeam | Nested | Yes | club |
| registrationSuccess | `/club/registrations/:regId/success` | Club | — | submit | none | Nested | Yes | club |
| myRegistrations | `/club/registrations` | Club | hostTournament | hub, success, notification | hostTournament | Nested | Yes | club |
| registrationDetails | `/club/registrations/:regId` | Club | myRegistrations | cards | myRegistrations | Nested | Yes | club |

\* In the prototype onboarding runs before authentication (no session model). In Flutter it runs after sign-up, so it needs an auth-but-onboarding-incomplete state.
\** Only while D3 is open.

---

## 5. Authentication flow (actual)

```
Login ──(Login, no validation)──────────────────────────────► Continue As
  │
  └─ Sign Up ─┬─ Create New Account ─► Create Account ─► Complete Profile (Step 2/3) ─► Playing Style (Step 3/3) ─► Continue As
              │                                            │ Skip ─────────────────────► Continue As
              │                                            (role required)             │ Skip ──► Continue As
              └─ Continue with Google ────────────────────► Complete Profile (skips Create Account)

Continue As ─┬─ Player Profile ─► Player Dashboard            (history reset; role = player)
             └─ Club Owner ─┬─ (has club profile) ─► Club Owner Dashboard   (history reset)
                            └─ (no profile, tag "Setup required") ─► Set Up Your Club
                                   ├─ Create a Club ─► Create Club ─► Club Details ─► Club Owner Dashboard  (profile flag set)
                                   └─ Join a Club  ─► Enter Club Code ─► Waiting ─► Join Approved ─► Player Dashboard | Club Owner Dashboard

Logout (drawer, Settings, chooseOption pill) ─► Login (history reset)
```

Facts and deviations:
- **Single account, multiple roles:** matches. "Signed in as {name} · one account, every role" (:8033).
- **Login always goes to Continue As**, even though `ceRole` is persisted in `localStorage`. There is no auto-resume of the last role.
- **First-time Club Owner setup:** there are two entries. One is Continue As → Club Owner with no profile, which goes to `chooseOption` (not `roleSetup`). The other is the drawer switch, which goes to `roleSetup` and then `chooseOption`. The profile flag is set when rendering `clubHome`, `clubProfile` **or `teams`** (:7981), not when the club form is submitted.
- **Logout does not clear** `ceRole`, `ceHasClubProfile` or `ceLastScreen` (all in `localStorage`, :7788-7803). The club profile survives logout and reload.
- The chooseOption "Logout" pill uses `go('login')`, which pushes onto history instead of resetting it.
- No validation on Login, Create Account or passwords. Password rules differ: "Min 6 characters" (:2979) versus "At least 8 characters" (:8214).
- Complete Profile inputs (name, DOB, phone) are unbound static values.

---

## 6. Role switching flow (actual)

| Aspect | Behaviour |
|---|---|
| Active-role state | `ceRole` ∈ {`player`, `club`}, persisted to `localStorage['criceco.activeRole']`, default `player` (:7801). |
| Available roles | Player is always available. Club Owner requires `ceHasClubProfile` (persisted). |
| Role setup state | `ceHasClubProfile=false` means the drawer shows "Set up Club Owner profile" with a + icon and subtitle "Create clubs and teams". Continue As shows a "Setup required" tag. |
| Last role screen | `ceLastScreen = {player, club}`. Only drawer destinations are remembered, never flow steps. Healed on load (:7992). |
| Switch action (`ceSwitchRole`, :7868) | Club without profile → `roleSetup`. Same role → go to home. Otherwise: set the role, pick the target (last screen, or home if the last screen is invalid), **reset history to `[target]`**, 160 ms fade, toast "Switched to {Role}". |
| Back after switching | The stack is reset, so Back at the root falls back to the role home (:8172). You cannot navigate back into the other role. |
| Drawer changes | Name, role pill (Player / Club Owner icon), club tag (player: "Club KRC001"; club: `club.name` or "Shalimar Cricket Club · 35HLWZ"), and a nav group per role (§8). |
| Dashboard changes | Player: `playerDashboard` with a "Player" pill. Club Owner: `clubHome` with a "Club Owner" crown tag. |
| Role badge | Drawer `ce-role-pill`, player hero pill, club hero `owner-tag`. There is no persistent badge in the app bar. |
| Drawer origin correction | Opening the drawer from a screen that belongs to the other role flips `ceRole` to that role (:7925). |

**Confirmed role-context leakage:**

| ID | Path | Effect | Evidence |
|---|---|---|---|
| **L1** | Player → Availability → bottom nav **"Squad"** → `teams` | Role silently becomes Club Owner **and `ceHasClubProfile` is set to true** (club setup skipped). The Club Owner drawer and nav appear. | `:3788`, `:7979-7981` |
| **L2** | Player Dashboard → Next Match → **"View Match Details"** → `upcomingMatches` | Role silently becomes Club Owner (no profile flag). The player sees the owner's booking and payment management. | `:4053` |
| **L3** | Join Approved as **Coach / Manager** → "Go to … Dashboard" → `clubHome` | The joining user becomes Club Owner of the demo club, and the profile flag is set. | `:3245`, `:7981` |
| L4 (dormant) | `myClub` renders the Player bottom nav when `ceRole==='player'` | Unreachable today, because rendering `myClub` forces the role to club first. It is a dead branch. | `:3495` |

---

## 7. Player flow

```
Player Dashboard (Home)
 ├─ ☰ Drawer: Dashboard · My Profile · My Performance | My Matches · Open Matches · Availability · Notifications | Settings · Switch · Logout
 ├─ 🔔 Notifications (badge "3", static)
 ├─ Availability pill (toggles Available / Unavailable only; does not change the Availability status)
 ├─ Quick actions: My Matches · Availability · My Performance · Open Matches  ("View All" opens the drawer)
 ├─ Next Match card: Directions (Google Maps, external) · View Match Details ─► [L2] Club Owner Match Management
 └─ Performance Snapshot (horizontal row) · See All ─► My Performance

My Matches ─ tabs Upcoming | Past | Cancelled
 └─ Past card (Titans CC, Warriors CC only) ─► Scorecard ─► back()
My Performance ─ tabs Batting | Bowling | Fielding ─ Match-by-Match (5) ─ View All ─► Match History (All | Won | Lost)
Availability ─ status grid ─ reason ─ until ─ notes ─ Update  (bottom nav "Squad" ─► [L1])
Open Matches ─ open-to-offers toggle ─ search ─ role chips (must pick a role) ─ I'm Interested
My Profile ─ Edit ─► Edit Profile ─ Save ─► My Profile
```

| Screen | Enters via | Actions → destinations | Back | Bottom nav | Local state | Empty | Modal/sheet |
|---|---|---|---|---|---|---|---|
| Player Dashboard | §2.5 | above | none | P-A (Home) | `playerAvailable` | — | Drawer |
| My Profile | drawer, Profile tab | Edit, View Full Performance, Update Availability | → Dashboard | none | — | — | — |
| My Matches | quick action, drawer, tab | scorecard (past only), Directions | → Dashboard | P-A (Matches) | tab | "No {tab} matches" | — |
| Scorecard | past card | — | back() | P-A (none) | opponent key | not-found | — |
| My Performance | quick action, drawer, tab | View All | → Dashboard | P-A (Performance) | perfTab | — | — |
| Match History | View All | filter | → My Performance | P-A (Performance) | filter | "No matches" | — |
| Availability | quick action, drawer | Update, toggles, calendar | → Dashboard | **P-B** | 9 vars | — | inline calendar |
| Open Matches | quick action, drawer | Interested, toggle | → Dashboard | P-A (none) | 4 vars | 3 variants | — |
| Notifications / Settings | shared | §13 | → Dashboard | none | — | — | — |

"Open to offers" toggle (Open Matches and Availability) adds the player to `openPlayers` with **`city: openPlayersCityFilter`**, which defaults to `''`. The Club Owner's Available Players list filters by city, so **the player never appears** (:3511, :7660).

---

## 8. Club Owner flow

```
Club Owner Dashboard (Home)
 ├─ ☰ Drawer: Dashboard · My Club · My Teams | Members · Player Hunt · Challenges · Match Management · Tournaments · Requests · Notifications | Settings · Switch · Logout
 ├─ Hero: "Shalimar Cricket Club", Islamabad, code 35HLWZ · "Share with players" (toast only)
 ├─ Stats: Members · Teams · Requests (not tappable)
 ├─ Quick actions (7): Requests · Members · Teams · Challenges · Open Player · Upcoming Matches · Tournament
 └─ Next Match (first confirmed) · View All ─► Match Management
```

| Module (drawer label / screen title) | Entry | Primary action | Secondary actions | Back | Related models | Related state |
|---|---|---|---|---|---|---|
| Dashboard / `clubHome` | many | quick actions | share code | none | Club, Match | membersList, teamsList, joinRequestsData, matchesList |
| My Club / `myClub` | drawer, Profile tab, Settings Account | — (read-only) | — | role home | Club, Member, Team | same |
| My Teams / `teams` | drawer, tab, quick action | Create Team (inline) | open squad | → Dashboard | Team | newTeam |
| Create Team (legacy) | side panel only | toast only | — | pop | — | — |
| Team Squad | team row | Add Players | filter | → Teams | Team, SquadPlayer | currentTeamName, filter |
| Add Players | squad | Save Squad | Stats sheet, filter | → Squad | SquadPlayer, PlayerStats | teamPlayerRoles |
| Members / `members` | drawer, tab, quick action | — | search (dead) | → Dashboard | Member | — |
| Player Hunt / `openPlayers` ("Open Players", quick action "Open Player") | drawer, quick action | Post Player Requirement | Remove slot, Invite (toast) | → Dashboard | PlayerHuntPost, OpenPlayer | newHunt, filters, tab |
| Challenges | drawer, quick action | Challenge (instant accept) | profile, slot | pop | ClubSummary, AvailabilitySlot | — |
| Match Management / `upcomingMatches` ("Upcoming Matches") | drawer, quick action, Next Match | open match (setup / pay / wait) | Select XI, Directions | → Dashboard | ClubMatch | upcomingTab |
| Tournaments → `myTournaments` (hub `hostTournament` via quick action) | drawer, quick action | Create / Browse / My / Registrations | Venues | → Hub / → Dashboard | Tournament, Registration | several |
| Requests / `joinRequests` | drawer, quick action, notification | Accept (as Player) | profile, decline | pop | JoinRequest, Member | index |
| Notifications / Settings | drawer | §13 | — | → Dashboard | NotificationItem, Prefs | — |

**Naming inconsistencies (must be preserved or resolved deliberately — D10):**
- Player Hunt is called "Player Hunt" (drawer), "Open Player" (quick action) and "Open Players" (title).
- Match Management is called "Match Management" (drawer) and "Upcoming Matches" (title and quick action).
- My Teams is called "My Teams" (drawer) and "Teams" (title, tab).
- The own club is "Shalimar Cricket Club" (hero), "Shalimar CC" (match cards) and `club.name` (drawer, if created).

---

## 9. Team management flow

```
My Teams ─ inline form (Team Name*, Format*) ─ Create Team ─► row appended (toast "Team created!")
   └─ team row ─► Team Squad ("N players in squad"; chips All/Batsman/Bowler/All-Rounder with counts)
                    └─ Add Players ─► Add Players (11 Playing XI + 4 Subs counters)
                                        ├─ tap row: Unselected → Playing (until 11) → Sub (until 4) → Unselected
                                        ├─ locked rows (injured / unavailable): toast "{name} is {status} and can't be added"
                                        ├─ Stats ─► Player Stats bottom sheet
                                        └─ Save Squad ─► Team Squad (toast "Squad updated!")
```

| Item | Prototype behaviour |
|---|---|
| Team creation fields | Team Name* (text), Format* (Test / T20 / ODI / Custom — **no overs input here**). |
| Team data stored | `{name, players, squad, captain, form}` (:5498). **The format is collected but not stored.** `captain` is set from `clubData[currentClubAbbr]` (an unrelated opponent club) and is never displayed. |
| Seed teams | "BS CS XI", "BS IT XI" (0 players, no squad). |
| Player pool for squads | `clubSquad`: 20 hard-coded players `{n, role, status}`. **This is not `membersList`.** |
| Playing XI / Sub | Capped at 11 + 4. Add Players does **not** require 11 + 4 to save (saving 0 players is allowed). Team Builder **does** require exactly 11 + 4. |
| XI / Sub persistence | **Lost on save.** `saveTeamPlayers` stores the players in `clubSquad` order without their role. `openAddPlayers` re-derives Playing for the first 11 and Sub for the rest, by list order (:5592, :5620). |
| Team Squad display | Name and role only. **It does not show Playing XI versus Sub.** |
| Captain / vice-captain | **Not present.** "Captain" appears only inside role text ("Captain / Batsman") and on opponent clubs. |
| Role assignment | Membership role (Player / Coach / Manager) at join approval only. Squad category comes from the role text via `squadCategory()` regex (:5531). |
| Remove player | Tap the row until it returns to Unselected. No confirmation. |
| Empty states | "No {filter} in this squad." (reads "No All in this squad." when the squad is empty); "No {filter} available." |
| Confirmation | Toast only; Save returns to the squad. |
| Keys | Teams are keyed by **name**, so duplicates are allowed and collide. Names are injected into `onclick` strings, so an apostrophe breaks them. |

Separately, match-day selection (**Team Builder**) uses the same `clubSquad` and the same cycle logic (`cycleSquadPick`, duplicated from `cycleAddPlayer`) but has **no Stats button or scouting metadata**. It produces a team named "New Match-Day Squad" that is **not** added to `teamsList`.

---

## 10. Player data and stats

### Confirmed fields in the prototype

| Field | Where shown | Source |
|---|---|---|
| Name | everywhere | various |
| Initial avatar | everywhere | `name[0]` |
| Playing role (Batsman / Bowler / All-Rounder) | profile setup, join requests, hunt | `profile.role`, `joinRequestsData.role` |
| Wicket-Keeper (as a role) | Player Hunt, Open Matches, Available Players | `playerHuntRoles` |
| Wicketkeeper flag | profile setup | `profile.isWicketkeeper` |
| Position (free text, e.g. "Opening Bat", "Leg Spinner") | squads, stats sheet, profile | `clubSquad.role` |
| Category (derived Batsman / Bowler / All-Rounder) | filters, stats sheet chip | `squadCategory()` |
| Batting style, Bowling style | setup, join request | profile, joinRequest |
| Age, City, Phone | join request profile | joinRequest |
| Skill level (Club / Division / District / Premier) | stats sheet, profile | `ceStats.skill` |
| Verified | Add Players, sheet, profile ("Verified player" is always shown on the profile) | `ceStats.verified` |
| Rating | Add Players, sheet, profile; dashboard "8.2" (static) | `ceStats.rating` |
| Availability status (5 values) | Add Players lock and badge, sheet chip | `clubSquad.status`, `playerStatus` |
| Matches | Add Players, sheet, profile | `ceStats.matches` |
| Recent form (5 × W/L) + W/L count | Add Players dots, sheet | `ceStats.form` |
| Batting: Runs, Average, Strike Rate, Best | sheet | `ceStats.bat` (also `fifties`, **computed but never shown**) |
| Bowling: Wickets, Economy, Average, Best | sheet | `ceStats.bowl` |
| Last match (opponent + line) | sheet | `ceStats.last` |
| Playing XI / Sub state | Add Players, Team Builder | selection maps |
| Own performance tiles: Batting (9), Bowling (7), Fielding (5) | My Performance | static arrays |
| Match log: opponent, date, W/L, runs (balls), wickets / overs | Performance, History | `matchLogPerf` |
| Join-request performance: matches, runs, wickets, batting avg (nullable) | joinRequestProfile | joinRequest |

### Optional / contextual
- Performance can be `null` on a join request ("No performance data available yet.").
- The Wicketkeeper toggle only appears for Batsman.
- `isMe` "You" pill in Available Players.
- `extra` ("Available Now", "Applied 2 days ago") is free text.

### Not present (do not invent)
Player photo (placeholder icon only), jersey number, captain / vice-captain designation, batting position number, fielding stats inside the scouting sheet, player-to-player messaging, strike-rate history charts, and bowling style on squad rows.

**Important:** all scouting stats are **deterministic mock values hashed from the player's name** (`ceStats`, :7706). Flutter needs a stats model; the hash exists only for demo data.

---

## 11. Members vs Team Squad vs Add Players vs Player Hunt

| Concept | Purpose | Data source (prototype) | Actions | Relationship to Club Owner | Flutter model / state |
|---|---|---|---|---|---|
| **Members** (`members`) | People formally in the club | `membersList` `{n, phone, role: Owner/Player/Coach/Manager}`. Grown by join-request approval and join simulation. | View only (search is dead) | Owner is a member with the "Owner" badge | `ClubMember` list in `clubMembersProvider` |
| **Team Squad** (`teamSquad`) | Roster of one named team | `team.squad` (subset of `clubSquad`) | Filter, Add Players | Owner manages teams | `Team.squad: List<TeamMember>` (with XI/Sub role — see D11) |
| **Add Players** (`addTeamPlayers`) | Pick up to 11 + 4 from the club's player pool into a team | `clubSquad` (20 fixed players with availability status) | Cycle select, Stats sheet, Save | Owner curates the team | Local selection map in a feature controller; pool = `clubPlayerPoolProvider` |
| **Player Hunt** (`openPlayers`) | Recruit **outside** players | *Find Players tab:* club's `publishedHunts` postings. *Available Players tab:* `openPlayers` (free agents who opted in). | Post / remove requirement, Invite | Owner advertises needs | `PlayerHuntPost`, `OpenPlayer` |
| (Player side) **Open Matches** | Players browse hunt postings | `publishedHunts` (all clubs, including the owner's own "SC") | Interested | — | same `PlayerHuntPost` + `interest` set |

**Gap to keep in mind (not silently fixed):** approved Members never enter `clubSquad`, so a newly approved player can never be added to a team. The prototype keeps the member list and the player pool fully separate (D11).

---

## 12. Challenges and match flow

### Challenges (actual)
```
Club Owner Dashboard ─► Challenges  [tabs: Challenges | My Challenges | Find Match]
  Challenges tab: "Create Availability Slot" box ─► Create Availability Slot ─ Post ─► Find Match (slot card shown on both tabs)
                  4 club cards (KK, IU, RR, FW) ─ tap ─► Club Profile ─ "Challenge This Club" ─┐
                                                 └ "Challenge" button ─────────────────────────┤
  Find Match tab: 2 cards (header claims 5) ─ tap ─► Club Profile ─ …                          │
                  └ "Send Match Request" ──────────────────────────────────────────────────────┤
                                                                                                ▼
                        toast "Challenge sent to X!" ─(400 ms)─► Challenge Accepted (no back)
                                                                  └ View in Upcoming Matches ─► addPendingMatch ─► Match Management · Waiting
  My Challenges tab: Awaiting your Decision (DB, GC — static) ─ Accept ─► addPendingMatch ─► Match Management · Waiting
                                                                  Decline ─► toast only (card stays)
                     Resolved: GT "ACCEPTED" (static)
Match Management · Waiting · "SETUP NEEDED" card ─► Match Setup ─► booking flow (§14)
```

- Every challenge route stays in the Club Owner context. Challenge flow screens are role-neutral but reachable only from owner screens.
- **Intermediate states present:** Challenge Accepted and pending match (SETUP NEEDED). **Absent:** challenge sent / awaiting response, and challenge declined by the opponent.
- The same club can be challenged or accepted repeatedly; each time creates a **duplicate pending match** (:5866, :7064).
- Find Match card "Rawalpindi Riders" uses abbreviation RR and opens the **Rawalpindi Rams** profile (:7116). Card data (W/L, rating, venue) does not match `clubData`.

### Match statuses

| Context | Values | UI |
|---|---|---|
| Player `myMatchesData.status` | `upcoming`, `past`, `cancelled` | chips CONFIRMED / PLAYED / CANCELLED; `result` ("Won by…", "Lost by…"), `reason` ("Rain") |
| Club `matchesList.status` | `pending` → `reserved` → `confirmed` → `completed` (reserved returns to pending on expiry) | chips SETUP NEEDED / 🔒 RESERVED / ✓ CONFIRMED / PLAYED |
| Club tabs | Waiting = pending + reserved; Scheduled = confirmed; History = completed | counts shown in tabs |
| Tournament fixture | `completed: bool`, `winner`, team placeholders `BYE` / `TBD` | "Tap to simulate result"; "{team} won" |

The Player and Club match datasets are **independent**: player matches are not derived from `matchesList`.

---

## 13. Notifications and Settings flow

### Notification types (static, per role; :8091)

| Role | Title | Subtitle | Tone | Destination |
|---|---|---|---|---|
| Player | Match request from Shalimar CC | Sunday 3:00 PM · Pindi Cricket Ground | green | `myMatches` |
| Player | Club approved your join request | You are now part of Club {code} | green | `playerProfile` |
| Player | Availability needed for next match | Confirm before Friday | amber | `availability` |
| Player | Tournament update: Spring Cup | Fixtures published | blue | **`openMatches`** (mismatch; Spring Cup does not exist in the data) |
| Club | New join request from Bilal Ahmed | Batsman · Rawalpindi | amber | `joinRequests` |
| Club | Challenge received from Karachi Kings CC | T20 · next Saturday | green | `myChallenges` (that screen lists DHA Bulls and GOR, not Karachi Kings) |
| Club | Opponent completed their payment share | Pindi Cricket Ground booking confirmed | green | `upcomingMatches`, Scheduled tab |
| Club | Tournament registration approved | Spring Cup · 8 teams | blue | `myRegistrations` (opens the **Pending** tab) |

- **Read/unread:** not present. There is no badge clearing, mark-all-read or delete.
- Tapping pushes the destination. The player bell badge is a static "3" (4 items); the club dashboard has **no bell**.

### Settings

| Item | Implementation | Target |
|---|---|---|
| Account | row → screen | `playerProfile` (player) / `myClub` (club) |
| Active profile | row → drawer | `menu` |
| Notifications ("Match, club and booking alerts") | row → **inbox, not preferences** | `notifications` |
| Privacy | real screen | 3 toggles (state `cePrefs`, not persisted) |
| Password & security | real screen | password form + 2 toggles |
| Log out | button, immediate, no confirmation | `login` |

---

## 14. Ground booking flow

```
Match Management · Waiting · pending card
 └─► 1 Match Setup (Format + Custom overs, Preferred City)
      └─► 2 Book a Ground (in-city grounds first, then others)
           └─► 3 Ground Details (carousel, Maps, specs, amenities)
                └─► 4 Select Date & Time (Aug 2026 baseline calendar; day status by day % 5; 5 fixed slots)
                     └─► 5 Booking Summary (cost = hourly price × 2 h; 50/50 split)
                          └─ "Reserve Ground for 30 Minutes"
                               ├─ slot reserved by another club ─► toast + clear slot ─► 4 Select Date  (BOOKING CONFLICT)
                               └─ reserve (30-min hold; match.status = reserved) ─► 6 Payment
                                    └─ Pay (processing 1.6 s ─► success 0.9 s) ─► 7 Waiting for Opponent (live countdown)
                                         ├─ Sim "Opponent Pays Now" ─► Opponent Payment (auto) ─► Booking Confirmed (status = confirmed; hold made permanent)
                                         │     ├─ Select Your Playing XI ─► Select Team ─► Team Builder | Team Picker ─► Match Management · Scheduled
                                         │     └─ View in Upcoming Matches ─► Scheduled
                                         └─ countdown hits 0 (or Dev force-expire) ─► Reservation Expired (slot released)
                                               ├─ Refund to Original Method ─┐
                                               └─ Move to CricEco Wallet ─────┴─► match reset to pending ─► Match Management · Waiting
Resume: reserved card ─► Payment (unpaid) or Waiting (paid)
```

| State | Mechanism |
|---|---|
| Payment status | `myPaid`, `oppPaid`, `paymentStage` (idle / processing / success), `myPaymentMethod` |
| Payment methods | CricEco Wallet (balance Rs 5,000; disabled when insufficient), EasyPaisa (default), JazzCash, Debit/Credit Card (**no card form**) |
| Escrow ledger | `cricecoWallet.balance/ledger` (club_payment, ground_settlement, refund) — **never shown in the UI** except the settlement summary |
| Commission | 5 % (`CRICECO_COMMISSION_RATE`), shown on Booking Confirmed |
| Conflict | Toast "That slot was just taken by another club — pick another time". The seeded reservation (National Stadium, 12th, 2:00 PM) demonstrates the "Reserved" chip. |
| Expiry | Only enforced by the countdown **on the Waiting screen**. Payment has no timer, and Match Management's reserved card shows a static remaining time with no expiry handling. |
| Recovery | Refund / Wallet (resets to pending). A conflict returns to date selection. |

**Confirmed issues:**
- The selected date stores only the **day number**; the month is hard-coded to "Aug 2026" in all summaries, even after navigating the calendar to another month (:6394, :6507).
- The hub's "Venues" opens `bookGround` with no active match, so the whole flow can run against no match and still reach "Booking Confirmed" (:4566).

---

## 15. Tournament flow

**Discover** = Browse Tournaments (`availableTournamentsData`, 4 seeds). **Registered** = My Registrations (`myRegistrations`). **Hosted** = My Tournaments (`myTournamentsData`, initially empty).

### Registration
```
Tournament Center ─► Browse Tournaments (choose City first)
  └─ card "Register Team" ─► Tournament Register Details (summary, rules, participating clubs)
       ├─ already registered ─► status + "View Registration"
       ├─ status "Registration Full" ─► disabled button
       └─ Continue Registration ─► Select Team (tournament context)
             ├─ Create New Team ─► Team Builder (11 + 4) ─┐
             └─ Select Existing Team ─► Team Picker ───────┴─► Registration Summary (agree to rules*) ─ Submit
                   ─► Registration Success ─┬─ View Registration ─► Registration Details
                                            └─ My Registrations (Pending | Approved | Rejected) ─► Registration Details
Registration Details:
  Pending  ─ "Prototype: Simulate Organizer Decision" Approve / Reject
  Rejected ─ empty state
  Approved ─ Teams · Fixtures/Schedule (auto-built) · Points Table · Upcoming (tap = simulate) · Results
```

### Hosting
```
Tournament Center ─► Create Tournament (12 fields) ─ Publish ─► Tournament Published
   ├─ View Tournament ─► Tournament Details [Overview | Teams | Fixtures | Points Table]  (share / ⋮ action sheets)
   │     Overview: stats · description · format & schedule · next match · Manage Teams · Generate/View Fixtures · Tournament Dashboard
   │     Manage Teams ─► pending row ─► Registration Request (Accept / Reject) ─► Manage Teams
   │     Fixtures: Generate (≥ 2 teams) ─ knockout bracket or league round-robin ─ tap = simulate result
   │     Tournament Dashboard: winner · upcoming · completed · points · awards (mock)
   └─ Back to Dashboard ─► Club Owner Dashboard
My Tournaments ─► card ─► Tournament Details
```

| States | Values |
|---|---|
| Tournament status | `Registration Open`, `Registration Full`, `Completed` (`Registration Closed` is styled but never set) |
| Registration status | `Pending`, `Approved`, `Rejected` |
| Type / format | Knockout / League; Test / T20 / ODI / Custom (overs 1–50) |
| Fixture | rounds `{name, matches[{teams[2], completed, winner}]}`; names Final / Semifinal / Quarterfinal / Round of 16 / 32 |
| Standing | `{played, won, lost, pts}` (win = 2 points) |

**Confirmed issues:**
- The hosted tournament's "Organizer Club" shows `clubData[currentClubAbbr]`, i.e. the last opponent or browsed club (default "Karachi Kings CC"), not the owner's club (:5081).
- Knockout with a non-power-of-two team count creates **BYE** matches that can never be played or auto-advanced, so the bracket can never complete (:4865).
- Registration pushes a **team name** into `pendingTeamsList`, which otherwise holds club abbreviations. Approval does not remove it from pending.
- Seed "Rawalpindi Rams T10 Bash" contains **IU twice** (:4315).
- No date validation: the end date can be before the start date, and the deadline is not enforced.
- The two tournament shapes differ (`teams` vs `maxTeams`; `organizerAbbr` and `rules` exist only on browse data).
- `completeMatch` and `completeMatchOn` duplicate the same logic, as do `statusPillClass` and `tournStatusPillClass`.

---

## 16. Form inventory

| # | Screen | Field | Type | Req | Options | Validation implied | Submit → success | Error |
|---|---|---|---|---|---|---|---|---|
| F1 | Login | Phone number | tel text | (UI no) | — | none | Login → Continue As | none |
| | | Password | password + eye | — | — | none | | |
| F2 | Create Account | Full Name | text (prefilled) | ✓ (no asterisk) | — | none | Create Account → Complete Profile | none |
| | | Sign up with | segmented | ✓ | Phone Number / Email | — | | |
| | | Phone Number *or* Email Address | tel / email | ✓ | — | placeholder "03XX-XXXXXXX" | | |
| | | Password, Confirm Password | password | ✓ | — | "Min 6 characters" (not enforced) | | |
| F3 | Complete Profile | Profile photo | tap picker | opt | — | — | Continue → Playing Style | toast (role) |
| | | Full Name*, Date of Birth*, Phone Number* | text / date / text | ✓ | — | not enforced | | |
| | | Select your role* | pills | ✓ enforced | Batsman, Bowler, All-Rounder | — | | |
| F4 | Playing Style | Batting Style* | pills | ✓ | Right-handed, Left-handed | both styles required | Save Profile → Continue As | "Please select both styles" |
| | | Bowling Style* | pills | ✓ | Right-arm Fast/Medium/Off-spin/Leg-spin, Left-arm Fast/Medium/Orthodox/Chinaman | | | |
| | | Also a Wicketkeeper? | toggle button | opt (Batsman only) | — | | | |
| F5 | Enter Club Code | Club Code* | text (uppercase) | ✓ | — | non-empty | → Waiting | "Please enter a club code" |
| F6 | Create Club | Club logo | tap picker | opt | — | — | Continue → Club Details | name / city toasts |
| | | Club Name* | text | ✓ | — | | | |
| | | Owner Name | text (prefill) | opt | — | | | |
| | | Address | text | opt | — | | | |
| | | City* | inline dropdown | ✓ | Karachi, Lahore, Islamabad, Rawalpindi, Faisalabad, Multan, Peshawar, Quetta, Sialkot, Hyderabad, Other | | | |
| F7 | Club Details | Club Email | email | opt | — | — | Create Club → Dashboard | "Please select a club type" |
| | | Club Type* | inline dropdown | ✓ | Professional, College/University, Corporate Club | | | |
| | | Home Ground | button + list | opt | 4 grounds | | | |
| F8 | My Teams (inline) | Team Name* | text | ✓ | — | | Create Team → list updates in place | name / format toasts |
| | | Select Format* | pills | ✓ | Test, T20, ODI, Custom | (no overs) | | |
| F9 | Create Team (legacy) | Team Name, Select Format | text, readonly (no options) | — | — | none | toast + My Teams (no creation) | — |
| F10 | Join Request Profile | Role Assignment | select | ✓ (default Player) | Player, Coach, Manager | — | Approve / Reject → back + toast | — |
| F11 | Availability | Status | card grid | ✓ | Available, Limited Availability, Unavailable, Injured, Other | — | Update Availability (toast, same screen) | — |
| | | Reason | select | opt | Injury, Personal Reasons, Work Commitment, Travel, Family Emergency, Rest Day, Other | | | |
| | | Unavailable Until | quick chips + calendar | — | Today, Tomorrow, This Weekend, Select Date | shown even for "Available" | | |
| | | Notes | textarea | opt | — | max 200 with counter | | |
| F12 | Player Hunt (post) | Role Needed* | card grid | ✓ | Batsman, Bowler, All-Rounder, Wicket-Keeper | | Post → list updates + toast | role toast |
| | | Match Format* | chips | ✓ (default T20) | T20, T10, ODI, Test, Custom (no overs) | | | |
| | | Players Needed | stepper | — | 1–11 | clamped | | |
| | | Location / Date / Time / Budget | select / date / time / select | opt | All, Karachi, Islamabad, Rawalpindi, Lahore · Any, Under Rs 2,000, Rs 2,000 - 5,000, Rs 5,000+ | | | |
| F13 | Available Players (filter) | City, Role | select | both needed to list | Islamabad, Rawalpindi, Karachi, Lahore · 4 roles | | — | empty prompt |
| F14 | Create Availability Slot | Format* (+ overs) | pills (+ number) | ✓ | Test, T20, ODI, Custom | overs required if Custom | Post → Find Match + toast | 5 toasts |
| | | City* | inline dropdown | ✓ | 20 Pakistan cities | | | |
| | | Preferred Ground | inline dropdown | opt | 4 grounds | | | |
| | | Date* | date | ✓ | — | | | |
| | | Time Slot* | pills | ✓ | 6am–8am, 8am–10am, 2pm–4pm, 4pm–6pm, 6pm–8pm | | | |
| | | Notes | textarea | opt | — | | | |
| F15 | Match Setup | Format* (+ overs 1–50) | option list | ✓ | 4 | | Continue → Book a Ground | 2 toasts |
| | | Preferred City* | inline dropdown | ✓ | 20 cities | | | |
| F16 | Book a Ground | Ground* | card select | ✓ | 4 | | → Ground Details | toast |
| F17 | Select Date & Time | Date* | calendar | ✓ (full days blocked) | — | | → Booking Summary | 3 toasts |
| | | Time slot* | chips | ✓ (booked / reserved disabled) | 5 | | | |
| F18 | Payment | Payment method | radio cards | ✓ (default EasyPaisa) | Wallet, EasyPaisa, JazzCash, Card | wallet balance ≥ share | Pay → Waiting | "Insufficient wallet balance…" |
| F19 | Team Builder | 11 Playing + 4 Subs | cycle selection | exactly 11 + 4 | squad | locked statuses | Confirm → Scheduled or Reg. Summary | "Select N more…" |
| F20 | Team Picker | Existing team | radio | ✓ | teamsList | | Confirm → same | "Please select a team" |
| F21 | Create Tournament | Tournament Name* | text | ✓ | — | ordered toasts (10) | Publish → Published | 10 toasts |
| | | City* | inline dropdown | ✓ | 20 cities | | | |
| | | Ground* | free text | ✓ | — | | | |
| | | Format* (+ overs 1–50) | pills | ✓ | Test, T20, ODI, Custom Overs | | | |
| | | Type* | pills | ✓ | Knockout, League | | | |
| | | Start Date*, End Date*, Registration Deadline* | date | ✓ | — | no ordering check | | |
| | | Entry Fee, Prize Amount | number | opt | — | | | |
| | | Maximum Teams* | number | ✓ | — | | | |
| | | Description | textarea | opt | — | | | |
| F22 | Browse Tournaments | City | select | needed to list | cities from data | | — | empty prompt |
| F23 | Registration Summary | I agree to the tournament rules | checkbox | ✓ | — | | Submit → Success | toast |
| F24 | Password & Security | Current password, New password | password | — | — | "At least 8 characters" (not enforced) | Update → Settings + toast | none |
| F25 | Edit Profile | Full name, City, Phone | text | — | — | only the name is saved | Save → My Profile + toast | none |
| F26 | Privacy / Security toggles | 5 switches | toggle | — | — | — | immediate | — |
| F27 | Open Matches | Search | text | — | — | `includes` on club / location | live filter | `No results for "…"` |

---

## 17. Search and filter audit

| Screen | Control | Behaviour |
|---|---|---|
| Open Matches | Search input | Case-insensitive `includes` on `clubName` or `location`. **Unranked.** Only applies after a role chip is chosen. |
| Open Matches | Role chips | All (shows nothing; prompts a choice) / Batsman / Bowler / All-Rounder / Wicket-Keeper |
| Members | "Search members…" | **Static div, not an input** |
| My Matches | tabs | Upcoming / Past / Cancelled |
| My Performance | tabs | Batting / Bowling / Fielding |
| Match History | tabs | All / Won / Lost |
| Team Squad, Add Players, Team Builder | chips with counts | All / Batsman / Bowler / All-Rounder (regex category from the role text) |
| Player Hunt | underline tabs | Find Players / Available Players |
| Available Players | City + Role selects | both required, exact match |
| Challenges group | tab row (navigates between screens) | Challenges / My Challenges / Find Match |
| Match Management | tabs with counts | Waiting / Scheduled / History |
| Browse Tournaments | City select | required; exact match |
| My Registrations | tabs | Pending / Approved / Rejected |
| Tournament Details | tabs | Overview / Teams / Fixtures / Points Table |
| Book a Ground | implicit sort | grounds in the selected city first |
| Points table | sort | pts descending, then name A–Z (`localeCompare`) |

**Search ranking rule (startsWith > contains): not present (X1).** If approved, it would apply in Flutter to: Open Matches search (clubName, location); Members search (currently dead; would need a real input); and optionally Available Players and Browse Tournaments, which are select-only today. Recommended implementation: one `rankedSearch<T>(items, query, fields)` utility that scores `startsWith` as 0, `contains` as 1 and excludes the rest, then sorts stably. Do not add it without approval.

---

## 18. Modal / bottom sheet / overlay inventory

| Overlay | Trigger | Content | Actions | Close | Result | Parent |
|---|---|---|---|---|---|---|
| **Drawer** (`menu`, implemented as a route) | ☰ on dashboards and chooseOption; "View All"; Settings → Active profile | profile header, role switch, nav groups, Settings, Logout, footer | navigate, switch, logout | tap scrim / ✕ → `go(origin)` (**push**) | navigation | dashboards |
| **Player Stats sheet** (`ceOpenPlayerSheet`) | Add Players → "Stats" | avatar, verified, position · skill, rating; chips (category, availability, matches); Batting ×4, Bowling ×4, Recent form, Last match | Close | Close button or scrim | none | Add Players only (not Team Builder) |
| **Action sheet: Share tournament** | Tournament Details 🔗 | Copy invite link / Share via WhatsApp / Share with club members | each shows a toast only | Cancel or scrim | toast | Tournament Details |
| **Action sheet: Tournament options** | Tournament Details ⋮ | Tournament dashboard / Manage teams / Share tournament | navigate or open the share sheet | Cancel or scrim | navigation | Tournament Details |
| Inline dropdowns (`fake-dropdown-list`) | tap readonly input | option list | pick | pick again / toggle | field set | Create Club (city), Club Details (type, ground), Create Tournament (city), Match Setup (city), Availability Slot (city, ground) |
| Inline calendar picker | Availability "until" row | month grid | pick day, month navigation | pick / toggle | date set | Availability |
| Native selects / date / time | — | platform pickers | — | — | — | Availability reason, Browse city, Join role, Available Players, Hunt filters, date inputs |
| Toast | ~60 call sites | text | — | auto after 1.5 s | — | global |
| Payment processing / success | Pay | spinner, then success | — | auto | → Waiting | Payment (in-screen states, not modal) |

**Confirmation dialogs: none exist.** Destructive or irreversible actions run immediately: Logout, Cancel Join Request, Decline request, Remove team from tournament, Remove hunt slot, Remove availability slot, Reject registration, Refund choice. Adding confirmations would be a UX change (D12).

---

## 19. Empty / success / error / confirmation states

### Empty states

| Screen | Icon | Title | Description | CTA |
|---|---|---|---|---|
| My Matches | circle-dot | No {upcoming/past/cancelled} matches | Matches will show up here. | — |
| Match History | circle-dot | No matches | No matches found for this filter. | — |
| Open Matches (no role) | circle-dot | Choose a role to get started | Tap Batsman, Bowler, All-Rounder or Wicket-Keeper above… | — |
| Open Matches (none / search) | circle-dot | No open requests | `No results for "q".` / Clubs haven't posted any {role} requests right now. | — |
| My Club | — | (text) No members listed yet. | — | — |
| Requests | user + check | No pending requests | All requests have been reviewed | — |
| Join Request performance | — | (text) No performance data available yet. | — | — |
| Team Squad | — | (text) No {filter} in this squad. | — | — |
| Add Players / Team Builder | — | (text) No {filter} available. / in your squad. | — | — |
| Available Players | circle-dot | Choose a city and role / No {role} available | Select both above… / No players in {city} have listed… | — |
| Match Management | calendar | No {waiting/scheduled/history} matches | per-tab copy | — |
| Select Date (no date) | — | (text) Pick a date above to see available time slots. | — | — |
| Book a Ground | — | (text) No grounds listed in {city} yet — showing nearby options. | — | — |
| Browse Tournaments | trophy | Choose a city / No tournaments in {city} | Select a city above… / Check back later… | — |
| My Tournaments | trophy | No tournaments yet | Tournaments you create will show up here. | **Host a Tournament** |
| Tournament → Teams tab | shield | No teams registered yet | Accept team requests from Manage Teams | (Manage Teams button below) |
| Tournament → Fixtures | calendar / circle-dot | Not enough teams yet / Ready to generate | Need at least 2 teams… / N teams registered… | **Generate Fixtures** |
| Tournament → Points | bar-chart-2 | No teams yet | Standings will appear once teams register | — |
| Tournament Dashboard | — | (text) No upcoming matches / No matches completed yet / Awards will appear once teams are registered | — | — |
| Manage Teams | — | (text) No pending registration requests. / No teams have joined yet. | — | — |
| Tournament Register | — | (text) No clubs registered yet | — | — |
| My Registrations | trophy | No {pending/approved/rejected} registrations | Registrations will appear here once submitted. | — |
| Registration Details | x-circle / hourglass | Registration Rejected / Pending Approval | explanatory copy | (Sim Approve/Reject) |
| Notifications | bell | No notifications yet | Match requests, approvals and booking updates will appear here. | Back to dashboard |
| Not-found guard (`ceNotFound`) | search | {Label} not found | This item is no longer available… | Go to dashboard · Go back |
| Role Setup | shield | Become a Club Owner | Create your Club Owner profile… | Set Up Club Owner Profile · Not now |
| **Missing** | — | No empty state for: Members, My Teams, Challenges, Find Match, Notifications (in practice) | — | — |

### Success / error / confirmation (how each is presented)

| Event | Presentation |
|---|---|
| Team created | Toast + updated data (inline list) |
| Player added/removed to squad; squad saved | Updated selection state; toast "Squad updated!" + navigate |
| Member approved / declined | Toast + updated list (and back from the profile) |
| Join request sent / approved | Dedicated screens (Waiting, Join Approved) |
| Join request cancelled | Toast + navigate |
| Club created | Navigate to dashboard (no toast) |
| Challenge sent / accepted | Toast + dedicated screen (Challenge Accepted) |
| Challenge accepted (incoming) / declined | Toast + navigate / toast only |
| Availability updated | Toast + updated hero card |
| Hunt posted / removed; slot posted / removed | Toast + updated list |
| Interest sent | Toast + button state "Interest Sent" |
| Ground reserved | Toast + navigate to Payment |
| Booking conflict | Toast + redirect to Select Date (slot cleared) |
| Payment processing / success | In-screen states (spinner, success card) |
| Opponent paid / booking confirmed | In-screen success, then dedicated screen (Booking Confirmed) |
| Reservation expired | Toast + dedicated screen |
| Refund / wallet | Toast + navigate |
| Team confirmed (match / tournament) | Toast + navigate |
| Tournament published | Dedicated screen |
| Registration submitted | Dedicated screen |
| Registration approved / rejected (sim) | Toast + updated state |
| Tournament team accepted / rejected / removed | Toast + navigate / updated list (remove has no toast) |
| Fixtures generated; result simulated | Toast + tab switch / updated data |
| Role switched | Fade transition + toast |
| Profile / password saved | `ceSaved`: navigate + toast (:8242) |
| Validation errors | **Toast only** (no inline field errors anywhere) |
| Wallet insufficient | Disabled card + toast |

---

## 20. Proposed Dart models (from prototype evidence only)

`?` = optional in the prototype. **Status fields** and **Relations** follow each model.

| Model | Required (confirmed) | Optional | Status fields | Relations |
|---|---|---|---|---|
| `UserAccount` | fullName, contactMethod | phone, email | — | has PlayerProfile; has ClubOwnerProfile? |
| `PlayerProfile` | role (PlayerRole), battingStyle, bowlingStyle | photo?, isWicketkeeper, dateOfBirth?, phone?, city? | availability (PlayerAvailability) | belongs to UserAccount; member of Club? |
| `PlayerAvailabilityRecord` | status, since | reason?, until (option + date), notes (≤ 200) | status | PlayerProfile |
| `RoleContext` | activeRole, hasClubOwnerProfile, lastRoute{player, club} | — | — | UserAccount |
| `Club` (own) | name, city, type, code | logo?, owner?, address?, email?, homeGroundId?, established? | — | owner UserAccount; members; teams |
| `ClubSummary` (other clubs) | id/abbr, name, city, level, formats, homeGround, captain{name, phone}, keyPlayers[{name, position, isCaptain}], recentForm[5], winRate, wins, losses, played, about, est/squadSize | color | — | referenced by Challenge, Match, Tournament |
| `ClubMember` | name, role (MemberRole) | phone | — | Club |
| `JoinRequest` (incoming) | id, name, age, city, battingStyle, bowlingStyle, role, phone, appliedLabel | performance{matches, runs, avg, wickets}? | (implicit pending) | → ClubMember on approve |
| `ClubJoinRequest` (outgoing, player) | clubCode, clubName | approvedRole? | JoinRequestStatus (pending / approved; cancel deletes) | UserAccount → Club |
| `SquadPlayer` (club pool) | name, position, availability | — | availability | Club; → PlayerStats |
| `PlayerStats` | matches, batting{runs, avg, sr, best, fifties}, bowling{wickets, econ, avg, best}, form[5], rating, category, position, skillLevel, verified, lastMatch{opponent, line} | — | availability | SquadPlayer |
| `Team` | id*, name, squad | format (**collected, not stored today**), captain? | — | Club; members = SquadPlayer + SelectionRole |
| `TeamSelection` | playerName → SelectionRole (playing / sub) | — | — | Team or Match |
| `ClubMatch` | id, opponent (ClubSummary), status | format, customOvers, city, groundId, date, slot, groundCost, halfCost, myPaid, oppPaid, myPaymentMethod, teamName, result, reservationExpiry, commission, toGround | MatchStatus | Challenge; Booking; Team |
| `PlayerMatch` | status, opponent, opponentAbbr, date, time, format, ground | result?, cancelReason?, playingTeam | PlayerMatchStatus | → Scorecard? |
| `Scorecard` | result, playerOfMatch, innings[2]{team, abbr, total, wickets, overs, batting[{name, runs, balls, fours, sixes, dismissal}], bowling[{name, overs, maidens, runs, wickets}]} | — | — | PlayerMatch |
| `PerformanceSummary` | batting tiles, bowling tiles, fielding tiles, recentForm[{opp, result, runs, wkts}], matchLog[{abbr, name, date, result, runs, balls, wkts, overs}] | — | result W/L | PlayerProfile |
| `Ground` | id, name, city, pricePerHour, rating, reviews, address, specs{boundary, radius, nets}, amenities[] | photos | — | Booking |
| `TimeSlot` | start, label | taken | SlotState | Ground |
| `GroundReservation` | groundId, date, slot, matchId, expiresAt | — | active / permanent / expired | ClubMatch |
| `BookingDraft` (flow state) | format, city | customOvers, groundId, date, slot, groundCost, halfCost | — | ClubMatch |
| `Wallet` / `LedgerEntry` | balance; type, matchId, amount, at | from, method, ground, toGround, commission | LedgerType | ClubMatch |
| `PaymentMethod` | id, name, subtitle, icon | — | enabled | — |
| `AvailabilitySlot` (club open date) | format, city, date, slot | customOvers, groundId, notes | — | Club |
| `Challenge` | club, format, date, ground | isNew | ChallengeStatus (awaiting / accepted) — **static in the prototype** | → ClubMatch |
| `MatchSeekerListing` (Find Match) | club, city, W/L, rating, format, dateTime, venue | — | — | ClubSummary |
| `PlayerHuntPost` | id, role, format, playersNeeded, clubName, clubAbbr | location, date, time, budget, notes | (always "Open") | Club; interested players |
| `OpenPlayer` | name, role, availabilityLabel, city | isMe | — | PlayerProfile? |
| `Tournament` (unified) | id, name, organizerClubId, city, ground, format, type, startDate, endDate, regDeadline, maxTeams, status | customOvers, entryFee, prize, description, rules[] | TournamentStatus | joined / pending teams; fixtures; standings; winner |
| `FixtureRound` / `FixtureMatch` | name; teams[2], completed | winner | completed | Tournament |
| `Standing` | played, won, lost, points | — | — | Tournament × team |
| `TournamentAwards` (derived) | topScorer, topWicketTaker, bestKeeper, bestFielder | — | — | Tournament |
| `TournamentRegistration` | id, tournamentId, teamName | — | RegistrationStatus | Tournament, Team |
| `NotificationItem` | icon, title, subtitle, timeAgo, tone, destination | preAction (tab), clubSuffix | (no read state) | role |
| `PrivacySecurityPrefs` | publicProfile, showStats, showPhone, twoStep, loginAlerts | — | — | UserAccount |

\* The prototype keys teams, scorecards and join requests by **name or array index**. Flutter must use stable IDs; route parameters depend on it.

---

## 21. Proposed enums (supported by the prototype)

| Enum | Values |
|---|---|
| `UserRole` (active context) | player, clubOwner |
| `MemberRole` | owner, player, coach, manager |
| `PlayerRole` (profile) | batsman, bowler, allRounder |
| `HuntRole` | batsman, bowler, allRounder, wicketKeeper |
| `SquadCategory` (derived) | batsman, bowler, allRounder |
| `BattingStyle` | rightHanded, leftHanded |
| `BowlingStyle` | rightArmFast, rightArmMedium, rightArmOffSpin, rightArmLegSpin, leftArmFast, leftArmMedium, leftArmOrthodox, leftArmChinaman |
| `PlayerAvailability` | available, limited, unavailable, injured, other (injured and unavailable lock selection) |
| `AvailabilityUntil` | today, tomorrow, weekend, custom |
| `AvailabilityReason` | injury, personal, work, travel, familyEmergency, restDay, other |
| `SkillLevel` | club, division, district, premier |
| `ClubType` | professional, collegeUniversity, corporate |
| `MatchFormat` | test, t20, odi, custom (+ `t10`, which appears in hunts, player matches and seeds — **decision: include T10**) |
| `TournamentType` | knockout, league |
| `MatchStatus` (club) | pending, reserved, confirmed, completed |
| `MatchTab` | waiting, scheduled, history |
| `PlayerMatchStatus` | upcoming, past, cancelled |
| `MatchResult` | won, lost |
| `SelectionRole` | playing, sub |
| `PaymentMethodType` | wallet, easypaisa, jazzcash, card |
| `PaymentStage` | idle, processing, success |
| `DayAvailability` | available, partial, full |
| `SlotState` | open, booked, reserved, selected |
| `ReservationResolution` | refund, wallet |
| `LedgerType` | clubPayment, groundSettlement, refund |
| `TournamentStatus` | registrationOpen, registrationFull, registrationClosed (style only), completed |
| `RegistrationStatus` | pending, approved, rejected |
| `JoinRequestStatus` (outgoing) | pending, approved |
| `ChallengeStatus` | awaiting, accepted (static) |
| `TeamSelectionContext` | match, tournament |
| `NotificationTone` | green, amber, blue |
| `ContactMethod` | phone, email |
| `HuntBudget` | any, under2000, from2000to5000, over5000 |

---

## 22. Frontend state inventory

| State | Prototype variable(s) | Scope |
|---|---|---|
| Authentication / session | (none; implied) | **Global** |
| Account profile | accountFullName, accountContactMethod, accountPhone, accountEmail, profile.* | **Global** |
| Active role, has-club-profile, last route per role | ceRole, ceHasClubProfile, ceLastScreen (persisted) | **Global** (persisted) |
| Own club | club.*, CE_CLUB_NAME, CE_CLUB_CODE | **Global** |
| Player availability status | playerStatus, playerStatusSince, playerAvailable, playerOpenToOffers | **Global** (read by dashboard, profile, sheet, open players) |
| Members | membersList | **Feature** (club) — shared by 3 screens |
| Join requests (incoming) | joinRequestsData | **Feature** |
| Outgoing join request | joinClubCode, joinClubRequestedName, joinClubApprovedRole | **Feature** (membership) |
| Teams + squads | teamsList, team.squad | **Feature** |
| Club player pool | clubSquad | **Feature** |
| Other clubs | clubData, clubColors | **Feature** (reference data) |
| Club matches | matchesList, matchIdCounter | **Feature** |
| Active booking flow | activeMatchId, wf, calMonthOffset, gdPhotoIndex, setupCityOpen, paymentMethod, paymentStage, countdown | **Feature (flow-scoped)** — must be keyed by matchId |
| Reservations, wallets | groundReservations, clubWalletBalance, cricecoWallet | **Feature** |
| Team selection flow | teamSelectionContext, squadRoles, squadFilter, selectedExistingTeam | **Feature (flow-scoped)** |
| Availability slots | myAvailabilitySlots, availSlotDraft | **Feature** |
| Player hunt | publishedHunts, newHunt, huntInterest, openPlayers | **Feature** (shared by club and player sides) |
| Tournaments | myTournamentsData, availableTournamentsData, myRegistrations, counters | **Feature** |
| Current selections | currentTournamentId, currentBrowseTournamentId, currentRegistrationId, currentTeamRequestAbbr, currentClubAbbr, currentTeamName, currentJoinRequestIndex, currentScorecardOpponent | → **route parameters** (not state) |
| Player matches / performance / scorecards | myMatchesData, scorecardData, matchLogPerf, stat arrays | **Feature** (player) |
| Notifications | CE_NOTIFS | **Feature** |
| Privacy / security prefs | cePrefs | **Feature** |
| Selected tabs | myMatchesTab, perfTab, matchHistoryFilter, upcomingTab (**set externally before navigating**), myRegTab, tournamentDetailsTab, openPlayersTab | **Local** (but `upcomingTab` and `tournamentDetailsTab` are deep-link parameters) |
| Filters / search | openMatchesSearch, openMatchesRoleFilter, teamSquadFilter, addPlayersFilter, openPlayersCityFilter, openFilter, browseTournamentsCityFilter | **Local** |
| Dropdown open flags, calendar offsets, carousel index | *Open, availPickerMonthOffset, availDatePickerOpen, gdPhotoIndex | **Local** |
| Form drafts | newTeam, newTournament, newHunt, availSlotDraft, club (setup), pending availability fields, agreeToRules | **Local / flow** |
| Navigation history | history_ | replaced by go_router |

`currentClubAbbr` alone does 5 unrelated jobs (challenge opponent, profile subject, booking opponent, "organizer" label, team captain source). It must be split (Risk R6).

---

## 23. Reusable Flutter widget inventory

| Widget | Prototype class / helper | Used on |
|---|---|---|
| `CeTopBar` (back + title + optional right action) | `.top-header`, `ceHeader()` | ~50 screens |
| `CeBrandHero` (gradient + arc motif) | `.banner`, `.club-hero`, `.home-hero`, `.tourn-hero`, `.tourney-banner`, `.sc-header-card`, `.winner-banner` | auth, continueAs, dashboards, profile, tournament screens, scorecard |
| `CeMenuHeader` (hamburger / bell inside hero) | `.pd-header`, `.hamburger` | dashboards, chooseOption |
| `CePrimaryButton` / `CeSoftButton` / `CeDangerOutlineButton` / `CeGoogleButton` | `.btn-primary`, `.btn-green-soft`, `.btn-outline-red`, `.btn-google` | everywhere |
| `CeTextField` (leading icon, trailing eye / chevron) | `.input-wrap` | all forms |
| `CeSelectField` (readonly + inline list) | `.fake-dropdown-list` | 6 forms |
| `CeSegmented` / `CeTabPills` | `.toggle-pill`, `.tab-pill-row` | login/signup, create account, 8 tabbed screens |
| `CeUnderlineTabs` | `.ph-u-tab`, `.td-tab` | Player Hunt, Tournament Details |
| `CeChip` (choice) / `CeFilterChipWithCount` | `.role-pill`, `.squad-filter-chip`, `.ph-format-chip` | forms, squads |
| `CeStatusChip` | `.status-chip`, `.status-badge`, `.tourney-status-pill`, `.new-pill`, `.accepted-pill` | matches, tournaments, registrations |
| `CeCard` (base) | card system rule (:2019) | everywhere |
| `CeStatCard` / `CeStatsRow` | `.stat-card`, `.pd-stat-card`, `.mp-stat-card`, `.cp-stat`, `.tsc-item` | dashboards, performance, tournaments, club profile |
| `CeQuickActionGrid` | `.quick-grid`, `.pd-quick-grid` | both dashboards |
| `CeSectionHeader` (+ "View All") | `.section-title`, `.pd-section-head` | most screens |
| `CeSummaryCard` (key/value rows + total) | `.summary-card` | ~15 screens |
| `CePlayerRow` / `CeSquadPickRow` (+ stats button, lock state) | `.player-row`, `.squad-pick-row`, `.member-row`, `.squad-row`, `.key-player-row` | requests, members, squads, builder, available players, club profile |
| `CeTeamRow` / `CeTeamRadioRow` | `.team-row`, `.team-radio-row` | teams, tournaments, picker |
| `CeMatchCard` (confirmed) | `.confirmed-match-card` | dashboards, My Matches, Match Mgmt |
| `CePendingMatchCard` | `.pending-card` | Match Mgmt |
| `CeNextMatchHeroCard` | `.pd-next-match` | player dashboard |
| `CeChallengeCard` | `challengeCard()`, `findMatchCard()`, `matchCardHtml()` | challenges, find match, fixtures |
| `CeTournamentCard` / `CeRegistrationCard` / `CeHostedTournamentCard` | `.tourn-browse-card`, `.reg-card`, `.mt-card` | tournament screens |
| `CeGroundCard`, `CeCalendarGrid`, `CeSlotChip`, `CePaymentMethodTile`, `CeSplitCard`, `CeCountdownBox`, `CeProgressDots` (wfProgress 1–7) | booking classes | booking flow |
| `CeSuccessPanel` (icon circle + title + copy; red variant) | `.wf-success` | 8 success / expired screens |
| `CeProgressChecklist` / pulse badge | `.oc-hero`, `.oc-checklist` | Waiting Approval, Waiting for Opponent |
| `CeEmptyState` (+ primary / secondary CTA) | `.empty-state`, `ceEmptyState()`, `emptyMsg()` | §19 |
| `CeBottomNav` (5 variants — §24) | `.bottom-nav` | 30+ screens |
| `CeRoleBadge` | `.ce-role-pill`, `.pd-role-pill`, `.owner-tag` | drawer, dashboards |
| `CeRoleDrawer` (+ switch row) | `screens.menu` | dashboards |
| `CeRoleCard` | `.ce-role-card` | Continue As |
| `CeBottomSheet` / `CePlayerStatsSheet` / `CeActionSheet` | `.ce-sheet` | Add Players, Tournament Details |
| `CeToast` (SnackBar styled) | `.toast` | global |
| `CeToggleRow` / `CeSettingsRow` / `CeProfileRow` / `CeNotificationTile` | `.ce-set-row`, `.ce-prof-row`, `.ce-notif`, `.oto-card` | settings, privacy, security, profile, notifications, open matches, availability |
| `CeAvatar` (initial) | `.avatar` | everywhere |
| `CeFormDots` (W/L) | `.ce-fd`, `.form-dot`, `.mfc-dot` | Add Players, sheet, club profile, performance |
| `CeScorecardTable` / `CePointsTable` | `.sc-*`, `.points-table` | scorecard, tournaments |
| `CeStepper` | `.ph-stepper-card` | Player Hunt |
| `CeInfoNote` | `.demo-box`, `.wallet-note`, `.avail2-tip`, `.ce-picker-note` | ~10 screens |

### Bottom navigation variants (must be decided — D5)

| Id | Items | Used on |
|---|---|---|
| P-A | Home · Matches · Performance · Profile | playerDashboard, myMatches, myPerformance, matchHistory, matchScorecard, openMatches |
| P-B | Home · Matches · **Squad (→ club `teams`)** · Profile | availability |
| C-A | Home · Teams · Members · Profile (→ myClub) | clubHome, teams, teamSquad, members, openPlayers, all tournament screens |
| C-B | Home · **Matches (→ challenges)** · Teams · Profile | challenges, myChallenges, findMatch |
| C-C | Home · **Matches (→ upcomingMatches)** · Teams · Profile | upcomingMatches |
| none | — | all flows, forms, profile, settings, requests, add players, booking |

---

## 24. Design token summary

**Colours** (effective after `build.js` recolouring and the v20 layer, :1875):

| Token | Value | Use |
|---|---|---|
| primary / green | `#158447` (**X7: host prop may override to `#0D3F2A`**) | CTA, active chips, toggles |
| primary-600 / green-mid | `#105C38` | pressed, gradient mid |
| primary-dark / green-dark | `#0B3324` | deep brand, drawer switch icon |
| primary-deep / green-darker | `#07261B` | gradient end |
| fresh | `#28A85F` | available dot, legend |
| mint / green-light / green-pale | `#EAF6EF` | icon wells, soft buttons, notes |
| mint-2 / green-pale2 | `#D6EDE0` | soft borders, progress track |
| bg | `#F6F8F6` | screen background |
| surface / white | `#FFFFFF` | cards |
| ink / ink-2 | `#152019` / `#2F3B34` | text |
| muted / muted-2 | `#69746D` / `#98A29B` | secondary text, inactive nav |
| line / line-2 | `#E4EAE6` / `#DBE3DD` | borders, inputs |
| red / red-soft | `#C43B2F` / `#FBEAE7` | danger, loss, rejected |
| amber / amber-soft | `#B7791F` / `#FDF3E2` (text `#8A5F12`) | pending, limited |
| blue / blue-soft | `#2563A8` / `#E9F1FB` | reserved, injured, info |
| toggle off | `#C8D2CB` | |
| countdown | gradient `#FDF3E2`→`#F7E3BB`, border `#F0D9A8`, text `#6E4A0F` | |
| club colours | KK `#b7791f`, IU `#2563a8`, RR / FW / DB `#c43b2f`, GC `#b7791f`, GT `#158447` | badges |
| brand gradient | `linear-gradient(135deg, #0B3324 0%, #105C38 60%, #158447 100%)` + radial lift `rgba(255,255,255,.10)` | heroes |
| scrims | drawer `rgba(0,0,0,.35)`; sheet `rgba(11,51,36,.42)` | |

**Typography:** Manrope, with Inter and Plus Jakarta Sans as selectable prop alternatives. Weights 500 / 600 / 700 / 800. Letter-spacing is slightly negative on titles (−0.01 to −0.035 em) and positive, uppercase, on stat labels (+0.04 to +0.08 em). Numerals use tabular and lining figures.

| Role | Size / weight |
|---|---|
| Hero name / banner h1 | 21–23 / 800 |
| Screen success title, empty title | 19 / 800 |
| Stat number | 15–20 / 800 |
| Top bar title | 16 / 700 (ellipsis) |
| Section title | 15 / 700 (sentence case) |
| Button | 15 / 700 |
| Input | 14.5 / 500 |
| Body / row title | 13–14 / 700 |
| Meta / row subtitle | 12–12.5 / 500 |
| Captions, chips | 11–12.5 / 600 |
| Stat label, drawer label | 10–11 / 600–700 uppercase |
| Bottom nav label | 10.5 / 600 (active 700) |

**Radii:** xs 8 · sm 10 · md 12 (buttons, inputs, icon wells) · lg 16 (cards) · 14 (rows, stat cards) · xl 20 (empty icon) · 22 (sheet top) · pill 999 (chips, status, avatars).

**Shadows:** card `0 3px 12px rgba(11,51,36,.05)`; raised `0 6px 18px -8px rgba(11,51,36,.22)`; hero `0 16px 34px -16px rgba(11,51,36,.5)`; primary button `0 6px 14px -8px rgba(22,128,61,.85)`; bottom nav `0 -4px 16px -10px rgba(13,63,42,.25)`; sheet `0 -14px 40px -16px rgba(11,51,36,.5)`; focus ring `0 0 0 3px rgba(22,128,61,.12)`; selected card ring `0 0 0 3px rgba(22,128,61,.1)`.

**Borders:** 1 px `line` (cards), `line-2` (inputs), primary on focus or selected; dashed 2 px `#98A29B` on photo pickers.

**Icons:** custom 24-px stroke set (Lucide-compatible names, stroke 2 in the file, rendered at 1.9), sized 1em. Wells: 26 / 30 / 32 / 34 / 36 / 44 / 46 / 56 / 64 / 72 px. Bottom-nav icon 22 px. All ~75 icons map 1:1 to `lucide_icons` names. `footprints` reuses the `activity` path.

**Spacing:** screen gutter **18 px** (lists and sections); form body 22 px; top bar 10×16; section title padding 20/18/10; card padding 14; gaps 6 / 8 / 10 / 12 / 14. Minimum heights: button 50, input 52, search 48, chip 31, status chip 22, touch target 40, nav item 52, drawer item 44, action row 48.

**Motion:** 140–220 ms; press scale .98–.99; screen fade-up 6 px / 220 ms; role-switch fade 160 ms; sheet slide 220 ms `cubic-bezier(.25,.9,.35,1)`; toast 1.5 s.

---

## 25. Responsive risks

| Risk | Where | Flutter-safe recommendation |
|---|---|---|
| Long names in hero / title | clubHome (`CE_CLUB_NAME_HTML` uses a hard `<br/>`), top bar titles (team names), drawer name / club tag (`nowrap`) | `Text(maxLines: 2, overflow: ellipsis)`; drop the hard line break; `Flexible` for the drawer tag |
| Multiple badges in one row | Add Players row (name + verified + rating + matches + 5 form dots + badge + Stats button); Find Match name + format tag | `Wrap` for meta; right column in `IntrinsicWidth`; allow the meta row to wrap to 2 lines at small widths |
| Dense stat rows | joinRequestProfile (4 stats), pd-stats-row (3 cards with fixed 2.5em label row), mp-simple-row (4), tsc (4), sheet 4-column grid | `Row` + `Expanded` with `FittedBox` on numbers; `textScaler` clamp ~1.3; allow labels 2 lines |
| 5-column status grid | Availability `.avail2-status-grid` (grid-auto-flow column, 5 across at 375 px) | `GridView` or `Wrap` with 3 columns (the earlier CSS intent) — decision D13 |
| Horizontal lists | tab-pill-row, squad-filter-row, perf-snap-row, role-pill-row | `SingleChildScrollView(scrollDirection: horizontal)` with edge padding 18; no nested vertical scroll |
| Bottom nav overlap | sticky `.bottom-nav` + last CTA (`scroll-padding-bottom: 84px`) | `Scaffold.bottomNavigationBar` + `SafeArea`; never overlay |
| Fixed-width elements | `.pd-club-card` 92 px, drawer 82 %, `perf-snap-item` 74 px, sheet max 88 % | `ConstrainedBox`; drawer `width: min(0.82·w, 320)`; `DraggableScrollableSheet` |
| Absolute-positioned UI | ground carousel controls, tournament banner icons, toast bottom 80, notif badge, photo-picker camera badge, drawer overlay | `Stack` + `Positioned` inside a fixed-height `SizedBox`; use a SnackBar for toasts |
| Long CTA labels | "Pay Rs 8,000 via Debit / Credit Card →", "Reserve Ground for 30 Minutes →", "Continue → Booking Summary", "Generate Fixtures (1/2 min)", "Set up Club Owner profile" | Buttons allow 2 lines, centred (CSS already `white-space: normal`); min height 50 |
| Nested scroll areas | drawer inner scroll, sheet scroll, horizontal rows inside the page, inline dropdown lists | `CustomScrollView` / slivers; no `ListView` inside `ListView` without `shrinkWrap` |
| Large forms | Create Tournament (12 fields), Availability, Player Hunt, Create Club | `Form` + `ListView`; keyboard-safe (`resizeToAvoidBottomInset`); sticky submit optional (keep inline per prototype) |
| Tables | Scorecard (name + dismissal + 4 numbers), points table | `Table` with flex column widths; the dismissal wraps under the name |
| Summary rows with long values | "{Opponent}'s Share (50%)", Tournament Dates range | label `Expanded`, value `Flexible` right-aligned, wrap |
| Invisible native inputs over cards | Player Hunt filter cards (select / date / time overlaid) | Replace with a tappable card that opens a Flutter picker (same visual) |

---

## 26. Navigation risks

| Risk | Prototype behaviour | Recommended Flutter behaviour (no product change) |
|---|---|---|
| **Drawer as a route** | `go('menu')` pushes the drawer; drawer items push on top. **Back from a destination reopens the drawer** (e.g. drawer → Challenges → Back). Closing the drawer *pushes* the origin again. | Drawer = `Scaffold.drawer`, not a route. Drawer items use `context.go()` to the role destination. Closing pops the drawer only. |
| Role switching | history reset to `[target]` + fade + toast | `context.go(roleHome or lastRoute)` (replace the stack); rebuild the shell for the other role; SnackBar |
| Continue As / Login / Logout | history reset | `go()` (replace). Logout: clear the session **and decide whether to clear persisted role flags (D4)** |
| Bottom navigation | every tab does `go()` (push); many hard-coded backs | `StatefulShellRoute` per role; tab tap = switch branch; keep hard-coded "Back" targets as `go(parent)` where the prototype hard-codes them |
| Back from nested flows | mix of `back()` pops and hard-coded targets; fallback at stack root = role home (auth screens → auth parent) | Reproduce: `pop()` where the prototype uses `back()`; `go(parent)` where hard-coded; `PopScope` fallback to role home |
| Tournament success | Published → View Tournament pushes Details; **Back returns to the success screen, then to the reset create form** | `pushReplacement` Published → Details (so Back returns to the hub or My Tournaments). **Needs approval** because it changes back behaviour. |
| Registration success | Success has no back; View Registration pushes Details (Back → My Registrations, hard-coded) | Keep: Details' back = `go('/club/registrations')` |
| Booking flow terminal states | Waiting / Opponent Payment / Confirmed / Expired have no back control | `PopScope(canPop: false)` on these; system back → Match Management |
| Booking expiry | only enforced on the Waiting screen | a timer in the booking controller; guard redirect on Payment / Waiting if expired (behaviour-preserving would enforce only on Waiting — D14) |
| Modal return | sheets close and then run the action after 120 ms | `showModalBottomSheet` returns an action; the caller navigates after `pop` |
| Challenge Accepted | no back; CTA creates the pending match | `PopScope(canPop:false)`; the CTA both creates and `go`es to Waiting |
| Join Approved → dashboard | pushes onto the join stack | `go()` (replace) |
| Tab deep links | `upcomingTab` / `tournamentDetailsTab` set in a global before navigating | query parameter `?tab=scheduled` |
| Payment back | Payment → back → Summary → re-reserve creates another reservation | keep the pop, but make `reserve` idempotent per match |
| Not-found guard | `ceNotFound` with dashboard / back CTAs | go_router `errorBuilder` + in-screen guards when an id is missing |

---

## 27. Potential duplicate / legacy screens (nothing removed)

| Candidate | Why it looks duplicate | Reachable in-app? | Recommendation (awaiting approval) |
|---|---|---|---|
| `createTeam` | Same form as the inline form on My Teams; its button only toasts, and the format field has no options | **No** (the only link was the legacy drawer) | Do not migrate as a separate route; the inline form on My Teams is canonical. **D9** |
| `screens.menu` (first definition, :5674) | Overridden by the role-aware drawer at :7923 | No (dead code) | Do not migrate |
| `teamBuilder` vs `addTeamPlayers` | Same 11 + 4 cycle picker (logic duplicated); only Add Players has Stats and scouting metadata | Both | One `SquadPicker` widget with a `showScouting` flag; keep both routes |
| Match-by-Match (My Performance) vs `matchHistory` | Same cards (first 5 vs all + filter) | Both | Keep; share `MatchLogCard` |
| `challenges` vs `findMatch` | Both show club cards and the availability-slot box, with different intent (clubs to challenge vs clubs seeking opponents) | Both | Keep both (distinct intent); share card widgets |
| Tournament Details "Teams" tab vs `tournamentTeamsManage` confirmed list | Same list and Remove action | Both | Keep; share widget |
| `tournamentDashboard` vs `registrationDetails` (approved) | Same fixtures, points and upcoming/results composition | Both (host vs participant) | Keep separate routes; share sections |
| `hostTournament` hub vs `myTournaments` | The drawer "Tournaments" bypasses the hub | Both | Keep; decide the drawer target (D10) |
| `myClub` | Player-facing copy ("Teammates") and a player-nav branch, in club context | Yes (club) | Keep in Club; decide copy / role (D3) |
| `myMatches` vs `upcomingMatches` | Both "matches" lists, but per role with different data models | Both | Keep both; do not merge |
| Unused helpers | `tournamentTabRow`, `setJoinReqTab` / `joinReqTab`, `shareViaWhatsapp` (also a broken template string), `cycleAvailDay` / `availCalNav` / `respondMatchAvail` / `playerAvailDays` / `matchAvailResponses` (old availability calendar), `toggleCityList` / `pickCity`, `completeMatchOn` ≈ `completeMatch`, `statusPillClass` ≈ `tournStatusPillClass` | — | Do not port |

---

## 28. Confirmed dead controls / routes

No undefined routes exist. All of the following are confirmed from code.

| # | Control | Screen | Issue |
|---|---|---|---|
| 1 | Password "eye" icons | Login, Create Account | no handler |
| 2 | "Search members…" | Members | static div |
| 3 | Format field | Create Team (legacy) | readonly, no options |
| 4 | "Create Team" | Create Team (legacy) | toast only, nothing created |
| 5 | "Share with players" | Club Dashboard | toast "Club code copied!" only (no clipboard or share) |
| 6 | "Invite" | Available Players | toast only |
| 7 | Share sheet actions (copy link, WhatsApp, members) | Tournament Details | toast only |
| 8 | "Decline" (incoming challenge) | My Challenges | toast only; card stays |
| 9 | "Accept Challenge" | My Challenges | card stays; repeat taps create duplicate pending matches |
| 10 | Info (i) button | Availability | toast only (acceptable tooltip) |
| 11 | Stat cards (Members / Teams / Requests; Upcoming / Rating / Played) | Both dashboards | not tappable |
| 12 | Upcoming and cancelled match cards | My Matches | no destination (no Match Details) |
| 13 | Settings → "Notifications" preference row | Settings | opens the inbox, not preferences |
| 14 | Edit Profile city / phone | Edit Profile | not saved |
| 15 | Complete Profile name / DOB / phone | Complete Profile | unbound |
| 16 | "Update Password" | Security | no validation; toast only |
| 17 | Notification "Tournament update: Spring Cup" | Player Notifications | routes to Open Matches (wrong destination) |
| 18 | Notification "Tournament registration approved" | Club Notifications | opens the Pending tab; the tournament does not exist |
| 19 | Bell badge "3" | Player Dashboard | static |
| 20 | "Match starts in 18h:45m:32s" and dashboard stats | Player Dashboard | static |
| 21 | "View Match Details" | Player Dashboard | **incorrect role destination (L2)** |
| 22 | Bottom nav "Squad" | Availability | **incorrect role destination (L1)** |
| 23 | "Go to Coach / Manager Dashboard" | Join Approved | **incorrect role destination (L3)** |
| 24 | Hub "Venues" | Tournament Center | enters the booking flow with no match |
| 25 | "5 Teams" header | Find Match | shows 2 |
| 26 | "Rawalpindi Riders" card | Find Match | opens Rawalpindi Rams |
| 27 | Enter Club Code back | Enter Club Code | returns to Continue As instead of its parent `chooseOption` |
| 28 | Back after drawer navigation | all `back()` screens reached from the drawer | reopens the drawer |
| 29 | Open-to-offers listing | Open Matches / Availability | never visible to clubs (empty city) |
| 30 | Organizer label | Tournament Details (hosted) | shows another club |
| 31 | Team format | My Teams | discarded on create |
| 32 | Playing XI / Sub | Add Players reopen | assignment lost |
| 33 | Booking month | Select Date → summaries | always "Aug 2026" |

Simulation / dev controls (not dead, but prototype-only — **D2**): "As Player / Coach / Manager", "Opponent Pays Now", "Dev: force reservation to expire now", "Prototype: Simulate Organizer Decision", "Tap to simulate result", random logo / photo pickers, KRC001 demo hints, "This is a Final Year Project — payments are simulated" notice.

---

## 29. Flutter migration risks

| Severity | Risk | Why | Mitigation |
|---|---|---|---|
| **Critical** | Role-context leakage L1–L3 | A typed router with role guards will either block these paths (changing behaviour) or reproduce privilege escalation (the Player gains a Club Owner profile). | Decide D1 before building the router. |
| **Critical** | Implicit global state as navigation input | 8 `current*` globals and `wf`, `activeMatchId`, `teamSelectionContext` are set before `go()`; restoring or deep-linking a route loses them. | Move every selection into route parameters; flow controllers keyed by id. |
| **High** | Drawer-as-route back stack (§26) | Faithful porting makes Back reopen the drawer. | Scaffold drawer (not a route). |
| **High** | Name- and index-keyed entities | teams, scorecards and join requests use name or array index; duplicates and splice shift indices. | Stable ids in models and routes. |
| **High** | Booking timer / expiry lifecycle | `setInterval` bound to one screen; expiry not enforced elsewhere. | Booking controller with a single `Timer` / clock; decide the enforcement scope (D14). |
| **High** | Two tournament shapes, two match datasets | Hosted vs browse tournaments differ; player vs club matches are unrelated. | Unified `Tournament` model with an adapter for seeds; keep player and club match lists separate until D7. |
| **High** | Squad XI / Sub persistence | Porting as-is keeps a data-loss bug. | `TeamMember.selectionRole` (D11). |
| **High** | `currentClubAbbr` reuse | Wrong organizer, captain and opponent leak across flows. | Split into opponentId (booking), clubId (profile route), organizerId (tournament). |
| Medium | 5 bottom-nav variants; "Matches" tab targets differ | Shell routes need one definition per role. | D5 |
| Medium | Brand colour conflict | Wrong green in every widget if chosen incorrectly. | D8 / X7 |
| Medium | Simulation controls mixed with product UI | Must be flagged or dev-only. | D2; compile-time `kDemoMode` |
| Medium | Knockout BYE never advances | Tournaments with 3, 5, 6 or 7 teams can never finish. | Report only; replicate unless approved. |
| Medium | Search ranking requested but absent | Scope creep if added silently. | X1 |
| Medium | Toast-only validation, no inline errors | Flutter `Form` validators would change the UX. | Keep SnackBar validation to match the prototype, unless approved. |
| Medium | Deterministic mock stats (`ceStats` hash) | Must not leak into production models. | Seed repository behind an interface. |
| Medium | Persisted role flags not cleared on logout | Security / UX ambiguity. | D4 |
| Low | Inline dropdowns and native selects | Pure presentation. | `CeSelectField` + bottom-sheet picker. |
| Low | Seed data inconsistencies (IU duplicate, Riders / Rams, "5 Teams", club naming) | Cosmetic. | Keep as seed; list in QA. |
| Low | Animation parity (fade-up, pulse rings, spinner) | Cosmetic. | `AnimatedSwitcher`, simple implicit animations. |
| Low | External links (Google Maps, WhatsApp) | Needs `url_launcher`. | Standard. |

---

## 30. Flow diagrams

```
AUTHENTICATION
Login → Continue As → Player Dashboard | Club Owner Dashboard | Set Up Your Club
Login → Sign Up → Create Account → Complete Profile → Playing Style → Continue As
Sign Up → Continue with Google → Complete Profile → …

PLAYER
Continue As → Player Dashboard → My Matches → (Past) Scorecard
Player Dashboard → My Performance → Match History
Player Dashboard → Availability → Update
Player Dashboard → Open Matches → I'm Interested
Drawer → My Profile → Edit Profile → Save → My Profile

CLUB OWNER
Continue As → Club Owner Dashboard → {Requests, Members, My Teams, Challenges, Player Hunt, Match Management, Tournament Center}
First time: Continue As → Set Up Your Club → Create Club → Club Details → Club Owner Dashboard

TEAM MANAGEMENT
My Teams → (inline Create Team) → Team Squad → Add Players → [Stats sheet] → Save Squad → Team Squad

CHALLENGES
Dashboard → Challenges → Club Profile → Challenge This Club → Challenge Accepted → Match Management (Waiting) → Match Setup
Dashboard → Challenges → Find Match → Send Match Request → Challenge Accepted → …
Challenges → My Challenges → Accept → Match Management (Waiting)
Challenges | Find Match → Create Availability Slot → Post → Find Match

MATCH MANAGEMENT
Match Management: Waiting (pending → Setup | reserved → Payment / Waiting) · Scheduled (→ Select XI) · History

GROUND BOOKING
Match Setup → Book a Ground → Ground Details → Select Date & Time → Booking Summary → [Reserve 30 min] → Payment
 → Waiting for Opponent → Opponent Payment → Booking Confirmed → Select Team → Team Builder | Team Picker → Match Management (Scheduled)
 ↳ conflict → Select Date & Time      ↳ timeout → Reservation Expired → Refund | Wallet → Match Management (Waiting)

TOURNAMENT REGISTRATION
Tournament Center → Browse (city) → Register Details → Select Team → Team Builder | Team Picker → Registration Summary → Submit
 → Registration Success → Registration Details | My Registrations → Registration Details

TOURNAMENT HOSTING
Tournament Center → Create Tournament → Published → Tournament Details [Overview | Teams | Fixtures | Points]
 → Manage Teams → Registration Request → Accept | Reject
 → Generate Fixtures → Tournament Dashboard
Drawer "Tournaments" → My Tournaments → Tournament Details

ROLE SWITCHING
Drawer → Switch to Club Owner → (no profile) Role Setup → Set Up Your Club → …
Drawer → Switch to Club Owner → (profile) last club screen / Club Owner Dashboard  [stack reset, toast]
Drawer → Switch to Player profile → last player screen / Player Dashboard  [stack reset, toast]

LOGOUT
Drawer | Settings → Logout → Login  (stack reset; persisted role flags retained)
Set Up Your Club → Logout pill → Login  (pushed)
```

---

## 31. Recommended Flutter folder structure

```
lib/
  main.dart
  app/
    app.dart                      # MaterialApp.router, theme
    router/
      app_router.dart             # go_router, redirects (auth, role, club-profile guard)
      routes.dart                 # route names = prototype screen keys
      shells/player_shell.dart    # StatefulShellRoute + CeBottomNav (P-A)
      shells/club_shell.dart      # (C-A, per D5)
    theme/
      tokens.dart                 # colours, radii, shadows, spacing, motion (from §24)
      typography.dart
      app_theme.dart
  core/
    models/                       # §20 (freezed / json_serializable)
    enums/                        # §21
    utils/format_display.dart, ranked_search.dart (only if X1 approved), date_utils.dart
    demo/                         # seed data + ceStats hash, behind kDemoMode
  data/
    repositories/                 # interfaces + in-memory implementations seeded from the prototype
  features/
    auth/                         # login, signup, createAccount, completeProfile, roleDetails
    role/                         # continueAs, roleSetup, drawer, role_controller
    club_setup/                   # chooseOption, createClub, clubDetails
    membership/                   # enterClubCode, waitingApproval, joinApproved
    player/
      dashboard/ profile/ matches/ scorecard/ performance/ availability/ open_matches/
    club/
      dashboard/ my_club/ members/ requests/ teams/ player_hunt/
    challenges/                   # challenges, myChallenges, findMatch, availabilitySlot, clubProfile, challengeAccepted
    matches/                      # upcomingMatches (Match Management)
    booking/                      # matchSetup … reservationExpired, booking_controller (timer)
    team_selection/               # selectTeam, teamBuilder, teamPicker (context: match | tournament)
    tournaments/
      hub/ create/ hosted/ browse/ registration/ fixtures/
    notifications/
    settings/                     # settings, privacy, security, editProfile
  shared/
    widgets/                      # §23 Ce* widgets
    sheets/                       # player stats sheet, action sheet
test/
  golden/  widget/  router/
```

State management recommendation: **Riverpod**, with a global `sessionProvider` and `roleContextProvider`, feature `Notifier`s, and `family` providers keyed by id for booking and team-selection flows. This is a recommendation for your approval, not a prototype fact.

---

## 32. Recommended migration order

1. **Foundation:** tokens, theme, typography, icon mapping (§24; resolve D8 first), `Ce*` base widgets (buttons, fields, cards, chips, status chips, empty state, top bar, bottom nav, toast, avatar), golden tests against screenshots of the prototype.
2. **Models, enums, seed repositories** (§20–21), with stable ids; port the seed data verbatim.
3. **Router skeleton:** all 71 routes as placeholders; auth → Continue As → role shells; the drawer; role-context controller (persist, switch, last route); back fallbacks. Resolve D1, D3, D4 and D5 first.
4. **Auth and onboarding** (5 screens) + Continue As + Role Setup + club setup (3) + membership (3).
5. **Player module** (8 screens) + Notifications / Settings / Privacy / Security / Edit Profile.
6. **Club core:** Dashboard, My Club, Members, Requests (+ profile), My Teams, Team Squad, Add Players + Player Stats sheet, Player Hunt.
7. **Challenges** (6 screens) → Match Management.
8. **Booking flow** (10 screens) + booking controller (timer, reservation, payment simulation) + team selection (3).
9. **Tournaments:** hub, create, published, hosted, details (tabs), dashboard, manage, request; then browse, register, summary, success, registrations, details; fixture engine.
10. **Parity QA** against every row of §2, §16, §18, §19, §28; navigation tests for every §26 case.

---

## 33. Decisions required before implementation

| ID | Decision | Options |
|---|---|---|
| D1 | Role leaks L1–L3 (Availability "Squad", "View Match Details", Coach/Manager → Club dashboard) | (a) reproduce exactly; (b) keep the controls but route within the Player context (needs a destination, e.g. My Club / a Match Details screen that does not exist yet); (c) remove the controls |
| D2 | Simulation / dev controls | keep visible · show only in demo mode · remove |
| D3 | `myClub` ownership and copy ("Teammates"); `editProfile` context | keep as-is in Club · add a player variant |
| D4 | Logout: clear persisted role, club-profile and last-route flags? | keep (prototype) · clear |
| D5 | Bottom-nav variants P-B, C-B, C-C | reproduce per screen · normalise per role |
| D6 | Location of Join a Club (inside Club Owner setup) | keep · also expose to Player |
| D7 | Player matches vs club matches datasets | keep independent · link |
| D8 | Brand green `#158447` vs host-prop default `#0D3F2A`; default font Manrope | pick one |
| D9 | Legacy `createTeam` route | drop · keep as an alias to My Teams |
| D10 | Naming (Player Hunt / Open Player / Open Players; Match Management / Upcoming Matches; drawer Tournaments → My Tournaments vs hub) | keep · unify |
| D11 | Persist Playing XI / Sub and team format; approved members joining the player pool | keep the prototype data loss · fix |
| D12 | Confirmation dialogs for destructive actions | none (prototype) · add |
| D13 | Availability status grid: 5 across vs 3 columns | — |
| D14 | Reservation expiry enforcement scope | Waiting screen only (prototype) · everywhere |
| D15 | Search ranking rule (X1) | do not add · add to Open Matches (+ Members, if its search becomes real) |
| D16 | Include T10 in `MatchFormat` | — |

---

## 34. Final readiness verdict

**Conditionally ready.**

- **Can start now without any product decision:** steps 1–2 of the migration order (design tokens, except the D8 colour choice; base widgets; models, enums and seed data with stable ids; golden-test harness). None of these change behaviour.
- **Blocked until decisions are made:** the router and shells (D1, D3, D4, D5, D10), the booking controller (D14), the team model (D11), search (D15) and the colour token (D8).
- The prototype is internally complete: 71 screens, no undefined routes, every screen reachable, and consistent component and token systems. Nothing blocks a faithful migration except the ambiguities listed above. The three critical role-context leaks (L1–L3) are the only items where a faithful port would carry forward behaviour that conflicts with your stated role architecture.

*End of audit. No Flutter implementation has been started.*
