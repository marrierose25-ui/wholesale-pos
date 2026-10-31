/// Shop wall clock: Addis Ababa (EAT) is UTC+3 all year — no DST — so a fixed
/// offset is exact and no timezone database is needed.
///
/// DISPLAY ONLY. Timestamps must keep being stored, compared and synced in
/// their original device-local/UTC form: converting a value before it reaches
/// the database, DateRange filters or the sync outbox would corrupt sync
/// cursors and the Postgres RPCs. Never feed a converted value back into
/// storage or filtering logic.
library;

/// [dt] as wall-clock time in Addis Ababa (EAT, UTC+3).
///
/// Handles both native rows (naive local ISO strings, parsed as device-local)
/// and cloud rows (UTC '...Z' strings): `toUtc()` normalises either to UTC
/// first, then the fixed +3 offset lands on the shop's clock. On a till that
/// already runs on EAT this is an identity — the displayed time never shifts.
DateTime toAddisAbabaTime(DateTime dt) =>
    dt.toUtc().add(const Duration(hours: 3));

/// '16:12' — the time-of-day part of [dt] on the Addis Ababa clock.
String formatAddisTime(DateTime dt) {
  final t = toAddisAbabaTime(dt);
  return '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';
}

/// '2026-10-31' — the calendar date part of [dt] on the Addis Ababa clock.
String formatAddisDate(DateTime dt) {
  final t = toAddisAbabaTime(dt);
  return '${t.year.toString().padLeft(4, '0')}-'
      '${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';
}

/// '2026-10-31 16:12' — receipt-style timestamp on the Addis Ababa clock.
String formatAddisDateTime(DateTime dt) =>
    '${formatAddisDate(dt)} ${formatAddisTime(dt)}';
