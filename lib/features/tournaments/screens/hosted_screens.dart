import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers/core_providers.dart';
import '../../../app/router/routes.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_indicators.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import '../tournaments_controller.dart';
import '../widgets/tournament_widgets.dart';

// ---------------------------------------------------------------------------
// My Tournaments (prototype `screens.myTournaments`, :4710): tournaments
// hosted by the owner's own club.
// ---------------------------------------------------------------------------

class MyTournamentsScreen extends ConsumerWidget {
  const MyTournamentsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loading = ref.watch(tournamentsProvider).isLoading;
    final hosted = ref.watch(hostedTournamentsProvider);
    final now = ref.read(clockProvider).now();
    final teams = hosted.fold<int>(0, (sum, t) => sum + t.joined.length);
    final open = hosted.where((t) => t.statusAt(now) == TournamentStatus.registrationOpen).length;
    return Scaffold(
      appBar: CeTopBar(
        title: 'My Tournaments',
        fallbackLocation: Routes.tournamentHub,
        actions: [TextButton(onPressed: () => context.go(Routes.createTournament), child: const Text('+ New'))],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : hosted.isEmpty
              ? ListView(children: [
                  CeEmptyState(
                    icon: 'trophy',
                    title: 'No tournaments yet',
                    body: 'Tournaments you create will show up here.',
                    primaryLabel: 'Host a Tournament',
                    onPrimary: () => context.go(Routes.createTournament),
                  ),
                ])
              : ListView(padding: const EdgeInsets.only(bottom: 28), children: [
                  const SizedBox(height: 14),
                  CeStatsRow(children: [
                    CeStatCard(value: '${hosted.length}', label: 'Hosted'),
                    CeStatCard(value: '$teams', label: 'Teams Joined'),
                    CeStatCard(value: '$open', label: 'Open Now'),
                  ]),
                  CeSectionHeader('Hosted by your Club · ${hosted.length}'),
                  for (final t in hosted) _HostedCard(tournament: t),
                ]),
    );
  }
}

class _HostedCard extends StatelessWidget {
  const _HostedCard({required this.tournament});
  final Tournament tournament;

  @override
  Widget build(BuildContext context) {
    final t = tournament;
    final joined = t.joined.length;
    return CeCard(
      margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 0, CeSpace.gutter, 12),
      onTap: () => context.go(Routes.tournamentDetails(t.id)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const CeIconWell('trophy', size: 42, iconSize: 19),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.name, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, color: CeColors.ink)),
              const SizedBox(height: 2),
              Text(tournamentMeta(t), style: const TextStyle(fontSize: 12, color: CeColors.muted)),
            ]),
          ),
          const SizedBox(width: 8),
          Flexible(child: Align(alignment: Alignment.topRight, child: TournamentStatusChip(t))),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          const Expanded(child: Text('Teams registered', style: TextStyle(fontSize: 12, color: CeColors.muted))),
          Text('$joined/${t.maxTeams}',
              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: CeColors.ink)),
        ]),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: t.maxTeams == 0 ? 0 : (joined / t.maxTeams).clamp(0, 1).toDouble(),
            minHeight: 7,
            backgroundColor: CeColors.mint2,
            color: CeColors.primary,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 14, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          _Meta(icon: 'calendar', text: CeFormat.date(t.startDate)),
          if (t.prize != null && t.prize! > 0) _Meta(icon: 'award', text: CeFormat.rupees(t.prize!)),
          Row(mainAxisSize: MainAxisSize.min, children: [
            const Text('View Details',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: CeColors.primary)),
            const SizedBox(width: 4),
            Icon(CeIcons.of('arrow-right'), size: 14, color: CeColors.primary),
          ]),
        ]),
      ]),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.icon, required this.text});
  final String icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(CeIcons.of(icon), size: 13, color: CeColors.muted),
        const SizedBox(width: 4),
        Text(text, style: const TextStyle(fontSize: 12, color: CeColors.muted)),
      ]);
}

