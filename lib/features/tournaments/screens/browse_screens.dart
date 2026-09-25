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
import '../../../shared/widgets/ce_inputs.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import '../../matches/lineup_controller.dart';
import '../../matches/widgets/lineup_widgets.dart';
import '../registration_draft.dart';
import '../tournaments_controller.dart';
import '../widgets/tournament_widgets.dart';

// ---------------------------------------------------------------------------
// Browse Tournaments (prototype `screens.browseTournaments`, :4667). The
// city filter lives in `?city=`; my own hosted tournaments are never listed.
// ---------------------------------------------------------------------------

class BrowseTournamentsScreen extends ConsumerStatefulWidget {
  const BrowseTournamentsScreen({super.key, this.city});

  /// `?city=`; when absent, the last city picked (Back from a tournament).
  final String? city;

  @override
  ConsumerState<BrowseTournamentsScreen> createState() => _BrowseTournamentsScreenState();
}

class _BrowseTournamentsScreenState extends ConsumerState<BrowseTournamentsScreen> {
  @override
  void initState() {
    super.initState();
    _remember();
  }

  @override
  void didUpdateWidget(covariant BrowseTournamentsScreen old) {
    super.didUpdateWidget(old);
    if (old.city != widget.city) _remember();
  }

  void _remember() {
    final city = widget.city;
    if (city != null) Future.microtask(() => ref.read(browseCityProvider.notifier).select(city));
  }

  @override
  Widget build(BuildContext context) {
    final loading = ref.watch(tournamentsProvider).isLoading;
    final cities = ref.watch(browseCitiesProvider);
    final city = widget.city ?? ref.watch(browseCityProvider);
    final selected = cities.contains(city) ? city : null;
    final visible = [for (final t in ref.watch(browseTournamentsProvider)) if (t.city == selected) t];

    return Scaffold(
      appBar: const CeTopBar(title: 'Browse Tournaments', fallbackLocation: Routes.tournamentHub),
      body: ListView(padding: const EdgeInsets.only(bottom: 28), children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 14, CeSpace.gutter, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const CeFieldLabel('City'),
            CeSelectField<String>(
              fieldKey: const Key('browse.city'),
              items: cities,
              value: selected,
              labelOf: (c) => c,
              onChanged: (c) => context.go(Routes.browseTournamentsIn(c)),
              sheetTitle: 'City',
              hint: 'Select City',
              icon: 'map-pin',
              itemIcon: 'building-2',
            ),
          ]),
        ),
        if (loading)
          const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
        else if (selected == null)
          const CeEmptyState(
            icon: 'trophy',
            title: 'Choose a city',
            body: 'Select a city above to see open tournaments there.',
          )
        else ...[
          CeSectionHeader('Open Tournaments in $selected · ${visible.length}',
              padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 4, CeSpace.gutter, 10)),
          if (visible.isEmpty)
            CeEmptyState(
              icon: 'trophy',
              title: 'No tournaments in $selected',
              body: 'Check back later or try another city.',
            )
          else
            for (final t in visible) TournamentBrowseCard(tournament: t),
        ],
      ]),
    );
  }
}

