import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers/core_providers.dart';
import '../../app/theme/tokens.dart';
import '../../core/models/models.dart';
import '../../data/repositories/repositories.dart';
import '../../shared/widgets/ce_feedback.dart';
import '../../shared/widgets/ce_icons.dart';
import '../../shared/widgets/ce_indicators.dart';
import '../../shared/widgets/ce_inputs.dart';
import '../../shared/widgets/ce_list_sheet.dart';
import '../../shared/widgets/ce_rows.dart';
import '../../shared/widgets/ce_surfaces.dart';

/// Stage 4.3.1 / 4.3.2: searchable city selection on [LocationRepository],
/// with optional province and district filters.
///
/// Not used by any screen yet — Profile Setup, the player profile and the
/// club screens switch to it in later Stage 4.3 steps.

/// How long typing must pause before a search is sent.
const kCitySearchDebounce = Duration(milliseconds: 250);

/// Opens the city sheet; resolves to the picked city, or `null` when closed.
Future<CityOption?> showCityPicker(
  BuildContext context, {
  required LocationRepository repository,
  CityOption? selected,
  String title = 'Select city',
}) => showCeListSheet<CityOption>(
  context,
  builder: (_) =>
      CityPickerSheet(repository: repository, selected: selected, title: title),
);

/// A read-only field (like [CeSelectField]) that opens the searchable city
/// sheet. Shows the picked city's label ("Kamra (Attock)"); validates inside
/// a [Form] like any other field. The cities come from
/// [locationRepositoryProvider] (memory mode: the 20 featured cities).
///
/// [onChanged] fires only when a *different* city is picked, so a screen can
/// reset what depends on the city (its Area) right there; re-picking the
/// same city, or closing the sheet, changes nothing.
class CityPickerField extends ConsumerStatefulWidget {
  const CityPickerField({
    super.key,
    required this.value,
    required this.onChanged,
    this.hint = 'Select city',
    this.sheetTitle = 'Select city',
    this.icon = 'map-pin',
    this.validator,
    this.fieldKey,
  });

  final CityOption? value;
  final ValueChanged<CityOption> onChanged;
  final String hint;
  final String sheetTitle;
  final String? icon;
  final String? Function(CityOption? value)? validator;
  final Key? fieldKey;

  @override
  ConsumerState<CityPickerField> createState() => _CityPickerFieldState();
}

class _CityPickerFieldState extends ConsumerState<CityPickerField> {
  late final _controller = TextEditingController(text: widget.value?.label);

  @override
  void didUpdateWidget(covariant CityPickerField old) {
    super.didUpdateWidget(old);
    // Value changed from outside: sync after this frame (changing the
    // controller during build would re-dirty the parent Form).
    if (old.value?.id != widget.value?.id ||
        old.value?.label != widget.value?.label) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final text = widget.value?.label ?? '';
        if (_controller.text != text) _controller.text = text;
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    FocusScope.of(context).unfocus();
    final picked = await showCityPicker(
      context,
      repository: ref.read(locationRepositoryProvider),
      selected: widget.value,
      title: widget.sheetTitle,
    );
    if (picked == null || !mounted || picked.id == widget.value?.id) return;
    _controller.text = picked.label;
    widget.onChanged(picked);
  }

  @override
  Widget build(BuildContext context) => CeTextField(
    fieldKey: widget.fieldKey,
    controller: _controller,
    hint: widget.hint,
    icon: widget.icon,
    readOnly: true,
    showChevron: true,
    onTap: _open,
    validator: widget.validator == null
        ? null
        : (_) => widget.validator!(widget.value),
  );
}

/// The sheet body: a search box, the province / district filters (when the
/// repository has provinces — never in memory mode), then the featured
/// cities (no filter, empty / short query), the filtered cities, or the
/// matches. Searches 250 ms after typing stops; a filter change searches at
/// once. A slower, older answer never replaces a newer one.
class CityPickerSheet extends StatefulWidget {
  const CityPickerSheet({
    super.key,
    required this.repository,
    this.selected,
    this.title = 'Select city',
  });

  final LocationRepository repository;
  final CityOption? selected;
  final String title;

  @override
  State<CityPickerSheet> createState() => _CityPickerSheetState();
}

/// What the city list on screen was searched with (its label and empty-state
/// wording follow this, not the text still being typed).
class _Shown {
  const _Shown(this.query, this.province, this.district);
  final String query;
  final Province? province;
  final District? district;

  bool get shortQuery => query.trim().length < 2;
  bool get filtered => province != null || district != null;
}

class _CityPickerSheetState extends State<CityPickerSheet> {
  Timer? _debounce;
  String _query = '';
  _Shown _shown = const _Shown('', null, null);
  List<CityOption>? _cities;
  bool _loading = false;
  bool _failed = false;

