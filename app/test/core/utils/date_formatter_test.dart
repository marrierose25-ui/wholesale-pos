import 'package:flutter_test/flutter_test.dart';
import 'package:wholesale_pos_app/core/utils/date_formatter.dart';

// The helper is display-only, so the tests pin the pure UTC→EAT maths with
// UTC inputs — deterministic on any CI machine timezone.
void main() {
  group('toAddisAbabaTime', () {
    test('shifts a UTC instant by +3 hours', () {
      final eat = toAddisAbabaTime(DateTime.utc(2026, 10, 31, 9));
      expect(eat.hour, 12);
      expect(eat.minute, 0);
    });

    test('crosses midnight into the next day', () {
      final eat = toAddisAbabaTime(DateTime.utc(2026, 10, 31, 22, 30));
      expect(eat.hour, 1);
      expect(eat.minute, 30);
      expect(eat.day, 1);
      expect(eat.month, 11);
    });

    test('crosses a month boundary', () {
      final eat = toAddisAbabaTime(DateTime.utc(2026, 8, 31, 21, 15));
      expect(eat.day, 1);
      expect(eat.month, 9);
    });

    test('parses an offset-aware cloud string correctly', () {
      expect(
        formatAddisTime(DateTime.parse('2026-10-28T10:15:00+00:00')),
        '13:15',
      );
    });
  });

  group('formatters', () {
    test('formatAddisTime pads to HH:mm', () {
      expect(formatAddisTime(DateTime.utc(2026, 1, 1, 0, 5)), '03:05');
    });

    test('formatAddisDateTime renders yyyy-MM-dd HH:mm in EAT', () {
      expect(
        formatAddisDateTime(DateTime.utc(2026, 10, 31, 9, 12)),
        '2026-10-31 12:12',
      );
    });

    test('formatAddisDate follows the EAT day, not the UTC day', () {
      expect(formatAddisDate(DateTime.utc(2026, 10, 31, 22)), '2026-11-01');
    });
  });
}
