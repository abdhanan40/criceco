import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/config/demo_mode.dart';
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
import '../../../shared/widgets/ce_surfaces.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import '../../club/club_providers.dart';
import '../tournament_demo_actions.dart';
import '../tournaments_controller.dart';

// ---------------------------------------------------------------------------
// Status styling
// ---------------------------------------------------------------------------

/// `.tourney-status-pill` open / full / closed (prototype `statusPillClass`).
CeTone tournamentStatusTone(TournamentStatus s) => switch (s) {
      TournamentStatus.registrationOpen => CeTone.green,
      TournamentStatus.registrationFull => CeTone.amber,
      TournamentStatus.registrationClosed || TournamentStatus.completed => CeTone.neutral,
    };

/// `.status-badge` Pending / Approved / Rejected (prototype `regStatusIcon`).
CeTone registrationTone(RegistrationStatus s) => switch (s) {
      RegistrationStatus.pending => CeTone.amber,
      RegistrationStatus.approved => CeTone.green,
      RegistrationStatus.rejected => CeTone.red,
    };

String registrationIcon(RegistrationStatus s) => switch (s) {
      RegistrationStatus.pending => 'hourglass',
      RegistrationStatus.approved => 'check-circle',
      RegistrationStatus.rejected => 'x-circle',
    };

String rupeesOrDash(int? amount) => amount == null || amount == 0 ? '—' : CeFormat.rupees(amount);

String tournamentMeta(Tournament t) => '${t.city} · ${t.format.display(t.customOvers)} · ${t.type.label}';

String tournamentDates(Tournament t) => '${CeFormat.date(t.startDate)} – ${CeFormat.date(t.endDate)}';

class TournamentStatusChip extends ConsumerWidget {
  const TournamentStatusChip(this.tournament, {super.key});
  final Tournament tournament;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = tournament.statusAt(ref.read(clockProvider).now());
    return CeStatusChip(s.label, tone: tournamentStatusTone(s));
  }
}

class RegistrationStatusChip extends StatelessWidget {
  const RegistrationStatusChip(this.status, {super.key});
  final RegistrationStatus status;

  @override
  Widget build(BuildContext context) =>
      CeStatusChip(status.label, tone: registrationTone(status), icon: registrationIcon(status));
}

// ---------------------------------------------------------------------------
// Screen shell
// ---------------------------------------------------------------------------

/// Which side of the tournament flow a screen belongs to. A host never
/// registers into their own tournament; a participant never lands in the
/// host tools (Details / Dashboard / Manage Teams).
enum TournamentAccess { any, host, participant }

/// Loading / not-found / wrong-side wrapper shared by every screen keyed by a
/// tournament id (like `BookingScaffold` for matches).
class TournamentScaffold extends ConsumerWidget {
  const TournamentScaffold({
    super.key,
    required this.tournamentId,
    required this.title,
    required this.builder,
    required this.fallbackLocation,
    this.access = TournamentAccess.any,
    this.onBack,
    this.actions = const [],
  });

  final String tournamentId;
  final String title;
  final String fallbackLocation;
  final TournamentAccess access;
  final VoidCallback? onBack;
  final List<Widget> actions;
  final Widget Function(BuildContext context, Tournament t) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loading = ref.watch(tournamentsProvider).isLoading ||
        ref.watch(tournamentRegistrationsProvider).isLoading ||
        ref.watch(clubDirectoryProvider).isLoading;
    final t = ref.watch(tournamentProvider(tournamentId));
    final ownClubId = ref.watch(currentClubProvider.select((c) => c?.id));
    final bar = CeTopBar(title: title, fallbackLocation: fallbackLocation, onBack: onBack, actions: actions);
    if (loading) return Scaffold(appBar: bar, body: const Center(child: CircularProgressIndicator()));
    if (t == null) {
      return Scaffold(
        appBar: bar,
        body: CeEmptyState(
          icon: 'trophy',
          title: 'Tournament not found',
          body: 'This tournament is no longer available.',
          primaryLabel: 'Back to Tournaments',
          onPrimary: () => context.go(Routes.tournamentHub),
        ),
      );
    }
    final hosting = t.organizerClubId == ownClubId;
    if (access == TournamentAccess.host && !hosting) {
      return Scaffold(
        appBar: bar,
        body: CeEmptyState(
          icon: 'lock',
          title: 'Hosted by another club',
          body: 'Only the organizing club can manage this tournament.',
          primaryLabel: 'View Tournament',
          onPrimary: () => context.go(Routes.tournamentRegister(t.id)),
        ),
      );
    }
    if (access == TournamentAccess.participant && hosting) {
      return Scaffold(
        appBar: bar,
        body: CeEmptyState(
          icon: 'shield',
          title: 'Your club is hosting this',
          body: 'Manage teams and fixtures from your tournament instead.',
          primaryLabel: 'Open Tournament Details',
          onPrimary: () => context.go(Routes.tournamentDetails(t.id)),
        ),
      );
    }
    return Scaffold(appBar: bar, body: builder(context, t));
  }
}

