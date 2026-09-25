import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../app/theme/tokens.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_indicators.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import '../../club/club_providers.dart';
import '../challenges_controller.dart';
import '../widgets/challenge_widgets.dart';

String _initials(String name) =>
    name.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).map((w) => w[0].toUpperCase()).take(2).join();

/// Opponent Club Profile (prototype `screens.clubProfile`, :6073), keyed by
/// club id (the prototype used a global abbreviation).
class ClubProfileScreen extends ConsumerStatefulWidget {
  const ClubProfileScreen({super.key, required this.clubId});
  final String clubId;

  @override
  ConsumerState<ClubProfileScreen> createState() => _ClubProfileScreenState();
}

class _ClubProfileScreenState extends ConsumerState<ClubProfileScreen> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final dirAsync = ref.watch(clubDirectoryProvider);
    final c = dirAsync.value?[widget.clubId];
    const bar = CeTopBar(title: 'Club Profile', fallbackLocation: Routes.challenges);
    if (dirAsync.isLoading) return const Scaffold(appBar: bar, body: Center(child: CircularProgressIndicator()));
    if (c == null) {
      return Scaffold(
        appBar: bar,
        body: CeEmptyState(
          icon: 'shield',
          title: 'Club not found',
          body: 'This club is no longer available.',
          primaryLabel: 'Back to Challenges',
          onPrimary: () => context.go(Routes.challenges),
        ),
      );
    }
    final waiting = ref.watch(pendingSentClubIdsProvider).contains(c.id);

    Widget stat(String n, String l, Color color) => Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
            decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.row)),
            child: Column(children: [
              Text(n, style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: color)),
              const SizedBox(height: 2),
              Text(l, style: const TextStyle(fontSize: 10.5, color: CeColors.muted)),
            ]),
          ),
        );

    return Scaffold(
      appBar: bar,
      body: ListView(padding: const EdgeInsets.only(bottom: 28), children: [
        // ---- Identity, form, win rate ----
        CeCard(
          margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 14, CeSpace.gutter, 0),
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 54,
                height: 54,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.color.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(CeRadius.lg),
                  border: Border.all(color: c.color.withValues(alpha: 0.4), width: 1.5),
                ),
                child: Text(c.abbr, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: c.color)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(c.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: CeColors.ink)),
                  const SizedBox(height: 2),
                  Text(c.meta, style: const TextStyle(fontSize: 12, color: CeColors.muted)),
                  Text('Est. ${c.established} · Squad of ${c.squadSize}',
                      style: const TextStyle(fontSize: 11.5, color: CeColors.muted)),
                ]),
              ),
            ]),
            const SizedBox(height: 14),
            const Text('Recent Form', style: TextStyle(fontSize: 12, color: CeColors.muted)),
            const SizedBox(height: 8),
            Align(alignment: Alignment.centerLeft, child: CeFormDots(c.recentForm, size: 24)),
            const SizedBox(height: 16),
            Row(children: [
              const Expanded(child: Text('Win Rate', style: TextStyle(fontSize: 12, color: CeColors.muted))),
              Text('${c.winRate}%', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: CeColors.ink)),
            ]),
            const SizedBox(height: 6),
            Semantics(
              label: 'Win rate ${c.winRate} percent',
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: c.winRate / 100,
                  minHeight: 7,
                  backgroundColor: CeColors.mint2,
                  color: CeColors.primaryDark,
                ),
              ),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 14, CeSpace.gutter, 0),
          child: Row(children: [
            stat('${c.wins}', 'Wins', CeColors.primaryDark),
            const SizedBox(width: 10),
            stat('${c.losses}', 'Losses', CeColors.red),
            const SizedBox(width: 10),
            stat('${c.played}', 'Played', CeColors.ink),
          ]),
        ),

        // ---- About / preferences ----
        const CeSectionHeader('About'),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.row)),
          child: Text(c.about, style: const TextStyle(fontSize: 12.5, color: CeColors.ink2, height: 1.45)),
        ),
        const CeSectionHeader('Match Preferences'),
        CeSummaryCard(rows: [
          ('Formats', CeSummaryCard.value(context, c.formats)),
          ('Home Ground', CeSummaryCard.value(context, c.homeGround)),
          ('City', CeSummaryCard.value(context, c.city)),
          ('Level', CeSummaryCard.value(context, c.level)),
        ]),

        // ---- Captain ----
        const CeSectionHeader('Club Captain'),
        CeCard(
          margin: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
          child: Row(children: [
            CircleAvatar(
              radius: 21,
              backgroundColor: c.color,
              child: Text(_initials(c.captain.name),
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: Colors.white)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(c.captain.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                Text('Captain · ${c.name}', style: const TextStyle(fontSize: 11.5, color: CeColors.muted)),
                Text(c.captain.phone, style: const TextStyle(fontSize: 11.5, color: CeColors.muted)),
              ]),
            ),
            Icon(CeIcons.of('shield'), size: 18, color: CeColors.primaryDark),
          ]),
        ),

        // ---- Key players ----
        CeSectionHeader('Key Players · Squad of ${c.squadSize}'),
        for (final p in c.keyPlayers)
          Container(
            margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 0, CeSpace.gutter, 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(CeRadius.row),
              border: Border.all(color: CeColors.line),
            ),
            child: Row(children: [
              CircleAvatar(
                radius: 17,
                backgroundColor: CeColors.line,
                child: Text(_initials(p.name),
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: CeColors.ink2)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(p.name, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                  Text(p.position, style: const TextStyle(fontSize: 11.5, color: CeColors.muted)),
                ]),
              ),
              if (p.isCaptain) const CeStatusChip('Captain', tone: CeTone.amber),
            ]),
          ),

        Padding(
          padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
          child: waiting
              ? CeButton.soft(label: 'Challenge Sent', icon: CeIcons.of('hourglass'))
              : CeButton(
                  label: 'Challenge This Club',
                  icon: CeIcons.of('swords'),
                  loading: _busy,
                  onPressed: _busy
                      ? null
                      : () async {
                          await sendChallenge(context, ref, c, onSending: () => setState(() => _busy = true));
                          if (mounted) setState(() => _busy = false);
                        },
                ),
        ),
      ]),
    );
  }
}
