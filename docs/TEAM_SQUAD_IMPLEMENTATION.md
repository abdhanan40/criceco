# Teams and squads (migration 12)

**Status:** the code is done, tested against fakes, and **validated on a disposable PostgreSQL 17.11** (docs/CLUB_MEMBERSHIP_IMPLEMENTATION.md). **Migrations 11 and 12 were applied to production on 2026-11-17** (SQL Editor; read-only checks `03b` / `03c`); the local stack doesn't have them. The app uses them only with the `CRICECO_MEMBERSHIPS=true` build switch.

## Business rules
| Rule | Decision |
|---|---|
| Owner | A team belongs to one club; only that club's owner reads or changes it |
| Name | 1–40 characters, unique per club among **active** teams (case and repeated spaces ignored), as the app already enforced |
| Format | `test` / `t20` / `odi` / `t10` / `custom`; custom needs 1–50 overs, the others none |
| Squad size | At most **11 Playing XI + 4 substitutes** (15), as `SquadRules` in the app |
| Who can be picked | Only **active members of the same club** who have a player profile (the pool). The trigger and `save_team` both check |
| Several teams | A member may be in several teams of the club (for example T20 and ODI squads), but **once per team** |
| Captain / vice-captain | Optional; must be in that team's squad; must be **different people**. Picking the current vice-captain as captain moves them. A leader taken out of the squad loses the role |
| Member removed from the club | Taken out of every team; captain and vice-captain are cleared (trigger `club_members_leave_teams`) |
| Edit team | Name, format and Custom overs, by the owner, on an active team. The squad, captain and vice-captain are kept. Same name and overs rules as creating |
| Delete team | **Archive** (`status = 'archived'`): gone from My Teams, its name free again, its rows kept |
| Teams with matches (future) | When matches exist they will reference teams with `ON DELETE RESTRICT`, so a team used in a match is never hard-deleted. Archiving stays the only delete |

**Assumption:** archived teams aren't shown anywhere yet. There's no restore; add one as `restore_team()` if needed.

