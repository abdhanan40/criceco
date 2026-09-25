import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../app/session/session_controller.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_indicators.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import '../../../shared/widgets/demo_widgets.dart';
import '../../club/club_providers.dart';
import '../../matches/widgets/lineup_widgets.dart';
import '../tournament_demo_actions.dart';
import '../tournaments_controller.dart';
import '../widgets/tournament_widgets.dart';

// ---------------------------------------------------------------------------
// Registration Success (prototype `screens.registrationSuccess`, :7325).
// Terminal: no Back; system Back → My Registrations (Pending, where the new
// registration is). Both CTAs REPLACE it.
// ---------------------------------------------------------------------------

class RegistrationSuccessScreen extends ConsumerWidget {
  const RegistrationSuccessScreen({super.key, required this.registrationId});
  final String registrationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loading = ref.watch(tournamentRegistrationsProvider).isLoading;
    final reg = ref.watch(registrationProvider(registrationId));
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) context.go(MyRegistrationsScreen.location(RegistrationStatus.pending));
      },
      child: Scaffold(
        appBar: const CeTopBar(title: 'Registration Status', showBack: false),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(padding: const EdgeInsets.only(bottom: 24), children: [
                if (reg == null)
                  const CeEmptyState(
                    icon: 'clipboard-list',
                    title: 'Registration not found',
                    body: 'This registration is no longer available.',
                  )
                else
                  const CeSuccessPanel(
                    title: 'Registration Submitted Successfully!',
                    body: Text('Your registration has been sent to the tournament organizer for approval.'),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
                  child: Column(children: [
                    if (reg != null) ...[
                      CeButton(
                        label: 'View Registration',
                        onPressed: () => context.go(Routes.registrationDetails(reg.id)),
                      ),
                      const SizedBox(height: 10),
                    ],
                    CeButton.soft(
                      label: 'My Registrations',
                      onPressed: () => context.go(MyRegistrationsScreen.location(RegistrationStatus.pending)),
                    ),
                  ]),
                ),
              ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// My Registrations (prototype `screens.myRegistrations`, :7360). Pending /
// Approved / Rejected live in `?tab=`.
// ---------------------------------------------------------------------------

class MyRegistrationsScreen extends ConsumerStatefulWidget {
  const MyRegistrationsScreen({super.key, this.tab});

  /// `?tab=`; when absent, the last tab viewed (Back from a registration).
  final RegistrationStatus? tab;

  static RegistrationStatus? parseTab(String? raw) => RegistrationStatus.values.where((t) => t.name == raw).firstOrNull;

  static String location(RegistrationStatus tab) => Routes.myRegistrationsIn(tab);

  @override
  ConsumerState<MyRegistrationsScreen> createState() => _MyRegistrationsScreenState();
}

class _MyRegistrationsScreenState extends ConsumerState<MyRegistrationsScreen> {
  @override
  void initState() {
    super.initState();
    _remember();
  }

  @override
  void didUpdateWidget(covariant MyRegistrationsScreen old) {
    super.didUpdateWidget(old);
    if (old.tab != widget.tab) _remember();
  }

  void _remember() {
    final tab = widget.tab;
    if (tab != null) Future.microtask(() => ref.read(myRegistrationsTabProvider.notifier).select(tab));
  }

  @override
  Widget build(BuildContext context) {
    final RegistrationStatus tab = widget.tab ?? ref.watch(myRegistrationsTabProvider);
    final loading = ref.watch(tournamentRegistrationsProvider).isLoading || ref.watch(tournamentsProvider).isLoading;
    final list = ref.watch(myRegistrationsByStatusProvider(tab));
    return Scaffold(
      appBar: const CeTopBar(title: 'My Registrations', fallbackLocation: Routes.tournamentHub),
      body: ListView(padding: const EdgeInsets.only(bottom: 28), children: [
        CeChipRow<RegistrationStatus>(
          values: RegistrationStatus.values,
          selected: tab,
          labelOf: (s) => s.label,
          countOf: (s) => ref.watch(myRegistrationsByStatusProvider(s)).length,
          onSelected: (s) => context.go(MyRegistrationsScreen.location(s)),
          padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 14, CeSpace.gutter, 12),
        ),
        if (loading)
          const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
        else if (list.isEmpty)
          CeEmptyState(
            icon: 'trophy',
            title: 'No ${tab.label.toLowerCase()} registrations',
            body: 'Registrations will appear here once submitted.',
          )
        else
          for (final r in list) _RegistrationCard(registration: r),
      ]),
    );
  }
}

class _RegistrationCard extends ConsumerWidget {
  const _RegistrationCard({required this.registration});
  final TournamentRegistration registration;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = registration;
    final t = ref.watch(tournamentProvider(r.tournamentId));
    if (t == null) return const SizedBox.shrink();
    return CeCard(
      margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 0, CeSpace.gutter, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TournamentCardHeader(
          tournament: t,
          subtitle: '${organizerName(ref, t)} · Team: ${r.teamName}',
          trailing: RegistrationStatusChip(r.status),
        ),
        const SizedBox(height: 12),
        TournamentInfoGrid(items: [
          ('Tournament Date', CeFormat.date(t.startDate)),
          ('Prize Pool', rupeesOrDash(t.prize)),
          ('Entry Fee', rupeesOrDash(t.entryFee)),
          ('Submitted', CeFormat.date(r.submittedAt)),
        ]),
        const SizedBox(height: 12),
        CeButton.soft(label: 'View Details', onPressed: () => context.go(Routes.registrationDetails(r.id))),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Registration Details (prototype `screens.registrationDetails`, :7383).
// Pending → awaiting the organizer (Demo: "Simulate Organizer Decision");
// Approved → teams, fixtures, points table, matches; Rejected → note.
// Participant view only: it never opens the host tools.
// ---------------------------------------------------------------------------

class RegistrationDetailsScreen extends ConsumerStatefulWidget {
  const RegistrationDetailsScreen({super.key, required this.registrationId});
  final String registrationId;

  @override
  ConsumerState<RegistrationDetailsScreen> createState() => _RegistrationDetailsScreenState();
}

class _RegistrationDetailsScreenState extends ConsumerState<RegistrationDetailsScreen> {
  bool _busy = false;

  Future<void> _simulateDecision({required bool approve}) async {
    if (_busy) return;
    setState(() => _busy = true);
    final decision =
        await ref.read(tournamentDemoActionsProvider).organizerDecides(widget.registrationId, approve: approve);
    if (!mounted) return;
    setState(() => _busy = false);
    final message = switch (decision) {
      RegistrationDecision.approved => 'Registration approved by organizer!',
      RegistrationDecision.rejected => 'Registration was rejected',
      RegistrationDecision.full => 'Tournament is full',
      RegistrationDecision.closed => 'Fixtures are already out — registration is closed',
      _ => null,
    };
    if (message != null) showCeToast(context, message);
  }

  @override
  Widget build(BuildContext context) {
    final loading = ref.watch(tournamentRegistrationsProvider).isLoading ||
        ref.watch(tournamentsProvider).isLoading ||
        ref.watch(clubDirectoryProvider).isLoading;
    final r = ref.watch(registrationProvider(widget.registrationId));
    final ownClubId = ref.watch(currentClubProvider.select((c) => c?.id));
    final t = r == null ? null : ref.watch(tournamentProvider(r.tournamentId));
    const bar = CeTopBar(title: 'Registration Details', fallbackLocation: Routes.myRegistrations);
    if (loading) return const Scaffold(appBar: bar, body: Center(child: CircularProgressIndicator()));
    if (r == null || t == null || r.clubId != ownClubId) {
      return Scaffold(
        appBar: bar,
        body: CeEmptyState(
          icon: 'clipboard-list',
          title: 'Registration not found',
          body: 'This registration is no longer available.',
          primaryLabel: 'Back to My Registrations',
          onPrimary: () => context.go(Routes.myRegistrations),
        ),
      );
    }

    final header = <Widget>[
      TournamentHero(tournament: t, showBadge: false),
      CeSummaryCard(margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 14, CeSpace.gutter, 0), rows: [
        ('Selected Team', CeSummaryCard.value(context, r.teamName)),
        ('Organizer Club', CeSummaryCard.value(context, organizerName(ref, t))),
        ('Entry Fee', CeSummaryCard.value(context, rupeesOrDash(t.entryFee))),
        ('Prize Pool', CeSummaryCard.value(context, rupeesOrDash(t.prize))),
        ('Tournament Dates', CeSummaryCard.value(context, tournamentDates(t))),
        ('Status', RegistrationStatusChip(r.status)),
      ]),
    ];

    final body = switch (r.status) {
      RegistrationStatus.pending => [
          const CeEmptyState(
            icon: 'hourglass',
            title: 'Pending Approval',
            body: "The organizer is reviewing your registration. You'll be notified once it's approved.",
          ),
          DemoPanel(
            margin: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
            note: 'Simulate Organizer Decision',
            actions: [
              DemoAction('Reject', () => _simulateDecision(approve: false)),
              DemoAction('Approve', () => _simulateDecision(approve: true)),
            ],
          ),
          if (r.lineup != null) ...[const CeSectionHeader('Your Squad'), LineupCard(lineup: r.lineup!)],
        ],
      RegistrationStatus.rejected => [
          CeEmptyState(
            icon: 'x-circle',
            title: 'Registration Rejected',
            body: 'The organizer did not approve this registration. '
                'You can register a different team or explore other tournaments.',
            primaryLabel: 'Browse Tournaments',
            onPrimary: () => context.go(Routes.browseTournamentsIn(t.city)),
          ),
        ],
      RegistrationStatus.approved => _approved(t, r),
    };

    return Scaffold(
      appBar: bar,
      body: ListView(padding: const EdgeInsets.only(bottom: 28), children: [...header, ...body]),
    );
  }

  List<Widget> _approved(Tournament t, TournamentRegistration r) {
    final all = flattenFixtures(t);
    final upcoming = [for (final f in all) if (!f.match.completed) f];
    final completed = [for (final f in all) if (f.match.completed) f];
    return [
      if (t.winnerId != null) WinnerBanner(name: entrantLabel(t, t.winnerId)),
      if (r.lineup != null) ...[const CeSectionHeader('Your Squad'), LineupCard(lineup: r.lineup!)],
      CeSectionHeader('Teams · ${t.joined.length}'),
      for (final e in t.joined)
        EntrantRow(
          clubId: e.clubId,
          name: e.displayName,
          subtitle: confirmedSubtitle(ref, e),
          trailing: e.id == r.id ? const CeStatusChip('You', icon: 'user') : null,
        ),
      const CeSectionHeader('Fixtures / Schedule'),
      if (t.fixtures == null)
        TournamentEmptyNote(fixturesPendingNote(t))
      else
        FixtureRounds(tournament: t),
      const CeSectionHeader('Points Table'),
      PointsTable(tournament: t),
      const CeSectionHeader('Upcoming Matches'),
      if (upcoming.isEmpty)
        const TournamentEmptyNote('No upcoming matches')
      else
        for (final f in upcoming) FixtureCard(tournament: t, fixture: f),
      const CeSectionHeader('Results'),
      if (completed.isEmpty)
        const TournamentEmptyNote('No results yet')
      else
        for (final f in completed) FixtureCard(tournament: t, fixture: f),
    ];
  }
}
