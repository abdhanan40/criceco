import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers/core_providers.dart';
import '../../../app/router/routes.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/constants/cities.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_calendar.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_indicators.dart';
import '../../../shared/widgets/ce_inputs.dart';
import '../../../shared/widgets/ce_match_widgets.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import '../tournaments_controller.dart';

enum _DateField { start, end, deadline }

/// Create Tournament (prototype `screens.createTournament`, :4582). The
/// prototype's toast-only validation becomes inline errors; the organizer is
/// always the owner's own club. "Publish Tournament" REPLACES this screen
/// with Tournament Published, so Back never returns to an emptied form.
class CreateTournamentScreen extends ConsumerStatefulWidget {
  const CreateTournamentScreen({super.key});

  @override
  ConsumerState<CreateTournamentScreen> createState() => _CreateTournamentScreenState();
}

class _CreateTournamentScreenState extends ConsumerState<CreateTournamentScreen> {
  final _name = TextEditingController();
  final _ground = TextEditingController();
  final _overs = TextEditingController();
  final _entryFee = TextEditingController();
  final _prize = TextEditingController();
  final _maxTeams = TextEditingController();
  final _description = TextEditingController();
  String? _city;
  MatchFormat? _format;
  TournamentType? _type;
  final _dates = <_DateField, DateTime>{};
  _DateField? _openPicker;
  late DateTime _month;
  bool _saving = false;
  Map<String, String> _errors = {};

  DateTime get _today => CeFormat.dateOnly(ref.read(clockProvider).now());

  @override
  void initState() {
    super.initState();
    _month = _today;
  }

  @override
  void dispose() {
    for (final c in [_name, _ground, _overs, _entryFee, _prize, _maxTeams, _description]) {
      c.dispose();
    }
    super.dispose();
  }

  TournamentInput get _input => TournamentInput(
        name: _name.text,
        city: _city,
        ground: _ground.text,
        format: _format,
        customOvers: int.tryParse(_overs.text),
        type: _type,
        startDate: _dates[_DateField.start],
        endDate: _dates[_DateField.end],
        registrationDeadline: _dates[_DateField.deadline],
        entryFee: int.tryParse(_entryFee.text),
        prize: int.tryParse(_prize.text),
        maxTeams: int.tryParse(_maxTeams.text),
        description: _description.text,
      );

  void _clear(String key) {
    if (_errors.containsKey(key)) setState(() => _errors = {..._errors}..remove(key));
  }

  Future<void> _publish() async {
    FocusScope.of(context).unfocus();
    final errors = validateTournamentInput(_input, ref.read(clockProvider).now());
    setState(() => _errors = errors);
    if (errors.isNotEmpty) {
      showCeToast(context, errors.values.first);
      return;
    }
    setState(() => _saving = true);
    final t = await ref.read(tournamentsProvider.notifier).create(_input);
    if (!mounted) return;
    context.go(Routes.tournamentPublished(t.id));
  }

