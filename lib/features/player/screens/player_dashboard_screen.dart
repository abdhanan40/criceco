import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers/core_providers.dart';
import '../../../app/router/routes.dart';
import '../../../app/session/session_controller.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_indicators.dart';
import '../../../shared/widgets/ce_match_widgets.dart';
import '../../../shared/widgets/ce_quick_actions.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import '../../notifications/notifications_controller.dart';
import '../player_providers.dart';
import 'performance_workspace.dart';

/// Player Dashboard (prototype `screens.playerDashboard`, :3961).
class PlayerDashboardScreen extends ConsumerWidget {
  const PlayerDashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(currentAccountProvider);
    final club = ref.watch(playerClubProvider);
    final availability = ref.watch(playerAvailabilityProvider);
    final perf = ref.watch(performanceProvider).value;
    final upcoming = ref.watch(playerMatchesByStatusProvider(PlayerMatchStatus.upcoming));
    final next = ref.watch(nextPlayerMatchProvider);
    final notifCount = ref.watch(unreadNotificationCountProvider(UserRole.player));
    final name = account?.fullName ?? 'Player';
    final available = availability.status == PlayerAvailability.available;
    final top = MediaQuery.paddingOf(context).top;

    String nextLabel() {
      if (next == null) return 'None scheduled';
      final now = ref.read(clockProvider).now();
      final days = CeFormat.dateOnly(next.startsAt).difference(CeFormat.dateOnly(now)).inDays;
      if (days == 0) return 'Next: Today';
      if (days == 1) return 'Next: Tomorrow';
      return 'Next: ${CeFormat.dayMonth(next.startsAt)}';
    }

    return Scaffold(
      body: CeStatusBarScrim(
        child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
          // ---- Hero ----
          AnnotatedRegion<SystemUiOverlayStyle>(
            value: SystemUiOverlayStyle.light,
            child: CeBrandHero(
              padding: EdgeInsets.fromLTRB(8, top + 4, 8, 24),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Builder(
                    builder: (ctx) => IconButton(
                      tooltip: 'Open menu',
                      icon: Icon(CeIcons.of('menu'), color: Colors.white, size: 20),
                      onPressed: () => CeTopBar.openDrawer(ctx),
                    ),
                  ),
                  const Spacer(),
                  _Bell(count: notifCount, onTap: () => context.push(Routes.notifications)),
                ]),
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _HeroAvatar(initial: account?.initial ?? 'A', available: available),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const _HeroPill(icon: 'circle-dot', label: 'Player'),
                        const SizedBox(height: 8),
                        Text('Welcome back,',
                            style: TextStyle(fontSize: 12.5, color: Colors.white.withValues(alpha: 0.85))),
                        const SizedBox(height: 2),
                        Text(name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 21, fontWeight: FontWeight.w800, color: Colors.white, height: 1.15, letterSpacing: -0.5)),
                        const SizedBox(height: 4),
                        Text('Club ${club.code} • ${club.city}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.85))),
                        const SizedBox(height: 9),
                        Semantics(
                          button: true,
                          label: available ? 'Available. Tap to mark unavailable' : 'Unavailable. Tap to mark available',
                          excludeSemantics: true,
                          child: GestureDetector(
                            onTap: () {
                              ref.read(playerAvailabilityProvider.notifier).toggleQuick();
                              // Feedback for a one-tap status change.
                              showCeToast(context,
                                  available ? "You're marked unavailable" : "You're marked available");
                            },
                            child: _HeroPill(
                              dotColor: available ? CeColors.fresh : CeColors.red,
                              label: available ? 'Available' : 'Unavailable',
                            ),
                          ),
                        ),
                      ]),
                    ),
                    const SizedBox(width: 10),
                    _ClubCard(code: club.code, established: club.established),
                  ]),
                ),
              ]),
            ),
          ),

          // ---- Stats ----
          Transform.translate(
            offset: const Offset(0, -6),
            child: CeStatsRow(children: [
              CeStatCard(
                icon: 'calendar',
                label: 'Upcoming Matches',
                value: '${upcoming.length}',
                sub: nextLabel(),
                onTap: () => context.go(Routes.myMatches),
              ),
              CeStatCard(
                icon: 'star',
                label: 'Performance Rating',
                value: perf?.rating ?? '–',
                sub: perf == null ? null : ratingLabel(perf.rating),
                onTap: () => context.go(Routes.myPerformance),
              ),
              CeStatCard(
                icon: 'trophy',
                label: 'Matches Played',
                // "–" while loading, never a misleading 0.
                value: perf == null ? '–' : '${perf.matches}',
                sub: 'This Season',
                onTap: () => context.go(PerformanceView.history.location),
              ),
            ]),
          ),

          // ---- Quick actions ----
          CeSectionHeader('Quick Actions',
              actionLabel: 'View All',
              onAction: () => CeTopBar.openDrawer(context),
              padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 8)),
          CeQuickActionGrid(actions: [
            CeQuickAction(icon: 'calendar', label: 'My Matches', onTap: () => context.go(Routes.myMatches)),
            CeQuickAction(icon: 'check-circle', label: 'Availability', onTap: () => context.go(Routes.availability)),
            CeQuickAction(icon: 'trending-up', label: 'My Performance', onTap: () => context.go(Routes.myPerformance)),
            CeQuickAction(icon: 'circle-dot', label: 'Open Matches', onTap: () => context.go(Routes.openMatches)),
          ]),

          // ---- Next match ----
          const CeSectionHeader('Next Match', padding: EdgeInsets.fromLTRB(CeSpace.gutter, 18, CeSpace.gutter, 8)),
          if (next == null)
            CeCard(
              margin: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
              child: Row(children: [
                const CeIconWell('calendar', size: 44),
                const SizedBox(width: 12),
                Expanded(
                  child: Text('No upcoming matches yet. Confirmed matches will show up here.',
                      style: Theme.of(context).textTheme.bodySmall),
                ),
              ]),
            )
          else
            _NextMatchCard(match: next),

          // ---- Performance snapshot (only once there is data: no empty header) ----
          if (perf != null) ...[
            CeSectionHeader('Your Performance Snapshot',
                actionLabel: 'See All',
                onAction: () => context.go(Routes.myPerformance),
                padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 18, CeSpace.gutter, 8)),
            _SnapshotRow(tiles: perf.snapshot),
          ],
        ]),
      ),
    );
  }
}

