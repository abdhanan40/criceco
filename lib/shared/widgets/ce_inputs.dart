import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme/tokens.dart';
import 'ce_feedback.dart';
import 'ce_icons.dart';

/// Field label above an input (prototype `.field-label`).
class CeFieldLabel extends StatelessWidget {
  const CeFieldLabel(this.text, {super.key, this.required = false});
  final String text;
  final bool required;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(required ? '$text *' : text,
            style: Theme.of(context).textTheme.labelMedium!.copyWith(color: CeColors.ink2, fontSize: 13)),
      );
}

/// Prototype `.input-wrap`: leading icon, optional password eye toggle
/// (fixes the prototype's inert eye), optional chevron for read-only selects.
/// Works inside a [Form] (validator, text actions, autofill, formatters).
class CeTextField extends StatefulWidget {
  const CeTextField({
    super.key,
    this.controller,
    this.hint,
    this.icon,
    this.obscure = false,
    this.keyboardType,
    this.maxLength,
    this.maxLines = 1,
    this.readOnly = false,
    this.showChevron = false,
    this.onTap,
    this.onChanged,
    this.initialValue,
    this.textCapitalization = TextCapitalization.none,
    this.validator,
    this.textInputAction,
    this.onFieldSubmitted,
    this.autofillHints,
    this.focusNode,
    this.inputFormatters,
    this.fieldKey,
  });

  final TextEditingController? controller;
  final String? hint;
  final String? icon;
  final bool obscure;
  final TextInputType? keyboardType;
  final int? maxLength;
  final int maxLines;
  final bool readOnly;
  final bool showChevron;
  final VoidCallback? onTap;
  final ValueChanged<String>? onChanged;
  final String? initialValue;
  final TextCapitalization textCapitalization;
  final FormFieldValidator<String>? validator;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onFieldSubmitted;
  final Iterable<String>? autofillHints;
  final FocusNode? focusNode;
  final List<TextInputFormatter>? inputFormatters;

  /// Key for the underlying [TextFormField] (tests / focus).
  final Key? fieldKey;

  @override
  State<CeTextField> createState() => _CeTextFieldState();
}

class _CeTextFieldState extends State<CeTextField> {
  late bool _hidden = widget.obscure;

  @override
  Widget build(BuildContext context) {
    Widget? suffix;
    if (widget.obscure) {
      suffix = IconButton(
        tooltip: _hidden ? 'Show password' : 'Hide password',
        icon: Icon(CeIcons.of(_hidden ? 'eye' : 'eye-off'), size: 18),
        onPressed: () => setState(() => _hidden = !_hidden),
      );
    } else if (widget.showChevron) {
      suffix = Icon(CeIcons.of('chevron-down'), size: 16);
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextFormField(
        key: widget.fieldKey,
        controller: widget.controller,
        initialValue: widget.controller == null ? widget.initialValue : null,
        obscureText: _hidden,
        keyboardType: widget.keyboardType,
        maxLength: widget.maxLength,
        maxLines: widget.obscure ? 1 : widget.maxLines,
        readOnly: widget.readOnly,
        onTap: widget.onTap,
        onChanged: widget.onChanged,
        textCapitalization: widget.textCapitalization,
        validator: widget.validator,
        textInputAction: widget.textInputAction,
        onFieldSubmitted: widget.onFieldSubmitted,
        autofillHints: widget.autofillHints,
        focusNode: widget.focusNode,
        inputFormatters: widget.inputFormatters,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        scrollPadding: const EdgeInsets.only(bottom: 120),
        style: Theme.of(context).textTheme.bodyLarge,
        decoration: InputDecoration(
          hintText: widget.hint,
          prefixIcon: widget.icon == null ? null : Icon(CeIcons.of(widget.icon!), size: 17),
          suffixIcon: suffix,
          errorMaxLines: 2,
        ),
      ),
    );
  }
}

/// Select field (prototype `.fake-dropdown-list` selects): a read-only
/// field that opens the shared CricEco bottom sheet with a compact, iconed
/// option list. Validates inside a [Form] like any other field.
class CeSelectField<T> extends StatefulWidget {
  const CeSelectField({
    super.key,
    required this.items,
    required this.labelOf,
    required this.onChanged,
    required this.sheetTitle,
    this.value,
    this.hint,
    this.icon,
    this.itemIcon,
    this.validator,
    this.fieldKey,
  });

  final List<T> items;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;
  final String sheetTitle;
  final T? value;
  final String? hint;
  final String? icon;

  /// Icon shown on every option row (prototype lists show one per row).
  final String? itemIcon;
  final String? Function(T? value)? validator;
  final Key? fieldKey;

