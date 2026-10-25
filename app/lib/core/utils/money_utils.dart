class MoneyUtils {
  static final RegExp _amountPattern = RegExp(r'^(\d+)(?:\.(\d{0,2}))?$');
  static final RegExp _quantityPattern = RegExp(r'^(\d{1,9})(?:\.(\d{1,3}))?$');

  /// Converts a user input string (e.g., "4500.50") to integer minor units
  /// (e.g., 450050). Returns null when the value is not a plain non-negative
  /// amount with at most two decimal places.
  static int? stringToMinorUnits(String value) {
    final cleaned = value.trim().replaceAll(',', '');
    if (cleaned.isEmpty) return null;
    final match = _amountPattern.firstMatch(cleaned);
    if (match == null) return null;

    final wholeUnits = int.tryParse(match.group(1)!);
    if (wholeUnits == null) return null;
    final fraction = (match.group(2) ?? '').padRight(2, '0');
    final minorUnits = int.tryParse(fraction);
    if (minorUnits == null) return null;

    // Guard against values that would overflow a 64-bit integer.
    if (wholeUnits > 90000000000000) return null;
    return wholeUnits * 100 + minorUnits;
  }

  /// Converts integer minor units (e.g., 450050) to a display string
  /// (e.g., "4500.50") without floating-point arithmetic.
  static String minorUnitsToString(int minorUnits) {
    final isNegative = minorUnits < 0;
    final absValue = minorUnits.abs();
    final wholeUnits = absValue ~/ 100;
    final fraction = (absValue % 100).toString().padLeft(2, '0');
    final formatted = '$wholeUnits.$fraction';
    return isNegative ? '-$formatted' : formatted;
  }

  /// Formats minor units as an Ethiopian-birr amount, e.g. `1,250.50 Br`.
  /// This is the app-wide currency format; use it everywhere money is shown.
  static String formatBr(int minorUnits) {
    final plain = minorUnitsToString(minorUnits);
    final isNegative = plain.startsWith('-');
    final unsigned = isNegative ? plain.substring(1) : plain;
    final parts = unsigned.split('.');
    final grouped = _groupThousands(parts[0]);
    final formatted = '$grouped.${parts[1]} Br';
    return isNegative ? '-$formatted' : formatted;
  }

  static String _groupThousands(String digits) {
    final buffer = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      buffer.write(digits[i]);
      final remaining = digits.length - i - 1;
      if (remaining > 0 && remaining % 3 == 0) buffer.write(',');
    }
    return buffer.toString();
  }

  /// Parses a plain decimal quantity such as "2", "1.5", or "0.25" into
  /// milliunits (1500 means 1.5). Returns null when the text is not a plain
  /// number, which lets callers keep descriptive quantities like
  /// "2 boxes and 1 piece" as text instead of guessing a value.
  static int? stringToMilliunits(String value) {
    final cleaned = value.trim().replaceAll(',', '');
    if (cleaned.isEmpty) return null;
    final match = _quantityPattern.firstMatch(cleaned);
    if (match == null) return null;

    final wholeUnits = int.tryParse(match.group(1)!);
    if (wholeUnits == null) return null;
    final fraction = (match.group(2) ?? '').padRight(3, '0');
    final fractionMilliunits = int.tryParse(fraction);
    if (fractionMilliunits == null) return null;

    // Guard against values that would overflow a 64-bit integer once scaled.
    if (wholeUnits > 9000000) return null;
    return wholeUnits * 1000 + fractionMilliunits;
  }

  /// Converts milliunits (1500 = 1.5) to a short decimal string ("1.5").
  /// Trailing zeros are dropped so "2" stays "2" and "0.25" stays "0.25".
  static String milliunitsToString(int milliunits) {
    final isNegative = milliunits < 0;
    final absValue = milliunits.abs();
    final whole = absValue ~/ 1000;
    var fraction = (absValue % 1000).toString().padLeft(3, '0');
    while (fraction.length > 1 && fraction.endsWith('0')) {
      fraction = fraction.substring(0, fraction.length - 1);
    }
    final formatted = fraction == '0' ? '$whole' : '$whole.$fraction';
    return isNegative ? '-$formatted' : formatted;
  }

  /// Multiplies a unit price by a billing quantity (milliunits) and rounds
  /// half-up to minor units using exact integer math — no floating point.
  /// Example: 500 minor units x 1500 milliunits (1.5) = 750 minor units.
  /// Returns null when inputs are negative or the result would overflow.
  static int? tryLineTotalMinorUnits(
    int unitPriceMinorUnits,
    int billingQuantityMilliunits,
  ) {
    if (unitPriceMinorUnits < 0 || billingQuantityMilliunits < 0) return null;
    if (billingQuantityMilliunits == 0) return 0;

    final product = unitPriceMinorUnits * billingQuantityMilliunits;
    // Detect 64-bit overflow: the division must give back the original price.
    if (product < 0 ||
        product ~/ billingQuantityMilliunits != unitPriceMinorUnits) {
      return null;
    }
    // Cap the result at JS MAX_SAFE_INTEGER (2^53-1). On the web build Dart
    // `int` is a double, so any product above this can no longer be divided
    // back down exactly — refusing it here guarantees the identical line total
    // is accepted on web as on native, instead of silently drifting. Real-world
    // amounts (guarded well below 2^53 by the input parsers) are never affected.
    if (product > 9007199254740991 - 500) return null;
    return (product + 500) ~/ 1000;
  }
}