class _Bell extends StatelessWidget {
  const _Bell({required this.count, required this.onTap});
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: count == 0 ? 'Notifications' : 'Notifications, $count',
        onPressed: onTap,
        icon: Stack(clipBehavior: Clip.none, children: [
          Icon(CeIcons.of('bell'), color: Colors.white, size: 20),
          if (count > 0)
            Positioned(
              top: -6,
              right: -7,
              child: Container(
                width: 16,
                height: 16,
                alignment: Alignment.center,
                decoration: const BoxDecoration(color: CeColors.red, shape: BoxShape.circle),
                child: Text(count > 9 ? '9+' : '$count',
                    style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: Colors.white)),
              ),
            ),
        ]),
      );
}

class _HeroAvatar extends StatelessWidget {
  const _HeroAvatar({required this.initial, required this.available});
  final String initial;
  final bool available;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 70,
        height: 70,
        child: Stack(children: [
          Container(
            width: 70,
            height: 70,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.2),
              border: Border.all(color: Colors.white.withValues(alpha: 0.35), width: 3),
            ),
            child: Text(initial, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: Colors.white)),
          ),
          Positioned(
            right: 2,
            bottom: 2,
            child: Container(
              width: 15,
              height: 15,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: available ? CeColors.fresh : CeColors.red,
                border: Border.all(color: CeColors.primaryDark, width: 2),
              ),
            ),
          ),
        ]),
      );
}

class _HeroPill extends StatelessWidget {
  const _HeroPill({required this.label, this.icon, this.dotColor});
  final String label;
  final String? icon;
  final Color? dotColor;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(CeRadius.pill),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) Icon(CeIcons.of(icon!), size: 12, color: Colors.white),
          if (dotColor != null)
            Container(width: 7, height: 7, decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          Flexible(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: Colors.white)),
          ),
        ]),
      );
}

class _ClubCard extends StatelessWidget {
  const _ClubCard({required this.code, required this.established});
  final String code;
  final int established;

  @override
  Widget build(BuildContext context) => Container(
        width: 84,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(CeRadius.row),
          border: Border.all(color: Colors.white.withValues(alpha: 0.24)),
        ),
        child: Column(children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(CeRadius.sm)),
            child: Icon(CeIcons.of('shield'), size: 17, color: Colors.white),
          ),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(code,
                style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, letterSpacing: 0.4, color: Colors.white)),
          ),
          const SizedBox(height: 2),
          Text('EST. $established', style: TextStyle(fontSize: 9, color: Colors.white.withValues(alpha: 0.72))),
        ]),
      );
}

