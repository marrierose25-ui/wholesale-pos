class MoneyUtils {
  /// Converts a user input string (e.g., "4500.50") to integer minor units (e.g., 450050).
  /// Returns null if the string is invalid.
  static int? stringToMinorUnits(String value) {
    final cleaned = value.trim().replaceAll(',', '');
    final parsed = double.tryParse(cleaned);
    if (parsed == null || parsed < 0) return null;

    // Use round() to mitigate floating-point representation issues
    return (parsed * 100).round();
  }

  /// Converts integer minor units (e.g., 450050) to a display string (e.g., "4500.50").
  static String minorUnitsToString(int minorUnits) {
    final isNegative = minorUnits < 0;
    final absValue = minorUnits.abs();
    final stringValue = (absValue / 100).toStringAsFixed(2);
    return isNegative ? '-$stringValue' : stringValue;
  }
}
