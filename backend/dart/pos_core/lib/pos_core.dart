/// Wholesale POS domain entities.
///
/// Pure Dart: this package intentionally has no Flutter, SQLite, Supabase, or
/// presentation imports so every layer (native repositories, cloud clients,
/// sync, UI) can share one authoritative model definition.
library;

export 'src/modules/catalog/domain/entities/product.dart';
export 'src/modules/finance/domain/entities/finance_category.dart';
export 'src/modules/finance/domain/entities/finance_entry.dart';
export 'src/modules/register/domain/entities/cash_movement.dart';
export 'src/modules/register/domain/entities/shift.dart';
export 'src/modules/sales/domain/entities/sale.dart';
export 'src/modules/sales/domain/entities/sale_item.dart';
export 'src/modules/sales/domain/entities/void_request.dart';
export 'src/modules/users/domain/entities/user.dart';
export 'src/modules/warehouse/domain/entities/picklist.dart';
export 'src/modules/warehouse/domain/entities/picklist_customer.dart';
export 'src/modules/warehouse/domain/entities/picklist_item.dart';
