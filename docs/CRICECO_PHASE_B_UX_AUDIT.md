# CricEco — Phase B UX Audit & Changes

Phase B is a UX refinement pass on top of the Phase A consolidation. It is not a redesign: routes, role boundaries, business rules and feature coverage are unchanged.

## 1. How the audit was done

The Flutter implementation was audited in three slices:

- **Club Owner:** dashboard, teams, squad, add players, members, my club, requests, player hunt.
- **Match flow:** challenges, match management, booking, playing XI.
- **Player and support:** player screens, tournaments, notifications, settings.

For every screen, the audit recorded:

- each control and where it leads;
- empty, loading and error states;
- search and filters;
- where status is shown by colour only;
- one-tap destructive or money-moving actions;
- places where a full screen was used for a small action.

## 2. Findings that shaped the changes

| Area | Finding | Response |
|---|---|---|
| All async lists | Load errors fell through to "empty" (e.g. "No members yet") | `CeErrorState` with Retry on Members, My Club, Teams, Match Management, My Challenges, Notifications |
| Destructive or money actions | Decline request, Decline challenge, Remove slot (Player Hunt and Find Match) and refund choice all happened in one tap | `showCeConfirmSheet` before each; accepting stays one tap |
| Teams | An always-open Create Team form pushed the team list below the fold | "New Team" row opens the same form in a bottom sheet; the list comes first |
| Team Squad | Rows could not be tapped; no XI/Sub status; plain-text empty state | XI/Sub counters, injured/unavailable note, tap row → stats sheet, `CeEmptyState` with Add Players |
| Add Players | No search; Save sat at the end of a long list; no sign of unsaved picks | Ranked search with result count, pinned Save bar, "Unsaved changes" marker, full-squad note |
| Club Dashboard | Pending requests were only a number; stats could not be tapped | Pending-requests banner (shown only when there are some), tappable stats, tappable Next Match |
| Match Management | Next action was a plain text row; the hold countdown never became urgent; no line-up status | Tinted action bar, countdown turns amber < 10 min and red with "Hurry" < 5 min, "Line-up needed / set" chip, whole scheduled card opens the line-up |
| Payment / Waiting | Booking details were only partly visible; unpaid share was shown by colour alone | Expandable "Booking details" card; "You · due" label; opponent share can read "Failed" |
| Booking progress | 7 bars with no visible label | "Step n of 7 · Name" above the bars |
| Playing XI builder | Counts scrolled away; Confirm sat at the end of the list | Pinned bar with XI/Subs counts, role balance and Confirm |
| Performance | Chart showed runs only | Runs ↔ Wickets segmented toggle, remembered for the session, with accessible label |
| Player Dashboard | Stats could not be tapped; "0" shown while loading; empty snapshot header | Tappable stats, "–" while loading, snapshot header only once data exists, feedback toast for the quick availability toggle |
| Notifications | One flat list | Today / Earlier groups |
| Hosted tournament | 9-row summary repeated above every tab | Summary on Overview only (tournament name no longer repeated) |
| Points table | No rank; own team not marked | Rank column; own team highlighted with "(You)" |
| Browse tournaments | Registration status hidden | Status chip on the card |
| Availability | Info icon only showed a toast | Short explainer bottom sheet |
| Scorecard | `reduce` could throw on empty innings | Null-safe top scorer / wicket-taker; empty innings shows "not available" |
| Booking Summary | Any non-conflict error left Reserve spinning | Generic failure resets Reserve and shows a toast |
| Search field (shared) | No clear button | Clear (✕) button; keyboard Search closes the keyboard |
| Bottom sheets (shared) | Opened on the shell navigator, so the bottom nav stayed tappable; not keyboard-safe | Opened on the root navigator; bottom padding follows the keyboard |

## 3. Reusable widgets added or extended

- `CeSegmented` — compact in-place segmented control, for local choices (not routes).
- `CeExpandableCard` — animated, accessible expandable card with a summary line.
- `CeErrorState` — standard load error with Retry.
- `showCeConfirmSheet` — confirmation sheet with red confirm for destructive actions and Cancel.
- `CeStatCard.onTap` — stat cards can open the list behind the number.
- `CeSearchField` — clear button and keyboard handling.
- `CeChipRow.countOf` — a count on selected chips only (used for the My Challenges tab badge).
- `showCeSheet` — root navigator and keyboard-safe.

## 4. Deliberately not changed (and why)

| Item | Why it stays |
|---|---|
| Open Matches "All" shows nothing until a role is picked | Prototype behaviour (documented in `player_providers.dart`) |
| Notification taps replace history (Back → the item's logical parent) | Phase 9 decision, covered by tests |
| Accepting a challenge hands off to Match Management → Waiting | Prototype flow |
| Multi-step booking and tournament creation | They genuinely need separate steps |
| Password & Security as its own screen | It holds a form; allowed by the brief |
| Match-count difference (Overview 8 vs History 12) | Prototype seed data; needs a product decision |
| Registration Details lists fixtures twice (all rounds, then Upcoming / Results) | Tests and Demo simulation depend on the full list; candidate for Phase C |
| Join-request profile as a full screen | It is a deep-link target from notifications |
| Challenge send without choosing a format | Adding a format step would change the business flow |
| Tab-root back arrows (Teams, Members, My Club, My Performance) | Consistent app-wide pattern: only the role home has the hamburger |
| Open Players invite is in-memory only | Backend concern, not UX |

## 5. Screen count

- **Screens:** 68 unique, the same as after Phase A. Phase B adds no screens and removes none. It moves interactions into sheets, cards and inline states instead.
- **Converted to bottom sheets:**
  - Create Team (was an inline, always-open form);
  - Availability info (was a toast);
  - confirmations for decline, remove and refund.
- **Converted to expandable sections:** booking details on Payment and Waiting for Opponent.
- **Converted to in-place views:** chart metric toggle; squad player stats open in the existing stats sheet from Team Squad.