// ---------------------------------------------------------------------------
// Tournament Details (host) — prototype `screens.tournamentDetails`, :5075.
// Overview / Teams / Fixtures / Points Table live in `?tab=`.
// ---------------------------------------------------------------------------

enum TournamentTab {
  overview('Overview'),
  teams('Teams'),
  fixtures('Fixtures'),
  points('Points Table');

  const TournamentTab(this.label);
  final String label;

  static TournamentTab parse(String? raw) => values.where((t) => t.name == raw).firstOrNull ?? overview;

  String location(String tournamentId) => this == overview
      ? Routes.tournamentDetails(tournamentId)
      : '${Routes.tournamentDetails(tournamentId)}?tab=$name';
}

/// Organizer "Generate Fixtures" (prototype `generateFixtures`): toasts and
/// opens the Fixtures tab once the draw exists.
Future<void> generateFixturesFlow(BuildContext context, WidgetRef ref, Tournament t) async {
  final outcome = await ref.read(tournamentsProvider.notifier).generateFixtures(t.id);
  if (!context.mounted) return;
  switch (outcome) {
    case FixturesOutcome.generated:
      showCeToast(context, t.type == TournamentType.knockout ? 'Bracket generated!' : 'League fixtures generated!');
      context.go(TournamentTab.fixtures.location(t.id));
    case FixturesOutcome.notEnoughTeams:
      showCeToast(context, 'Need at least ${Tournament.minTeamsForFixtures} teams to generate fixtures');
    case FixturesOutcome.alreadyGenerated:
      context.go(TournamentTab.fixtures.location(t.id));
    case FixturesOutcome.notFound:
      break;
  }
}

/// Organizer "Remove" on a confirmed team (before fixtures only).
Future<void> removeTeamFlow(BuildContext context, WidgetRef ref, Tournament t, TournamentEntrant e) async {
  final ok = await ref.read(tournamentsProvider.notifier).removeTeam(t.id, e.id);
  if (!context.mounted) return;
  showCeToast(context, ok ? '${e.displayName} removed' : 'Teams are locked once fixtures are generated');
}