  Widget _label(String t, {bool required = true}) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: CeFieldLabel(t, required: required),
      );

  Widget _date(_DateField field, String label, {String icon = 'calendar', required String errorKey}) {
    final value = _dates[field];
    final open = _openPicker == field;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _label(label),
      CeDateRow(
        label: label,
        icon: icon,
        date: value,
        open: open,
        hasError: _errors.containsKey(errorKey),
        onTap: () => setState(() {
          _openPicker = open ? null : field;
          if (!open) _month = value ?? _dates[_DateField.start] ?? _today;
        }),
      ),
      CeInlineError(_errors[errorKey]),
      if (open)
        CeMonthCalendar(
          margin: const EdgeInsets.only(top: 8),
          visibleMonth: _month,
          today: _today,
          selected: value,
          isEnabled: (d) => !d.isBefore(_today),
          onMonthChanged: (m) => setState(() => _month = m),
          onSelected: (d) {
            setState(() {
              _dates[field] = d;
              _openPicker = null;
            });
            _clear(errorKey);
          },
        ),
      const SizedBox(height: 14),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final digits = [FilteringTextInputFormatter.digitsOnly];
    return Scaffold(
      appBar: const CeTopBar(title: 'Create Tournament', fallbackLocation: Routes.tournamentHub),
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        behavior: HitTestBehavior.translucent,
        child: ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: EdgeInsets.fromLTRB(CeSpace.gutter, 14, CeSpace.gutter, 28 + MediaQuery.viewInsetsOf(context).bottom),
          children: [
            // `.new-team-hero`
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
              margin: const EdgeInsets.only(bottom: 14),
              decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.lg)),
              child: const Column(children: [
                CeIconWell('trophy', size: 48, iconSize: 22, background: Colors.white, circle: true),
                SizedBox(height: 8),
                Text('New Tournament', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                SizedBox(height: 2),
                Text('Set up a tournament and invite clubs to compete',
                    textAlign: TextAlign.center, style: TextStyle(fontSize: 12.5, color: CeColors.muted)),
              ]),
            ),

            _label('Tournament Name'),
            CeTextField(
              fieldKey: const Key('tournament.name'),
              controller: _name,
              hint: 'e.g. Islamabad Premier League',
              icon: 'trophy',
              maxLength: 60,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              onChanged: (_) => _clear('name'),
            ),
            CeInlineError(_errors['name']),

            _label('City'),
            CeSelectField<String>(
              fieldKey: const Key('tournament.city'),
              items: kPakistanCities,
              value: _city,
              labelOf: (c) => c,
              onChanged: (c) {
                setState(() => _city = c);
                _clear('city');
              },
              sheetTitle: 'City',
              hint: 'Select city',
              icon: 'map-pin',
              itemIcon: 'building-2',
            ),
            CeInlineError(_errors['city']),

            _label('Ground'),
            CeTextField(
              fieldKey: const Key('tournament.ground'),
              controller: _ground,
              hint: 'e.g. Pindi Cricket Ground',
              icon: 'flag',
              maxLength: 60,
              textCapitalization: TextCapitalization.words,
              onChanged: (_) => _clear('ground'),
            ),
            CeInlineError(_errors['ground']),

            _label('Tournament Format'),
            Wrap(spacing: 7, runSpacing: 7, children: [
              for (final f in MatchFormat.standard)
                CeChip(
                  label: f == MatchFormat.custom ? 'Custom Overs' : f.label,
                  icon: formatIcon(f),
                  selected: f == _format,
                  onTap: () {
                    setState(() => _format = f);
                    _clear('format');
                  },
                ),
            ]),
            CeInlineError(_errors['format']),
            if (_format == MatchFormat.custom) ...[
              const SizedBox(height: 10),
              CeTextField(
                fieldKey: const Key('tournament.overs'),
                controller: _overs,
                hint: 'Number of overs (e.g. 15)',
                icon: 'hash',
                keyboardType: TextInputType.number,
                inputFormatters: [...digits, LengthLimitingTextInputFormatter(2)],
                onChanged: (_) => _clear('overs'),
              ),
              CeInlineError(_errors['overs']),
            ],
            const SizedBox(height: 14),

            _label('Tournament Type'),
            Wrap(spacing: 7, runSpacing: 7, children: [
              for (final t in TournamentType.values)
                CeChip(
                  label: t.label,
                  selected: t == _type,
                  onTap: () {
                    setState(() => _type = t);
                    _clear('type');
                  },
                ),
            ]),
            CeInlineError(_errors['type']),
            const SizedBox(height: 14),

            _date(_DateField.start, 'Start Date', errorKey: 'start'),
            _date(_DateField.end, 'End Date', errorKey: 'end'),
            _date(_DateField.deadline, 'Registration Deadline', icon: 'hourglass', errorKey: 'deadline'),

            _label('Entry Fee', required: false),
            CeTextField(
              fieldKey: const Key('tournament.entryFee'),
              controller: _entryFee,
              hint: 'e.g. 15000',
              icon: 'banknote',
              keyboardType: TextInputType.number,
              inputFormatters: [...digits, LengthLimitingTextInputFormatter(7)],
            ),

            _label('Prize Amount', required: false),
            CeTextField(
              fieldKey: const Key('tournament.prize'),
              controller: _prize,
              hint: 'e.g. 100000',
              icon: 'award',
              keyboardType: TextInputType.number,
              inputFormatters: [...digits, LengthLimitingTextInputFormatter(8)],
            ),

            _label('Maximum Teams'),
            CeTextField(
              fieldKey: const Key('tournament.maxTeams'),
              controller: _maxTeams,
              hint: 'e.g. 8',
              icon: 'users',
              keyboardType: TextInputType.number,
              inputFormatters: [...digits, LengthLimitingTextInputFormatter(2)],
              onChanged: (_) => _clear('maxTeams'),
            ),
            CeInlineError(_errors['maxTeams']),

            _label('Description', required: false),
            CeTextField(
              fieldKey: const Key('tournament.description'),
              controller: _description,
              hint: 'Tell teams about your tournament — rules, venue details, prizes, etc.',
              maxLines: 4,
              maxLength: 500,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              textCapitalization: TextCapitalization.sentences,
            ),

            const SizedBox(height: 8),
            CeButton(
              label: 'Publish Tournament',
              loading: _saving,
              onPressed: _saving ? null : _publish,
            ),
          ],
        ),
      ),
    );
  }
}

/// Tournament Published (prototype `screens.tournamentPublished`, :4651).
/// Terminal: no Back; system Back → the hub. "View Tournament" REPLACES it
/// with Tournament Details (whose Back is My Tournaments).
class TournamentPublishedScreen extends ConsumerWidget {
  const TournamentPublishedScreen({super.key, required this.tournamentId});
  final String tournamentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loading = ref.watch(tournamentsProvider).isLoading;
    final t = ref.watch(tournamentProvider(tournamentId));
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) context.go(Routes.tournamentHub);
      },
      child: Scaffold(
        appBar: const CeTopBar(title: 'Tournament Status', showBack: false),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : t == null
                ? CeEmptyState(
                    icon: 'trophy',
                    title: 'Tournament not found',
                    body: 'This tournament is no longer available.',
                    primaryLabel: 'Back to Tournaments',
                    onPrimary: () => context.go(Routes.tournamentHub),
                  )
                : ListView(padding: const EdgeInsets.only(bottom: 24), children: [
                    CeSuccessPanel(
                      title: 'Tournament Created Successfully',
                      body: Text.rich(
                        TextSpan(children: [
                          TextSpan(text: t.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                          TextSpan(text: ' is now live. Clubs in ${t.city} can start registering their teams.'),
                        ]),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
                      child: Column(children: [
                        CeButton(
                          label: 'View Tournament',
                          trailingIcon: CeIcons.of('arrow-right'),
                          onPressed: () => context.go(Routes.tournamentDetails(t.id)),
                        ),
                        const SizedBox(height: 10),
                        CeButton.soft(label: 'Back to Dashboard', onPressed: () => context.go(Routes.clubHome)),
                      ]),
                    ),
                  ]),
      ),
    );
  }
}
