import 'package:flutter_test/flutter_test.dart';
import 'package:wholesale_pos_app/core/util/phone_number.dart';

// The login identifier is an Ethiopian mobile number stored in one canonical
// form (0 + 9/7 + 8 digits). These cases pin the folding rules shared by the
// native repository and `pos-api`, plus the demo account exception.
void main() {
  group('PhoneNumber.normalize', () {
    test('folds every accepted spelling to the canonical form', () {
      for (final input in [
        '0912345678',
        '+251912345678',
        '251912345678',
        '912345678',
        '0912 345 678',
        '0912-345-678',
        '(0912) 345678',
        '  0912345678  ',
      ]) {
        expect(PhoneNumber.normalize(input), '0912345678', reason: input);
      }
      // 07 numbers are just as valid.
      expect(PhoneNumber.normalize('+251712345678'), '0712345678');
      expect(PhoneNumber.normalize('712345678'), '0712345678');
    });

    test('rejects names, wrong lengths and non-mobile prefixes', () {
      for (final input in [
        '',
        'demo',
        'cashier',
        '091234567', // 8 digits
        '09123456789', // 10 digits after the trunk 0
        '0612345678', // not a mobile prefix
        '0912A45678',
        '+1 (555) 010-9999',
      ]) {
        expect(PhoneNumber.normalize(input), isNull, reason: input);
      }
    });
  });

  group('PhoneNumber.loginIdentifier', () {
    test('normalises phones and passes legacy identifiers through', () {
      expect(PhoneNumber.loginIdentifier('+251 912 345 678'), '0912345678');
      expect(PhoneNumber.loginIdentifier(' 0912-345-678 '), '0912345678');
      // Accounts created before phone-number login keep working until renamed.
      expect(PhoneNumber.loginIdentifier('owner'), 'owner');
      expect(PhoneNumber.loginIdentifier('  '), '');
    });

    test('keeps the demo login exactly as `demo`', () {
      expect(PhoneNumber.loginIdentifier('demo'), 'demo');
      expect(PhoneNumber.loginIdentifier(' DEMO '), 'demo');
      expect(PhoneNumber.isDemo('Demo'), isTrue);
      expect(PhoneNumber.isDemo('0912345678'), isFalse);
    });
  });
}