class TournamentDetailsScreen extends ConsumerWidget {
  const TournamentDetailsScreen({super.key, required this.tournamentId, this.tab = TournamentTab.overview});
  final String tournamentId;
  final TournamentTab tab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return TournamentScaffold(
      tournamentId: tournamentId,
      title: 'Tournament Details',
      access: TournamentAccess.host,
      fallbackLocation: Routes.myTournaments,
      builder: (context, t) {
        final pending = ref.watch(pendingRequestsProvider(t.id)).length;
        return ListView(padding: const EdgeInsets.only(bottom: 28), children: [
          TournamentHero(tournament: t),
          CeChipRow<TournamentTab>(
            values: TournamentTab.values,
            selected: tab,
            labelOf: (x) => x.label,
            onSelected: (x) => context.go(x.location(t.id)),
          ),
          CeSummaryCard(margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 10, CeSpace.gutter, 0), rows: [
            ('Tournament Name', CeSummaryCard.value(context, t.name)),
            ('Organizer Club', CeSummaryCard.value(context, organizerName(ref, t))),
            ('Ground', CeSummaryCard.value(context, t.ground)),
            ('Prize', CeSummaryCard.value(context, rupeesOrDash(t.prize))),
            ('Entry Fee', CeSummaryCard.value(context, rupeesOrDash(t.entryFee))),
            ('Registered Teams', CeSummaryCard.value(context, '${t.joined.length}/${t.maxTeams}')),
            ('Available Slots', CeSummaryCard.value(context, '${t.availableSlots}')),
            ('Registration Deadline', CeSummaryCard.value(context, CeFormat.date(t.registrationDeadline))),
            ('Status', TournamentStatusChip(t)),
          ]),
          ...switch (tab) {
            TournamentTab.overview => _overview(context, ref, t, pending),
            TournamentTab.teams => _teams(context, ref, t),
            TournamentTab.fixtures => _fixtures(context, ref, t),
            TournamentTab.points => [const SizedBox(height: 14), PointsTable(tournament: t)],
          },
        ]);
      },
    );
  }

  List<Widget> _overview(BuildContext context, WidgetRef ref, Tournament t, int pending) {
    final now = ref.read(clockProvider).now();
    final next = flattenFixtures(t).where((f) => !f.match.completed).firstOrNull;
    final joined = t.joined.length;
    return [
      const SizedBox(height: 14),
      CeStatsRow(children: [
        CeStatCard(value: '$joined/${t.maxTeams}', label: 'Teams'),
        CeStatCard(value: '$pending', label: 'Pending'),
        CeStatCard(value: CeFormat.daysLeft(t.registrationDeadline, now), label: 'Reg. Closes'),
      ]),
      if (t.description.isNotEmpty) ...[
        const CeSectionHeader('Description'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
          child: Text(t.description, style: const TextStyle(fontSize: 13, color: CeColors.ink, height: 1.55)),
        ),
      ],
      const CeSectionHeader('Format & Schedule'),
      CeSummaryCard(rows: [
        ('Format', CeSummaryCard.value(context, t.format.display(t.customOvers))),
        ('Type', CeSummaryCard.value(context, t.type.label)),
        ('Start Date', CeSummaryCard.value(context, CeFormat.date(t.startDate))),
        ('End Date', CeSummaryCard.value(context, CeFormat.date(t.endDate))),
      ]),
      if (t.winnerId != null) WinnerBanner(name: entrantLabel(t, t.winnerId)),
      if (next != null) ...[
        const CeSectionHeader('Next Match'),
        FixtureCard(tournament: t, fixture: next),
      ],
      const CeSectionHeader('Manage'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
        child: Column(children: [
          CeButton.soft(
            label: 'Manage Teams${pending > 0 ? ' ($pending pending)' : ''}',
            onPressed: () => context.go(Routes.tournamentTeamsManage(t.id)),
          ),
          const SizedBox(height: 10),
          if (t.fixtures != null)
            CeButton(label: 'View Fixtures', onPressed: () => context.go(TournamentTab.fixtures.location(t.id)))
          else if (t.canGenerateFixtures)
            CeButton(label: 'Generate Fixtures', onPressed: () => generateFixturesFlow(context, ref, t))
          else
            // Prototype: a muted red button that explains why (not a dead control).
            CeButton.danger(
              label: 'Generate Fixtures ($joined/${Tournament.minTeamsForFixtures} min)',
              onPressed: () =>
                  showCeToast(context, 'Need at least ${Tournament.minTeamsForFixtures} teams to generate fixtures'),
            ),
          const SizedBox(height: 10),
          CeButton.soft(
            label: 'Tournament Dashboard',
            icon: CeIcons.of('trophy'),
            onPressed: () => context.go(Routes.tournamentDashboard(t.id)),
          ),
        ]),
      ),
    ];
  }

  List<Widget> _teams(BuildContext context, WidgetRef ref, Tournament t) => [
        Padding(
          padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 14, CeSpace.gutter, 10),
          child: Text('${t.joined.length}/${t.maxTeams} teams registered',
              style: const TextStyle(fontSize: 12, color: CeColors.muted)),
        ),
        if (t.joined.isEmpty)
          const CeEmptyState(
              icon: 'shield', title: 'No teams registered yet', body: 'Accept team requests from Manage Teams')
        else
          ...confirmedTeamRows(context, ref, t),
        Padding(
          padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 8, CeSpace.gutter, 0),
          child: CeButton.soft(
            label: 'Manage Teams / Requests',
            onPressed: () => context.go(Routes.tournamentTeamsManage(t.id)),
          ),
        ),
      ];

  List<Widget> _fixtures(BuildContext context, WidgetRef ref, Tournament t) {
    if (t.fixtures == null) {
      final joined = t.joined.length;
      if (!t.canGenerateFixtures) {
        return [
          CeEmptyState(
            icon: 'calendar',
            title: 'Not enough teams yet',
            body: 'Need at least ${Tournament.minTeamsForFixtures} teams to generate fixtures '
                '($joined/${Tournament.minTeamsForFixtures})',
          ),
        ];
      }
      return [
        CeEmptyState(
          icon: 'circle-dot',
          title: 'Ready to generate',
          body: '$joined teams registered. Generate the '
              '${t.type == TournamentType.knockout ? 'knockout bracket (QF → SF → Final)' : 'league schedule'} now.',
          primaryLabel: 'Generate Fixtures',
          onPrimary: () => generateFixturesFlow(context, ref, t),
        ),
      ];
    }
    return [
      FixtureRounds(tournament: t),
      Padding(
        padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 10, CeSpace.gutter, 0),
        child: CeButton.soft(
          label: 'View Tournament Dashboard',
          icon: CeIcons.of('trophy'),
          onPressed: () => context.go(Routes.tournamentDashboard(t.id)),
        ),
      ),
    ];
  }
}

