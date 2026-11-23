import 'package:flutter/widgets.dart';
import 'package:pos_contracts/pos_contracts.dart' hide AppBackend;
import 'package:pos_local_engine/pos_local_engine.dart';
import 'package:sqflite/sqflite.dart';

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
  late final SessionStore _session;
  late final SqliteLocalDataOps _localDataOps;

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
    SessionStore? session,
  }) : _db = db,
       _products = products ?? SqfliteProductRepository(db),
       _sales = sales ?? SqfliteSaleRepository(db),
       _reporting = reporting ?? SqfliteReportingRepository(db),
       _users = users ?? SqfliteUserRepository(db),
       _shifts = shifts ?? SqfliteShiftRepository(db),
       _finance = finance ?? SqfliteFinanceRepository(db),
       _picklists = picklists ?? SqflitePicklistRepository(db),
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