  @override
  State<CeSelectField<T>> createState() => _CeSelectFieldState<T>();
}

class _CeSelectFieldState<T> extends State<CeSelectField<T>> {
  late final _controller = TextEditingController(text: _label(widget.value));

  String _label(T? v) => v == null ? '' : widget.labelOf(v);

  @override
  void didUpdateWidget(covariant CeSelectField<T> old) {
    super.didUpdateWidget(old);
    // Value changed from outside: sync after this frame (changing the
    // controller during build would re-dirty the parent Form).
    if (old.value != widget.value) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final text = _label(widget.value);
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
    final picked = await showCeSheet<T>(
      context,
      builder: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(widget.sheetTitle, style: Theme.of(ctx).textTheme.titleLarge),
        const SizedBox(height: 8),
        for (final item in widget.items)
          InkWell(
            borderRadius: BorderRadius.circular(CeRadius.sm),
            onTap: () => Navigator.of(ctx).pop(item),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Row(children: [
                const SizedBox(width: 4),
                if (widget.itemIcon != null) ...[
                  Icon(CeIcons.of(widget.itemIcon!), size: 16, color: CeColors.muted),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Text(widget.labelOf(item),
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: item == widget.value ? FontWeight.w700 : FontWeight.w500,
                        color: item == widget.value ? CeColors.primaryDark : CeColors.ink2,
                      )),
                ),
                if (item == widget.value) Icon(CeIcons.of('check'), size: 16, color: CeColors.primary),
                const SizedBox(width: 4),
              ]),
            ),
          ),
      ]),
    );
    if (picked == null || !mounted) return;
    _controller.text = _label(picked);
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
        validator: widget.validator == null ? null : (_) => widget.validator!(widget.value),
      );
}

/// Search input (prototype `.search-input` / `.om-search-wrap`). A clear (✕)
/// button appears once there is text; Search on the keyboard closes it.
class CeSearchField extends StatefulWidget {
  const CeSearchField({super.key, required this.hint, required this.onChanged, this.controller});
  final String hint;
  final ValueChanged<String> onChanged;
  final TextEditingController? controller;

  @override
  State<CeSearchField> createState() => _CeSearchFieldState();
}

class _CeSearchFieldState extends State<CeSearchField> {
  TextEditingController? _own;
  TextEditingController get _controller => widget.controller ?? (_own ??= TextEditingController());

  @override
  void initState() {
    super.initState();
    _controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant CeSearchField old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      (old.controller ?? _own)?.removeListener(_changed);
      _controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    _own?.dispose();
    super.dispose();
  }

  void _changed() => setState(() {});

  void _clear() {
    _controller.clear();
    widget.onChanged('');
  }

  @override
  Widget build(BuildContext context) => TextField(
        controller: _controller,
        onChanged: widget.onChanged,
        onSubmitted: (_) => FocusScope.of(context).unfocus(),
        textInputAction: TextInputAction.search,
        style: Theme.of(context).textTheme.bodyLarge,
        decoration: InputDecoration(
          hintText: widget.hint,
          constraints: const BoxConstraints(minHeight: CeSize.searchMinHeight),
          prefixIcon: Icon(CeIcons.of('search'), size: 17),
          suffixIcon: _controller.text.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear search',
                  icon: Icon(CeIcons.of('x'), size: 17),
                  onPressed: _clear,
                ),
        ),
      );
}

/// Inline error for a non-text input group (chip group, picker).
class CeInlineError extends StatelessWidget {
  const CeInlineError(this.message, {super.key});
  final String? message;

  @override
  Widget build(BuildContext context) {
    if (message == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 4),
      child: Text(message!, style: const TextStyle(color: CeColors.red, fontSize: 12, fontWeight: FontWeight.w500)),
    );
  }
}

/// Form-level error banner (e.g. "Incorrect phone number or password").
class CeErrorBanner extends StatelessWidget {
  const CeErrorBanner(this.message, {super.key});
  final String message;

  @override
  Widget build(BuildContext context) => Semantics(
        liveRegion: true,
        child: Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: CeColors.redSoft,
            borderRadius: BorderRadius.circular(CeRadius.md),
            border: Border.all(color: CeColors.redBorder),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(CeIcons.of('info'), size: 15, color: CeColors.red),
            const SizedBox(width: 8),
            Expanded(
              child: Text(message,
                  style: const TextStyle(color: CeColors.red, fontSize: 12.5, fontWeight: FontWeight.w600)),
            ),
          ]),
        ),
      );
}