/// `tournamentBrowseCard`: summary grid + Register Team / View Registration.
class TournamentBrowseCard extends ConsumerWidget {
  const TournamentBrowseCard({super.key, required this.tournament});
  final Tournament tournament;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = tournament;
    final reg = ref.watch(activeRegistrationProvider(t.id));
    final open = t.acceptsRegistrationsAt(ref.read(clockProvider).now());
    return CeCard(
      margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 0, CeSpace.gutter, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TournamentCardHeader(
          tournament: t,
          subtitle: '${organizerName(ref, t)} · ${t.city}',
          trailing: TournamentStatusChip(t),
        ),
        const SizedBox(height: 12),
        TournamentInfoGrid(items: [
          ('Format', t.format.display(t.customOvers)),
          ('Type', t.type.label),
          ('Prize Pool', rupeesOrDash(t.prize)),
          ('Entry Fee', rupeesOrDash(t.entryFee)),
          ('Registered Teams', '${t.joined.length} / ${t.maxTeams} Teams'),
          ('Reg. Deadline', CeFormat.date(t.registrationDeadline)),
        ]),
        const SizedBox(height: 12),
        if (reg != null) ...[
          // Your registration's status, right on the card.
          Row(children: [
            const Text('Your registration', style: TextStyle(fontSize: 12, color: CeColors.muted)),
            const SizedBox(width: 8),
            // Flexible: a long status ellipsizes instead of overflowing.
            Expanded(child: Align(alignment: Alignment.centerRight, child: RegistrationStatusChip(reg.status))),
          ]),
          const SizedBox(height: 10),
          CeButton.soft(
            label: 'View Registration',
            onPressed: () => context.go(Routes.registrationDetails(reg.id)),
          ),
        ] else
          CeButton(
            label: open ? 'Register Team' : 'View Tournament',
            onPressed: () => context.go(Routes.tournamentRegister(t.id)),
          ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Tournament Details for a participant (prototype `screens.tournamentRegister`,
// :7236): the tournament, its rules and clubs, then Continue Registration.
// ---------------------------------------------------------------------------

class TournamentRegisterScreen extends ConsumerWidget {
  const TournamentRegisterScreen({super.key, required this.tournamentId});
  final String tournamentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return TournamentScaffold(
      tournamentId: tournamentId,
      title: 'Tournament Details',
      access: TournamentAccess.participant,
      fallbackLocation: Routes.browseTournaments,
      builder: (context, t) {
        final now = ref.read(clockProvider).now();
        final reg = ref.watch(activeRegistrationProvider(t.id));
        final rejectedBefore = reg == null &&
            ref.watch(myRegistrationsProvider).any((r) => r.tournamentId == t.id && r.status == RegistrationStatus.rejected);
        final status = t.statusAt(now);
        return ListView(padding: const EdgeInsets.only(bottom: 28), children: [
          TournamentHero(tournament: t, showBadge: false),
          CeSummaryCard(margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 14, CeSpace.gutter, 0), rows: [
            ('Tournament Name', CeSummaryCard.value(context, t.name)),
            ('Organizer Club', CeSummaryCard.value(context, organizerName(ref, t))),
            ('City', CeSummaryCard.value(context, t.city)),
            ('Ground', CeSummaryCard.value(context, t.ground)),
            ('Format', CeSummaryCard.value(context, t.format.display(t.customOvers))),
            ('Type', CeSummaryCard.value(context, t.type.label)),
            ('Prize Pool', CeSummaryCard.value(context, rupeesOrDash(t.prize))),
            ('Entry Fee', CeSummaryCard.value(context, rupeesOrDash(t.entryFee))),
            ('Maximum Teams', CeSummaryCard.value(context, '${t.maxTeams}')),
            ('Registered Teams', CeSummaryCard.value(context, '${t.joined.length}/${t.maxTeams}')),
            ('Available Slots', CeSummaryCard.value(context, '${t.availableSlots}')),
            ('Registration Deadline', CeSummaryCard.value(context, CeFormat.date(t.registrationDeadline))),
            ('Start Date', CeSummaryCard.value(context, CeFormat.date(t.startDate))),
            ('Status', TournamentStatusChip(t)),
          ]),
          if (t.description.isNotEmpty) ...[
            const CeSectionHeader('Description'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
              child: Text(t.description, style: const TextStyle(fontSize: 13, color: CeColors.ink, height: 1.55)),
            ),
          ],
          if (t.rules.isNotEmpty) ...[
            const CeSectionHeader('Rules'),
            _RulesBox(rules: t.rules),
          ],
          CeSectionHeader('Participating Clubs · ${t.joined.length}'),
          if (t.joined.isEmpty)
            const TournamentEmptyNote('No clubs registered yet')
          else
            for (final e in t.joined) EntrantRow(clubId: e.clubId, name: e.displayName, subtitle: confirmedSubtitle(ref, e)),
          Padding(
            padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 10, CeSpace.gutter, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (reg != null) ...[
                CeSummaryCard(margin: const EdgeInsets.only(bottom: 10), rows: [
                  ('Your Team', CeSummaryCard.value(context, reg.teamName)),
                  ('Status', RegistrationStatusChip(reg.status)),
                ]),
                CeButton.soft(
                  label: 'View Registration',
                  onPressed: () => context.go(Routes.registrationDetails(reg.id)),
                ),
              ] else if (t.acceptsRegistrationsAt(now)) ...[
                if (rejectedBefore)
                  const CeInfoNote(
                    margin: EdgeInsets.only(bottom: 10),
                    text: 'Your previous registration was not approved. You can register a different team.',
                  ),
                CeButton(
                  label: 'Continue Registration',
                  trailingIcon: CeIcons.of('arrow-right'),
                  onPressed: () => context.go(Routes.tournamentTeam(t.id)),
                ),
              ] else
                CeInfoNote(
                  icon: 'lock',
                  margin: EdgeInsets.zero,
                  text: switch (status) {
                    TournamentStatus.completed => 'This tournament has finished.',
                    _ when t.isFull || status == TournamentStatus.registrationFull =>
                      'Registration is full — no slots are left.',
                    _ => 'Registration for this tournament has closed.',
                  },
                ),
            ]),
          ),
        ]);
      },
    );
  }
}