/// Confirmed teams with Remove (only before fixtures exist).
List<Widget> confirmedTeamRows(BuildContext context, WidgetRef ref, Tournament t) {
  final locked = t.fixtures != null;
  return [
    for (final e in t.joined)
      EntrantRow(
        clubId: e.clubId,
        name: e.displayName,
        subtitle: confirmedSubtitle(ref, e),
        trailing: locked
            ? null
            : OutlinedButton(
                onPressed: () => removeTeamFlow(context, ref, t, e),
                style: OutlinedButton.styleFrom(
                  foregroundColor: CeColors.red,
                  side: const BorderSide(color: CeColors.redBorder),
                  minimumSize: const Size(0, CeSize.touchTarget),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
                ),
                child: const Text('Remove'),
              ),
      ),
    if (locked)
      const CeInfoNote(
        icon: 'lock',
        margin: EdgeInsets.fromLTRB(CeSpace.gutter, 2, CeSpace.gutter, 8),
        text: 'Teams are locked once fixtures are generated.',
      ),
  ];
}

// ---------------------------------------------------------------------------
// Tournament Dashboard (prototype `screens.tournamentDashboard`, :5118).
// ---------------------------------------------------------------------------

class TournamentDashboardScreen extends ConsumerWidget {
  const TournamentDashboardScreen({super.key, required this.tournamentId});
  final String tournamentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return TournamentScaffold(
      tournamentId: tournamentId,
      title: 'Tournament Dashboard',
      access: TournamentAccess.host,
      fallbackLocation: Routes.tournamentDetails(tournamentId),
      builder: (context, t) {
        final all = flattenFixtures(t);
        final upcoming = [for (final f in all) if (!f.match.completed) f];
        final completed = [for (final f in all) if (f.match.completed) f];
        final awards = ref.watch(tournamentAwardsProvider(t.id));
        return ListView(padding: const EdgeInsets.only(bottom: 28), children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
            child: Text(t.name, style: const TextStyle(fontSize: 12.5, color: CeColors.muted)),
          ),
          if (t.winnerId != null) WinnerBanner(name: entrantLabel(t, t.winnerId)),
          const CeSectionHeader('Upcoming Matches'),
          if (upcoming.isEmpty)
            TournamentEmptyNote(t.fixtures == null ? 'Fixtures have not been generated yet' : 'No upcoming matches')
          else
            for (final f in upcoming) FixtureCard(tournament: t, fixture: f),
          const CeSectionHeader('Completed Matches'),
          if (completed.isEmpty)
            const TournamentEmptyNote('No matches completed yet')
          else
            for (final f in completed) FixtureCard(tournament: t, fixture: f),
          const CeSectionHeader('Points Table'),
          PointsTable(tournament: t),
          const CeSectionHeader('Tournament Awards'),
          if (awards == null)
            const TournamentEmptyNote('Awards will appear once teams are registered')
          else
            _AwardGrid(tournament: t, awards: awards),
        ]);
      },
    );
  }
}

