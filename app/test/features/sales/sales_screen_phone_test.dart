import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wholesale_pos_app/core/database/local_database.dart';
import 'package:wholesale_pos_app/core/models/user.dart';
import 'package:wholesale_pos_app/core/repositories/sale_repository.dart';
import 'package:wholesale_pos_app/core/repositories/shift_repository.dart';
import 'package:wholesale_pos_app/features/sales/sales_screen.dart';

// Renders the POS at a real phone width so any RenderFlex overflow fails the
// test, and drives the single-item "New Sale" dialog end to end: the recorded
// sale must land and the shell's onSaleCompleted hand-off must fire.
void main() {
  late Database db;

  setUp(() async {
    db = await LocalDatabase.openInMemory();
    final now = DateTime.now().toIso8601String();
    await db.insert('users', {
      'id': 'u-1',
      'username': 'owner',
      'password_hash': 'x',
      'salt': 'y',
      'role': 'OWNER',
      'created_at': now,
    });
    // The sale row has a FOREIGN KEY(device_id) REFERENCES devices(id), so the
    // device the POS posts against must exist or saveSale throws.
    await db.insert('devices', {
      'id': 'test-device',
      'name': 'Till',
      'platform': 'Windows',
    });
  });

  tearDown(() async {
    await db.close();
  });

  final owner = User(
    id: 'u-1',
    username: 'owner',
    passwordHash: 'x',
    salt: 'y',
    role: 'OWNER',
  );

  testWidgets('POS lays out at phone width and completes a single-item sale', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var completed = 0;
    var saleCount = 0;
    var totalMinorUnits = 0;
    var quantityText = '';

    // Pump real-time frames so async DB work + dialog animations advance
    // without pumpAndSettle (which hangs inside tester.runAsync).
    Future<void> pumpFrames([int n = 10]) async {
      for (var i = 0; i < n; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        await tester.pump(const Duration(milliseconds: 40));
      }
    }

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SalesScreen(
              saleRepository: SaleRepository(db),
              shiftRepository: ShiftRepository(db),
              deviceId: 'test-device',
              currentUser: owner,
              onSaleCompleted: () => completed++,
            ),
          ),
        ),
      );

      // The screen kicks off an async DB load (ensureActiveShift) in initState.
      await pumpFrames();

      // The decluttered POS is a single action: just the glowing + circle,
      // no title, no description, no button label anywhere.
      expect(find.byIcon(Icons.add), findsOneWidget);
      expect(find.text('Ring up a single item'), findsNothing);
      expect(find.text('New Sale'), findsNothing);
      expect(tester.takeException(), isNull); // main screen alone must fit

      // Tap the + circle to open the dialog and ring up one item.
      await tester.tap(find.byIcon(Icons.add));
      await pumpFrames();
      expect(find.text('Price (Br)'), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Sugar');
      await tester.enterText(find.widgetWithText(TextField, 'Quantity'), '2');
      await tester.enterText(
        find.widgetWithText(TextField, 'Price (Br)'),
        '500',
      );
      await tester.pump();

      // Unit is a fixed-choice dropdown (Karton / Kuntal / Derzen / Fre);
      // swap the default for Derzen and carry on.
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await pumpFrames();
      // .last - the offstage menu-measurement copy matches find.text too.
      await tester.tap(find.text('Derzen').last);
      await pumpFrames();

      // Total = quantity x price, shown live before committing.
      expect(find.text('1,000.00 Br'), findsWidgets);

      // Step 1 ends with Next; the payment choice moved to a second, compact
      // window so the fields stay visible above the on-screen keyboard.
      await tester.tap(find.text('Next'));
      await pumpFrames();
      expect(find.text('Payment Method'), findsOneWidget);

      // Payment method starts unselected and is required: completing without a
      // pick is blocked with an inline error, not a saved sale.
      expect(find.text('Select a payment method.'), findsNothing);
      await tester.tap(find.text('Complete'));
      await pumpFrames(3);
      expect(find.text('Select a payment method.'), findsOneWidget);

      // Three till choices: Cash, Bank Transfer, Loan. Pick Cash to proceed.
      expect(find.widgetWithText(ChoiceChip, 'Loan'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Bank Transfer'), findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Cash'));
      await pumpFrames();

      // A reason is required before the sale can be completed.
      await tester.enterText(
        find.widgetWithText(TextField, 'Reason / Reference'),
        'Walk-in customer',
      );
      await tester.pump();

      await tester.tap(find.text('Complete'));
      // The save runs as a fire-and-forget real-time future on the screen. Poll
      // for its row INSIDE runAsync: awaiting sqflite only resolves on the real
      // event loop, and it must fully land (firing the shell hand-off) before
      // we leave runAsync - a real DB await afterwards hangs the fake zone.
      for (var i = 0; i < 50; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump(const Duration(milliseconds: 20));
        final rows = await SaleRepository(db).getSales();
        if (rows.isNotEmpty) {
          saleCount = rows.length;
          totalMinorUnits = rows.single.totalMinorUnits;
          quantityText = rows.single.items.single.quantityText;
          break;
        }
      }
    });

    // The sale was recorded and the hand-off to the register tab fired.
    expect(completed, 1);
    expect(saleCount, 1);
    expect(totalMinorUnits, 100000); // 2 x Br 500 in minor units
    // The chosen unit is stored alongside the quantity on the sale line.
    expect(quantityText, '2 Derzen');

    // No layout/paint exception was recorded.
    expect(tester.takeException(), isNull);
  });
}