/// `.pd-next-match`: gradient body + mint footer with live countdown.
class _NextMatchCard extends ConsumerWidget {
  const _NextMatchCard({required this.match});
  final PlayerMatch match;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(nowProvider).value ?? ref.read(clockProvider).now();
    final remaining = match.startsAt.difference(now);
    final white85 = Colors.white.withValues(alpha: 0.95);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [BoxShadow(color: Color(0x26092328), blurRadius: 14, offset: Offset(0, 4))],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          decoration: const BoxDecoration(gradient: CeColors.brandGradient),
          padding: const EdgeInsets.all(16),
          child: DefaultTextStyle.merge(
            style: const TextStyle(color: Colors.white),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Align(
                alignment: Alignment.centerRight,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.22), borderRadius: BorderRadius.circular(CeRadius.pill)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(CeIcons.of('check'), size: 11, color: Colors.white),
                    const SizedBox(width: 4),
                    const Text('CONFIRMED', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800)),
                  ]),
                ),
              ),
              const SizedBox(height: 12),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                CeTeamBadge(match.ownTeamAbbr, size: 46, color: CeColors.primaryDark),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text('VS', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 1)),
                ),
                CeTeamBadge(match.opponentAbbr, size: 46, color: CeColors.red),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: Text(match.ownTeamName,
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700)),
                ),
                Expanded(
                  child: Text(match.opponentName,
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700)),
                ),
              ]),
              const SizedBox(height: 14),
              InkWell(
                onTap: () => openDirections(context, match.ground),
                child: Row(children: [
                  Icon(CeIcons.of('map-pin'), size: 13, color: white85),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(match.ground,
                        overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: white85)),
                  ),
                  const Text('Directions',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, decoration: TextDecoration.underline, decorationColor: Colors.white)),
                  Icon(CeIcons.of('arrow-up-right'), size: 11, color: Colors.white),
                ]),
              ),
              const SizedBox(height: 7),
              Wrap(spacing: 10, runSpacing: 4, children: [
                _WhiteInfo(icon: 'calendar', text: CeFormat.dayDate(match.startsAt)),
                _WhiteInfo(icon: 'clock', text: CeFormat.time(match.startsAt)),
              ]),
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 6, children: [
                _Tag('${match.format.display()} Match'),
                if (match.matchType != null) _Tag(match.matchType!),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                Icon(CeIcons.of('users'), size: 12, color: white85),
                const SizedBox(width: 5),
                Text('Playing: ', style: TextStyle(fontSize: 11.5, color: white85)),
                Flexible(
                  child: Text(match.playingTeamName,
                      overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700)),
                ),
              ]),
            ]),
          ),
        ),
        Container(
          color: CeColors.mint,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Match starts in', style: TextStyle(fontSize: 10.5, color: CeColors.primaryDark)),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(remaining.isNegative ? 'Started' : CeFormat.hms(remaining),
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: CeColors.primaryDark,
                          fontFeatures: [FontFeature.tabularFigures()])),
                ),
              ]),
            ),
            const SizedBox(width: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 170),
              child: Semantics(
                button: true,
                label: 'View Match Details',
                excludeSemantics: true,
                child: Material(
                  color: CeColors.primaryDark,
                  borderRadius: BorderRadius.circular(CeRadius.sm),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(CeRadius.sm),
                    // Player context: the Player Match Details route (never Club Owner Match Management).
                    onTap: () => context.go(Routes.playerMatchDetails(match.id)),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Flexible(
                          child: Text('View Match Details',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white)),
                        ),
                        const SizedBox(width: 4),
                        Icon(CeIcons.of('chevron-right'), size: 13, color: Colors.white),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _WhiteInfo extends StatelessWidget {
  const _WhiteInfo({required this.icon, required this.text});
  final String icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(CeIcons.of(icon), size: 12, color: Colors.white),
        const SizedBox(width: 5),
        Text(text, style: const TextStyle(fontSize: 11.5, color: Colors.white)),
      ]);
}

class _Tag extends StatelessWidget {
  const _Tag(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(CeRadius.sm)),
        child: Text(text, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Colors.white)),
      );
}

/// `.perf-snap-row`: five equal cells with dividers (label · value · icon).
class _SnapshotRow extends StatelessWidget {
  const _SnapshotRow({required this.tiles});
  final List<StatTile> tiles;

  static const _icons = {
    'Runs': 'circle-dot',
    'Average': 'bar-chart',
    'Strike Rate': 'zap',
    'Wickets': 'target',
    'Best Score': 'star',
  };

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(CeRadius.lg),
          border: Border.all(color: CeColors.line),
          boxShadow: CeShadows.card,
        ),
        child: IntrinsicHeight(
          child: Row(children: [
            for (var i = 0; i < tiles.length; i++) ...[
              if (i > 0) const VerticalDivider(width: 1, color: CeColors.line),
              Expanded(
                child: Column(children: [
                  SizedBox(
                    height: 26,
                    child: Center(
                      child: Text(tiles[i].label,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          style: const TextStyle(fontSize: 9.5, color: CeColors.muted, height: 1.2)),
                    ),
                  ),
                  const SizedBox(height: 4),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(tiles[i].value,
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: CeColors.ink)),
                  ),
                  const SizedBox(height: 4),
                  CeIconWell(_icons[tiles[i].label] ?? 'circle-dot', size: 26, iconSize: 14),
                ]),
              ),
            ],
          ]),
        ),
      );
}