class _AwardGrid extends StatelessWidget {
  const _AwardGrid({required this.tournament, required this.awards});
  final Tournament tournament;
  final TournamentAwards awards;

  @override
  Widget build(BuildContext context) {
    final t = tournament;
    Widget card(String icon, String label, TournamentAward a, String unit) => CeCard(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CeIconWell(icon, size: 34, iconSize: 16),
            const SizedBox(height: 8),
            Text(label.toUpperCase(),
                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 0.4, color: CeColors.muted)),
            const SizedBox(height: 4),
            Text(a.playerName, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: CeColors.ink)),
            const SizedBox(height: 2),
            Text('${a.value} $unit · ${entrantLabel(t, a.entrantId)}',
                style: const TextStyle(fontSize: 11.5, color: CeColors.muted)),
          ]),
        );
    Widget pair(Widget a, Widget b) => IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: a),
            const SizedBox(width: 10),
            Expanded(child: b),
          ]),
        );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
      child: Column(children: [
        pair(
          card('circle-dot', 'Top Run Scorer', awards.topScorer, 'runs'),
          card('target', 'Top Wicket Taker', awards.topWicketTaker, 'wkts'),
        ),
        const SizedBox(height: 10),
        pair(
          card('hand', 'Best Wicketkeeper', awards.bestKeeper, 'dismissals'),
          card('sparkles', 'Best Fielder', awards.bestFielder, 'catches'),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Manage Teams (prototype `screens.tournamentTeamsManage`, :5192).
// ---------------------------------------------------------------------------

class ManageTeamsScreen extends ConsumerWidget {
  const ManageTeamsScreen({super.key, required this.tournamentId});
  final String tournamentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return TournamentScaffold(
      tournamentId: tournamentId,
      title: 'Manage Teams',
      access: TournamentAccess.host,
      fallbackLocation: Routes.tournamentDetails(tournamentId),
      builder: (context, t) {
        final requests = ref.watch(pendingRequestsProvider(t.id));
        final clubs = ref.watch(tournamentClubsProvider);
        return ListView(padding: const EdgeInsets.only(bottom: 28), children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
            child: Text('${t.joined.length}/${t.maxTeams} teams registered',
                style: const TextStyle(fontSize: 12, color: CeColors.muted)),
          ),
          CeSectionHeader('Clubs Requesting Registration · ${requests.length}'),
          if (requests.isEmpty)
            const TournamentEmptyNote('No pending registration requests.')
          else
            for (final r in requests)
              EntrantRow(
                clubId: r.clubId,
                name: clubs[r.clubId]?.name ?? r.teamName,
                subtitle: [
                  if ((clubs[r.clubId]?.city ?? '').isNotEmpty) clubs[r.clubId]!.city,
                  'Tap to review',
                ].join(' · '),
                trailing: Icon(CeIcons.of('chevron-right'), size: 18, color: CeColors.muted),
                onTap: () => context.go(Routes.teamRequestDetail(t.id, r.id)),
              ),
          CeSectionHeader('Confirmed Teams · ${t.joined.length}'),
          if (t.joined.isEmpty)
            const TournamentEmptyNote('No teams have joined yet.')
          else
            ...confirmedTeamRows(context, ref, t),
        ]);
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Registration Request (prototype `screens.teamRequestDetail`): the organizer
// accepts or rejects one club's request — a real decision, not a demo.
// ---------------------------------------------------------------------------

class TeamRequestDetailScreen extends ConsumerStatefulWidget {
  const TeamRequestDetailScreen({super.key, required this.tournamentId, required this.registrationId});
  final String tournamentId;
  final String registrationId;

  @override
  ConsumerState<TeamRequestDetailScreen> createState() => _TeamRequestDetailScreenState();
}

class _TeamRequestDetailScreenState extends ConsumerState<TeamRequestDetailScreen> {
  bool _busy = false;

  Future<void> _decide(String name, {required bool approve}) async {
    if (_busy) return;
    setState(() => _busy = true);
    final decision =
        await ref.read(tournamentRegistrationsProvider.notifier).decide(widget.registrationId, approve: approve);
    if (!mounted) return;
    setState(() => _busy = false);
    showCeToast(context, switch (decision) {
      RegistrationDecision.approved => '$name accepted',
      RegistrationDecision.rejected => '$name rejected',
      RegistrationDecision.full => 'Tournament is full',
      RegistrationDecision.closed => 'Fixtures are already generated',
      RegistrationDecision.notPending => 'This request has already been decided',
      RegistrationDecision.notFound => 'Request not found',
    });
    context.go(Routes.tournamentTeamsManage(widget.tournamentId));
  }

  @override
  Widget build(BuildContext context) {
    final manage = Routes.tournamentTeamsManage(widget.tournamentId);
    return TournamentScaffold(
      tournamentId: widget.tournamentId,
      title: 'Registration Request',
      access: TournamentAccess.host,
      fallbackLocation: manage,
      builder: (context, t) {
        final r = ref.watch(registrationProvider(widget.registrationId));
        if (r == null || r.tournamentId != t.id) {
          return CeEmptyState(
            icon: 'clipboard-list',
            title: 'Request not found',
            body: 'This registration request is no longer available.',
            primaryLabel: 'Back to Manage Teams',
            onPrimary: () => context.go(manage),
          );
        }
        final club = ref.watch(tournamentClubsProvider)[r.clubId];
        final s = club?.summary;
        final name = club?.name ?? r.teamName;
        return ListView(padding: const EdgeInsets.only(bottom: 28), children: [
          CeCard(
            margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 16, CeSpace.gutter, 0),
            child: Row(children: [
              TournamentClubBadge(clubId: r.clubId, fallbackName: name, size: 50),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: CeColors.ink)),
                  const SizedBox(height: 3),
                  Row(children: [
                    Icon(CeIcons.of('map-pin'), size: 13, color: CeColors.muted),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(club?.city ?? '—', style: const TextStyle(fontSize: 12, color: CeColors.muted)),
                    ),
                  ]),
                ]),
              ),
            ]),
          ),
          CeSummaryCard(margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0), rows: [
            ('Club Name', CeSummaryCard.value(context, name)),
            ('City', CeSummaryCard.value(context, club?.city ?? '—')),
            ('Captain', CeSummaryCard.value(context, s?.captain.name ?? '—')),
            ('Win %', CeSummaryCard.value(context, s == null ? '—' : '${s.winRate}%')),
            ('Requested', CeSummaryCard.value(context, CeFormat.date(r.submittedAt))),
          ]),
          if (s != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 14, CeSpace.gutter, 0),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  const Expanded(child: Text('Win Rate', style: TextStyle(fontSize: 12, color: CeColors.muted))),
                  Text('${s.winRate}%',
                      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: CeColors.ink)),
                ]),
                const SizedBox(height: 6),
                Semantics(
                  label: 'Win rate ${s.winRate} percent',
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: s.winRate / 100,
                      minHeight: 7,
                      backgroundColor: CeColors.mint2,
                      color: CeColors.primaryDark,
                    ),
                  ),
                ),
              ]),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 24, CeSpace.gutter, 0),
            child: r.isPending
                ? Row(children: [
                    Expanded(
                      child: CeButton.danger(
                        label: 'Reject',
                        icon: CeIcons.of('x'),
                        onPressed: _busy ? null : () => _decide(name, approve: false),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: CeButton(
                        label: 'Accept',
                        icon: CeIcons.of('check'),
                        loading: _busy,
                        onPressed: _busy ? null : () => _decide(name, approve: true),
                      ),
                    ),
                  ])
                : Center(child: RegistrationStatusChip(r.status)),
          ),
        ]);
      },
    );
  }
}
