import 'package:flutter_test/flutter_test.dart';
import 'package:wholesale_pos_app/core/utils/money_utils.dart';

void main() {
  group('stringToMinorUnits', () {
    test('parses exact whole and fractional amounts', () {
      expect(MoneyUtils.stringToMinorUnits('0'), 0);
      expect(MoneyUtils.stringToMinorUnits('12'), 1200);
      expect(MoneyUtils.stringToMinorUnits('12.3'), 1230);
      expect(MoneyUtils.stringToMinorUnits('12.34'), 1234);
      expect(MoneyUtils.stringToMinorUnits(' 1,234.50 '), 123450);
      expect(MoneyUtils.stringToMinorUnits('00012.05'), 1205);
    });

    test('rejects invalid, negative, and over-precise input', () {
      expect(MoneyUtils.stringToMinorUnits(''), isNull);
      expect(MoneyUtils.stringToMinorUnits('   '), isNull);
      expect(MoneyUtils.stringToMinorUnits('abc'), isNull);
      expect(MoneyUtils.stringToMinorUnits('-1'), isNull);
      expect(MoneyUtils.stringToMinorUnits('1.234'), isNull);
      expect(MoneyUtils.stringToMinorUnits('.5'), isNull);
      expect(MoneyUtils.stringToMinorUnits('NaN'), isNull);
      expect(MoneyUtils.stringToMinorUnits('Infinity'), isNull);
      expect(MoneyUtils.stringToMinorUnits('90000000000001'), isNull);
    });
  });

  group('minorUnitsToString', () {
    test('formats without floating point drift', () {
      expect(MoneyUtils.minorUnitsToString(0), '0.00');
      expect(MoneyUtils.minorUnitsToString(5), '0.05');
      expect(MoneyUtils.minorUnitsToString(100), '1.00');
      expect(MoneyUtils.minorUnitsToString(123456), '1234.56');
      expect(MoneyUtils.minorUnitsToString(-12345), '-123.45');
    });
  });

  group('formatBr', () {
    test('formats amounts as birr with thousands grouping', () {
      expect(MoneyUtils.formatBr(0), '0.00 Br');
      expect(MoneyUtils.formatBr(5), '0.05 Br');
      expect(MoneyUtils.formatBr(125050), '1,250.50 Br');
      expect(MoneyUtils.formatBr(123456789), '1,234,567.89 Br');
      expect(MoneyUtils.formatBr(-125050), '-1,250.50 Br');
    });
  });

  group('stringToMilliunits', () {
    test('parses plain decimal quantities with up to three places', () {
      expect(MoneyUtils.stringToMilliunits('2'), 2000);
      expect(MoneyUtils.stringToMilliunits('1.5'), 1500);
      expect(MoneyUtils.stringToMilliunits('0.25'), 250);
      expect(MoneyUtils.stringToMilliunits('1.250'), 1250);
      expect(MoneyUtils.stringToMilliunits('1,000'), 1000000);
      expect(MoneyUtils.stringToMilliunits(' 2 '), 2000);
      expect(MoneyUtils.stringToMilliunits('0002'), 2000);
    });

    test('rejects descriptive or invalid text instead of guessing', () {
      expect(MoneyUtils.stringToMilliunits(''), isNull);
      expect(MoneyUtils.stringToMilliunits('2 boxes and 1 piece'), isNull);
      expect(MoneyUtils.stringToMilliunits('1 kunital'), isNull);
      expect(MoneyUtils.stringToMilliunits('1.2345'), isNull);
      expect(MoneyUtils.stringToMilliunits('-1'), isNull);
      expect(MoneyUtils.stringToMilliunits('.5'), isNull);
      expect(MoneyUtils.stringToMilliunits('9000001'), isNull);
      expect(MoneyUtils.stringToMilliunits('NaN'), isNull);
    });
  });

  group('milliunitsToString', () {
    test('drops trailing zeros', () {
      expect(MoneyUtils.milliunitsToString(2000), '2');
      expect(MoneyUtils.milliunitsToString(1500), '1.5');
      expect(MoneyUtils.milliunitsToString(250), '0.25');
      expect(MoneyUtils.milliunitsToString(1230), '1.23');
      expect(MoneyUtils.milliunitsToString(-1500), '-1.5');
    });
  });

  group('tryLineTotalMinorUnits', () {
    test('multiplies exactly with round-half-up integer math', () {
      expect(MoneyUtils.tryLineTotalMinorUnits(500, 1500), 750);
      expect(MoneyUtils.tryLineTotalMinorUnits(5000, 1000), 5000);
      // 333 x 0.111 = 36.963 -> 37.
      expect(MoneyUtils.tryLineTotalMinorUnits(333, 111), 37);
      // 1005 x 0.1 = 100.5 -> 101 (ties always round up).
      expect(MoneyUtils.tryLineTotalMinorUnits(1005, 100), 101);
      expect(MoneyUtils.tryLineTotalMinorUnits(500, 0), 0);
    });

    test('returns null for negative inputs or overflow', () {
      expect(MoneyUtils.tryLineTotalMinorUnits(-1, 1000), isNull);
      expect(MoneyUtils.tryLineTotalMinorUnits(100, -1000), isNull);
      // 9e14 x 9e6 overflows a 64-bit integer.
      expect(
        MoneyUtils.tryLineTotalMinorUnits(900000000000000, 9000000),
        isNull,
      );
    });
  });
}
