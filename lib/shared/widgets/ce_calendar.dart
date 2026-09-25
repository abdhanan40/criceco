import 'package:flutter/material.dart';

import '../../app/theme/tokens.dart';
import '../../core/utils/formatters.dart';
import 'ce_icons.dart';

/// Visual state of one calendar day (prototype `.cal-day` classes).
enum CeDayStyle { normal, available, partial, full, unavailable }

/// Inline month calendar (`.cal-card`): month navigation, Sunday-first grid,
/// selected / today markers, optional per-day style and enable rules. Every
/// label is derived from real [DateTime]s (no hard-coded months).
class CeMonthCalendar extends StatelessWidget {
  const CeMonthCalendar({
    super.key,
    required this.visibleMonth,
    required this.onMonthChanged,
    required this.onSelected,
    this.selected,
    this.today,
    this.styleOf,
    this.isEnabled,
    this.margin = const EdgeInsets.fromLTRB(CeSpace.gutter, 8, CeSpace.gutter, 0),
  });

  /// Any date in the month to show.
  final DateTime visibleMonth;
  final ValueChanged<DateTime> onMonthChanged;
  final ValueChanged<DateTime> onSelected;
  final DateTime? selected;
  final DateTime? today;
  final CeDayStyle Function(DateTime day)? styleOf;
  final bool Function(DateTime day)? isEnabled;
  final EdgeInsetsGeometry margin;

  static bool _same(DateTime a, DateTime? b) =>
      b != null && a.year == b.year && a.month == b.month && a.day == b.day;

  @override
  Widget build(BuildContext context) {
    final first = DateTime(visibleMonth.year, visibleMonth.month, 1);
    final daysInMonth = DateTime(first.year, first.month + 1, 0).day;
    final leading = first.weekday % 7; // Sunday-first
    const dows = ['Su', 'Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa'];

    Widget day(int d) {
      final date = DateTime(first.year, first.month, d);
      final isSel = _same(date, selected);
      final isToday = _same(date, today);
      final enabled = isEnabled?.call(date) ?? true;
      final style = styleOf?.call(date) ?? CeDayStyle.normal;
      final (bg, fg) = isSel
          ? (CeColors.primaryDark, Colors.white)
          : switch (style) {
              CeDayStyle.available => (CeColors.mint2, CeColors.primaryDark),
              CeDayStyle.partial => (const Color(0xFFF7E3BB), CeColors.amber),
              CeDayStyle.full || CeDayStyle.unavailable => (const Color(0xFFF7DCD7), CeColors.red),
              CeDayStyle.normal => (Colors.transparent, CeColors.ink2),
            };
      return Semantics(
        button: true,
        selected: isSel,
        label: CeFormat.dayDate(date),
        excludeSemantics: true,
        child: GestureDetector(
          onTap: enabled ? () => onSelected(date) : null,
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(CeRadius.sm),
              border: isToday && !isSel ? Border.all(color: CeColors.ink, width: 2) : null,
            ),
            child: Text('$d',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isToday ? FontWeight.w800 : FontWeight.w600,
                  color: enabled ? fg : CeColors.muted2,
                )),
          ),
        ),
      );
    }

    return Container(
      margin: margin,
      padding: const EdgeInsets.fromLTRB(10, 12, 10, 14),
      decoration: BoxDecoration(color: CeColors.mint, borderRadius: BorderRadius.circular(CeRadius.lg)),
      child: Column(children: [
        Row(children: [
          IconButton(
            tooltip: 'Previous month',
            icon: Icon(CeIcons.of('chevron-left'), size: 18, color: CeColors.primaryDark),
            onPressed: () => onMonthChanged(DateTime(first.year, first.month - 1, 1)),
          ),
          Expanded(
            child: Text(CeFormat.monthYear(first),
                textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
          ),
          IconButton(
            tooltip: 'Next month',
            icon: Icon(CeIcons.of('chevron-right'), size: 18, color: CeColors.primaryDark),
            onPressed: () => onMonthChanged(DateTime(first.year, first.month + 1, 1)),
          ),
        ]),
        const SizedBox(height: 4),
        GridView.count(
          crossAxisCount: 7,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
          childAspectRatio: 1.15,
          children: [
            for (final d in dows)
              Center(
                child: Text(d,
                    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: CeColors.muted)),
              ),
            for (var i = 0; i < leading; i++) const SizedBox.shrink(),
            for (var d = 1; d <= daysInMonth; d++) day(d),
          ],
        ),
      ]),
    );
  }
}
