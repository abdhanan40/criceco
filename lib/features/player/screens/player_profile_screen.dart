import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers/core_providers.dart';
import '../../../app/router/routes.dart';
import '../../../app/session/session_controller.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/constants/cities.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/utils/validators.dart';
import '../../../shared/widgets/ce_availability.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_indicators.dart';
import '../../../shared/widgets/ce_inputs.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import '../player_providers.dart';


/// Player Profile (prototype `screens.playerProfile`, :8052) with Edit
/// Profile (:8223) folded in as an inline edit mode — consolidation Phase A.
///
/// * `/player/profile` → view mode; `/player/profile?edit=1` (and the legacy
///   `/player/profile/edit`, which redirects here) → edit mode.
/// * Edit mode swaps the Details rows for the form; the hero and Career stay.
/// * Save validates and writes the account; Cancel / Back discard the edit.
class PlayerProfileScreen extends ConsumerStatefulWidget {
  const PlayerProfileScreen({super.key, this.editing = false});

  /// Open in edit mode (route `?edit=1`).
  final bool editing;

  @override
  ConsumerState<PlayerProfileScreen> createState() => _PlayerProfileScreenState();
}

class _PlayerProfileScreenState extends ConsumerState<PlayerProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  String? _city;
  bool _editing = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (widget.editing) _startEdit();
  }

  @override
  void didUpdateWidget(covariant PlayerProfileScreen old) {
    super.didUpdateWidget(old);
    if (widget.editing && !old.editing && !_editing) _startEdit();
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  /// Accounts created with an email may not have a phone number yet.
  bool get _phoneRequired => ref.read(currentAccountProvider)?.contactMethod != ContactMethod.email;

  void _startEdit() {
    final a = ref.read(currentAccountProvider);
    _name.text = a?.fullName ?? '';
    _phone.text = a?.phone ?? '';
    _city = kPakistanCities.contains(a?.city) ? a?.city : null;
    if (mounted) {
      setState(() => _editing = true);
    } else {
      _editing = true;
    }
  }

  /// Leave edit mode without saving: the typed values are dropped, the
  /// account is untouched. Clears a `?edit=1` query so a rebuild can't
  /// re-enter edit mode.
  void _endEdit() {
    FocusScope.of(context).unfocus();
    setState(() => _editing = false);
    if (widget.editing) context.go(Routes.playerProfile);
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final phone = _phone.text.trim().isEmpty ? null : formatPkPhone(CeValidators.normalizePkPhone(_phone.text)!);
    await ref.read(sessionProvider.notifier).updateAccount(
          (a) => a.copyWith(fullName: _name.text.trim(), city: _city, phone: phone),
        );
    // A player listed as available is shown to clubs with the new details.
    if (ref.read(playerAvailabilityProvider).openToOffers) {
      await ref.read(playerAvailabilityProvider.notifier).setOpenToOffers(true);
    }
    if (!mounted) return;
    setState(() => _saving = false);
    showCeToast(context, 'Profile updated');
    _endEdit();
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(currentAccountProvider);
    final name = account?.fullName ?? 'Player';
    // Profile attributes (position, skill level, verified) — keyed by the
    // account, never the editable name.
    final s = ref.watch(playerStatsProvider(account?.id ?? name));
    // Career numbers: the same source as the Dashboard and My Performance.
    final perf = ref.watch(performanceProvider).value;
    final club = ref.watch(playerClubProvider);
    final availability = ref.watch(playerAvailabilityProvider.select((a) => a.status));
    final position = account?.playerProfile.role?.label ?? s.position;

    return PopScope(
      canPop: !_editing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _editing) _endEdit();
      },
      child: Scaffold(
        appBar: CeTopBar(
          title: 'My Profile',
          onBack: _editing ? _endEdit : () => context.go(Routes.playerHome),
          actions: [
            TextButton(
              onPressed: _editing ? _endEdit : _startEdit,
              child: Text(_editing ? 'Cancel' : 'Edit'),
            ),
          ],
        ),
        body: GestureDetector(
          onTap: () => FocusScope.of(context).unfocus(),
          behavior: HitTestBehavior.translucent,
          child: ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: EdgeInsets.only(bottom: 24 + MediaQuery.viewInsetsOf(context).bottom),
            children: [
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
                    ('${perf?.matches ?? '—'}', 'Matches'),
                    ('${perf?.runs ?? '—'}', 'Runs'),
                    (perf?.battingAverage ?? '—', 'Average'),
                    (perf?.rating ?? '—', 'Rating'),
                  ].indexed) ...[
                    if (i > 0) const SizedBox(width: 8),
                    Expanded(child: _CareerCell(value: v, label: l)),
                  ],
                ]),
              ),
              CeSectionHeader(_editing ? 'Edit Details' : 'Details'),
              if (_editing)
                _EditForm(
                  formKey: _formKey,
                  name: _name,
                  phone: _phone,
                  city: _city,
                  phoneRequired: _phoneRequired,
                  onCity: (c) => setState(() => _city = c),
                  onSubmit: _save,
                  clubCode: club.code,
                  availability: availability,
                )
              else
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
                child: _editing
                    ? Column(children: [
                        CeButton(label: 'Save Changes', loading: _saving, onPressed: _saving ? null : _save),
                        const SizedBox(height: 10),
                        CeButton.soft(label: 'Cancel', onPressed: _saving ? null : _endEdit),
                      ])
                    : Column(children: [
                        CeButton(label: 'View Full Performance', onPressed: () => context.go(Routes.myPerformance)),
                        const SizedBox(height: 10),
                        CeButton.soft(label: 'Update Availability', onPressed: () => context.go(Routes.availability)),
                      ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Edit mode: the editable Details become fields (same validators as the
/// former Edit Profile screen); Club and Availability stay read-only.
class _EditForm extends StatelessWidget {
  const _EditForm({
    required this.formKey,
    required this.name,
    required this.phone,
    required this.city,
    required this.phoneRequired,
    required this.onCity,
    required this.onSubmit,
    required this.clubCode,
    required this.availability,
  });

  final GlobalKey<FormState> formKey;
  final TextEditingController name;
  final TextEditingController phone;
  final String? city;
  final bool phoneRequired;
  final ValueChanged<String> onCity;
  final VoidCallback onSubmit;
  final String clubCode;
  final PlayerAvailability availability;

  @override
  Widget build(BuildContext context) => CeCard(
        margin: const EdgeInsets.symmetric(horizontal: CeSpace.gutter),
        padding: const EdgeInsets.fromLTRB(14, 16, 14, 4),
        child: Form(
          key: formKey,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const CeFieldLabel('Full name', required: true),
            CeTextField(
              fieldKey: const Key('edit.name'),
              controller: name,
              hint: 'Muhammad Ali',
              icon: 'user',
              maxLength: 40,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.name],
              validator: CeValidators.personName,
            ),
            const CeFieldLabel('City', required: true),
            CeSelectField<String>(
              fieldKey: const Key('edit.city'),
              items: kPakistanCities,
              value: city,
              labelOf: (c) => c,
              onChanged: onCity,
              sheetTitle: 'City',
              hint: 'Select city',
              icon: 'map-pin',
              itemIcon: 'building-2',
              validator: (c) => c == null ? 'Please select a city' : null,
            ),
            CeFieldLabel('Phone', required: phoneRequired),
            CeTextField(
              fieldKey: const Key('edit.phone'),
              controller: phone,
              hint: '03XX-XXXXXXX',
              icon: 'phone',
              keyboardType: TextInputType.phone,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.telephoneNumber],
              validator: (v) => (!phoneRequired && (v == null || v.trim().isEmpty)) ? null : CeValidators.pkPhone(v),
              onFieldSubmitted: (_) => onSubmit(),
            ),
            _DetailRow(icon: 'shield', label: 'Club', value: Text(clubCode, style: _DetailRow.valueStyle)),
            _DetailRow(
              icon: 'check-circle',
              label: 'Availability',
              value: CeStatusChip(availability.label, tone: availabilityTone(availability)),
              last: true,
            ),
          ]),
        ),
      );
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
          border: last ? null : const Border(bottom: BorderSide(color: CeColors.hairline)),
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