/// `.tourney-banner`: format · type badge, name and meta on the brand hero.
class TournamentHero extends StatelessWidget {
  const TournamentHero({super.key, required this.tournament, this.showBadge = true});
  final Tournament tournament;
  final bool showBadge;

  @override
  Widget build(BuildContext context) {
    final t = tournament;
    return CeBrandHero(
      margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 14, CeSpace.gutter, 0),
      radius: CeRadius.lg,
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (showBadge) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(CeRadius.pill),
            ),
            child: Text('${t.format.label} ${t.type.label}'.toUpperCase(),
                style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
          ),
          const SizedBox(height: 10),
        ],
        Text(t.name, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, height: 1.2)),
        const SizedBox(height: 6),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(CeIcons.of('map-pin'), size: 13, color: Colors.white.withValues(alpha: 0.8)),
          ),
          const SizedBox(width: 5),
          Expanded(
            child: Text(tournamentMeta(t),
                style: TextStyle(fontSize: 12.5, color: Colors.white.withValues(alpha: 0.85))),
          ),
        ]),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Clubs / entrants
// ---------------------------------------------------------------------------

/// Club badge for an organizer / entrant / applicant.
class TournamentClubBadge extends ConsumerWidget {
  const TournamentClubBadge({super.key, required this.clubId, required this.fallbackName, this.size = 40});
  final String? clubId;
  final String fallbackName;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.watch(tournamentClubsProvider)[clubId];
    final abbr = c?.abbr ?? clubAbbr(c?.name ?? fallbackName);
    return CeTeamBadge(abbr, color: c?.color ?? clubBadgeColor(abbr), size: size);
  }
}

/// `.team-row`: badge, name, sub-line and an optional trailing widget.
class EntrantRow extends ConsumerWidget {
  const EntrantRow({
    super.key,
    required this.clubId,
    required this.name,
    required this.subtitle,
    this.trailing,
    this.onTap,
  });
  final String? clubId;
  final String name;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) => CeCard(
        margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 0, CeSpace.gutter, 8),
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
        onTap: onTap,
        child: Row(children: [
          TournamentClubBadge(clubId: clubId, fallbackName: name),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: CeColors.ink)),
              const SizedBox(height: 2),
              Text(subtitle, style: const TextStyle(fontSize: 12, color: CeColors.muted)),
            ]),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ]),
      );
}

/// Sub-line for a confirmed entrant: its city, then "Confirmed".
String confirmedSubtitle(WidgetRef ref, TournamentEntrant e) {
  final city = ref.watch(tournamentClubsProvider)[e.clubId]?.city;
  return [if (city != null && city.isNotEmpty) city, 'Confirmed'].join(' · ');
}

/// Muted one-line empty note (prototype `emptyMsg`).
class TournamentEmptyNote extends StatelessWidget {
  const TournamentEmptyNote(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 2, CeSpace.gutter, 6),
        child: Text(text, style: const TextStyle(fontSize: 12.5, color: CeColors.muted)),
      );
}

// ---------------------------------------------------------------------------
// Cards
// ---------------------------------------------------------------------------

