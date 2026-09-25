import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers/core_providers.dart';
import '../../../app/router/routes.dart';
import '../../../app/session/session_controller.dart';
import '../../../app/theme/tokens.dart';
import '../../../shared/widgets/ce_availability.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_indicators.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import '../player_providers.dart';

/// Player Profile (prototype `screens.playerProfile`, :8052).
class PlayerProfileScreen extends ConsumerWidget {
  const PlayerProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(currentAccountProvider);
    final name = account?.fullName ?? 'Player';
    // Keyed by the account, not the name: editing the name must not re-roll
    // the (demo-generated) career stats.
    final s = ref.watch(playerStatsProvider(account?.id ?? name));
    final club = ref.watch(playerClubProvider);
    final availability = ref.watch(playerAvailabilityProvider.select((a) => a.status));
    final position = account?.playerProfile.role?.label ?? s.position;

    return Scaffold(
      appBar: CeTopBar(
        title: 'My Profile',
        onBack: () => context.go(Routes.playerHome),
        actions: [
          TextButton(
            onPressed: () => context.push(Routes.editProfile),
            child: const Text('Edit'),
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
        CeBrandHero(
          margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 14, CeSpace.gutter, 0),
          radius: 18,
          padding: const EdgeInsets.all(20),
          child: Row(children: [
            Container(
              width: 62,
              height: 62,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.18),
                border: Border.all(color: Colors.white.withValues(alpha: 0.35), width: 2),
              ),
              child: Text(account?.initial ?? 'A',
                  style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w800, color: Colors.white)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
                const SizedBox(height: 2),
                Text('$position · ${s.skill.label} level',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Colors.white.withValues(alpha: 0.8))),
                if (s.verified) ...[
                  const SizedBox(height: 7),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(CeRadius.pill)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(CeIcons.of('check-circle'), size: 12, color: Colors.white),
                      const SizedBox(width: 5),
                      const Flexible(
                        child: Text('Verified player',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: Colors.white)),
                      ),
                    ]),
                  ),
                ],
              ]),
            ),
          ]),
        ),
        const CeSectionHeader('Career'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
          child: Row(children: [
            for (final (i, (v, l)) in [
              ('${s.matches}', 'Matches'),
              ('${s.batting.runs}', 'Runs'),
              (s.batting.average, 'Average'),
              (s.rating, 'Rating'),
            ].indexed) ...[
              if (i > 0) const SizedBox(width: 8),
              Expanded(child: _CareerCell(value: v, label: l)),
            ],
          ]),
        ),
        const CeSectionHeader('Details'),
        CeCard(
          margin: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: Column(children: [
            if (account?.phone != null)
              _DetailRow(icon: 'phone', label: 'Phone', value: Text(account!.phone!, style: _DetailRow.valueStyle))
            else if (account?.email != null)
              _DetailRow(icon: 'mail', label: 'Email', value: Text(account!.email!, style: _DetailRow.valueStyle)),
            _DetailRow(icon: 'map-pin', label: 'City', value: Text(account?.city ?? club.city, style: _DetailRow.valueStyle)),
            _DetailRow(icon: 'shield', label: 'Club', value: Text(club.code, style: _DetailRow.valueStyle)),
            _DetailRow(
              icon: 'check-circle',
              label: 'Availability',
              value: CeStatusChip(availability.label, tone: availabilityTone(availability)),
              last: true,
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 18, CeSpace.gutter, 0),
          child: Column(children: [
            CeButton(label: 'View Full Performance', onPressed: () => context.go(Routes.myPerformance)),
            const SizedBox(height: 10),
            CeButton.soft(label: 'Update Availability', onPressed: () => context.go(Routes.availability)),
          ]),
        ),
      ]),
    );
  }
}

class _CareerCell extends StatelessWidget {
  const _CareerCell({required this.value, required this.label});
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(CeRadius.row),
          border: Border.all(color: CeColors.line),
          boxShadow: CeShadows.card,
        ),
        child: Column(children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(value,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w800, color: CeColors.ink, fontFeatures: [FontFeature.tabularFigures()])),
          ),
          const SizedBox(height: 3),
          Text(label, maxLines: 1, style: const TextStyle(fontSize: 10, color: CeColors.muted)),
        ]),
      );
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.icon, required this.label, required this.value, this.last = false});
  final String icon;
  final String label;
  final Widget value;
  final bool last;

  static const valueStyle = TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: CeColors.ink);

  @override
  Widget build(BuildContext context) => Container(
        constraints: const BoxConstraints(minHeight: 46),
        decoration: BoxDecoration(
          border: last ? null : const Border(bottom: BorderSide(color: Color(0xFFF1F5F2))),
        ),
        child: Row(children: [
          CeIconWell(icon, size: 30, iconSize: 15),
          const SizedBox(width: 10),
          Text(label, style: const TextStyle(fontSize: 12.5, color: CeColors.muted)),
          const SizedBox(width: 12),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              // Text values ellipsize; chips scale down rather than overflow.
              child: value is Text
                  ? DefaultTextStyle.merge(overflow: TextOverflow.ellipsis, maxLines: 1, child: value)
                  : FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: value),
            ),
          ),
        ]),
      );
}
