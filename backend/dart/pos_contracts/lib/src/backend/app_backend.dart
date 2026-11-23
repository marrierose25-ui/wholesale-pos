import '../auth/session_store.dart';
import '../repositories/finance_repository.dart';
import '../repositories/picklist_repository.dart';
import '../repositories/product_repository.dart';
import '../repositories/reporting_repository.dart';
import '../repositories/sale_repository.dart';
import '../repositories/shift_repository.dart';
import '../repositories/user_repository.dart';

/// The storage + platform seam every shell widget talks to instead of a raw
/// `Database`.
///
/// Milestone 1 put the data-access behind repository interfaces; this is the
/// companion seam that removes the last `Database` references from the shared
/// shell (theme persistence, the "stay signed in" session, the shop's device
/// id). [NativeBackend] wraps the local-first SQLite stack; [CloudBackend]
/// wraps the `pos-api` Edge Function.
///
/// This contract describes application capabilities and backend-facing
/// services only — it never constructs widgets or screens. Screen selection
/// is the frontend shell's job; the web shell builds `WebActivationGate` /
/// `WebSettingsScreen` itself from [isProvisioned] / [provisionShop].
abstract class AppBackend {
  ProductRepository get products;
  SaleRepository get sales;

  /// Read-only reporting capability (dashboard stats, revenue trend, audit
  /// log, product summary, cashier performance). Separated from
  /// [SaleRepository] in Stage 4; [SaleRepository] still exposes the same
  /// methods as compatibility delegates for existing consumers. Null by default:
  /// native backends supply a real repository; web backends return null since
  /// the browser reads reporting through `pos-api` which has no dedicated
  /// reporting endpoints (stats come from the sales stream).
  ReportingRepository? get reporting => null;
  UserRepository get users;
  ShiftRepository get shifts;
  FinanceRepository get finance;

  /// Warehouse Picklists (Digital Fulfillment). Null by default: the browser
  /// build reads everything through `pos-api`, which has no picklist endpoints,
  /// so the web shell simply does not render the Warehouse tab. A native /
  /// SQLite-backed seam would supply a real repository here. Keeping it null is
  /// the deliberate isolation that guarantees picklists can never reach Sales.
  PicklistRepository? get picklists => null;

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

  /// Verifies and persists a shop activation code (the web build's tenant
  /// identity) before sign-in. Returns a display-safe error string, or null on
  /// success. Only reachable when [isProvisioned] is false; native tills are
  /// always provisioned and never call this.
  Future<String?> provisionShop(String code) =>
      throw UnsupportedError('This backend is always provisioned.');
}
