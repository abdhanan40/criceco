import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/config/backend_modules.dart';
import '../../app/session/session_controller.dart';
import '../../core/constants/city_areas.dart';
import '../../core/models/models.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/validators.dart';
import '../../shared/widgets/ce_inputs.dart';
import '../location/area_field.dart';
import '../location/city_picker.dart';
import '../player/player_providers.dart';

/// The editable personal details of the signed-in account — Full name,
/// City (+ Area once the City changes), optionally Date of Birth, and Phone —
/// shared by My Profile's edit mode (Player) and the Personal Details sheet
/// (Club Owner, Settings → Account). Holds the form's values only; the host
/// widget owns the [Form] and calls `setState` around the mutators.
class PersonalDetailsEditor {
  final name = TextEditingController();
  final phone = TextEditingController();
  final area = TextEditingController();

  /// The Date of Birth as the field shows it ([dateOfBirth] formatted).
  final dateOfBirthText = TextEditingController();

  // The City as the picker shows it, and as it was when editing began (id 0:
  // a saved city without a database id). Area shows once the City changes.
  CityOption? city;
  CityOption? savedCity;
  String savedArea = '';

  // "Other (type it)" picked in the Area picker before anything was typed.
  bool areaOther = false;

  /// The account's date of birth, or the one picked since [load].
  DateTime? dateOfBirth;

  /// Accounts created with an email may not have a phone number yet.
  static bool phoneRequiredFor(UserAccount? a) =>
      a?.contactMethod != ContactMethod.email;

  /// Fills the form from the saved account.
  void load(UserAccount? a) {
    name.text = a?.fullName ?? '';
    phone.text = a?.phone ?? '';
    // Any saved city (featured or not); its id belongs to the Current City.
    final saved = a?.city?.trim();
    savedCity = saved == null || saved.isEmpty
        ? null
        : CityOption(
            id:
                (saved == a?.currentCity?.trim() ? a?.currentCityId : null) ??
                0,
            name: saved,
          );
    city = savedCity;
    savedArea = a?.currentArea ?? '';
    area.text = savedArea;
    areaOther = false;
    dateOfBirth = a?.dateOfBirth;
    dateOfBirthText.text = dateOfBirth == null
        ? ''
        : CeFormat.date(dateOfBirth!);
  }

  /// The City differs from the saved one (another id, or another name).
  bool get cityChanged {
    final c = city, s = savedCity;
    if (c == null || s == null) return c != s;
    return c.id != s.id || c.name != s.name;
  }

  /// City picked (City Picker: a different city only). Back to the saved
  /// city → the saved Area again (the Area field hides). Another city keeps
  /// the Area only while it still fits ([CityAreas.keepsArea]), else clears it.
  void pickCity(CityOption picked, CityAreas areas) {
    final previous = city?.name;
    city = picked;
    if (!cityChanged) {
      area.text = savedArea;
      areaOther = false;
    } else if (!areas.keepsArea(previous, picked.name, area.text)) {
      area.clear();
      areaOther = false;
    }
  }

  /// Area picked from the list, or "Other (type it)".
  void pickArea(String picked, CityAreas areas) {
    areaOther = picked == kOtherArea;
    area.text = AreaField.textFor(
      picked,
      listed: areas.areasFor(city?.name),
      typed: area.text,
    );
  }

  /// A date picked in the Date of Birth picker.
  void setDateOfBirth(DateTime picked) {
    dateOfBirth = picked;
    dateOfBirthText.text = CeFormat.date(picked);
  }

  void dispose() {
    name.dispose();
    phone.dispose();
    area.dispose();
    dateOfBirthText.dispose();
  }
}

