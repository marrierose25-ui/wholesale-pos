import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:wholesale_pos_app/core/database/local_database.dart';
import 'package:wholesale_pos_app/core/models/user.dart';
import 'package:wholesale_pos_app/core/repositories/finance_repository.dart';
import 'package:wholesale_pos_app/core/repositories/product_repository.dart';
import 'package:wholesale_pos_app/core/repositories/sale_repository.dart';
import 'package:wholesale_pos_app/core/repositories/user_repository.dart';
import 'package:wholesale_pos_app/features/audit/audit_log_screen.dart';
import 'package:wholesale_pos_app/features/dashboard/dashboard_screen.dart';
import 'package:wholesale_pos_app/features/finance/finance_overview_screen.dart';
import 'package:wholesale_pos_app/features/products/product_list_screen.dart';
import 'package:wholesale_pos_app/features/reports/reports_screen.dart';
import 'package:wholesale_pos_app/features/sales/sales_history_screen.dart';
import 'package:wholesale_pos_app/features/settings/settings_screen.dart';
import 'package:wholesale_pos_app/features/users/user_management_screen.dart';
import 'package:wholesale_pos_app/features/sales/sale.dart';
import 'package:wholesale_pos_app/features/sales/sale_item.dart';

// Device-free phone-width guard for every screen reachable from the compact
// (phone) navigation drawer. Each screen is rendered at a real phone size
// (390x844); any RenderFlex overflow is recorded by the framework and fails
// the test via `takeException`. POS + Register have their own dedicated tests.
void main() {
  late Database db;

  setUp(() async {
    db = await LocalDatabase.openInMemory();

    // Seed representative rows so the phone-width guard exercises populated
    // list tiles / stat breakdowns, not just empty states (empty layouts fit;
    // overflows hide in data rows). FK dependencies first.
    final now = DateTime.now().toIso8601String();
    await db.insert('users', {
      'id': 'u-owner',
      'username': 'owner',
      'password_hash': 'x',
      'salt': 'y',
      'role': 'OWNER',
      'created_at': now,
    });
    await db.insert('users', {
      'id': 'u-cashier',
      'username': 'cashier-long-username-example',
      'password_hash': 'x',
      'salt': 'y',
      'role': 'CASHIER',
      'created_at': now,
    });
    await db.insert('devices', {
      'id': 'device-1',
      'name': 'Till 1',
      'platform': 'Windows',
    });
    await db.insert('shifts', {
      'id': 'shift-1',
      'cashier_id': 'u-owner',
      'opening_cash_minor_units': 5000,
      'status': 'OPEN',
      'opened_at': now,
    });
    await db.insert('products', {
      'id': 'prod-1',
      'name': 'Super Sugar 1kg (bulk carton pack)',
      'code': 'SUGAR-1KG-BULK-CARTON-XYZ',
      'category': 'Groceries',
      'unit': 'kg',
      'selling_price_minor_units': 5000,
      'created_at': now,
      'updated_at': now,
    });
    await SaleRepository(db).saveSale(
      Sale(
        id: 'sale-1',
        receiptNumber: 'REC-0001',
        cashierId: 'u-owner',
        deviceId: 'device-1',
        shiftId: 'shift-1',
        customerName: 'Abebe Kebede Wholesale Merchant',
        subtotalMinorUnits: 5000,
        discountMinorUnits: 0,
        totalMinorUnits: 5000,
        amountPaidMinorUnits: 5000,
        changeMinorUnits: 0,
        createdAt: DateTime.now(),
        items: [
          SaleItem(
            id: 'item-1',
            saleId: 'sale-1',
            productId: 'prod-1',
            productNameSnapshot: 'Super Sugar 1kg (bulk carton pack)',
            unitPriceSnapshotMinorUnits: 5000,
            quantityText: '1',
            billingQuantityMilliunits: 1000,
            lineTotalMinorUnits: 5000,
          ),
        ],
      ),
    );
    final catId = 'fin-cat-1';
    await db.insert('finance_categories', {
      'id': catId,
      'name': 'Transport & Logistics Costs',
      'created_at': now,
      'updated_at': now,
    });
    await db.insert('finance_entries', {
      'id': 'fin-entry-1',
      'category_id': catId,
      'source': 'ABC Shipping Company Limited',
      'amount_minor_units': 120000,
      'description': 'Monthly warehouse delivery truck rental settlement',
      'status': 'PENDING',
      'entry_date': now,
      'created_at': now,
      'created_by': 'u-owner',
      'updated_at': now,
    });
  });

  tearDown(() async {
    await db.close();
  });

  final owner = User(
    id: 'u-owner',
    username: 'owner',
    passwordHash: 'x',
    salt: 'y',
    role: 'OWNER',
  );

  // Pumps [screen] at phone width on the real event loop (so sqflite's async
  // loads + their watchdog timers complete/cancel) and asserts no overflow.
  Future<void> pumpAtPhone(WidgetTester tester, Widget screen) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(home: screen));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await tester.pump();
    });

    expect(tester.takeException(), isNull);
  }

  testWidgets('Sales history lays out at phone width', (tester) async {
    await pumpAtPhone(
      tester,
      SalesHistoryScreen(
        saleRepository: SaleRepository(db),
        currentUser: owner,
        onSaleVoided: () {},
      ),
    );
  });

  testWidgets('Product list lays out at phone width', (tester) async {
    await pumpAtPhone(
      tester,
      ProductListScreen(repository: ProductRepository(db)),
    );
  });

  testWidgets('Dashboard lays out at phone width', (tester) async {
    await pumpAtPhone(
      tester,
      DashboardScreen(saleRepository: SaleRepository(db)),
    );
  });

  testWidgets('Reports lays out at phone width', (tester) async {
    await pumpAtPhone(
      tester,
      ReportsScreen(saleRepository: SaleRepository(db)),
    );
  });

  testWidgets('User management lays out at phone width', (tester) async {
    await pumpAtPhone(
      tester,
      UserManagementScreen(
        userRepository: UserRepository(db),
        currentUser: owner,
      ),
    );
  });

  testWidgets('Audit log lays out at phone width', (tester) async {
    await pumpAtPhone(
      tester,
      AuditLogScreen(saleRepository: SaleRepository(db)),
    );
  });

  testWidgets('Finance overview lays out at phone width', (tester) async {
    await pumpAtPhone(
      tester,
      FinanceOverviewScreen(
        financeRepository: FinanceRepository(db),
        currentUser: owner,
      ),
    );
  });

  testWidgets('Settings lays out at phone width', (tester) async {
    await pumpAtPhone(
      tester,
      SettingsScreen(
        currentUser: owner,
        db: db,
        userRepository: UserRepository(db),
        onLogout: () {},
        isDarkMode: false,
        onToggleTheme: () {},
      ),
    );
  });
}
