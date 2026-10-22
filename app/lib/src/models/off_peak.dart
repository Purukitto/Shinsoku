/// Off-peak hours as the engine applies them (`window_open` in
/// `core/src/queue/manager.rs`), so the app can say when a scheduled download
/// will start. Minutes since local midnight; `startMin > endMin` wraps past
/// midnight and `startMin == endMin` never opens. [days] has bit 0 for Monday
/// through bit 6 for Sunday and picks the days the hours begin on.
class OffPeakHours {
  const OffPeakHours({required this.startMin, required this.endMin, this.days = everyDay});

  static const everyDay = 0x7f;

  final int startMin;
  final int endMin;
  final int days;

  /// No time of the week falls inside these hours.
  bool get never => startMin == endMin || days & everyDay == 0;

  /// [weekday] as [DateTime.weekday] counts it (1 = Monday); 8 wraps to Monday.
  bool beginsOn(int weekday) => days & (1 << ((weekday - 1) % 7)) != 0;

  bool isOpen(DateTime t) {
    final mins = t.hour * 60 + t.minute;
    if (startMin == endMin) return false;
    if (startMin < endMin) return mins >= startMin && mins < endMin && beginsOn(t.weekday);
    if (mins >= startMin) return beginsOn(t.weekday);
    // after midnight: these hours began the day before
    return mins < endMin && beginsOn(t.weekday + 6);
  }

  /// When the hours next open after [now], or null when they never do.
  DateTime? nextStart(DateTime now) {
    if (never) return null;
    for (var d = 0; d <= 7; d++) {
      final start = DateTime(now.year, now.month, now.day + d, startMin ~/ 60, startMin % 60);
      if (start.isAfter(now) && beginsOn(start.weekday)) return start;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is OffPeakHours &&
      other.startMin == startMin &&
      other.endMin == endMin &&
      other.days == days;

  @override
  int get hashCode => Object.hash(startMin, endMin, days);
}

const _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

/// `HH:MM` for minutes since midnight.
String fmtClock(int m) {
  final h = (m ~/ 60) % 24;
  final mm = m % 60;
  return '${h.toString().padLeft(2, '0')}:${mm.toString().padLeft(2, '0')}';
}

/// What a download scheduled at [now] will do, for the Add dialog.
String scheduleHint(OffPeakHours hours, DateTime now) {
  final stop = 'stops at ${fmtClock(hours.endMin)}';
  if (hours.isOpen(now)) return 'Off-peak now: starts at once, $stop';
  final next = hours.nextStart(now);
  if (next == null) return 'Off-peak hours never open; set them in Settings';
  // calendar days apart; UTC so a daylight-saving shift can't shorten a day
  final today = DateTime.utc(now.year, now.month, now.day);
  final days = DateTime.utc(next.year, next.month, next.day).difference(today).inDays;
  final when = switch (days) {
    0 => 'today',
    1 => 'tomorrow',
    _ => 'on ${_weekdays[next.weekday - 1]}',
  };
  return 'Starts $when at ${fmtClock(hours.startMin)}, $stop';
}