/// `.tbc-grid`: two columns of label / value.
class TournamentInfoGrid extends StatelessWidget {
  const TournamentInfoGrid({super.key, required this.items});
  final List<(String, String)> items;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final w = (box.maxWidth - 10) / 2;
        return Wrap(spacing: 10, runSpacing: 10, children: [
          for (final (label, value) in items)
            SizedBox(
              width: w,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: const TextStyle(fontSize: 11, color: CeColors.muted)),
                const SizedBox(height: 2),
                Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: CeColors.ink)),
              ]),
            ),
        ]);
      });
}

/// Card header shared by Browse and My Registrations cards (`.tbc-top`).
class TournamentCardHeader extends ConsumerWidget {
  const TournamentCardHeader({super.key, required this.tournament, required this.subtitle, required this.trailing});
  final Tournament tournament;
  final String subtitle;
  final Widget trailing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final org = ref.watch(tournamentClubsProvider)[tournament.organizerClubId];
    final color = org?.color ?? CeColors.primaryDark;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(CeRadius.md)),
        child: Icon(CeIcons.of('trophy'), size: 18, color: Colors.white),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tournament.name,
              style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, color: CeColors.ink, height: 1.25)),
          const SizedBox(height: 2),
          Text(subtitle, style: const TextStyle(fontSize: 12, color: CeColors.muted)),
        ]),
      ),
      const SizedBox(width: 8),
      Flexible(child: Align(alignment: Alignment.topRight, child: trailing)),
    ]);
  }
}

/// Organizer club name for a tournament.
String organizerName(WidgetRef ref, Tournament t) =>
    ref.watch(tournamentClubsProvider)[t.organizerClubId]?.name ?? 'Organizer';

// ---------------------------------------------------------------------------
// Fixtures, points table, winner
// ---------------------------------------------------------------------------

/// A fixture (`matchCardHtml`). With Demo Mode ON a ready, unplayed fixture
/// is tappable ("Tap to simulate result"); with it OFF fixtures are
/// read-only (P10).
class FixtureCard extends ConsumerStatefulWidget {
  const FixtureCard({super.key, required this.tournament, required this.fixture});
  final Tournament tournament;
  final FixtureRef fixture;

  @override
  ConsumerState<FixtureCard> createState() => _FixtureCardState();
}

class _FixtureCardState extends ConsumerState<FixtureCard> {
  bool _busy = false;

  Future<void> _simulate() async {
    if (_busy) return;
    setState(() => _busy = true);
    final t = widget.tournament;
    final winner = await ref.read(tournamentDemoActionsProvider).simulateResult(t.id, widget.fixture);
    if (!mounted) return;
    setState(() => _busy = false);
    if (winner != null) showCeToast(context, '${entrantLabel(t, winner)} won the match!');
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.tournament;
    final f = widget.fixture;
    final m = f.match;
    final demo = ref.watch(demoModeProvider);
    final canSimulate = demo && m.ready && !m.completed;
    final title = '${entrantLabel(t, m.home)} vs ${entrantLabel(t, m.away)}';
    return Semantics(
      button: canSimulate,
      label: canSimulate ? '$title, tap to simulate result' : title,
      excludeSemantics: true,
      child: CeCard(
        margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 0, CeSpace.gutter, 8),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        onTap: canSimulate ? _simulate : null,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: CeColors.primaryDark, borderRadius: BorderRadius.circular(CeRadius.sm)),
              child: Text(f.roundName.characters.first,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: Colors.white)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: CeColors.ink)),
                const SizedBox(height: 2),
                Text('${f.roundName} · ${t.ground}', style: const TextStyle(fontSize: 11.5, color: CeColors.muted)),
              ]),
            ),
            if (_busy) ...[
              const SizedBox(width: 8),
              const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ]),
          if (m.completed) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: CeStatusChip('${entrantLabel(t, m.winnerId)} won', icon: 'trophy'),
            ),
          ] else if (canSimulate) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: CeColors.demoBg,
                borderRadius: BorderRadius.circular(CeRadius.sm),
                border: Border.all(color: CeColors.demoBorder),
              ),
              child: Row(children: [
                Icon(CeIcons.of('flask-conical'), size: 13, color: CeColors.amberInk),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text('Tap to simulate result',
                      style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: CeColors.amberInk)),
                ),
              ]),
            ),
          ] else if (!m.completed && !m.ready) ...[
            const SizedBox(height: 6),
            const Text('Waiting for the previous round',
                style: TextStyle(fontSize: 11.5, color: CeColors.muted)),
          ],
        ]),
      ),
    );
  }
}

