import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:wholesale_pos_app/core/database/local_database.dart';
import 'package:wholesale_pos_app/core/models/user.dart';
import 'package:wholesale_pos_app/core/repositories/finance_repository.dart';
import 'package:wholesale_pos_app/core/repositories/product_repository.dart';
import 'package:wholesale_pos_app/core/repositories/sale_repository.dart';
import 'package:wholesale_pos_app/core/repositories/shift_repository.dart';
import 'package:wholesale_pos_app/core/repositories/user_repository.dart';
import 'package:wholesale_pos_app/main.dart';

// The Android/iOS (native) shell is [MainLayout]; it picks its chrome purely by
// window width: < 600dp is the compact phone layout (hamburger + bottom pill
// nav), >= 600dp is the wide sidebar layout that tablets and desktops share.
// This guards the tablet contract of the single APK: a tablet-width window must
// auto-render the wide sidebar (no phone hamburger) without overflowing, while
// a phone-width window still gets the compact layout.
//
// A zero-tick CASHIER is used so the shell mounts only the always-visible
// Settings destination — no data-loading screens fire, keeping the render
// deterministic while still exercising the real responsive scaffold.
void main() {
  late Database db;

  setUp(() async {
    db = await LocalDatabase.openInMemory();
    final now = DateTime.now().toIso8601String();
    await db.insert('users', {
      'id': 'u-staff',
      'username': 'staff',
      'password_hash': 'x',
      'salt': 'y',
      'role': 'CASHIER',
      'created_at': now,
    });
  });

  tearDown(() async {
    await db.close();
  });

  final staff = User(
    id: 'u-staff',
    username: 'staff',
    passwordHash: 'x',
    salt: 'y',
    role: 'CASHIER',
    permissions: const [],
  );

  Widget shell() => MainLayout(
    db: db,
    productRepository: ProductRepository(db),
    saleRepository: SaleRepository(db),
    userRepository: UserRepository(db),
    shiftRepository: ShiftRepository(db),
    financeRepository: FinanceRepository(db),
    deviceId: 'test-device',
    currentUser: staff,
    onLogout: () {},
    isDarkMode: true,
    onToggleTheme: () {},
  );

  Future<void> pumpAt(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(home: shell()));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await tester.pump();
    });

    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'tablet portrait width shows the wide sidebar, not the phone chrome',
    (tester) async {
      // 800x1180 ~ an 8-9" tablet in portrait: >= 600dp wide -> sidebar layout.
      await pumpAt(tester, const Size(800, 1180));

      // The compact-only hamburger must be gone...
      expect(find.byIcon(Icons.menu), findsNothing);
      // ...and the sidebar's brand + nav labels render instead.
      expect(find.text('Settings'), findsWidgets);
      expect(find.text('Wholesale POS'), findsWidgets);
    },
  );

  testWidgets('landscape tablet width also renders the wide sidebar', (
    tester,
  ) async {
    // 1280x800 ~ a 10" tablet in landscape (>= 900dp -> full-width sidebar).
    await pumpAt(tester, const Size(1280, 800));
    expect(find.byIcon(Icons.menu), findsNothing);
    expect(find.text('Wholesale POS'), findsWidgets);
  });

  testWidgets('phone width still collapses to the compact hamburger layout', (
    tester,
  ) async {
    // Companion guard: proves the breakpoint is width-driven, not always-wide.
    await pumpAt(tester, const Size(390, 844));
    expect(find.byIcon(Icons.menu), findsOneWidget);
  });
}
