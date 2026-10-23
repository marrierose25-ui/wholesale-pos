import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wholesale_pos_app/core/database/local_database.dart';
import 'package:wholesale_pos_app/core/models/user.dart';
import 'package:wholesale_pos_app/core/repositories/sale_repository.dart';
import 'package:wholesale_pos_app/core/repositories/shift_repository.dart';
import 'package:wholesale_pos_app/features/register/register_screen.dart';

// Renders the ACTIVE cash register (an open shift, so the stat cards and the
// close/voids section are shown) at a real phone width and asserts nothing
// overflows. Device-free guard for the register's compact layout.
void main() {
  late Database db;

  setUp(() async {
    db = await LocalDatabase.openInMemory();
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets('Active register lays out at phone width without overflowing', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final owner = User(
      id: 'u-owner',
      username: 'owner',
      passwordHash: 'x',
      salt: 'y',
      role: 'OWNER',
    );

    await tester.runAsync(() async {
      // Open a shift on the real event loop first, so the register renders its
      // active content (stat cards + close/voids) rather than the empty state.
      await ShiftRepository(db).openShift(owner.id, 5000);

      await tester.pumpWidget(
        MaterialApp(
          home: RegisterScreen(
            currentUser: owner,
            shiftRepository: ShiftRepository(db),
            saleRepository: SaleRepository(db),
            onShiftUpdated: () {},
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await tester.pump();
    });

    // The active-register content must be present at 390px.
    expect(find.text('Cash Register'), findsOneWidget);
    expect(find.text('Expected Cash'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
