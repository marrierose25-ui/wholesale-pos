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
}
