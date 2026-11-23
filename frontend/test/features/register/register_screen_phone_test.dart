import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:pos_local_engine/pos_local_engine.dart';
import 'package:pos_contracts/pos_contracts.dart';
import 'package:wholesale_pos_app/features/register/register_screen.dart';

// The redesign drops open/close in favour of a persistent balance plus daily
// "Today" counters. These tests cover both halves:
//   * a phone-width layout guard that also proves tapping the withdrawals card
//     opens the WITHDRAWAL cash-movement dialog (the tap-to-withdraw path);
//   * a repository-driven check that a withdrawal against the perpetual shift
//     is reflected in the running balance and the daily counter.
//
// The dialog is dismissed with Cancel rather than saved inside the widget
// pump: the post-save path fires an unawaited reload whose real-time DB work
// races the fake-async teardown, so the movement math is verified directly.
void main() {
  const ownerId = 'u-owner';
  late Database db;

  final owner = User(
    id: ownerId,
    username: 'owner',
    passwordHash: 'x',
    salt: 'y',
    role: 'OWNER',
  );

  setUp(() async {
    db = await LocalDatabase.openInMemory();
    final now = DateTime.now().toIso8601String();
    await db.insert('users', {
      'id': ownerId,
      'username': 'owner',
      'password_hash': 'x',
      'salt': 'y',
      'role': 'OWNER',
      'created_at': now,
    });
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets(
    'Register lays out at phone width and opens the withdrawal dialog',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: RegisterScreen(
              currentUser: owner,
              shiftRepository: SqfliteShiftRepository(db),
              saleRepository: SqfliteSaleRepository(db),
              onShiftUpdated: () {},
            ),
          ),
        );
        // Real-time pumps so the async ensureActiveShift + snapshot load and
        // the route animation complete without pumpAndSettle (which hangs on
        // the loading spinner). Advance fake time so the dialog's transition
        // settles.
        for (var i = 0; i < 6; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 40));
          await tester.pump(const Duration(milliseconds: 40));
        }

        // Persistent balance + the daily "Today" counters replace open/close.
        expect(find.text('Cash Register'), findsOneWidget);
        expect(find.text('Register Balance'), findsOneWidget);
        expect(find.text('Today Debits'), findsOneWidget);
        // The register history ledger is embedded below the credit/debit cards.
        expect(find.text('Register History'), findsOneWidget);

        // Tapping the debits card opens the movement dialog preset to it.
        await tester.tap(find.text('Today Debits'));
        for (var i = 0; i < 6; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 40));
          await tester.pump(const Duration(milliseconds: 40));
        }
        expect(find.text('Debit (Withdrawal)'), findsOneWidget);
        // The debit dialog offers an (optional) proof photo picker.
        expect(find.text('Add photo (optional)'), findsOneWidget);

        // Dismiss it cleanly so no route/ticker is left live at teardown.
        await tester.tap(find.text('Cancel'));
        for (var i = 0; i < 6; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 40));
          await tester.pump(const Duration(milliseconds: 40));
        }
      });

      expect(tester.takeException(), isNull);
    },
  );

  test('A withdrawal against the perpetual shift lowers the balance', () async {
    final shift = await SqfliteShiftRepository(db).ensureActiveShift(ownerId);
    await SqfliteShiftRepository(db).addCashMovement(
      shift.id,
      'WITHDRAWAL',
      20000, // Br 200 in minor units
      'Shop rent',
      userId: ownerId,
    );

    final snapshot = await SqfliteShiftRepository(db)
        .getRegisterSnapshot(DateRange.today());
    expect(snapshot['today_withdrawals'], 20000);
    expect(snapshot['balance'], -20000); // withdrawal drains the drawer
  });
}
