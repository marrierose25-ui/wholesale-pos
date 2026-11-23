/// Phone-number identity rules shared by the local and cloud repositories.
///
/// An account's login identifier is an Ethiopian mobile number. The value is
/// stored in the existing `username` column (native `users.username`, cloud
/// `pos_users.username`) as one canonical form so lookups stay exact and
/// unique: a leading `0`, then `9` or `7`, then eight digits (e.g.
/// `0912345678`). Anything the cashier can reasonably type is accepted on the
/// way in — `+251912345678`, `251912345678`, `912345678`, spaces, dashes and
/// parentheses are all folded to the same canonical value.
///
/// The permanent training account is the one documented exception: its
/// identifier is the literal `demo`, so a trainee only has to type that.
class PhoneNumber {
  PhoneNumber._();

  /// Identifier of the seeded training account.
  static const String demo = 'demo';

  /// Canonical local mobile form: 0 + 9/7 + 8 digits.
  static final RegExp _canonical = RegExp(r'^0[79]\d{8}$');

  /// A bare subscriber number without the trunk 0 (9 + 8 digits).
  static final RegExp _national = RegExp(r'^[79]\d{8}$');

  /// Human-readable example used in validation messages and hints.
  static const String example = '0912345678';

  static const String invalidMessage =
      'Enter a valid phone number, for example $example.';

  /// True when [raw] is the training account's identifier (any casing).
  static bool isDemo(String raw) => raw.trim().toLowerCase() == demo;

  /// Folds any accepted spelling of a mobile number into the canonical form,
  /// or returns null when it is not a usable phone number.
  static String? normalize(String raw) {
    var digits = raw.trim().replaceAll(RegExp(r'[\s\-()]'), '');
    if (digits.startsWith('+251')) {
      digits = '0${digits.substring(4)}';
    } else if (digits.startsWith('251') && digits.length == 12) {
      digits = '0${digits.substring(3)}';
    } else if (_national.hasMatch(digits)) {
      digits = '0$digits';
    }
    return _canonical.hasMatch(digits) ? digits : null;
  }

  /// Identifier used to look an account up at sign-in. A valid phone number is
  /// normalised; the demo account passes through; anything else is returned
  /// as typed so accounts created before phone-number login (e.g. `owner`)
  /// keep working until the owner edits them.
  static String loginIdentifier(String raw) {
    final trimmed = raw.trim();
    if (isDemo(trimmed)) return demo;
    return normalize(trimmed) ?? trimmed;
  }
}