class _RulesBox extends StatelessWidget {
  const _RulesBox({required this.rules});
  final List<String> rules;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.row)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final r in rules)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Padding(
                  padding: EdgeInsets.only(top: 6, right: 8),
                  child: SizedBox(
                    width: 5,
                    height: 5,
                    child: DecoratedBox(decoration: BoxDecoration(color: CeColors.primaryDark, shape: BoxShape.circle)),
                  ),
                ),
                Expanded(child: Text(r, style: const TextStyle(fontSize: 12.5, color: CeColors.ink2, height: 1.45))),
              ]),
            ),
        ]),
      );
}

// ---------------------------------------------------------------------------
// Tournament line-up: Select Team → Build | Pick → Registration Summary.
// The shared line-up flow with a `TournamentEntryTarget` (prototype
// `teamSelectionContext = 'tournament'`).
// ---------------------------------------------------------------------------

/// Registration can't continue: already registered, full or closed.
Widget? _registrationBlocked(BuildContext context, WidgetRef ref, Tournament t) {
  final reg = ref.watch(activeRegistrationProvider(t.id));
  if (reg != null) {
    return CeEmptyState(
      icon: 'clipboard-list',
      title: 'Already registered',
      body: 'Your club has registered ${reg.teamName} for this tournament.',
      primaryLabel: 'View Registration',
      onPrimary: () => context.go(Routes.registrationDetails(reg.id)),
    );
  }
  if (!t.acceptsRegistrationsAt(ref.read(clockProvider).now())) {
    return CeEmptyState(
      icon: 'lock',
      title: 'Registration closed',
      body: 'This tournament is no longer accepting registrations.',
      primaryLabel: 'Back to Tournament',
      onPrimary: () => context.go(Routes.tournamentRegister(t.id)),
    );
  }
  return null;
}

class TournamentSelectTeamScreen extends ConsumerWidget {
  const TournamentSelectTeamScreen({super.key, required this.tournamentId});
  final String tournamentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final target = TournamentEntryTarget(tournamentId);
    return TournamentScaffold(
      tournamentId: tournamentId,
      title: 'Select Team',
      access: TournamentAccess.participant,
      fallbackLocation: Routes.tournamentRegister(tournamentId),
      builder: (context, t) {
        final blocked = _registrationBlocked(context, ref, t);
        if (blocked != null) return blocked;
        final draft = ref.watch(lineupDraftProvider(target));
        final lineup = ref.watch(registrationDraftProvider(t.id)).lineup;
        return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
          LineupIntroCard(icon: 'trophy', title: 'Almost there!', body: 'Now pick your squad for ${t.name}.'),
          if (draft.dirty) UnsavedLineupBanner(onContinue: () => context.go(Routes.tournamentTeamBuild(t.id))),
          if (lineup != null) ...[
            const CeSectionHeader('Selected Team'),
            LineupCard(lineup: lineup),
            Padding(
              padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
              child: CeButton(
                label: 'Continue to Summary',
                trailingIcon: CeIcons.of('arrow-right'),
                onPressed: () => context.go(Routes.registrationSummary(t.id)),
              ),
            ),
          ],
          CeSectionHeader(lineup == null ? 'Choose Your Team' : 'Or Choose Another Team'),
          LineupOptions(
            target: target,
            onBuild: () => context.go(Routes.tournamentTeamBuild(t.id)),
            onPick: () => context.go(Routes.tournamentTeamPick(t.id)),
          ),
        ]);
      },
    );
  }
}

class TournamentTeamBuilderScreen extends ConsumerWidget {
  const TournamentTeamBuilderScreen({super.key, required this.tournamentId});
  final String tournamentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final target = TournamentEntryTarget(tournamentId);
    return TournamentScaffold(
      tournamentId: tournamentId,
      title: 'Build Your Team',
      access: TournamentAccess.participant,
      fallbackLocation: Routes.tournamentTeam(tournamentId),
      onBack: () => context.go(Routes.tournamentTeam(tournamentId)),
      actions: [LineupDiscardAction(target: target)],
      builder: (context, t) =>
          _registrationBlocked(context, ref, t) ??
          LineupBuilderView(
            target: target,
            onConfirmed: () {
              showCeToast(context, 'Team confirmed!');
              context.go(Routes.registrationSummary(t.id)); // prototype `assignTeamToRegistration`
            },
          ),
    );
  }
}

