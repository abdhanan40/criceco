# CricEco — Foundation Phase Report

**Status:** complete. No feature screens were built; every route shows a placeholder with its final route, top bar and back behaviour.
**Toolchain:** Flutter 3.47.5 stable / Dart 3.13.4, installed at `C:\src\flutter` (not on PATH — run `C:\src\flutter\bin\flutter.bat`).
**Packages:**
- `flutter_riverpod` 3.4
- `go_router` 18.0
- `intl`
- `google_fonts` (Manrope)
- `lucide_icons_flutter`
- `shared_preferences`
- `url_launcher`
- `clock`
- `collection`
- `cupertino_icons`
- `flutter_lints` 6 (stricter rules in `analysis_options.yaml`)

## Verification

| Check | Result |
|---|---|
| `flutter analyze` | No issues found |
| `flutter test` | 43 / 43 passed |
| `flutter build web` | Built `build\web` |
| Manual check in browser (375×812) | Login → Continue As → Player dashboard; drawer; bottom nav; the persisted role restores on reload |

## Deviations from the revised blueprint (flagged, not silent)

1. **Challenges sub-screens** (My Challenges, Find Match, Create Availability Slot) are children of `/club/challenges`, so Back returns to **Challenges**, as it does in the prototype. The blueprint table said Back → Dashboard.
2. **Registration Summary** path is `/club/tournaments/browse/:id/team/summary`, not `…/:id/summary`. The extra `/team` segment makes Back return to Select Team, as the blueprint intended.
3. **Router guard order:** the wrong-role check now runs before the club-profile check, so a Player who hits a stray `/club/...` link goes back to the Player home rather than to club setup.
4. **Seed dates:** "upcoming" seed items (the next match, the confirmed booking, tournament deadlines) are anchored to today with the prototype's relative spacing. Past history keeps the prototype's absolute dates.

## Known limitations of the mock layer
- The mock repositories live in memory for the session only. After an app restart the remembered role is restored, but a Club Owner profile created in that session is gone. In that case the app falls back to Continue As instead of breaking. A real backend removes this limitation.
- Creating a club attaches the prototype's demo club data (members, teams, player pool) to the new club name, so every Club Owner screen has data to show.
- Manrope is fetched at runtime by `google_fonts`. Bundling the font files is recommended before offline or store builds.
- Only the web target was built. Android and iOS toolchains (`flutter doctor`) have not been checked on this machine.
