import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers/core_providers.dart';
import '../../../app/router/routes.dart';
import '../../../app/session/account_error_text.dart';
import '../../../app/session/session_controller.dart';
import '../../../app/theme/tokens.dart';
import '../../../app/theme/typography.dart';
import '../../../core/constants/city_areas.dart';
import '../../../core/models/models.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/utils/validators.dart';
import '../../../shared/media/photo_picker.dart';
import '../../../shared/widgets/ce_availability.dart';
import '../../../shared/widgets/ce_buttons.dart';
import '../../../shared/widgets/ce_feedback.dart';
import '../../../shared/widgets/ce_icons.dart';
import '../../../shared/widgets/ce_indicators.dart';
import '../../../shared/widgets/ce_inputs.dart';
import '../../../shared/widgets/ce_surfaces.dart';
import '../../../shared/widgets/ce_top_bar.dart';
import '../../location/area_field.dart';
import '../../location/city_picker.dart';
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
  final _area = TextEditingController();
  // The City as the picker shows it, and as it was when editing began (id 0:
  // a saved city without a database id). Area shows once the City changes.
  CityOption? _city;
  CityOption? _savedCity;
  String _savedArea = '';
  // "Other (type it)" picked in the Area picker before anything was typed.
  bool _areaOther = false;
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
    _area.dispose();
    super.dispose();
  }

  /// Accounts created with an email may not have a phone number yet.
  bool get _phoneRequired => ref.read(currentAccountProvider)?.contactMethod != ContactMethod.email;

  void _startEdit() {
    final a = ref.read(currentAccountProvider);
    _name.text = a?.fullName ?? '';
    _phone.text = a?.phone ?? '';
    // Any saved city (featured or not); its id belongs to the Current City.
    final city = a?.city?.trim();
    _savedCity = city == null || city.isEmpty
        ? null
        : CityOption(id: (city == a?.currentCity?.trim() ? a?.currentCityId : null) ?? 0, name: city);
    _city = _savedCity;
    _savedArea = a?.currentArea ?? '';
    _area.text = _savedArea;
    _areaOther = false;
    if (mounted) {
      setState(() => _editing = true);
    } else {
      _editing = true;
    }
  }

  /// The City differs from the saved one (another id, or another name).
  bool get _cityChanged {
    final c = _city, s = _savedCity;
    if (c == null || s == null) return c != s;
    return c.id != s.id || c.name != s.name;
  }

  /// City picked (City Picker: a different city only). Back to the saved
  /// city → the saved Area again (the Area field hides). Another city keeps
  /// the Area only while it still fits ([CityAreas.keepsArea]), else clears it.
  void _pickCity(CityOption city) {
    final previous = _city?.name;
    final areas = ref.read(cityAreasProvider).value ?? CityAreas.empty;
    setState(() {
      _city = city;
      if (!_cityChanged) {
        _area.text = _savedArea;
        _areaOther = false;
      } else if (!areas.keepsArea(previous, city.name, _area.text)) {
        _area.clear();
        _areaOther = false;
      }
    });
  }

  /// Area picked from the list, or "Other (type it)".
  void _pickArea(String area) {
    final areas = ref.read(cityAreasProvider).value ?? CityAreas.empty;
    setState(() {
      _areaOther = area == kOtherArea;
      _area.text = AreaField.textFor(area, listed: areas.areasFor(_city?.name), typed: _area.text);
    });
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
    if (_saving) return;
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final phone = _phone.text.trim().isEmpty ? null : formatPkPhone(CeValidators.normalizePkPhone(_phone.text)!);
    // A changed City goes with its id (none: a city without one) and the
    // Area shown for it; an unchanged City leaves the address alone.
    final city = _cityChanged ? _city : null;
    final cityId = city != null && city.id > 0 ? city.id : null;
    try {
      await ref.read(sessionProvider.notifier).updateAccount(
            (a) => city == null
                ? a.copyWith(fullName: _name.text.trim(), phone: phone)
                : a.copyWith(
                    fullName: _name.text.trim(),
                    phone: phone,
                    city: city.name,
                    currentCityId: cityId,
                    clearCurrentCityId: cityId == null,
                    currentArea: _area.text.trim(),
                  ),
          );
      // A player listed as available is shown to clubs with the new details.
      if (ref.read(playerAvailabilityProvider).openToOffers) {
        await ref.read(playerAvailabilityProvider.notifier).setOpenToOffers(true);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      if (signOutIfNeeded(context, ref, e)) return;
      showCeToast(context, accountErrorText(e, fallback: "Couldn't save your profile — please try again"));
      return;
    }
    if (!mounted) return;
    setState(() => _saving = false);
    showCeToast(context, 'Profile updated');
    _endEdit();
  }

  /// Add / change / remove the profile picture (works in view and edit mode;
  /// saved on the account right away, independent of the Details form).
  Future<void> _changePhoto() async {
    final hasPhoto = ref.read(currentAccountProvider)?.photoPath != null;
    final change = await choosePhoto(context, ref, title: 'Profile picture', hasPhoto: hasPhoto);
    if (change == null || !mounted) return;
    try {
      await ref.read(sessionProvider.notifier).updateAccount((a) => change.path == null
          ? a.copyWith(hasPhoto: false, clearPhoto: true)
          : a.copyWith(hasPhoto: true, photoPath: change.path));
    } catch (e) {
      if (!mounted) return;
      if (signOutIfNeeded(context, ref, e)) return;
      showCeToast(context, accountErrorText(e, fallback: "Couldn't update your profile picture — please try again"));
      return;
    }
    if (mounted) showCeToast(context, change.path == null ? 'Profile picture removed' : 'Profile picture updated');
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
              // Reference profile structure: identity → stats row → grouped
              // detail rows → actions.
              CeBrandHero(
                margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
                radius: CeRadius.hero,
                padding: const EdgeInsets.all(18),
                child: Row(children: [
                  CeEditablePhoto(
                    key: const Key('profile.photo'),
                    size: 56,
                    semanticLabel: account?.photoPath == null ? 'Add profile picture' : 'Change profile picture',
                    onTap: _changePhoto,
                    child: CePhotoImage(
                      path: account?.photoPath,
                      size: 56,
                      fallback: Container(
                        width: 56,
                        height: 56,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: CeColors.sage,
                          border: Border.all(color: Colors.white.withValues(alpha: 0.1), width: 3),
                        ),
                        child: Text(account?.initial ?? 'A', style: CeType.heroName.copyWith(fontSize: 22, color: CeColors.ink)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: CeType.pageTitle.copyWith(color: Colors.white, height: 1.15)),
                      const SizedBox(height: 4),
                      Text('$position · ${s.skill.label} level',
                          style: CeType.bodySmall.copyWith(fontWeight: FontWeight.w600, color: const Color(0xFFCFE3D2))),
                      if (s.verified) ...[
                        const SizedBox(height: 7),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(color: CeColors.sage, borderRadius: BorderRadius.circular(CeRadius.xs)),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(CeIcons.of('check-circle'), size: 12, color: CeColors.ink),
                            const SizedBox(width: 5),
                            Flexible(
                              child: Text('Verified player',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: CeType.micro.copyWith(fontSize: 11, color: CeColors.ink)),
                            ),
                          ]),
                        ),
                      ],
                    ]),
                  ),
                ]),
              ),
              // Career numbers in one compact stats row under the identity.
              CeStatGroup(
                margin: const EdgeInsets.fromLTRB(CeSpace.gutter, 12, CeSpace.gutter, 0),
                cells: [
                  CeStatCell(value: '${perf?.matches ?? '—'}', label: 'Matches'),
                  CeStatCell(value: '${perf?.runs ?? '—'}', label: 'Runs'),
                  CeStatCell(value: perf?.battingAverage ?? '—', label: 'Average'),
                  CeStatCell(value: perf?.rating ?? '—', label: 'Rating'),
                ],
              ),
              CeSectionHeader(_editing ? 'Edit Details' : 'Details'),
              if (_editing)
                _EditForm(
                  formKey: _formKey,
                  name: _name,
                  phone: _phone,
                  city: _city,
                  phoneRequired: _phoneRequired,
                  onCity: _pickCity,
                  showArea: _cityChanged,
                  areaData: ref.watch(cityAreasProvider).value ?? CityAreas.empty,
                  area: _area,
                  areaOther: _areaOther,
                  onPickArea: _pickArea,
                  onArea: (_) => setState(() {}),
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
                padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 16, CeSpace.gutter, 0),
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
    required this.showArea,
    required this.areaData,
    required this.area,
    required this.areaOther,
    required this.onPickArea,
    required this.onArea,
    required this.onSubmit,
    required this.clubCode,
    required this.availability,
  });

  final GlobalKey<FormState> formKey;
  final TextEditingController name;
  final TextEditingController phone;
  final CityOption? city;
  final bool phoneRequired;
  final ValueChanged<CityOption> onCity;

  /// Area (required) shows once the City changes: kept while it still fits
  /// the new city, else cleared (E1-B). Keys `edit.currentAreaPicker` /
  /// `edit.currentArea`.
  final bool showArea;
  final CityAreas areaData;
  final TextEditingController area;
  final bool areaOther;
  final ValueChanged<String> onPickArea;
  final ValueChanged<String> onArea;
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
            // Searchable nationwide city list (featured cities first; province /
            // district filters in Supabase mode).
            CityPickerField(
              fieldKey: const Key('edit.city'),
              value: city,
              onChanged: onCity,
              sheetTitle: 'City',
              hint: 'Select city',
              icon: 'map-pin',
              validator: (c) => c == null ? 'Please select a city' : null,
            ),
            if (showArea)
              AreaField(
                keyPrefix: 'edit.current',
                areaData: areaData,
                city: city?.name,
                areaValue: area.text,
                otherPicked: areaOther,
                onPickArea: onPickArea,
                controller: area,
                onArea: onArea,
              ),
            CeFieldLabel('Phone', required: phoneRequired),
            CeTextField(
              fieldKey: const Key('edit.phone'),
              controller: phone,
              hint: '03XX-XXXXXXX',
              icon: 'phone',
              keyboardType: TextInputType.phone,
              inputFormatters: kPhoneInputFormatters,
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

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.icon, required this.label, required this.value, this.last = false});
  final String icon;
  final String label;
  final Widget value;
  final bool last;

  static const valueStyle = TextStyle(fontFamily: CeType.ui, fontSize: 13.5, fontWeight: FontWeight.w700, color: CeColors.ink);

  @override
  Widget build(BuildContext context) => Container(
        constraints: const BoxConstraints(minHeight: 50),
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          border: last ? null : const Border(bottom: BorderSide(color: CeColors.hairline)),
        ),
        child: Row(children: [
          CeIconWell(icon, size: 32, iconSize: 15),
          const SizedBox(width: 12),
          Text(label, style: CeType.bodySmall.copyWith(fontSize: 13)),
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
