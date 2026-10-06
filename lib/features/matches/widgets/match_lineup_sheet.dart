import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../app/theme/tokens.dart';
import '../../../app/theme/typography.dart';
import '../../../core/models/models.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_indicators.dart';
import '../../../shared/widgets/ce_inputs.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../../club/teams/teams_controller.dart';
import '../club_matches_controller.dart';
import '../lineup_controller.dart';
import 'lineup_widgets.dart';

/// Scheduled match → "View / Edit Line-up": a bottom sheet first.
///  * No team yet → "Select Team" (club teams with squad size and Playing XI
///    status); the chosen team becomes the match's line-up.
///  * A team is set → "Current Team" with Edit Line-up (the existing builder)
///    and Replace Team (another team, after a confirmation).
/// Teams themselves are never changed — the match keeps a line-up snapshot
/// (same `useTeam` logic as the full Select Team screen, still reachable via
/// "More line-up options").
Future<void> showMatchLineupSheet(BuildContext context, String matchId) =>
    showCeSheet<void>(context, builder: (_) => _MatchLineupSheet(matchId: matchId, router: GoRouter.of(context)));

enum _Mode { overview, replace }

class _MatchLineupSheet extends ConsumerStatefulWidget {
  const _MatchLineupSheet({required this.matchId, required this.router});
  final String matchId;
  final GoRouter router;

  @override
  ConsumerState<_MatchLineupSheet> createState() => _MatchLineupSheetState();
}

class _MatchLineupSheetState extends ConsumerState<_MatchLineupSheet> {
  _Mode _mode = _Mode.overview;
  String? _selected;
  String? _error;
  String? _note; // "BS CS XI selected for this match." after a change
  bool _saving = false;

  MatchLineupTarget get _target => MatchLineupTarget(widget.matchId);

  /// Leaves the sheet, then opens [location] in the Matches branch.
  void _goTo(String location) {
    Navigator.of(context).pop();
    widget.router.go(location);
  }

  void _pick(String teamId) => setState(() {
        _selected = teamId;
        _error = null;
      });

