import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:pos_local_engine/pos_local_engine.dart';
import 'package:pos_core/pos_core.dart';
import 'package:wholesale_pos_app/core/backend/native_backend.dart';
import 'package:wholesale_pos_app/core/theme/app_design.dart';
import 'package:wholesale_pos_app/core/theme/app_theme.dart';
import 'package:wholesale_pos_app/features/audit/audit_log_screen.dart';
import 'package:wholesale_pos_app/features/auth/login_screen.dart';
import 'package:wholesale_pos_app/features/dashboard/dashboard_screen.dart';
import 'package:wholesale_pos_app/features/dashboard/sales_by_day_screen.dart';
import 'package:wholesale_pos_app/features/finance/finance_overview_screen.dart';
import 'package:wholesale_pos_app/features/finance/finance_person_screen.dart';
import 'package:wholesale_pos_app/features/licensing/activation_screen.dart';
import 'package:wholesale_pos_app/features/register/register_screen.dart';
import 'package:wholesale_pos_app/features/reports/reports_screen.dart';
import 'package:wholesale_pos_app/features/sales/sales_screen.dart';
import 'package:wholesale_pos_app/features/settings/settings_screen.dart';
import 'package:wholesale_pos_app/features/users/user_management_screen.dart';
import 'package:wholesale_pos_app/features/warehouse/warehouse_history_screen.dart';
import 'package:wholesale_pos_app/features/warehouse/warehouse_screen.dart';

// Whole-app rendering matrix: every primary screen at small-phone, phone,
// tablet and desktop widths, in BOTH light and dark themes. A RenderFlex
// overflow (or any other framework exception) fails the test, so layout
// regressions surface on any supported device shape before release.
//
// Rows are seeded with deliberately long names/amounts: empty screens always
// fit, and overflows hide in populated data rows.
const List<Size> _sizes = [
  Size(320, 568), // small phone (iPhone SE 1st gen / low-end Android)
  Size(390, 844), // mainstream phone
  Size(768, 1024), // tablet portrait
  Size(1280, 800), // desktop / tablet landscape
];

const List<Brightness> _brightnesses = [Brightness.light, Brightness.dark];

