
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers/core_providers.dart';
import '../../../app/router/routes.dart';
import '../../../app/session/session_controller.dart';
import '../../../app/theme/tokens.dart';
import '../../../app/theme/typography.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/media/photo_picker.dart';
import '../../../shared/widgets/ce_dashboard_hero.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_match_widgets.dart';
import '../../../shared/widgets/ce_quick_actions.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../../fitness/fitness_providers.dart';
import '../../fitness/fitness_widgets.dart';
import '../../fitness/workout_sheet.dart';
import '../../notifications/notifications_controller.dart';
import '../../notifications/notifications_sheet.dart';
import '../player_providers.dart';
import '../widgets/match_availability_sheet.dart';
import '../widgets/performance_sheet.dart';

/// Player Dashboard (prototype `screens.playerDashboard`, :3961).
class PlayerDashboardScreen extends ConsumerWidget {
  const PlayerDashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(currentAccountProvider);
    final availability = ref.watch(playerAvailabilityProvider);
    final perf = ref.watch(performanceProvider).value;
    final next = ref.watch(nextPlayerMatchProvider);
    final notifCount = ref.watch(unreadNotificationCountProvider(UserRole.player));
    final fitness = ref.watch(playerFitnessProvider);
    final workouts = ref.watch(playerWorkoutsProvider);
    final profile = account?.playerProfile;
    final name = account?.fullName ?? 'Player';
    final available = availability.status == PlayerAvailability.available;

    // Structure: hero (greeting, glass player card with key stats) → quick
    // actions → next match → Fitness Meter. Recent form and the full season
    // numbers live in Performance and Matches.
    return Scaffold(
      body: CeStatusBarScrim(
        child: ListView(padding: const EdgeInsets.only(bottom: 20), children: [
          // ---- Hero: greeting + glass player card (identity, styles, chips, stats) ----
          CeDashboardHero(
            keyPrefix: 'player',
            greeting: ceGreeting(ref.read(clockProvider).now()),
            name: name.trim().isEmpty ? 'Player' : name.trim().split(RegExp(r'\s+')).first,
            notificationCount: notifCount,
            onNotifications: () => showNotificationsSheet(context, UserRole.player),
            card: CeHeroGlassCard(
              keyPrefix: 'player',
              semanticLabel: 'Open my profile, $name',
              onTap: () => context.go(Routes.playerProfile),
              leading: _HeroAvatar(initial: account?.initial ?? 'A', photoPath: account?.photoPath, available: available),
              title: name,
              subtitle: [
                if (profile?.role != null) profile!.role!.label,
                if (profile?.battingStyle != null) profile!.battingStyle == BattingStyle.rightHanded ? 'RHB' : 'LHB',
                if (profile?.bowlingStyle != null) profile!.bowlingStyle!.label,
              ].join(' · '),
              chips: [
                Semantics(
                  container: true,
                  button: true,
                  label: available ? 'Available. Tap to mark unavailable' : 'Unavailable. Tap to mark available',
                  excludeSemantics: true,
                  child: GestureDetector(
                    onTap: () {
                      ref.read(playerAvailabilityProvider.notifier).toggleQuick();
                      // Feedback for a one-tap status change.
                      showCeToast(context, available ? "You're marked unavailable" : "You're marked available");
                    },
                    child: CeHeroPill(
                      dotColor: available ? CeColors.fresh : CeColors.red,
                      label: available ? 'Available' : 'Unavailable',
                    ),
                  ),
                ),
                if (profile?.isWicketkeeper ?? false) const CeHeroPill(icon: 'shield', label: 'Wicket Keeper'),
                if (account?.memberships.firstOrNull?.clubName case final club?) CeHeroPill(icon: 'users', label: club),
              ],
              // "–" while loading, never a misleading 0.
              stats: [
                (perf == null ? '–' : '${perf.matches}', 'Matches'),
                (perf == null ? '–' : '${perf.runs}', 'Runs'),
                (perf == null ? '–' : '${perf.wickets}', 'Wickets'),
                (perf?.battingAverage ?? '–', 'Bat Avg'),
              ],
            ),
          ),

          // ---- Quick actions: secondary actions only (no bottom-nav tabs) ----
          const CeSectionHeader('Quick Actions'),
          CeQuickActionGrid(key: const Key('player.quickActions'), actions: [
            CeQuickAction(icon: 'circle-dot', label: 'Playing Opportunities', onTap: () => context.go(Routes.openMatches)),
            // The Matches area on its default view.
            CeQuickAction(icon: 'calendar', label: 'My Matches', onTap: () => context.go(Routes.myMatches)),
            CeQuickAction(
                icon: 'calendar-check', label: 'Match Availability', onTap: () => showMatchAvailabilitySheet(context)),
            // A summary in a sheet; the full Performance screen is one tap further.
            CeQuickAction(icon: 'bar-chart', label: 'Performance', onTap: () => showPerformanceSheet(context)),
          ]),

          // ---- Next match ----
          const CeSectionHeader('Next Match'),
          if (next == null)
            CeCard(
              margin: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
              child: Row(children: [
                const CeIconWell('calendar', size: 38, iconSize: 17),
                const SizedBox(width: 12),
                Expanded(
                  child: Text('No upcoming matches yet. Confirmed matches will show up here.',
                      style: Theme.of(context).textTheme.bodySmall),
                ),
              ]),
            )
          else
            _NextMatchCard(match: next),

          // ---- Fitness Meter (after the next match, before performance) ----
          if (fitness != null)
            FitnessMeterView(
              report: fitness,
              log: perf?.matchLog ?? const [],
              now: ref.read(clockProvider).now(),
              nextMatch: next == null ? null : (startsAt: next.startsAt, opponent: next.opponentName),
              // A club owner sees their members' fitness (Members, Member Profile).
              sharedWithClub: account?.memberships.firstOrNull?.clubName,
              workouts: workouts,
              onAddWorkout: () => showAddWorkoutSheet(context),
              onTap: () => showFitnessSheet(context, fitness,
                  log: perf?.matchLog ?? const [], now: ref.read(clockProvider).now(), workouts: workouts),
            ),

        ]),
      ),
    );
  }
}