/// Every fixture grouped by round.
class FixtureRounds extends StatelessWidget {
  const FixtureRounds({super.key, required this.tournament});
  final Tournament tournament;

  @override
  Widget build(BuildContext context) {
    final byRound = <String, List<FixtureRef>>{};
    for (final f in flattenFixtures(tournament)) {
      byRound.putIfAbsent(f.roundName, () => []).add(f);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final e in byRound.entries) ...[
        CeSectionHeader(e.key, padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 14, CeSpace.gutter, 8)),
        for (final f in e.value) FixtureCard(tournament: tournament, fixture: f),
      ],
    ]);
  }
}

/// `.points-table` (P · W · L · Pts), sorted by points then name.
class PointsTable extends ConsumerWidget {
  const PointsTable({super.key, required this.tournament});
  final Tournament tournament;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = tournament;
    if (t.joined.isEmpty) {
      return const CeEmptyState(
          icon: 'bar-chart', title: 'No teams yet', body: 'Standings will appear once teams register');
    }
    final demo = ref.watch(demoModeProvider);
    const head = TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: CeColors.muted, letterSpacing: 0.3);
    const cell = TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: CeColors.ink);
    Widget num(String v, TextStyle s) => SizedBox(width: 34, child: Text(v, textAlign: TextAlign.center, style: s));
    Widget row(String team, List<String> values, TextStyle s, {bool last = false}) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(border: last ? null : const Border(bottom: BorderSide(color: CeColors.mint2))),
          child: Row(children: [
            Expanded(child: Text(team, maxLines: 2, overflow: TextOverflow.ellipsis, style: s)),
            for (final v in values) num(v, s),
          ]),
        );
    final rows = standingsTable(t);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      CeCard(
        margin: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
        padding: EdgeInsets.zero,
        child: Column(children: [
          row('TEAM', const ['P', 'W', 'L', 'PTS'], head),
          for (final (i, (e, s)) in rows.indexed)
            row(e.displayName, ['${s.played}', '${s.won}', '${s.lost}', '${s.points}'], cell, last: i == rows.length - 1),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 10, CeSpace.gutter, 0),
        child: Text(
          t.fixtures == null
              ? 'Points table updates once fixtures are generated and results are recorded.'
              : demo
                  ? 'Tap a match in Fixtures to simulate a result and update standings.'
                  : 'Standings update as results are recorded.',
          style: const TextStyle(fontSize: 11.5, color: CeColors.muted),
        ),
      ),
    ]);
  }
}

/// `.winner-banner`.
class WinnerBanner extends StatelessWidget {
  const WinnerBanner({super.key, required this.name});
  final String name;

  @override
  Widget build(BuildContext context) => CeBrandHero(
        margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 14, CeSpace.gutter, 0),
        radius: CeRadius.lg,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
        child: SizedBox(
          width: double.infinity,
          child: Column(children: [
            Icon(CeIcons.of('trophy'), size: 28, color: Colors.white),
            const SizedBox(height: 8),
            Text(name,
                textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text('Tournament Winner'.toUpperCase(),
                style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                    color: Colors.white.withValues(alpha: 0.8))),
          ]),
        ),
      );
}

/// "Fixtures will be generated once N more team(s) join." or the
/// organizer-side note.
String fixturesPendingNote(Tournament t) {
  final need = Tournament.minTeamsForFixtures - t.joined.length;
  return need > 0
      ? 'Fixtures will be generated once $need more team${need == 1 ? '' : 's'} join.'
      : 'The organizer has not published fixtures yet.';
}
