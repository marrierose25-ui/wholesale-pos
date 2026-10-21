class MoneyUtils {
  static final RegExp _amountPattern = RegExp(r'^(\d+)(?:\.(\d{0,2}))?$');

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
}
