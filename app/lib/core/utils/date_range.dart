/// A half-open local-time range `[start, end)` used for reporting periods.
/// All boundaries are computed in the machine's local timezone, matching how
/// `created_at` timestamps are stored (local, no UTC suffix), so string
/// comparisons and `date()` filtering stay consistent at midnight.
class DateRange {
  final DateTime start;
  final DateTime end;

  const DateRange({required this.start, required this.end});

  factory DateRange.today() {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    return DateRange(start: start, end: start.add(const Duration(days: 1)));
  }

  factory DateRange.yesterday() {
    final now = DateTime.now();
    final start = DateTime(
      now.year,
      now.month,
      now.day,
    ).subtract(const Duration(days: 1));
    return DateRange(start: start, end: start.add(const Duration(days: 1)));
  }

  /// Monday-based week: from Monday 00:00 until next Monday 00:00.
  factory DateRange.thisWeek() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final start = today.subtract(
      Duration(days: today.weekday - DateTime.monday),
    );
    return DateRange(start: start, end: start.add(const Duration(days: 7)));
  }

  factory DateRange.thisMonth() {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, 1);
    return DateRange(
      start: start,
      end: now.month == 12
          ? DateTime(now.year + 1, 1, 1)
          : DateTime(now.year, now.month + 1, 1),
    );
  }

  factory DateRange.thisYear() {
    final now = DateTime.now();
    return DateRange(
      start: DateTime(now.year, 1, 1),
      end: DateTime(now.year + 1, 1, 1),
    );
  }

  /// Everything the app has ever recorded. Used for "All time" views.
  factory DateRange.allTime() {
    return DateRange(start: DateTime(2000), end: DateTime(2100));
  }

  /// A custom range where both dates are inclusive calendar days.
  factory DateRange.custom(DateTime startDay, DateTime endDay) {
    final start = DateTime(startDay.year, startDay.month, startDay.day);
    var end = DateTime(endDay.year, endDay.month, endDay.day);
    if (end.isBefore(start)) end = start;
    return DateRange(start: start, end: end.add(const Duration(days: 1)));
  }

  bool contains(DateTime moment) =>
      !moment.isBefore(start) && moment.isBefore(end);
}

/// The period presets offered on the dashboard, history, and report screens.
enum ReportPeriod {
  today('Day'),
  yesterday('Yesterday'),
  thisWeek('Week'),
  thisMonth('Month'),
  thisYear('Year'),
  allTime('All'),
  custom('Custom');

  const ReportPeriod(this.label);
  final String label;

  /// Resolves the preset to a concrete local-time range. `custom` returns
  /// null; callers combine it with their own picked dates.
  DateRange? toDateRange() {
    switch (this) {
      case ReportPeriod.today:
        return DateRange.today();
      case ReportPeriod.yesterday:
        return DateRange.yesterday();
      case ReportPeriod.thisWeek:
        return DateRange.thisWeek();
      case ReportPeriod.thisMonth:
        return DateRange.thisMonth();
      case ReportPeriod.thisYear:
        return DateRange.thisYear();
      case ReportPeriod.allTime:
        return DateRange.allTime();
      case ReportPeriod.custom:
        return null;
    }
  }
}
