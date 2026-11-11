import 'package:flutter/material.dart';

import '../../core/constants/city_areas.dart';
import '../../core/utils/validators.dart';
import '../../shared/widgets/ce_inputs.dart';

/// The required Area of an address (Profile Setup, Edit Profile): a picker
/// of the city's listed areas plus "Other (type it)", which opens the typed
/// field below it. Before a city is chosen the picker reads "Select a city
/// first". A city with no listed areas (or no area data) keeps the typed
/// field. Keys: `<keyPrefix>AreaPicker`, `<keyPrefix>Area` (the typed field).
class AreaField extends StatelessWidget {
  const AreaField({
    super.key,
    required this.keyPrefix,
    required this.areaData,
    required this.city,
    required this.areaValue,
    required this.otherPicked,
    required this.onPickArea,
    required this.controller,
    required this.onArea,
  });

  final String keyPrefix;
  final CityAreas areaData;

  /// The city's name (its areas are looked up by name).
  final String? city;

  /// The current Area (listed or typed).
  final String? areaValue;

  /// "Other (type it)" chosen while nothing is typed yet.
  final bool otherPicked;
  final ValueChanged<String> onPickArea;
  final TextEditingController controller;
  final ValueChanged<String> onArea;

  /// The typed field's text after [picked] is chosen in the picker: a listed
  /// area as it is; "Other (type it)" keeps a typed area ([typed]) and clears
  /// a listed one so the user types their own.
  static String textFor(
    String picked, {
    required List<String> listed,
    required String typed,
  }) => picked == kOtherArea ? (listed.contains(typed) ? '' : typed) : picked;

  @override
  Widget build(BuildContext context) {
    final listed = areaData.areasFor(city);
    final picker = areaData.isNotEmpty && (city == null || listed.isNotEmpty);
    final typed =
        (areaValue ?? '').trim().isNotEmpty && !listed.contains(areaValue);
    // Typed field: no listed areas for this city, or "Other" in the picker.
    final other = picker && city != null && (otherPicked || typed);
    final typedField = CeTextField(
      fieldKey: Key('${keyPrefix}Area'),
      controller: controller,
      maxLength: CeValidators.areaMaxLength,
      hint: other ? 'Type your area' : 'e.g. Gulshan-e-Iqbal',
      icon: 'map',
      textCapitalization: TextCapitalization.words,
      textInputAction: TextInputAction.next,
      validator: (v) => CeValidators.addressPart(v, 'Area'),
      onChanged: onArea,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
              value: other
                  ? kOtherArea
                  : (listed.contains(areaValue) ? areaValue : null),
              hint: city == null ? 'Select a city first' : 'Select area',
              icon: 'map',
              validator: (v) => v == null ? 'Area is required' : null,
              onChanged: onPickArea,
            ),
          ),
          if (other) typedField,
        ] else
          typedField,
      ],
    );
  }
}
