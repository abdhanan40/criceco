import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/models/models.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import '../../club/club_providers.dart';
import '../../club/teams/teams_controller.dart';
import '../../matches/club_matches_controller.dart';
import '../tournaments_controller.dart';

/// Tournament Hub — "Tournament Center" (prototype `screens.hostTournament`,
/// :4497). The drawer's Tournaments item and the dashboard's Tournament
/// quick action open it; Back → the club dashboard. The prototype's bottom
/// nav is dropped: club modules are drawer destinations (architecture §4).
class TournamentHubScreen extends ConsumerWidget {
  const TournamentHubScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(tournamentHubStatsProvider);
    final confirmed =
        (ref.watch(clubMatchesProvider).value ?? const <ClubMatch>[]).where((m) => m.status == MatchStatus.confirmed).length;
    final teamCount = ref.watch(teamsProvider).value?.length ?? 0;
    final venues = ref.watch(groundDirectoryProvider).value?.length ?? 0;

    return Scaffold(
      appBar: const CeTopBar(title: 'Tournament', fallbackLocation: Routes.clubHome),
      body: ListView(padding: const EdgeInsets.only(bottom: 28), children: [
        // ---- Hero ----
        CeBrandHero(
          margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 14, CeSpace.gutter, 0),
          radius: CeRadius.lg,
          padding: const EdgeInsets.fromLTRB(18, 20, 18, 20),
          child: Column(children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.16), shape: BoxShape.circle),
              child: Icon(CeIcons.of('trophy'), size: 24, color: Colors.white),
            ),
            const SizedBox(height: 10),
            const Text.rich(
              TextSpan(children: [
                TextSpan(text: 'Tournament '),
                TextSpan(text: 'Center', style: TextStyle(color: CeColors.sage)),
              ]),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            Text('Organize, discover and manage tournaments with ease.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: Colors.white.withValues(alpha: 0.85))),
          ]),
        ),

        // ---- Stats ----
        CeCard(
          margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
          child: Row(children: [
            _Stat(icon: 'trophy', color: CeColors.primary, value: stats.hosted, label: 'Hosted'),
            _Stat(icon: 'users', color: CeColors.blue, value: stats.open, label: 'Open'),
            _Stat(icon: 'clipboard-list', color: CeColors.violet, value: stats.registered, label: 'Registered'),
            _Stat(icon: 'shield', color: CeColors.amber, value: stats.approved, label: 'Approved'),
          ]),
        ),

        const CeSectionHeader('What would you like to do?'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
          child: Column(children: [
            IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Expanded(
                  child: _HubCard(
                    icon: 'trophy',
                    color: CeColors.primary,
                    title: 'Create Tournament',
                    body: 'Create a new tournament and invite clubs to participate.',
                    onTap: () => context.go(Routes.createTournament),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _HubCard(
                    icon: 'search',
                    color: CeColors.blue,
                    title: 'Browse Tournaments',
                    body: 'Find tournaments open for registration and enter a team.',
                    badge: stats.open,
                    onTap: () => context.go(Routes.browseTournaments),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 10),
            IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Expanded(
                  child: _HubCard(
                    icon: 'shield',
                    color: CeColors.violet,
                    title: 'My Tournaments',
                    body: 'View and manage tournaments created by your club.',
                    onTap: () => context.go(Routes.myTournaments),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _HubCard(
                    icon: 'clipboard-list',
                    color: CeColors.amber,
                    title: 'My Registrations',
                    body: "Track teams you've registered into other tournaments.",
                    badge: stats.pendingRegistrations,
                    onTap: () => context.go(Routes.myRegistrations),
                  ),
                ),
              ]),
            ),
          ]),
        ),

        // ---- Quick Overview ----
        CeSectionHeader(
          'Quick Overview',
          actionLabel: 'See all',
          onAction: () => context.go(Routes.matchManagement(MatchTab.scheduled)),
        ),
        CeCard(
          margin: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Column(children: [
            _OverviewRow(
              icon: 'calendar',
              label: 'Upcoming Matches',
              value: confirmed,
              onTap: () => context.go(Routes.matchManagement(MatchTab.scheduled)),
            ),
            _OverviewRow(icon: 'users', label: 'Total Teams', value: teamCount, onTap: () => context.go(Routes.teams)),
            // P8: a read-only ground browse isn't part of this phase, so the
            // Venues count is informational (no dead arrow).
            _OverviewRow(icon: 'map-pin', label: 'Venues', value: venues, last: true),
          ]),
        ),
      ]),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.icon, required this.color, required this.value, required this.label});
  final String icon;
  final Color color;
  final int value;
  final String label;

  @override
  Widget build(BuildContext context) => Expanded(
        child: Semantics(
          label: '$value $label',
          excludeSemantics: true,
          child: Column(children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(CeRadius.sm)),
              child: Icon(CeIcons.of(icon), size: 16, color: color),
            ),
            const SizedBox(height: 6),
            Text('$value', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: CeColors.ink)),
            Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: CeColors.muted)),
          ]),
        ),
      );
}

class _HubCard extends StatelessWidget {
  const _HubCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
    required this.onTap,
    this.badge = 0,
  });
  final String icon;
  final Color color;
  final String title;
  final String body;
  final VoidCallback onTap;
  final int badge;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: badge > 0 ? '$title, $badge' : title,
        excludeSemantics: true,
        child: CeCard(
          onTap: onTap,
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(CeRadius.md)),
                child: Icon(CeIcons.of(icon), size: 19, color: color),
              ),
              const Spacer(),
              if (badge > 0)
                Container(
                  constraints: const BoxConstraints(minWidth: 22),
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(color: CeColors.red, borderRadius: BorderRadius.circular(CeRadius.pill)),
                  child: Text('$badge',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Colors.white)),
                ),
            ]),
            const SizedBox(height: 10),
            Text(title, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: CeColors.ink, height: 1.25)),
            const SizedBox(height: 4),
            Text(body, style: const TextStyle(fontSize: 11.5, color: CeColors.muted, height: 1.35)),
            const Spacer(),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(color: color.withValues(alpha: 0.12), shape: BoxShape.circle),
                child: Icon(CeIcons.of('chevron-right'), size: 15, color: color),
              ),
            ),
          ]),
        ),
      );
}

class _OverviewRow extends StatelessWidget {
  const _OverviewRow({required this.icon, required this.label, required this.value, this.onTap, this.last = false});
  final String icon;
  final String label;
  final int value;
  final VoidCallback? onTap;
  final bool last;

  @override
  Widget build(BuildContext context) => Semantics(
        button: onTap != null,
        label: '$label, $value',
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 50),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: last ? null : const BoxDecoration(border: Border(bottom: BorderSide(color: CeColors.line))),
            child: Row(children: [
              CeIconWell(icon, size: 32, iconSize: 15),
              const SizedBox(width: 11),
              Expanded(
                child: Text(label, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: CeColors.ink)),
              ),
              Text('$value', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: CeColors.ink)),
              SizedBox(
                width: 26,
                child: onTap == null
                    ? null
                    : Align(
                        alignment: Alignment.centerRight,
                        child: Icon(CeIcons.of('arrow-right'), size: 15, color: CeColors.muted),
                      ),
              ),
            ]),
          ),
        ),
      );
}
