import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:pos_cloud_engine/pos_cloud_engine.dart' show CloudApiClient;
import 'package:pos_contracts/pos_contracts.dart' hide AppBackend;
import 'package:pos_local_engine/pos_local_engine.dart';
import 'package:sqflite/sqflite.dart';

import '../sync/owner_action_reconciler.dart';
import 'app_backend.dart';
import '../../features/settings/settings_screen.dart';

/// The native [AppBackend]: wraps the existing SQLite repositories and
/// services so the shared shell ([PosRoot]) can drive both platforms through
/// one contract. Constructed once in `main()`; owns no widgets.
class NativeBackend extends AppBackend implements LocalDataOpsProvider {
  final Database _db;
  @override
  final String deviceId;

  late final ProductRepository _products;
  late final SaleRepository _sales;
  late final ReportingRepository _reporting;
  late final UserRepository _users;
  late final ShiftRepository _shifts;
  late final FinanceRepository _finance;
  late final PicklistRepository _picklists;
  late final InventoryRepository _inventory;
  late final SessionStore _session;
  late final SqliteLocalDataOps _localDataOps;

  /// The underlying SQLite handle, exposed for owner-only recovery surfaces
  /// (e.g. the pending owner-actions Settings tile) that must read the
  /// pending-action store directly. Not part of [AppBackend].
  Database get db => _db;

  /// One-round-trip settings bootstrap for the Settings screen: the
  /// remember-login flag AND the pending owner-action status in a SINGLE
  /// query. Two separate sqflite calls in initState serialize on the ffi
  /// isolate and the second routinely outlives a widget test's teardown,
  /// leaking its timeout timer (Stage 4.1.4).
  Future<
      ({
        String? remember,
        int pendingOwnerActions,
        bool pendingOwnerActionsCorrupt,
      })> settingsBootstrap() async {
    final rows = await _db.query(
      'settings',
      columns: const ['key', 'value'],
      where: 'key IN (?, ?)',
      whereArgs: const [SessionStore.rememberKey, PendingOwnerActions.settingKey],
    );
    String? remember;
    var pendingRaw = '';
    for (final row in rows) {
      if (row['key'] == SessionStore.rememberKey) {
        remember = row['value'] as String?;
      } else if (row['key'] == PendingOwnerActions.settingKey) {
        pendingRaw = row['value'] as String? ?? '';
      }
    }
    if (pendingRaw.isEmpty) {
      return (
        remember: remember,
        pendingOwnerActions: 0,
        pendingOwnerActionsCorrupt: false,
      );
    }
    try {
      final decoded = jsonDecode(pendingRaw);
      if (decoded is! List) throw const FormatException('not a list');
      var count = 0;
      for (final item in decoded) {
        if (item is! Map<String, dynamic> ||
            PendingOwnerAction.fromJson(item) == null) {
          throw const FormatException('invalid entry');
        }
        count++;
      }
      return (
        remember: remember,
        pendingOwnerActions: count,
        pendingOwnerActionsCorrupt: false,
      );
    } catch (_) {
      return (
        remember: remember,
        pendingOwnerActions: -1,
        pendingOwnerActionsCorrupt: true,
      );
    }
  }

  /// Unresolved offline owner transitions awaiting cloud authorization.
  /// Returns `(count, corrupt)` in ONE store read — two sequential queries
  /// lengthen the async window during widget tests/teardown for no benefit.
  /// `count` is -1 when the pending store is corrupt (raw preserved).
  Future<({int count, bool corrupt})> pendingOwnerActionStatus() async {
    try {
      return (
        count: (await PendingOwnerActions.load(_db)).length,
        corrupt: false,
      );
    } on PendingOwnerActionsCorrupt {
      return (count: -1, corrupt: true);
    }
  }

  /// Builds the pos-api reconciler for pending owner actions, or null when
  /// this build lacks the API URL or the device has no activation code.
  /// The owner still re-authenticates with cloud credentials per call.
  Future<OwnerActionReconciler?> ownerActionReconciler() async {
    final apiUrl = const String.fromEnvironment('WHOLESALE_POS_API_URL');
    final activationCode =
        await LocalDatabase.getSetting(_db, DeviceActivation.activationCodeKey) ??
        '';
    if (apiUrl.isEmpty || activationCode.isEmpty) return null;
    return OwnerActionReconciler(
      db: _db,
      api: CloudApiClient(url: apiUrl, activationCode: activationCode),
      activationCode: activationCode,
    );
  }

  NativeBackend({
    required Database db,
    required this.deviceId,
    ProductRepository? products,
    SaleRepository? sales,
    ReportingRepository? reporting,
    UserRepository? users,
    ShiftRepository? shifts,
    FinanceRepository? finance,
    PicklistRepository? picklists,
    InventoryRepository? inventory,
    SessionStore? session,
  }) : _db = db,
       _products = products ?? SqfliteProductRepository(db),
       _sales = sales ?? SqfliteSaleRepository(db),
       _reporting = reporting ?? SqfliteReportingRepository(db),
       _users = users ?? SqfliteUserRepository(db),
       _shifts = shifts ?? SqfliteShiftRepository(db),
       _finance = finance ?? SqfliteFinanceRepository(db),
       _picklists = picklists ?? SqflitePicklistRepository(db),
       _inventory = inventory ?? SqfliteInventoryRepository(db),
       _session = session ?? SettingsSessionStore(db),
       _localDataOps = SqliteLocalDataOps(db);

  @override
  ProductRepository get products => _products;
  @override
  SaleRepository get sales => _sales;
  @override
  ReportingRepository get reporting => _reporting;
  @override
  UserRepository get users => _users;
  @override
  ShiftRepository get shifts => _shifts;
  @override
  FinanceRepository get finance => _finance;
  @override
  PicklistRepository? get picklists => _picklists;
  @override
  InventoryRepository? get inventory => _inventory;
  @override
  SessionStore get session => _session;

  @override
  LocalDataOps get localDataOps => _localDataOps;

  /// Native tills offer backup / restore / device-seat management.
  @override
  bool get supportsLocalDataOps => true;

  @override
  Future<String?> getSetting(String key) => LocalDatabase.getSetting(_db, key);

  @override
  Future<void> setSetting(String key, String value) =>
      LocalDatabase.setSetting(_db, key, value);

  @override
  Widget settingsScreen({
    required User currentUser,
    required VoidCallback onLogout,
    required bool isDarkMode,
    required VoidCallback onToggleTheme,
  }) {
    return SettingsScreen(
      currentUser: currentUser,
      backend: this,
      onLogout: onLogout,
      isDarkMode: isDarkMode,
      onToggleTheme: onToggleTheme,
      syncRuntime: null,
    );
  }
}
