// pos_local_engine - native SQLite persistence engine for Wholesale POS.
//
// This package owns the SQLite database lifecycle, schema, migrations,
// indexes, triggers, backup/restore, and local repository implementations.
//
// It depends on pos_core and pos_contracts, and on native SQLite packages.
// It must not depend on the main application package, frontend screens, or
// presentation controllers.

library pos_local_engine;

export 'src/pos_local_engine.dart';
export 'src/database/local_database.dart';
export 'src/database/local_database_app.dart';
export 'src/repositories/sqflite_sale_repository.dart';
export 'src/repositories/sqflite_finance_repository.dart';
export 'src/repositories/sqflite_shift_repository.dart';
export 'src/repositories/sqflite_user_repository.dart';
export 'src/repositories/sqflite_product_repository.dart';
export 'src/repositories/sqflite_picklist_repository.dart';
export 'src/repositories/sqflite_reporting_repository.dart';
export 'src/auth/settings_session_store.dart';
export 'src/backend/sqlite_local_data_ops.dart';
export 'src/sync/sqflite_sync_outbox_repository.dart';
export 'src/sync/sync_outbox.dart';
export 'src/sync/sync_pull_applier.dart';
export 'src/licensing/activation_client.dart';
export 'src/licensing/device_activation.dart';
export 'src/licensing/device_fingerprint.dart';
export 'src/licensing/license_validator.dart';
export 'src/utils/data_exporter.dart';
export 'src/utils/data_importer.dart';
export 'src/repositories/feature_gate.dart';
