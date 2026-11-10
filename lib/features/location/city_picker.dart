import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers/core_providers.dart';
import '../../app/theme/tokens.dart';
import '../../core/models/models.dart';
import '../../data/repositories/repositories.dart';
import '../../shared/widgets/ce_feedback.dart';
import '../../shared/widgets/ce_icons.dart';
import '../../shared/widgets/ce_inputs.dart';
import '../../shared/widgets/ce_list_sheet.dart';
import '../../shared/widgets/ce_rows.dart';
import '../../shared/widgets/ce_surfaces.dart';

/// Stage 4.3.1: searchable city selection on [LocationRepository].
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
    if (picked == null || !mounted) return;
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

/// The sheet body: a search box, then the featured cities (empty / short
/// query) or the matches. Searches 250 ms after typing stops; a slower,
/// older answer never replaces a newer one.
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

class _CityPickerSheetState extends State<CityPickerSheet> {
  Timer? _debounce;
  String _query = '';

  /// The query whose answer is on screen (the label and the empty-state
  /// wording follow it, not the text still being typed).
  String _shownQuery = '';
  List<CityOption>? _cities;
  bool _loading = false;
  bool _failed = false;

  /// Increments with every request; only the latest one may update the list.
  int _request = 0;

  bool get _showingFeatured => _shownQuery.trim().length < 2;

  @override
  void initState() {
    super.initState();
    _load('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String q) {
    _query = q;
    _debounce?.cancel();
    _debounce = Timer(kCitySearchDebounce, () => _load(q));
  }

  Future<void> _load(String q) async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final cities = await widget.repository.searchCities(q);
      if (!mounted || request != _request) return;
      setState(() {
        _cities = cities;
        _shownQuery = q;
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

  void _retry() {
    _debounce?.cancel();
    _load(_query);
  }

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
    ],
    children: _body(context),
  );

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
            onRetry: _retry,
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
            body: _showingFeatured
                ? 'No cities are available right now.'
                : 'Check the spelling, or choose the nearest city.',
          ),
        )
      else ...[
        CeSectionHeader(
          _showingFeatured ? 'Popular cities' : 'Results',
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
