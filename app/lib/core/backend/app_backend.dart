import 'package:flutter/widgets.dart';

import '../auth/session_store.dart';
import '../models/user.dart';
import '../repositories/finance_repository.dart';
import '../repositories/product_repository.dart';
import '../repositories/sale_repository.dart';
import '../repositories/shift_repository.dart';
import '../repositories/user_repository.dart';

/// The storage + platform seam every shell widget talks to instead of a raw
/// `Database`.
///
/// Milestone 1 put the data-access behind repository interfaces; this is the
/// companion seam that removes the last `Database` references from the shared
/// shell (theme persistence, the "stay signed in" session, the shop's device
/// id, and the platform-appropriate settings screen). [NativeBackend] wraps the
/// local-first SQLite stack; [CloudBackend] wraps the `pos-api` Edge Function.
///
/// The whole point is that the shared shell in `app_shell.dart` depends ONLY on
/// this abstract type, so the browser compile graph never pulls in the
/// `dart:io`-coupled pieces (`SettingsScreen`'s backup/restore + device
/// management) — those live behind [settingsScreen] and [buildActivationGate],
/// supplied per platform.
abstract class AppBackend {
  ProductRepository get products;
  SaleRepository get sales;
  UserRepository get users;
  ShiftRepository get shifts;
  FinanceRepository get finance;

  /// Persists the opaque "stay signed in" session.
  SessionStore get session;

  /// Stable identifier stamped on every sale this device/browser records.
  String get deviceId;

  /// The settings key holding the chosen theme ('dark' | 'light').
  static const String themeSettingKey = 'theme_mode';

  Future<String?> getSetting(String key);

  Future<void> setSetting(String key, String value);

  /// Whether this backend offers the native-only local data tools (backup /
  /// restore / device seat management). The browser build returns false, so the
  /// shared settings UI hides them without importing any `dart:io` code.
  bool get supportsLocalDataOps => false;

  /// Native tills license-activate before the shell ever runs, so from the
  /// shell's point of view they are always provisioned. The web build must
  /// capture the shop's activation code (its tenant identity) first.
  bool get isProvisioned => true;

  /// Shown by the shell when [isProvisioned] is false. Only the web backend
  /// reaches this; native inherits the (never-invoked) default.
  Widget buildActivationGate({required VoidCallback onReady}) =>
      throw UnsupportedError('This backend is always provisioned.');

  /// The platform-appropriate Settings screen. Kept behind the seam so the
  /// shared shell never imports the `dart:io`-coupled `SettingsScreen`.
  Widget settingsScreen({
    required User currentUser,
    required VoidCallback onLogout,
    required bool isDarkMode,
    required VoidCallback onToggleTheme,
  });
}
