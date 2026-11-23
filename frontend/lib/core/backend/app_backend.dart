import 'package:flutter/widgets.dart';
import 'package:pos_contracts/pos_contracts.dart' as pos_contracts;
import 'package:pos_core/pos_core.dart';

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
abstract class AppBackend extends pos_contracts.AppBackend {
  /// Alias for the contract's settings key so shell call sites can keep using
  /// `AppBackend.themeSettingKey` (statics are not inherited).
  static const String themeSettingKey = pos_contracts.AppBackend.themeSettingKey;

  @override
  pos_contracts.ReportingRepository? get reporting => null;

  /// Warehouse Picklists (Digital Fulfillment). Null by default: the browser
  /// build reads everything through `pos-api`, which has no picklist endpoints,
  /// so the web shell simply does not render the Warehouse tab. A native /
  /// SQLite-backed seam would supply a real repository here. Keeping it null is
  /// the deliberate isolation that guarantees picklists can never reach Sales.
  @override
  pos_contracts.PicklistRepository? get picklists => null;

  /// Whether this backend offers the native-only local data tools (backup /
  /// restore / device seat management). The browser build returns false, so the
  /// shared settings UI hides them without importing any `dart:io` code.
  @override
  bool get supportsLocalDataOps => false;

  /// Native tills license-activate before the shell ever runs, so from the
  /// shell's point of view they are always provisioned. The web build must
  /// capture the shop's activation code (its tenant identity) first.
  @override
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
