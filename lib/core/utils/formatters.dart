import 'package:intl/intl.dart';

/// All user-visible dates, times and amounts are derived from typed values
/// (fixes the prototype's hard-coded "Aug 2026").
abstract final class CeFormat {
  static final _dayDate = DateFormat('EEE, d MMM y'); // Fri, 2 Aug 2025
  static final _date = DateFormat('d MMM y'); // 12 Aug 2026
  static final _dayMonth = DateFormat('d MMM'); // 12 Aug
  static final _monthYear = DateFormat('MMMM y'); // August 2026
  static final _time = DateFormat('h:mm a'); // 8:00 AM
  static final _amount = NumberFormat.decimalPattern('en_US');

  static String dayDate(DateTime d) => _dayDate.format(d);
  static String date(DateTime d) => _date.format(d);
  static String dayMonth(DateTime d) => _dayMonth.format(d);
  static String monthYear(DateTime d) => _monthYear.format(d);
  static String time(DateTime d) => _time.format(d);

  /// "Rs 8,000"
  static String rupees(int amount) => 'Rs ${_amount.format(amount)}';

  /// Reservation countdown "mm:ss" (prototype `formatCountdown`).
  static String mmss(Duration d) {
    final s = d.isNegative ? 0 : d.inSeconds;
    return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
  }

  /// Match countdown "18h : 45m : 32s".
  static String hms(Duration d) {
    if (d.isNegative) d = Duration.zero;
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    return '${h}h : ${m.toString().padLeft(2, '0')}m : ${s.toString().padLeft(2, '0')}s';
  }

  /// Days until a deadline: "5d" / "Today" / "Closed".
  static String daysLeft(DateTime deadline, DateTime now) {
    final a = DateTime(now.year, now.month, now.day);
    final b = DateTime(deadline.year, deadline.month, deadline.day);
    final diff = b.difference(a).inDays;
    if (diff > 0) return '${diff}d';
    if (diff == 0) return 'Today';
    return 'Closed';
  }

  /// Local midnight of [d].
  static DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
}