/// Saves [e] on the account (in Supabase mode one `update_profile_details`
/// call, made by the account repository only when something changed). The
/// Date of Birth is sent only when [includeDateOfBirth] (the Club Owner's
/// sheet); My Profile leaves it as it is. Throws what the repository throws.
Future<void> savePersonalDetails(
  WidgetRef ref,
  PersonalDetailsEditor e, {
  bool includeDateOfBirth = false,
}) async {
  final phone = e.phone.text.trim().isEmpty
      ? null
      : formatPkPhone(CeValidators.normalizePkPhone(e.phone.text)!);
  // A changed City goes with its id (none: a city without one) and the
  // Area shown for it; an unchanged City leaves the address alone.
  final city = e.cityChanged ? e.city : null;
  final cityId = city != null && city.id > 0 ? city.id : null;
  // A blank phone clears the saved one (allowed for email accounts only:
  // the form requires it otherwise).
  final clearPhone = phone == null;
  final dateOfBirth = includeDateOfBirth ? e.dateOfBirth : null;
  await ref
      .read(sessionProvider.notifier)
      .updateAccount(
        (a) => city == null
            ? a.copyWith(
                fullName: e.name.text.trim(),
                phone: phone,
                clearPhone: clearPhone,
                dateOfBirth: dateOfBirth,
              )
            : a.copyWith(
                fullName: e.name.text.trim(),
                phone: phone,
                clearPhone: clearPhone,
                dateOfBirth: dateOfBirth,
                city: city.name,
                currentCityId: cityId,
                clearCurrentCityId: cityId == null,
                currentArea: e.area.text.trim(),
              ),
      );
  // A player listed as available is shown to clubs with the new details.
  // (Player Hunt only: no listing where that module has no backend.)
  if (ref.read(backendModulesProvider).has(BackendModule.playerHunt) &&
      ref.read(playerAvailabilityProvider).openToOffers) {
    await ref.read(playerAvailabilityProvider.notifier).setOpenToOffers(true);
  }
}

/// The personal details fields, in this order: Full name → City → Area (once
/// the City changes) → Date of Birth (only with [onPickDateOfBirth]) → Phone.
/// Keys: `<keyPrefix>.name`, `.city`, `.currentAreaPicker` / `.currentArea`,
/// `.dob`, `.phone` (My Profile uses the prefix `edit`). Place inside a [Form].
class PersonalDetailsFields extends StatelessWidget {
  const PersonalDetailsFields({
    super.key,
    required this.keyPrefix,
    required this.editor,
    required this.phoneRequired,
    required this.areaData,
    required this.onCity,
    required this.onPickArea,
    required this.onArea,
    required this.onSubmit,
    this.onPickDateOfBirth,
  });

  final String keyPrefix;
  final PersonalDetailsEditor editor;
  final bool phoneRequired;
  final CityAreas areaData;
  final ValueChanged<CityOption> onCity;
  final ValueChanged<String> onPickArea;
  final ValueChanged<String> onArea;
  final VoidCallback onSubmit;

  /// Shows the Date of Birth field (required, picked from a calendar).
  final VoidCallback? onPickDateOfBirth;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const CeFieldLabel('Full name', required: true),
      CeTextField(
        fieldKey: Key('$keyPrefix.name'),
        controller: editor.name,
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
        fieldKey: Key('$keyPrefix.city'),
        value: editor.city,
        onChanged: onCity,
        sheetTitle: 'City',
        hint: 'Select city',
        icon: 'map-pin',
        validator: (c) => c == null ? 'Please select a city' : null,
      ),
      // Area (required) shows once the City changes: kept while it still
      // fits the new city, else cleared (E1-B).
      if (editor.cityChanged)
        AreaField(
          keyPrefix: '$keyPrefix.current',
          areaData: areaData,
          city: editor.city?.name,
          areaValue: editor.area.text,
          otherPicked: editor.areaOther,
          onPickArea: onPickArea,
          controller: editor.area,
          onArea: onArea,
        ),
      if (onPickDateOfBirth != null) ...[
        const CeFieldLabel('Date of Birth', required: true),
        CeTextField(
          fieldKey: Key('$keyPrefix.dob'),
          controller: editor.dateOfBirthText,
          hint: 'Select date of birth',
          icon: 'calendar',
          readOnly: true,
          showChevron: true,
          onTap: onPickDateOfBirth,
          validator: (_) =>
              CeValidators.dateOfBirth(editor.dateOfBirth, DateTime.now()),
        ),
      ],
      CeFieldLabel('Phone', required: phoneRequired),
      CeTextField(
        fieldKey: Key('$keyPrefix.phone'),
        controller: editor.phone,
        hint: '03XX-XXXXXXX',
        icon: 'phone',
        keyboardType: TextInputType.phone,
        inputFormatters: kPhoneInputFormatters,
        textInputAction: TextInputAction.done,
        autofillHints: const [AutofillHints.telephoneNumber],
        validator: (v) => (!phoneRequired && (v == null || v.trim().isEmpty))
            ? null
            : CeValidators.pkPhone(v),
        onFieldSubmitted: (_) => onSubmit(),
      ),
    ],
  );
}
