import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers/core_providers.dart';
import '../../app/router/routes.dart';
import '../../app/session/role_controller.dart';
import '../../app/session/session_controller.dart';
import '../../app/theme/tokens.dart';
import '../../app/theme/typography.dart';
import '../../core/constants/cities.dart';
import '../../core/constants/city_areas.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/validators.dart';
import '../../shared/media/photo_picker.dart';
import '../../shared/widgets/ce_buttons.dart';
import '../../shared/widgets/ce_feedback.dart';
import '../../shared/widgets/ce_form_widgets.dart';
import '../../shared/widgets/ce_inputs.dart';
import '../../shared/widgets/ce_surfaces.dart';
import 'onboarding_controller.dart';
import 'widgets/auth_widgets.dart';

/// User Profile Setup — the common CricEco profile of the account: Full Name,
/// Phone Number, Date of Birth, Profile Picture, Current Address and
/// Permanent Address. No cricket-role questions here; Role Selection comes
/// next.
class UserProfileSetupScreen extends ConsumerStatefulWidget {
  const UserProfileSetupScreen({super.key});

  @override
  ConsumerState<UserProfileSetupScreen> createState() => _UserProfileSetupScreenState();
}

class _UserProfileSetupScreenState extends ConsumerState<UserProfileSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final TextEditingController _dob;
  // Cities are picked from a list and live only in the onboarding draft.
  late final TextEditingController _currentArea;
  late final TextEditingController _currentAddress;
  // Kept while the permanent fields are hidden (Yes), so No brings them back.
  late final TextEditingController _permanentArea;
  late final TextEditingController _permanentAddress;
  // "Other (type it)" picked in the Area picker before anything was typed.
  bool _currentOther = false;
  bool _permanentOther = false;
  bool _saving = false;

  /// City picked: the draft clears an Area that no longer fits — mirror that
  /// in the typed field.
  void _pickCity({required bool current, required String city}) {
    final notifier = ref.read(onboardingProvider.notifier);
    current ? notifier.setCurrentCity(city) : notifier.setPermanentCity(city);
    final d = ref.read(onboardingProvider);
    if ((current ? d.currentArea : d.permanentArea) != null) return;
    setState(() => current ? _currentOther = false : _permanentOther = false);
    (current ? _currentArea : _permanentArea).clear();
  }

  /// Area picked from the list, or "Other (type it)" (keeps a typed area; a
  /// listed one is cleared so the user types their own).
  void _pickArea({required bool current, required String area, required List<String> listed}) {
    final notifier = ref.read(onboardingProvider.notifier);
    final controller = current ? _currentArea : _permanentArea;
    final other = area == kOtherArea;
    setState(() => current ? _currentOther = other : _permanentOther = other);
    final text = other ? (listed.contains(controller.text) ? '' : controller.text) : area;
    controller.text = text;
    current ? notifier.setCurrentArea(text) : notifier.setPermanentArea(text);
  }

  @override
  void initState() {
    super.initState();
    final d = ref.read(onboardingProvider);
    _name = TextEditingController(text: d.fullName);
    _phone = TextEditingController(text: d.phone);
    _dob = TextEditingController(text: d.dateOfBirth == null ? '' : CeFormat.date(d.dateOfBirth!));
    _currentArea = TextEditingController(text: d.currentArea ?? '');
    _currentAddress = TextEditingController(text: d.currentAddress ?? '');
    _permanentArea = TextEditingController(text: d.permanentArea ?? '');
    _permanentAddress = TextEditingController(text: d.permanentAddress ?? '');
  }

  @override
  void dispose() {
    for (final c in [_name, _phone, _dob, _currentArea, _currentAddress, _permanentArea, _permanentAddress]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickDob() async {
    FocusScope.of(context).unfocus();
    final draft = ref.read(onboardingProvider);
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: draft.dateOfBirth ?? DateTime(now.year - 20, now.month, now.day),
      firstDate: DateTime(now.year - 80),
      lastDate: now,
      helpText: 'Date of birth',
    );
    if (picked == null) return;
    ref.read(onboardingProvider.notifier).setDateOfBirth(picked);
    _dob.text = CeFormat.date(picked);
    _formKey.currentState?.validate();
  }

  Future<void> _continue() async {
    if (_saving) return;
    FocusScope.of(context).unfocus();
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    // Stored in the account's display form ("0312 9020000"), as Edit Profile does.
    final phone = formatPkPhone(CeValidators.normalizePkPhone(_phone.text)!);
    try {
      await ref.read(onboardingProvider.notifier).saveProfile(phone: phone);
    } catch (_) {
      if (mounted) setState(() => _saving = false);
      if (mounted) showCeToast(context, "Couldn't save your profile — please try again");
      return;
    }
    if (!mounted) return;
    setState(() => _saving = false);
    // A returning user with a set-up role enters it; everyone else chooses.
    final role = ref.read(activeRoleProvider);
    context.go(role == null ? Routes.roleSelection : Routes.home(role));
  }

  /// Back → the auth flow: the sign-up step if it's underneath, else Login.
  void _back() {
    if (context.canPop()) {
      context.pop();
      return;
    }
    ref.read(sessionProvider.notifier).logout();
    context.go(Routes.login);
  }

  @override
  Widget build(BuildContext context) {
    final draft = ref.watch(onboardingProvider);
    // City → areas (none listed yet, or still loading → typed Area field).
    final areaData = ref.watch(cityAreasProvider).value ?? CityAreas.empty;
    final notifier = ref.read(onboardingProvider.notifier);
    final same = draft.isPermanentSameAsCurrent;
    return PopScope(
      canPop: context.canPop(),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        backgroundColor: CeColors.bg,
        body: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // Stadium header (as Login / Sign Up) with Back.
            AuthBanner(
              title: 'Set up your profile',
              subtitle: 'This is your CricEco account — you choose Player or Club Owner next.',
              stadiumPhoto: true,
              showLogo: false,
              onBack: _back,
            ),
            AuthPanel(
              child: Form(
                key: _formKey,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const CeStepProgress(value: 0.66, label: 'Step 2 of 3 — Your Profile', padding: EdgeInsets.zero),
                  const SizedBox(height: 20),
                  Center(
                    child: CePhotoPicker(
                      title: 'Profile picture',
                      placeholderIcon: 'camera',
                      caption: draft.hasPhoto
                          ? 'Looking good. Tap the photo to change it.'
                          : 'Optional · a clear face photo helps clubs recognise you.',
                      imagePath: draft.photoPath,
                      semanticLabel: draft.hasPhoto ? 'Change profile picture' : 'Add profile picture',
                      // Gallery / camera (and Remove once set) — the same picker as My Profile.
                      onTap: () async {
                        final change = await choosePhoto(context, ref, title: 'Profile picture', hasPhoto: draft.hasPhoto);
                        if (change != null) notifier.setPhoto(change.path);
                      },
                    ),
                  ),
                  const SizedBox(height: 20),
                  const CeFieldLabel('Full Name', required: true),
                  CeTextField(
                    fieldKey: const Key('profile.name'),
                    controller: _name,
                    maxLength: CeValidators.nameMaxLength,
                    hint: 'Muhammad Ali',
                    icon: 'user',
                    textCapitalization: TextCapitalization.words,
                    textInputAction: TextInputAction.next,
                    autofillHints: const [AutofillHints.name],
                    validator: CeValidators.personName,
                    onChanged: notifier.setFullName,
                  ),
                  const CeFieldLabel('Phone Number', required: true),
                  CeTextField(
                    fieldKey: const Key('profile.phone'),
                    controller: _phone,
                    hint: '03XX-XXXXXXX',
                    icon: 'phone',
                    keyboardType: TextInputType.phone,
                    inputFormatters: kPhoneInputFormatters,
                    // Date of Birth and City open pickers, so the keyboard
                    // closes here rather than jumping past them.
                    textInputAction: TextInputAction.done,
                    autofillHints: const [AutofillHints.telephoneNumber],
                    validator: CeValidators.pkPhone,
                    onChanged: notifier.setPhone,
                  ),
                  const CeFieldLabel('Date of Birth', required: true),
                  CeTextField(
                    fieldKey: const Key('profile.dob'),
                    controller: _dob,
                    hint: 'Select date of birth',
                    icon: 'calendar',
                    readOnly: true,
                    showChevron: true,
                    onTap: _pickDob,
                    validator: (_) => CeValidators.dateOfBirth(draft.dateOfBirth, DateTime.now()),
                  ),

                  // ---- Current Address ----
                  const _SectionHeading('Current Address', subtitle: 'Where you live now'),
                  _AddressFields(
                    keyPrefix: 'profile.current',
                    areaData: areaData,
                    city: draft.currentCity,
                    onCity: (v) => _pickCity(current: true, city: v),
                    areaValue: draft.currentArea,
                    otherPicked: _currentOther,
                    onPickArea: (v) =>
                        _pickArea(current: true, area: v, listed: areaData.areasFor(draft.currentCity)),
                    area: _currentArea,
                    onArea: notifier.setCurrentArea,
                    address: _currentAddress,
                    onAddress: notifier.setCurrentAddress,
                    // Last text field on the form when Yes: close the keyboard.
                    lastField: same,
                  ),

                  // ---- Permanent Address ----
                  const _SectionHeading('Permanent Address', subtitle: 'Your home town address'),
                  _SameAddressCard(
                    same: same,
                    onChanged: (v) {
                      FocusScope.of(context).unfocus();
                      notifier.setPermanentSameAsCurrent(v);
                    },
                  ),
                  if (!same) ...[
                    const SizedBox(height: 16),
                    _AddressFields(
                      keyPrefix: 'profile.permanent',
                      areaData: areaData,
                      city: draft.permanentCity,
                      onCity: (v) => _pickCity(current: false, city: v),
                      areaValue: draft.permanentArea,
                      otherPicked: _permanentOther,
                      onPickArea: (v) =>
                          _pickArea(current: false, area: v, listed: areaData.areasFor(draft.permanentCity)),
                      area: _permanentArea,
                      onArea: notifier.setPermanentArea,
                      address: _permanentAddress,
                      onAddress: notifier.setPermanentAddress,
                      lastField: true,
                    ),
                  ] else
                    const SizedBox(height: 14),
                  const SizedBox(height: 10),
                  CeButton(label: 'Continue', loading: _saving, onPressed: _saving ? null : _continue),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Section title inside the form, with a one-line hint.
class _SectionHeading extends StatelessWidget {
  const _SectionHeading(this.title, {required this.subtitle});
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          CeSectionHeader(title, padding: EdgeInsets.zero),
          const SizedBox(height: 2),
          Text(subtitle, style: CeType.bodySmall),
        ]),
      );
}

/// City (picker) · Area · Address — the same three required fields for the
/// current and the permanent address.
///
/// Area is a picker (like City) of the selected city's listed areas plus
/// "Other (type it)", which opens the typed field below it. Before a city is
/// chosen the picker reads "Select a city first". A city with no listed areas
/// keeps the typed Area field. Keys: `<keyPrefix>City`, `AreaPicker`,
/// `Area` (the typed field), `Address`.
class _AddressFields extends StatelessWidget {
  const _AddressFields({
    required this.keyPrefix,
    required this.areaData,
    required this.city,
    required this.onCity,
    required this.areaValue,
    required this.otherPicked,
    required this.onPickArea,
    required this.area,
    required this.onArea,
    required this.address,
    required this.onAddress,
    required this.lastField,
  });

  final String keyPrefix;
  final CityAreas areaData;
  final String? city;
  final ValueChanged<String> onCity;

  /// The draft's Area (listed or typed).
  final String? areaValue;

  /// "Other (type it)" chosen while nothing is typed yet.
  final bool otherPicked;
  final ValueChanged<String> onPickArea;
  final TextEditingController area;
  final ValueChanged<String> onArea;
  final TextEditingController address;
  final ValueChanged<String> onAddress;
  final bool lastField;

  @override
  Widget build(BuildContext context) {
    final listed = areaData.areasFor(city);
    final picker = areaData.isNotEmpty && (city == null || listed.isNotEmpty);
    final typed = (areaValue ?? '').trim().isNotEmpty && !listed.contains(areaValue);
    // Typed field: no listed areas for this city, or "Other" in the picker.
    final other = picker && city != null && (otherPicked || typed);
    final typedField = CeTextField(
      fieldKey: Key('${keyPrefix}Area'),
      controller: area,
      maxLength: CeValidators.areaMaxLength,
      hint: other ? 'Type your area' : 'e.g. Gulshan-e-Iqbal',
      icon: 'map',
      textCapitalization: TextCapitalization.words,
      textInputAction: TextInputAction.next,
      validator: (v) => CeValidators.addressPart(v, 'Area'),
      onChanged: onArea,
    );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const CeFieldLabel('City', required: true),
        CeSelectField<String>(
          fieldKey: Key('${keyPrefix}City'),
          items: kPakistanCities,
          labelOf: (v) => v,
          sheetTitle: 'Select City',
          itemIcon: 'building-2',
          value: city,
          hint: 'Select city',
          icon: 'building-2',
          validator: CeValidators.city,
          onChanged: onCity,
        ),
        const CeFieldLabel('Area', required: true),
        if (picker) ...[
          // Tappable once a city is chosen (its areas depend on it).
          IgnorePointer(
            ignoring: city == null,
            child: CeSelectField<String>(
              fieldKey: Key('${keyPrefix}AreaPicker'),
              items: [...listed, kOtherArea],
              labelOf: (v) => v,
              sheetTitle: 'Select Area',
              itemIcon: 'map',
              value: other ? kOtherArea : (listed.contains(areaValue) ? areaValue : null),
              hint: city == null ? 'Select a city first' : 'Select area',
              icon: 'map',
              validator: (v) => v == null ? 'Area is required' : null,
              onChanged: onPickArea,
            ),
          ),
          if (other) typedField,
        ] else
          typedField,
        const CeFieldLabel('Address', required: true),
        CeTextField(
          fieldKey: Key('${keyPrefix}Address'),
          controller: address,
          maxLength: CeValidators.addressMaxLength,
          hint: 'House, street, sector',
          icon: 'map-pin',
          keyboardType: TextInputType.streetAddress,
          textCapitalization: TextCapitalization.words,
          textInputAction: lastField ? TextInputAction.done : TextInputAction.next,
          autofillHints: const [AutofillHints.streetAddressLine1],
          validator: (v) => CeValidators.addressPart(v, 'Address'),
          onChanged: onAddress,
        ),
      ]);
  }
}

/// "Same as current address?" — the Yes / No question card used on Club
/// Setup (home ground).
class _SameAddressCard extends StatelessWidget {
  const _SameAddressCard({required this.same, required this.onChanged});
  final bool same;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Container(
        key: const Key('profile.permanentSame'),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(CeRadius.card),
          border: Border.all(color: CeColors.line2, width: 1.5),
        ),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Same as current address?', style: CeType.listTitle),
              const SizedBox(height: 3),
              Text(
                same ? 'Your current address will be saved as permanent.' : 'Enter your permanent address below.',
                style: CeType.bodySmall,
              ),
            ]),
          ),
          const SizedBox(width: 12),
          CeYesNo(value: same, onChanged: onChanged),
        ]),
      );
}
