
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers/core_providers.dart';
import '../../../app/router/routes.dart';
import '../../../app/session/session_controller.dart';
import '../../../app/theme/tokens.dart';
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
import '../player_providers.dart';
import '../widgets/join_club_sheet.dart';
import '../widgets/match_availability_sheet.dart';

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
            onNotifications: () => context.push(Routes.notifications),
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
            CeQuickAction(
                icon: 'calendar',
                label: 'Upcoming Matches',
                onTap: () => context.go('${Routes.myMatches}?tab=${PlayerMatchStatus.upcoming.name}')),
            CeQuickAction(icon: 'user-plus', label: 'Join Club', onTap: () => showJoinClubSheet(context)),
            CeQuickAction(
                icon: 'calendar-check', label: 'Match Availability', onTap: () => showMatchAvailabilitySheet(context)),
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
              child: Text(initial, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800, color: Colors.white)),
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
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(CeRadius.lg),
        boxShadow: const [BoxShadow(color: Color(0x26092328), blurRadius: 14, offset: Offset(0, 4))],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          decoration: const BoxDecoration(gradient: CeColors.brandGradient),
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
          child: DefaultTextStyle.merge(
            style: const TextStyle(color: Colors.white),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                CeTeamBadge(match.ownTeamAbbr, size: 38, color: CeColors.primaryDark),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6),
                  child: Text('VS', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, letterSpacing: 1)),
                ),
                CeTeamBadge(match.opponentAbbr, size: 38, color: CeColors.red),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.22), borderRadius: BorderRadius.circular(CeRadius.pill)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(CeIcons.of('check'), size: 10, color: Colors.white),
                    const SizedBox(width: 3),
                    const Text('CONFIRMED', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800)),
                  ]),
                ),
              ]),
              // Names get the full width (never clipped by the status pill at 320 px).
              const SizedBox(height: 8),
              Text('${match.ownTeamName} vs',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: white85)),
              Text(match.opponentName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, letterSpacing: -0.2)),
              const SizedBox(height: 10),
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
          padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
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