class _HeroAvatar extends StatelessWidget {
  const _HeroAvatar({required this.initial, required this.available, this.photoPath});
  final String initial;
  final String? photoPath;
  final bool available;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 54,
        height: 54,
        child: Stack(children: [
          // The profile picture when one is set (My Profile), else the initial.
          CePhotoImage(
            path: photoPath,
            size: 54,
            fallback: Container(
              width: 54,
              height: 54,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.2),
                border: Border.all(color: Colors.white.withValues(alpha: 0.35), width: 2.5),
              ),
              child: Text(initial, style: CeType.heroName.copyWith(fontSize: 21, color: Colors.white)),
            ),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: 14,
              height: 14,
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

/// `.pd-next-match`, compact: gradient body (teams, status, when/where) +
/// mint footer with the live countdown and the one primary action.
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
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(CeRadius.card)),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          decoration: const BoxDecoration(gradient: CeColors.brandGradient),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
          child: DefaultTextStyle.merge(
            style: const TextStyle(color: Colors.white),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                CeTeamBadge(match.ownTeamAbbr, size: 38, color: CeColors.primaryDark),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6),
                  child: Text('VS', style: TextStyle(fontFamily: CeType.ui, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1)),
                ),
                CeTeamBadge(match.opponentAbbr, size: 38, color: CeColors.red),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: CeColors.sage, borderRadius: BorderRadius.circular(CeRadius.xs)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(CeIcons.of('check'), size: 11, color: CeColors.ink),
                    const SizedBox(width: 3),
                    Text('CONFIRMED', style: CeType.micro.copyWith(color: CeColors.ink)),
                  ]),
                ),
              ]),
              // Names get the full width (never clipped by the status pill at 320 px).
              const SizedBox(height: 8),
              Text('${match.ownTeamName} vs',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: CeType.caption.copyWith(fontSize: 12, color: CeColors.sage)),
              Text(match.opponentName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: CeType.heroName.copyWith(fontSize: 18, color: Colors.white)),
              const SizedBox(height: 10),
              InkWell(
                onTap: () => openDirections(context, match.ground),
                child: Row(children: [
                  Icon(CeIcons.of('map-pin'), size: 13, color: white85),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(match.ground,
                        overflow: TextOverflow.ellipsis, style: CeType.bodySmall.copyWith(fontSize: 12, color: white85)),
                  ),
                  Text('Directions',
                      style: CeType.chip.copyWith(fontSize: 12, color: CeColors.sage, decoration: TextDecoration.underline, decorationColor: CeColors.sage)),
                  Icon(CeIcons.of('arrow-up-right'), size: 12, color: CeColors.sage),
                ]),
              ),
              const SizedBox(height: 8),
              Wrap(spacing: 10, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                _WhiteInfo(icon: 'calendar', text: CeFormat.dayDate(match.startsAt)),
                _WhiteInfo(icon: 'clock', text: CeFormat.time(match.startsAt)),
                _Tag('${match.format.display()} Match'),
                if (match.matchType != null) _Tag(match.matchType!),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Icon(CeIcons.of('users'), size: 12, color: white85),
                const SizedBox(width: 5),
                Text('Playing: ', style: CeType.bodySmall.copyWith(fontSize: 12, color: white85)),
                Flexible(
                  child: Text(match.playingTeamName,
                      overflow: TextOverflow.ellipsis, style: CeType.chip.copyWith(fontSize: 12, color: Colors.white)),
                ),
              ]),
            ]),
          ),
        ),
        Container(
          color: CeColors.mint,
          padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Match starts in', style: CeType.statLabel.copyWith(color: CeColors.primary)),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(remaining.isNegative ? 'Started' : CeFormat.hms(remaining),
                      style: CeType.statValue(15).copyWith(
                          color: CeColors.primary, fontFeatures: const [FontFeature.tabularFigures()])),
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
                  color: CeColors.primary,
                  borderRadius: BorderRadius.circular(CeRadius.tab),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(CeRadius.tab),
                    highlightColor: CeColors.primaryPressed,
                    // Player context: the Player Match Details route (never Club Owner Match Management).
                    onTap: () => context.go(Routes.playerMatchDetails(match.id)),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Flexible(
                          child: Text('View Match Details',
                              textAlign: TextAlign.center,
                              style: CeType.buttonSmall.copyWith(fontSize: 12.5, color: Colors.white)),
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
        Text(text, style: CeType.bodySmall.copyWith(fontSize: 12, color: Colors.white)),
      ]);
}

class _Tag extends StatelessWidget {
  const _Tag(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(CeRadius.xs)),
        child: Text(text, style: CeType.micro.copyWith(fontSize: 11, color: Colors.white)),
      );
}