## Database
`supabase/migrations/20261116090100_create_teams.sql`. Rollback: `supabase/rollback/20261116_rollback_teams.sql` (run it before migration 11's).

### Tables
| Table | Contents |
|---|---|
| `teams` | `id`, `club_id → clubs` (cascade), `name`, `format`, `custom_overs`, `captain_member_id` / `vice_captain_member_id → club_members` (set null), `status`, `archived_at`, timestamps |
| `team_players` | `(team_id, member_id)` primary key, `selection` (`playing` / `sub`), `position` (1–15, unique per team: the pick order), `added_at` |

**Teams checks:** overs follow the format; archived exactly when `archived_at` is set; the two leaders are different.

**Indexes:** the unique active-name index `teams_club_name_active_key` on `(club_id, team_name_key(name)) where status = 'active'`, plus indexes on the foreign-key columns.

### Security
- **RLS:** SELECT only, for the club's owner (`is_club_owner`). No INSERT / UPDATE / DELETE grants.
- **`create_team`:** checks the owner, maps a duplicate name to `team: duplicate name`, and invalid values to `team: invalid`.
- **`save_team`:** one transaction, with the team row locked. It checks:
  - the owner, and that the team isn't archived;
  - the JSON squad's shape (uuid ids, `playing` / `sub`), no duplicates, the 11 + 4 limits;
  - every player is an active member of the club;
  - the leaders are in the squad and different.

  Then it updates the details and replaces the squad in pick order.
- **`archive_team`:** owner only; repeating it changes nothing.
- **Errors** start with `team:`. They map to `TeamRuleException(message)` / `PermissionDeniedException` in the app.

## App integration
```
Teams / Team Squad / Add Players / Create Team sheet / Suggest Team
  → TeamsController (create, updateDetails, saveMembers, setLeaders, archive, dropPlayer)
    → TeamRepository  (demo: InMemoryTeamRepository · Supabase+switch: SupabaseTeamRepository
                        · Supabase without switch: UnavailableTeamRepository)
      → SupabaseTeamGateway → teams?select=*,team_players(*) / rpc(create_team|save_team|archive_team)
```
- **Contract:** `TeamRepository` gained `archive()`. `Team.copyWith` gained `clearCaptain` / `clearViceCaptain` / `clearCustomOvers`.
- **Player ids are club member ids:** the pool (`playerPool`) is built from `club_member_list` (members with a player profile), so teams, the pool and Members share one id per person.
- **Team Squad:**
  - a **Captain / Vice-captain** card (a picker of squad players, or "No one");
  - leaders labelled on their rows;
  - **Edit team** (pencil, key `team.edit`) and **Delete team** in the top bar, Edit on the left; Delete asks for confirmation.
- **Edit Team** (`lib/features/club/widgets/edit_team_sheet.dart`): a bottom sheet styled like Create Team.
  - Fields: Team Name (prefilled), format chips (T20 / ODI / Test / Custom), and Number of Overs when Custom is picked.
  - Save is enabled only once something changed; Cancel closes without saving. Success toasts "Team updated", closes, and the top bar shows the new name.
  - Validation is shared with creating (`validateTeamDetails`, `normalizeTeamName`): required, at most 40 characters, Custom needs 1–50 overs. A name used by another active team (case and repeated spaces ignored; the team itself excluded) is refused on the field. When the database refuses a name (taken on another device a moment earlier), its message shows on the field the same way; other errors show as a toast.
  - `TeamsController.updateDetails(teamId, name, {format, customOvers})`:
    - nothing changed → nothing read or saved;
    - otherwise it **re-reads the club's teams first** and applies the change to that latest copy, because `save_team` stores the whole team. A squad or captaincy changed on another device is therefore kept, not overwritten.
    - A team archived meanwhile, or one this account can't read (not the owner), gives "This team is no longer available"; nothing is saved.
  - Switching from Custom to another format clears the overs.
  - No schema or migration change: `save_team` already updates name, format and overs.
- **Saving the squad** clears a leader who left it.
- **Creating a team with a suggested squad** is two calls (`create_team`, then `save_team`). The new team is listed as soon as it exists; if the squad save then fails, the owner sees "The team was created, but its squad wasn't saved: …" (`TeamSquadNotSavedException`), and can add players from Team Squad. A retry never hits "name already exists" for a team the app didn't know.
- **Errors** from creating a team or saving a squad show the database's reason (duplicate name, full squad, not a member).
- **Removing a member** (Member Profile) re-reads teams in Supabase, because the database already removed them. The demo removes them in the controller.
- **Suggest Team and rankings:** unchanged. In Supabase they get `PlayerStats.unrecorded` (no invented rating or form), so the suggestion ranks by role and fitness only, and rankings say "not yet ranked".

## Tests
**`test/team_squad_supabase_test.dart` (12):**
- create with format and overs; duplicate names;
- pick order, and no player twice; 11 + 4 limits with nothing half-saved;
- non-members and other clubs' members refused;
- leaders: in the squad, different, clearable;
- archive keeps the row and frees the name; an archived team can't be saved;
- a removed member leaves teams and loses captaincy;
- non-owners blocked; save parameters; offline; behaviour without the switch.

**`test/production_demo_mode_test.dart`:** controller tests for leaders, the squad change that clears a leader, archive, and `dropPlayer`.

**`test/edit_team_test.dart` (10), `updateDetails` on the Supabase fakes:**
- rename keeps the squad (order and roles), captain and vice-captain; re-read before the save;
- format and Custom overs set, kept, and cleared;
- empty, over 40 characters, and missing or out-of-range overs refused, with nothing saved;
- unchanged values read and save nothing;
- duplicates of another active team refused; the team's own name in a new case allowed; an archived team's name free again;
- a squad and captaincy changed elsewhere are kept;
- a name listed only after the re-read is refused;
- the database's duplicate error (name taken between re-read and save) is surfaced, with nothing changed;
- archived teams and non-owners: nothing changed.

**`test/club_core_test.dart` → "Edit Team" (2 widget tests):**
- the pencil sits left of Delete; the sheet opens prefilled; Save waits for a change; Cancel keeps the team;
- empty and duplicate names, missing and out-of-range overs; save, "Team updated", the new title, squad and leaders kept; back to T20 clears the overs.

## Known limitations
- Player availability isn't stored in the database, so every pool player shows as available (selectable).
- `TeamCategory` stays model-only (approved P4).
- No restore for archived teams; no transfer of a team to another club.