  /// Uses [team] as the match's line-up (asks first when replacing).
  Future<void> _apply(List<Team> teams, {required bool replacing}) async {
    final team = teams.where((t) => t.id == _selected).firstOrNull;
    if (team == null) {
      setState(() => _error = 'Please select a team');
      return;
    }
    // Never put an empty squad on a match.
    if (team.playerCount == 0) {
      setState(() => _error = '${team.name} has no players yet — add players in My Teams first');
      return;
    }
    if (replacing) {
      final ok = await showCeConfirmSheet(
        context,
        title: 'Replace current team?',
        body: 'This will replace the currently selected team for this match.',
        confirmLabel: 'Replace Team',
        icon: 'repeat',
      );
      if (!ok || !mounted) return;
    }
    setState(() => _saving = true);
    final leftOut = await ref.read(lineupDraftProvider(_target).notifier).useTeam(team);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _mode = _Mode.overview;
      _selected = null;
      _note = [
        replacing ? '${team.name} now plays this match.' : '${team.name} selected for this match.',
        if (leftOut > 0)
          '$leftOut injured or unavailable player${leftOut == 1 ? ' was' : 's were'} left out.',
      ].join(' ');
    });
  }

  @override
  Widget build(BuildContext context) {
    final match = ref.watch(clubMatchProvider(widget.matchId));
    final editable = ref.watch(lineupEditableProvider(widget.matchId));
    final teamsAsync = ref.watch(teamsProvider);
    final teams = teamsAsync.value ?? const <Team>[];
    final lineup = match?.lineup;

    if (match == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Text('This match is no longer available.', textAlign: TextAlign.center),
      );
    }

    // ---- Case A: no team selected yet / Replace: pick from the club's teams ----
    if (lineup == null || _mode == _Mode.replace) {
      final replacing = lineup != null;
      final choices = [for (final t in teams) if (!replacing || t.id != lineup.sourceTeamId) t];
      return Column(
        key: Key(replacing ? 'lineupSheet.replace' : 'lineupSheet.select'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _Header(
            icon: replacing ? 'repeat' : 'users',
            title: replacing ? 'Replace Team' : 'Select Team',
            subtitle: replacing
                ? 'Choose the team that replaces ${lineup.name} for this match.'
                : 'Choose which club team plays this match.',
          ),
          if (!editable)
            const CeInfoNote(
              margin: EdgeInsets.only(top: 12),
              icon: 'lock',
              text: 'This match has started, so its line-up is locked.',
            )
          else if (teamsAsync.isLoading)
            const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
          else if (choices.isEmpty)
            CeInfoNote(
              margin: const EdgeInsets.only(top: 12),
              icon: 'shield',
              text: replacing ? 'There are no other club teams to switch to.' : 'Your club has no teams yet.',
            )
          else ...[
            for (final t in choices)
              TeamRadioRow(
                key: Key('lineupSheet.team.${t.id}'),
                team: t,
                selected: _selected == t.id,
                margin: const EdgeInsets.only(top: 10),
                trailing: _XiStatus(team: t),
                onTap: () => _pick(t.id),
              ),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 6), child: CeInlineError(_error)),
            const SizedBox(height: 16),
            CeButton(
              label: replacing ? 'Replace Team' : 'Select Team',
              loading: _saving,
              onPressed: _saving ? null : () => _apply(teams, replacing: replacing),
            ),
          ],
          const SizedBox(height: 10),
          if (replacing)
            CeButton.soft(
              label: 'Cancel',
              onPressed: () => setState(() {
                _mode = _Mode.overview;
                _selected = null;
                _error = null;
              }),
            )
          else if (editable)
            // The full flow (incl. building a new match-day squad) stays available.
            CeButton.soft(label: 'More line-up options', onPressed: () => _goTo(Routes.matchLineup(match.id))),
        ],
      );
    }

    // ---- Case B: a team is selected → Edit Line-up / Replace Team ----
    final playing = lineup.members.where((m) => m.selection == SelectionRole.playing).length;
    final subs = lineup.members.where((m) => m.selection == SelectionRole.sub).length;
    return Column(
      key: const Key('lineupSheet.current'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const _Header(icon: 'users', title: 'Current Team', subtitle: 'The team playing this match.'),
        const SizedBox(height: 12),
        Container(
          key: const Key('lineupSheet.currentTeam'),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: CeColors.mint,
            borderRadius: BorderRadius.circular(CeRadius.lg),
            border: Border.all(color: CeColors.primary.withValues(alpha: 0.35)),
          ),
          child: Row(children: [
            const CeIconWell('shield', size: 40, iconSize: 19),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(lineup.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontFamily: CeType.display, fontSize: 15, fontWeight: FontWeight.w700, color: CeColors.ink)),
                const SizedBox(height: 2),
                Text('$playing Playing XI · $subs Sub${subs == 1 ? '' : 's'}',
                    style: const TextStyle(fontSize: 12, color: CeColors.muted)),
              ]),
            ),
          ]),
        ),
        if (_note != null)
          CeInfoNote(key: const Key('lineupSheet.note'), margin: const EdgeInsets.only(top: 10), icon: 'check', text: _note!),
        if (!editable) ...[
          const CeInfoNote(
            margin: EdgeInsets.only(top: 10),
            icon: 'lock',
            text: 'This match has started, so its line-up is locked.',
          ),
          const SizedBox(height: 16),
          CeButton.soft(label: 'View Line-up', onPressed: () => _goTo(Routes.matchLineup(match.id))),
        ] else ...[
          const SizedBox(height: 16),
          CeButton(
            label: 'Edit Line-up',
            icon: CeIcons.of('edit-3'),
            onPressed: () {
              ref.read(lineupDraftProvider(_target).notifier).startEdit();
              _goTo(Routes.matchLineupBuild(match.id));
            },
          ),
          const SizedBox(height: 10),
          CeButton.soft(
            label: 'Replace Team',
            icon: CeIcons.of('repeat'),
            onPressed: () => setState(() {
              _mode = _Mode.replace;
              _selected = null;
              _error = null;
              _note = null;
            }),
          ),
        ],
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.icon, required this.title, required this.subtitle});
  final String icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Row(children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.sm)),
          child: Icon(CeIcons.of(icon), size: 18, color: CeColors.primaryDark),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            Text(subtitle, style: const TextStyle(fontSize: 12, color: CeColors.muted)),
          ]),
        ),
      ]);
}

/// Playing XI status of a team: complete (11) or how many are picked.
class _XiStatus extends StatelessWidget {
  const _XiStatus({required this.team});
  final Team team;

  @override
  Widget build(BuildContext context) {
    final n = team.playingCount;
    return n >= SquadRules.maxPlaying
        ? const CeStatusChip('XI Ready', icon: 'check')
        : CeStatusChip('XI $n/${SquadRules.maxPlaying}', tone: n == 0 ? CeTone.neutral : CeTone.amber);
  }
}