class TournamentTeamPickerScreen extends ConsumerWidget {
  const TournamentTeamPickerScreen({super.key, required this.tournamentId});
  final String tournamentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return TournamentScaffold(
      tournamentId: tournamentId,
      title: 'Select Existing Team',
      access: TournamentAccess.participant,
      fallbackLocation: Routes.tournamentTeam(tournamentId),
      onBack: () => context.go(Routes.tournamentTeam(tournamentId)),
      builder: (context, t) =>
          _registrationBlocked(context, ref, t) ??
          LineupTeamPickerView(
            target: TournamentEntryTarget(t.id),
            intro: "Choose which of your club's teams will enter this tournament.",
            initialTeamId: ref.read(registrationDraftProvider(t.id)).lineup?.sourceTeamId,
            onGoToTeams: () => context.go(Routes.teams),
            onConfirmed: (leftOut) {
              showCeToast(context, teamConfirmedToast(leftOut));
              context.go(Routes.registrationSummary(t.id));
            },
          ),
    );
  }
}

// ---------------------------------------------------------------------------
// Registration Summary (prototype `screens.registrationSummary`, :7289).
// Submit REPLACES the flow with Registration Success.
// ---------------------------------------------------------------------------

class RegistrationSummaryScreen extends ConsumerStatefulWidget {
  const RegistrationSummaryScreen({super.key, required this.tournamentId});
  final String tournamentId;

  @override
  ConsumerState<RegistrationSummaryScreen> createState() => _RegistrationSummaryScreenState();
}

class _RegistrationSummaryScreenState extends ConsumerState<RegistrationSummaryScreen> {
  bool _saving = false;
  String? _error;

  Future<void> _submit() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await ref.read(tournamentRegistrationsProvider.notifier).submit(widget.tournamentId);
    if (!mounted) return;
    final reg = result.registration;
    if (reg == null) {
      setState(() {
        _saving = false;
        _error = result.error;
      });
      return;
    }
    context.go(Routes.registrationSuccess(reg.id));
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.tournamentId;
    return TournamentScaffold(
      tournamentId: id,
      title: 'Registration Summary',
      access: TournamentAccess.participant,
      fallbackLocation: Routes.tournamentTeam(id),
      onBack: () => context.go(Routes.tournamentTeam(id)),
      builder: (context, t) {
        final draft = ref.watch(registrationDraftProvider(id));
        final lineup = draft.lineup;
        if (_saving == false) {
          final blocked = _registrationBlocked(context, ref, t);
          if (blocked != null) return blocked;
        }
        if (lineup == null) {
          return CeEmptyState(
            icon: 'shield',
            title: 'Pick your team first',
            body: 'Choose the squad your club will enter before submitting.',
            primaryLabel: 'Select Team',
            onPrimary: () => context.go(Routes.tournamentTeam(id)),
          );
        }
        return ListView(padding: const EdgeInsets.only(bottom: 28), children: [
          CeSummaryCard(margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 16, CeSpace.gutter, 0), rows: [
            ('Tournament', CeSummaryCard.value(context, t.name)),
            ('Selected Team', CeSummaryCard.value(context, lineup.name)),
            ('Entry Fee', CeSummaryCard.value(context, rupeesOrDash(t.entryFee))),
            ('Prize Pool', CeSummaryCard.value(context, rupeesOrDash(t.prize))),
            ('Tournament Dates', CeSummaryCard.value(context, tournamentDates(t))),
            ('Organizer Club', CeSummaryCard.value(context, organizerName(ref, t))),
            ('Registration Deadline', CeSummaryCard.value(context, CeFormat.date(t.registrationDeadline))),
          ]),
          Padding(
            padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 14, CeSpace.gutter, 0),
            child: _AgreeRow(
              value: draft.agreed,
              onChanged: (v) {
                ref.read(registrationDraftProvider(id).notifier).setAgreed(v);
                if (_error != null) setState(() => _error = null);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (_error != null) CeErrorBanner(_error!),
              CeButton(
                label: 'Submit Registration',
                loading: _saving,
                onPressed: _saving ? null : _submit,
              ),
            ]),
          ),
        ]);
      },
    );
  }
}

/// `.agree-row`: "I agree to the tournament rules."
class _AgreeRow extends StatelessWidget {
  const _AgreeRow({required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Semantics(
        checked: value,
        label: 'I agree to the tournament rules.',
        excludeSemantics: true,
        child: InkWell(
          borderRadius: BorderRadius.circular(CeRadius.md),
          onTap: () => onChanged(!value),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Row(children: [
              AnimatedContainer(
                duration: CeMotion.fast,
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: value ? CeColors.primary : Colors.white,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: value ? CeColors.primary : CeColors.line2, width: 1.5),
                ),
                child: value ? Icon(CeIcons.of('check'), size: 14, color: Colors.white) : null,
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text('I agree to the tournament rules.',
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: CeColors.ink)),
              ),
            ]),
          ),
        ),
      );
}