  /// Increments with every city request; only the latest may update the list.
  int _request = 0;

  // Filters. Provinces load once per sheet; an empty list hides the filters.
  List<Province>? _provinces;
  bool _provincesFailed = false;
  Province? _province;
  List<District>? _districts;
  bool _districtsFailed = false;
  District? _district;
  int _districtRequest = 0;

  @override
  void initState() {
    super.initState();
    _load();
    _loadProvinces();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Cities
  // ---------------------------------------------------------------------------

  void _onChanged(String q) {
    _query = q;
    _debounce?.cancel();
    _debounce = Timer(kCitySearchDebounce, _load);
  }

  /// Searches with the current text and filters.
  Future<void> _load() async {
    final request = ++_request;
    final shown = _Shown(_query, _province, _district);
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final cities = await widget.repository.searchCities(
        shown.query,
        provinceId: shown.province?.id,
        districtId: shown.district?.id,
      );
      if (!mounted || request != _request) return;
      setState(() {
        _cities = cities;
        _shown = shown;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || request != _request) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  /// A filter changed: search now (no debounce), with the text as it is.
  void _reload() {
    _debounce?.cancel();
    _load();
  }

  // ---------------------------------------------------------------------------
  // Province / district filters
  // ---------------------------------------------------------------------------

  Future<void> _loadProvinces() async {
    setState(() => _provincesFailed = false);
    try {
      final provinces = await widget.repository.provinces();
      if (!mounted) return;
      setState(() => _provinces = provinces);
    } catch (_) {
      if (!mounted) return;
      setState(() => _provincesFailed = true);
    }
  }

  /// Selecting a province (or "All", `null`) clears the district and reloads
  /// the cities; the district list is loaded for the new province.
  void _selectProvince(Province? p) {
    if (p?.id == _province?.id) return;
    setState(() {
      _province = p;
      _district = null;
      _districts = null;
      _districtsFailed = false;
    });
    if (p != null) _loadDistricts(p);
    _reload();
  }

  Future<void> _loadDistricts(Province p) async {
    final request = ++_districtRequest;
    setState(() => _districtsFailed = false);
    try {
      final districts = await widget.repository.districts(p.id);
      if (!mounted || request != _districtRequest) return;
      setState(() => _districts = districts);
    } catch (_) {
      if (!mounted || request != _districtRequest) return;
      setState(() => _districtsFailed = true);
    }
  }

  void _selectDistrict(District? d) {
    if (d?.id == _district?.id) return;
    setState(() => _district = d);
    _reload();
  }

  void _clearFilters() {
    setState(() {
      _province = null;
      _district = null;
      _districts = null;
      _districtsFailed = false;
    });
    _reload();
  }

  /// The district list (with "All districts" to clear) in the shared sheet.
  Future<void> _pickDistrict() async {
    final districts = _districts;
    if (districts == null) return;
    // A one-element list distinguishes "All districts" ([null]) from closing.
    final picked = await showCeSheet<List<District?>>(
      context,
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'District in ${_province?.name ?? ''}',
            style: Theme.of(ctx).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          _DistrictOption(
            key: const Key('district-option-all'),
            label: 'All districts',
            selected: _district == null,
            onTap: () => Navigator.of(ctx).pop(const <District?>[null]),
          ),
          for (final d in districts)
            _DistrictOption(
              key: Key('district-option-${d.id}'),
              label: d.name,
              selected: d.id == _district?.id,
              onTap: () => Navigator.of(ctx).pop(<District?>[d]),
            ),
          if (districts.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(
                'No districts listed for this province.',
                style: Theme.of(ctx).textTheme.bodyMedium,
              ),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    _selectDistrict(picked.single);
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) => CeListSheetFrame(
    title: widget.title,
    top: [
      Padding(
        padding: const EdgeInsets.fromLTRB(
          CeSpace.gutter,
          4,
          CeSpace.gutter,
          6,
        ),
        child: CeSearchField(
          key: const Key('city-picker-search'),
          hint: 'Search city or town',
          onChanged: _onChanged,
        ),
      ),
      ..._filters(),
    ],
    children: _body(context),
  );

  List<Widget> _filters() {
    if (_provincesFailed) {
      return [
        Padding(
          padding: const EdgeInsets.fromLTRB(CeSpace.gutter, 0, 6, 2),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Couldn\'t load provinces',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              TextButton(
                key: const Key('province-retry'),
                onPressed: _loadProvinces,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      ];
    }
    final provinces = _provinces;
    // Still loading, or none (memory mode): no filters.
    if (provinces == null || provinces.isEmpty) return const [];
    return [
      Semantics(
        container: true,
        label: 'Filter by province',
        child: CeChipRow<Province?>(
          key: const Key('province-filter'),
          values: [null, ...provinces],
          selected: _province,
          labelOf: (p) => p?.name ?? 'All',
          onSelected: _selectProvince,
          padding: const EdgeInsets.fromLTRB(
            CeSpace.gutter,
            2,
            CeSpace.gutter,
            4,
          ),
        ),
      ),
      if (_province != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(
            CeSpace.gutter,
            2,
            CeSpace.gutter,
            4,
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Semantics(label: 'District filter', child: _districtChip()),
          ),
        ),
    ];
  }

  Widget _districtChip() {
    if (_districtsFailed) {
      return CeChip(
        key: const Key('district-filter'),
        label: 'Couldn\'t load districts · Retry',
        icon: 'repeat',
        selected: false,
        onTap: () => _loadDistricts(_province!),
      );
    }
    final loading = _districts == null;
    return CeChip(
      key: const Key('district-filter'),
      label: loading
          ? 'Loading districts…'
          : _district?.name ?? 'All districts',
      icon: 'map-pin',
      selected: _district != null,
      onTap: loading ? null : _pickDistrict,
    );
  }

  List<Widget> _body(BuildContext context) {
    final cities = _cities;
    if (_failed) {
      return [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            CeSpace.gutter,
            12,
            CeSpace.gutter,
            0,
          ),
          child: CeErrorState(
            key: const Key('city-picker-error'),
            title: 'Couldn\'t load cities',
            onRetry: _reload,
          ),
        ),
      ];
    }
    if (cities == null) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 36),
          child: Center(
            child: SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                key: Key('city-picker-loading'),
                semanticsLabel: 'Loading cities',
                strokeWidth: 2.6,
              ),
            ),
          ),
        ),
      ];
    }
    final shown = _shown;
    return [
      // A newer search is on its way: keep the old list, show a thin bar.
      SizedBox(
        height: 2,
        child: _loading
            ? const LinearProgressIndicator(
                key: Key('city-picker-refreshing'),
                minHeight: 2,
              )
            : null,
      ),
      if (cities.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(
            CeSpace.gutter,
            12,
            CeSpace.gutter,
            0,
          ),
          child: CeEmptyState(
            key: const Key('city-picker-empty'),
            icon: 'search',
            title: 'No matching city',
            body: !shown.shortQuery
                ? 'Check the spelling, or choose the nearest city.'
                : shown.filtered
                ? 'No cities are listed here yet.'
                : 'No cities are available right now.',
            secondaryLabel: shown.filtered ? 'Clear filters' : null,
            onSecondary: shown.filtered ? _clearFilters : null,
          ),
        )
      else ...[
        CeSectionHeader(
          _sectionTitle(shown),
          key: const Key('city-picker-section'),
          padding: const EdgeInsets.fromLTRB(
            CeSpace.gutter,
            10,
            CeSpace.gutter,
            2,
          ),
        ),
        for (final c in cities) _row(context, c),
      ],
    ];
  }

  static String _sectionTitle(_Shown shown) {
    if (!shown.shortQuery) return 'Results';
    final place = shown.district?.name ?? shown.province?.name;
    return place == null ? 'Popular cities' : 'Cities in $place';
  }

  Widget _row(BuildContext context, CityOption c) {
    final selected = c.id == widget.selected?.id;
    final subtitle = c.subtitle.isEmpty ? null : c.subtitle;
    return CeListRow(
      key: Key('city-option-${c.id}'),
      title: c.label,
      subtitle: subtitle,
      leading: Icon(
        CeIcons.of(c.isFeatured ? 'building-2' : 'map-pin'),
        size: 18,
        color: selected ? CeColors.primary : CeColors.muted,
      ),
      trailing: selected
          ? Icon(CeIcons.of('check'), size: 18, color: CeColors.primary)
          : null,
      chevron: false,
      semanticLabel: [c.label, ?subtitle, if (selected) 'selected'].join(', '),
      onTap: () => Navigator.of(context).pop(c),
    );
  }
}

/// One row of the district list (the same look as [CeSelectField]'s sheet).
class _DistrictOption extends StatelessWidget {
  const _DistrictOption({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    button: true,
    child: InkWell(
      borderRadius: BorderRadius.circular(CeRadius.sm),
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Row(
          children: [
            const SizedBox(width: 4),
            Icon(CeIcons.of('map-pin'), size: 16, color: CeColors.muted),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? CeColors.primaryDark : CeColors.ink2,
                ),
              ),
            ),
            if (selected)
              Icon(CeIcons.of('check'), size: 16, color: CeColors.primary),
            const SizedBox(width: 4),
          ],
        ),
      ),
    ),
  );
}