void main() {
  late Database db;
  late User owner;

  setUp(() async {
    db = await LocalDatabase.openInMemory();
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
      'username': 'cashier-with-a-very-long-username',
      'password_hash': 'x',
      'salt': 'y',
      'role': 'CASHIER',
      'created_at': now,
    });
    await db.insert('devices', {
      'id': 'test-device',
      'name': 'Front Counter Till',
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
    await SqfliteSaleRepository(db).saveSale(
      Sale(
        id: 'sale-1',
        receiptNumber: 'REC-0001',
        cashierId: 'u-owner',
        deviceId: 'test-device',
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

    await db.insert('finance_categories', {
      'id': 'fin-cat-1',
      'name': 'Transport & Logistics Costs',
      'created_at': now,
      'updated_at': now,
    });
    await db.insert('finance_entries', {
      'id': 'fin-entry-1',
      'category_id': 'fin-cat-1',
      'source': 'ABC Shipping Company Limited',
      'amount_minor_units': 120000,
      'description': 'Monthly warehouse delivery truck rental settlement',
      'status': 'PENDING',
      'entry_date': now,
      'created_at': now,
      'created_by': 'u-owner',
      'updated_at': now,
    });

    await db.insert('picklists', {
      'id': 'pl-1',
      'customer_name': 'Abebe Kebede Wholesale Merchant',
      'status': 'PENDING',
      'created_by': 'u-owner',
      'created_at': now,
      'updated_at': now,
    });
    await db.insert('picklist_items', {
      'id': 'pli-1',
      'picklist_id': 'pl-1',
      'product_name': 'Super Sugar 1kg (bulk carton pack)',
      'requested_qty': 500,
      'taken_qty': 120,
      'unit': 'Karton',
      'unit_price_minor_units': 4550,
      'line_total_minor_units': 2275000,
      'updated_at': now,
    });
    await db.insert('picklist_customers', {
      'id': 'pc-1',
      'name': 'Abebe Kebede Wholesale Merchant',
      'phone': '+251 911 111 111',
      'created_at': now,
    });

    owner = User(
      id: 'u-owner',
      username: 'owner',
      passwordHash: 'x',
      salt: 'y',
      role: 'OWNER',
    );
  });

  tearDown(() async {
    AppDesign.setMode(Brightness.dark);
    await db.close();
  });

  final screens = <String, Widget Function(Brightness)>{
    'Login': (_) =>
        LoginScreen(userRepository: SqfliteUserRepository(db), onLoginSuccess: (_) {}),
    'Activation': (_) => ActivationScreen(
      onActivated: () {},
      hardwareIdProvider: () async => 'AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-1111-2222',
      showCodeEntry: true,
      onActivateWithCode: (_) async => null,
    ),
    'Dashboard': (_) =>
        DashboardScreen(saleRepository: SqfliteSaleRepository(db), currentUser: owner),
    'POS': (_) => SalesScreen(
      saleRepository: SqfliteSaleRepository(db),
      shiftRepository: SqfliteShiftRepository(db),
      deviceId: 'test-device',
      currentUser: owner,
      onSaleCompleted: () {},
    ),
    'Register': (_) => RegisterScreen(
      currentUser: owner,
      shiftRepository: SqfliteShiftRepository(db),
      saleRepository: SqfliteSaleRepository(db),
      onShiftUpdated: () {},
    ),
    'Finance': (_) => FinanceOverviewScreen(
      financeRepository: SqfliteFinanceRepository(db),
      currentUser: owner,
    ),
    'Finance person': (_) => FinancePersonScreen(
      financeRepository: SqfliteFinanceRepository(db),
      currentUser: owner,
      categoryId: 'fin-cat-1',
      personName: 'ABC Shipping Company Limited',
    ),
    'Warehouse': (_) =>
        WarehouseScreen(repository: SqflitePicklistRepository(db), currentUser: owner),
    'Warehouse history': (_) => WarehouseHistoryScreen(
      repository: SqflitePicklistRepository(db),
      showMoney: true,
    ),
    'Reports': (_) =>
        ReportsScreen(saleRepository: SqfliteSaleRepository(db), currentUser: owner),
    'Users': (_) => UserManagementScreen(
      userRepository: SqfliteUserRepository(db),
      currentUser: owner,
    ),
    'Audit': (_) =>
        AuditLogScreen(saleRepository: SqfliteSaleRepository(db), currentUser: owner),
    'Sales history': (_) => SalesByDayScreen(
      saleRepository: SqfliteSaleRepository(db),
      currentUser: owner,
      onSaleVoided: () {},
    ),
    'Settings': (brightness) => SettingsScreen(
      currentUser: owner,
      backend: NativeBackend(
        db: db,
        deviceId: 'test-device',
        users: SqfliteUserRepository(db),
      ),
      onLogout: () {},
      isDarkMode: brightness == Brightness.dark,
      onToggleTheme: () {},
    ),
  };

  void registerCases({
    required String label,
    required Brightness brightness,
    required Size size,
    double? keyboard,
    double textScale = 1.0,
  }) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    group('$mode $label', () {
      for (final entry in screens.entries) {
        testWidgets(entry.key, (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;
          if (keyboard != null) {
            tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
          }
          addTearDown(tester.view.reset);

          AppDesign.setMode(brightness);

          await tester.runAsync(() async {
            await tester.pumpWidget(
              MaterialApp(
                theme: brightness == Brightness.dark
                    ? AppTheme.dark()
                    : AppTheme.light(),
                // Optional accessibility pass: the same screen with larger text.
                builder: textScale == 1.0
                    ? null
                    : (context, child) => MediaQuery(
                        data: MediaQuery.of(context)
                            .copyWith(textScaler: TextScaler.linear(textScale)),
                        child: child!,
                      ),
                home: entry.value(brightness),
              ),
            );
            // Real-time frames so SQLite-backed screens finish loading their
            // rows before the overflow guard is checked.
            for (var i = 0; i < 5; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 40));
              await tester.pump(const Duration(milliseconds: 40));
            }
          });

          expect(
            tester.takeException(),
            isNull,
            reason: '${entry.key} overflowed or threw at $label ($mode)',
          );
        });
      }
    });
  }

  for (final brightness in _brightnesses) {
    for (final size in _sizes) {
      registerCases(
        label: '${size.width.toInt()}x${size.height.toInt()}',
        brightness: brightness,
        size: size,
      );
    }
    // The on-screen keyboard shrinks the body to roughly the top half of the
    // smallest supported phone; every screen must still fit or scroll.
    registerCases(
      label: '320x568 keyboard',
      brightness: brightness,
      size: const Size(320, 568),
      keyboard: 260,
    );
    // Accessibility: the same small phone with enlarged system text.
    registerCases(
      label: '320x568 large text',
      brightness: brightness,
      size: const Size(320, 568),
      textScale: 1.3,
    );
  }
}
