/// Pakistan time for match scheduling: the server applies its match rules in
/// Asia/Karachi (UTC+5 all year, no daylight saving), so match times are
/// proposed and shown on a Pakistan clock whatever the device's time zone.
///
/// Instants (a match's start, a cancellation) stay instants in the models —
/// compared with the clock and sent as UTC. Only what a person reads or
/// picks is a Pakistan "wall clock": a [DateTime] whose year … minute fields
/// are the time in Pakistan. It is flagged UTC so no device time zone or
/// daylight-saving rule touches it; it's for display and input only, never
/// compared with an instant.
abstract final class PakistanTime {
  /// Pakistan Standard Time: UTC+5 all year.
  static const offset = Duration(hours: 5);

  /// [instant] on a clock in Pakistan (fields = Pakistan wall-clock time).
  static DateTime wallClock(DateTime instant) => instant.toUtc().add(offset);

  /// The instant at which a clock in Pakistan shows [wall]'s year … minute
  /// (its own time zone flag is ignored).
  static DateTime instantOf(DateTime wall) => DateTime.utc(
    wall.year,
    wall.month,
    wall.day,
    wall.hour,
    wall.minute,
    wall.second,
  ).subtract(offset);

  /// [year]-[month]-[day] [hour]:[minute] in Pakistan, as an instant.
  static DateTime instant(
    int year,
    int month,
    int day, [
    int hour = 0,
    int minute = 0,
  ]) => DateTime.utc(year, month, day, hour, minute).subtract(offset);

  /// The calendar date in Pakistan at [instant] (a local midnight with that
  /// year-month-day, like the app's other calendar dates) — what the
  /// database calls "today" (`now() at time zone 'Asia/Karachi'`).
  static DateTime dateOf(DateTime instant) {
    final pk = wallClock(instant);
    return DateTime(pk.year, pk.month, pk.day);
  }
}

/// `t.inPakistan` — [PakistanTime.wallClock] for display.
extension PakistanWallClock on DateTime {
  /// This instant on a clock in Pakistan (display only).
  DateTime get inPakistan => PakistanTime.wallClock(this);
}
