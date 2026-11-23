// pos_contracts - platform-independent backend interfaces and contracts for Wholesale POS.
//
// This package contains only pure Dart interfaces and contract types. It has
// no dependency on Flutter, sqflite, path_provider, dart:io, Supabase, or any
// platform-specific implementation.

library pos_contracts;

export 'src/repositories/sale_repository.dart';
export 'src/repositories/finance_repository.dart';
export 'src/repositories/shift_repository.dart';
export 'src/repositories/user_repository.dart';
export 'src/repositories/product_repository.dart';
export 'src/repositories/picklist_repository.dart';
export 'src/repositories/reporting_repository.dart';
export 'src/repositories/feature_gate.dart';

export 'src/auth/session_store.dart';

export 'src/backend/app_backend.dart';
export 'src/backend/local_data_ops.dart';

export 'src/sync/sync_outbox_entry.dart';
export 'src/sync/sync_outbox_repository.dart';
export 'src/sync/sync_backend.dart';

export 'src/licensing/device_activation.dart';

export 'src/utils/money_utils.dart';
export 'src/utils/demo_operator.dart';
export 'src/utils/date_range.dart';
export 'src/utils/phone_number.dart';
export 'src/utils/app_logger.dart';

// Re-export domain entities needed for the backend interfaces
export 'package:pos_core/pos_core.dart' show User;
