import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wholesale_pos_app/core/database/local_database.dart';
import 'package:wholesale_pos_app/core/models/user.dart';
import 'package:wholesale_pos_app/core/repositories/product_repository.dart';
import 'package:wholesale_pos_app/core/repositories/sale_repository.dart';
import 'package:wholesale_pos_app/core/repositories/shift_repository.dart';
import 'package:wholesale_pos_app/features/sales/sales_screen.dart';

// Renders the POS at a real phone width so any RenderFlex overflow fails the
// test. This is the device-free guard for the compact (stacked) register layout.
void main() {
  late Database db;

  setUp(() async {
    db = await LocalDatabase.openInMemory();
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets('POS lays out at phone width without overflowing', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final owner = User(
      id: 'u-1',
      username: 'owner',
      passwordHash: 'x',
      salt: 'y',
      role: 'OWNER',
    );

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SalesScreen(
              saleRepository: SaleRepository(db),
              shiftRepository: ShiftRepository(db),
              productRepository: ProductRepository(db),
              deviceId: 'test-device',
              currentUser: owner,
              onSaleCompleted: () {},
            ),
          ),
        ),
      );

      // The screen kicks off async DB loads in initState. Run them on the real
      // event loop (so sqflite's watchdog timers are cancelled) and pump so the
      // compact branch re-lays-out once data resolves.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await tester.pump();
    });

    // Core regions must both be present and on-screen (stacked, not clipped).
    expect(find.text('Add Item'), findsOneWidget);
    expect(find.text('Current Sale'), findsOneWidget);

    // No overflow exception was recorded during layout/paint above; if a
    // RenderFlex overflowed, testWidgets would already have failed.
    expect(tester.takeException(), isNull);
  });
}
