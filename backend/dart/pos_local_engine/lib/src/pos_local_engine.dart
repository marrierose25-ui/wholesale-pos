import 'package:sqflite/sqflite.dart';

import 'database/local_database_app.dart';
import 'repositories/sqflite_sale_repository.dart';
import 'repositories/sqflite_finance_repository.dart';
import 'repositories/sqflite_shift_repository.dart';
import 'repositories/sqflite_user_repository.dart';
import 'repositories/sqflite_product_repository.dart';
import 'repositories/sqflite_picklist_repository.dart';
import 'repositories/sqflite_reporting_repository.dart';
import 'auth/settings_session_store.dart';
import 'backend/sqlite_local_data_ops.dart';
import 'sync/sqflite_sync_outbox_repository.dart';
import 'package:pos_contracts/pos_contracts.dart';

/// The initialized local engine providing all database and repository access.
class PosLocalEngine {
  final Database database;
  final ProductRepository productRepository;
  final SaleRepository saleRepository;
  final UserRepository userRepository;
  final ShiftRepository shiftRepository;
  final FinanceRepository financeRepository;
  final PicklistRepository picklistRepository;
  final ReportingRepository reportingRepository;
  final SessionStore sessionStore;
  final SyncOutboxRepository syncOutboxRepository;
  final SqliteLocalDataOps localDataOps;

  PosLocalEngine._({
    required this.database,
    required this.productRepository,
    required this.saleRepository,
    required this.userRepository,
    required this.shiftRepository,
    required this.financeRepository,
    required this.picklistRepository,
    required this.reportingRepository,
    required this.sessionStore,
    required this.syncOutboxRepository,
    required this.localDataOps,
  });

  /// Initializes the local engine by opening the database and constructing
  /// all repositories.
  static Future<PosLocalEngine> initialize() async {
    final db = await openApplicationDatabase();
    final productRepository = SqfliteProductRepository(db);
    final saleRepository = SqfliteSaleRepository(db, reporting: SqfliteReportingRepository(db));
    final userRepository = SqfliteUserRepository(db);
    final shiftRepository = SqfliteShiftRepository(db);
    final financeRepository = SqfliteFinanceRepository(db);
    final picklistRepository = SqflitePicklistRepository(db);
    final reportingRepository = SqfliteReportingRepository(db);
    final sessionStore = SettingsSessionStore(db);
    final syncOutboxRepository = SqfliteSyncOutboxRepository(db);
    final localDataOps = SqliteLocalDataOps(db);

    return PosLocalEngine._(
      database: db,
      productRepository: productRepository,
      saleRepository: saleRepository,
      userRepository: userRepository,
      shiftRepository: shiftRepository,
      financeRepository: financeRepository,
      picklistRepository: picklistRepository,
      reportingRepository: reportingRepository,
      sessionStore: sessionStore,
      syncOutboxRepository: syncOutboxRepository,
      localDataOps: localDataOps,
    );
  }
}