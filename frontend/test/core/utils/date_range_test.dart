import 'package:flutter_test/flutter_test.dart';
import 'package:pos_contracts/pos_contracts.dart';

void main() {
  group('DateRange.today', () {
    test('spans local midnight to midnight', () {
      final now = DateTime.now();
      final range = DateRange.today();

      expect(range.start, DateTime(now.year, now.month, now.day));
      expect(
        range.end,
        DateTime(now.year, now.month, now.day).add(const Duration(days: 1)),
      );
      expect(range.contains(now), isTrue);
    });

    test('does not include yesterday or tomorrow', () {
      final range = DateRange.today();
      expect(
        range.contains(range.start.subtract(const Duration(hours: 1))),
        isFalse,
      );
      expect(range.contains(range.start.add(const Duration(days: 1))), isFalse);
    });
  });

  test('DateRange.yesterday covers the previous calendar day', () {
    final now = DateTime.now();
    final range = DateRange.yesterday();

    expect(range.contains(DateTime(now.year, now.month, now.day, 12)), isFalse);
    expect(
      range.contains(
        DateTime(
          now.year,
          now.month,
          now.day,
        ).subtract(const Duration(days: 1)),
      ),
      isTrue,
    );
  });

  test('DateRange.thisWeek starts on Monday', () {
    final now = DateTime.now();
    final range = DateRange.thisWeek();

    expect(range.start.weekday, DateTime.monday);
    expect(range.end.difference(range.start), const Duration(days: 7));
    expect(range.contains(now), isTrue);
  });

  test('DateRange.thisMonth spans the whole local month', () {
    final now = DateTime.now();
    final range = DateRange.thisMonth();

    expect(range.start, DateTime(now.year, now.month, 1));
    expect(range.contains(now), isTrue);
    expect(
      range.contains(range.start.subtract(const Duration(milliseconds: 1))),
      isFalse,
    );
  });

  test('DateRange.thisYear spans January to January', () {
    final now = DateTime.now();
    final range = DateRange.thisYear();

    expect(range.start, DateTime(now.year, 1, 1));
    expect(range.end, DateTime(now.year + 1, 1, 1));
  });

  group('DateRange.custom', () {
    test('includes both picked calendar days', () {
      final range = DateRange.custom(
        DateTime(2026, 10, 20),
        DateTime(2026, 10, 22),
      );

      expect(range.start, DateTime(2026, 10, 20));
      expect(range.end, DateTime(2026, 10, 23)); // exclusive boundary
      expect(range.contains(DateTime(2026, 10, 20, 0, 0)), isTrue);
      expect(range.contains(DateTime(2026, 10, 22, 23, 59, 59)), isTrue);
      expect(range.contains(DateTime(2026, 10, 23, 0, 0)), isFalse);
    });

    test('clamps a reversed range to a single day', () {
      final range = DateRange.custom(
        DateTime(2026, 10, 22),
        DateTime(2026, 10, 20),
      );

      expect(range.start, DateTime(2026, 10, 22));
      expect(range.end, DateTime(2026, 10, 23));
    });
  });

  test('ReportPeriod.custom resolves to null; presets resolve to ranges', () {
    expect(ReportPeriod.custom.toDateRange(), isNull);
    expect(ReportPeriod.today.toDateRange(), isNotNull);
    expect(
      ReportPeriod.allTime.toDateRange()!.contains(DateTime(2025, 6, 1)),
      isTrue,
    );
  });
}
