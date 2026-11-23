import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:pos_local_engine/pos_local_engine.dart';
import 'package:pos_core/pos_core.dart';
import 'package:wholesale_pos_app/features/sales/sales_screen.dart';

// Walkthrough coverage for the two-step sale flow: step 1 (Name/Unit/Quantity/
// Price -> Next) must stay above the on-screen keyboard, and step 2 (a small
// payment-method window -> Complete) must block without a pick then persist the
// chosen method. A Loan sale collects nothing toward the register's cash.
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

  Widget host() => MaterialApp(
    home: Scaffold(
      body: SalesScreen(
        saleRepository: SqfliteSaleRepository(db),
        shiftRepository: SqfliteShiftRepository(db),
        deviceId: 'test-device',
        currentUser: owner,
        onSaleCompleted: () {},
      ),
    ),
  );

  Future<void> pumpFrames(WidgetTester tester, [int n = 10]) async {
    for (var i = 0; i < n; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  Future<void> openDialogWithValues(WidgetTester tester) async {
    await tester.tap(find.byIcon(CupertinoIcons.plus));
    await pumpFrames(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Sugar');
    await tester.enterText(find.widgetWithText(TextField, 'Quantity'), '2');
    await tester.enterText(find.widgetWithText(TextField, 'Price (Br)'), '500');
    await tester.pump();
  }

  testWidgets('sale fields and Next button stay above the on-screen keyboard', (
    tester,
  ) async {
    // A tall phone with a 320px soft keyboard.
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      await tester.pumpWidget(host());
      await pumpFrames(tester);
      await openDialogWithValues(tester);

      // Top edge of the keyboard.
      final keyboardTop = 844.0 - 320.0;

      // With the payment row removed, the fields and the Next action must all
      // sit above the keyboard so nothing is hidden while typing.
      for (final label in ['Name', 'Quantity', 'Price (Br)']) {
        final rect = tester.getRect(find.widgetWithText(TextField, label));
        expect(
          rect.bottom,
          lessThanOrEqualTo(keyboardTop),
          reason:
              '$label field is behind the keyboard (bottom ${rect.bottom} > $keyboardTop)',
        );
      }

      final buttonRect = tester.getRect(find.text('Next'));
      expect(buttonRect.bottom, lessThanOrEqualTo(keyboardTop));

      // Next opens the compact payment window: all three choices are offered.
      await tester.tap(find.text('Next'));
      await pumpFrames(tester);
      expect(find.text('Payment'), findsOneWidget);
      for (final label in ['Cash', 'Bank', 'Loan']) {
        expect(find.text(label), findsOneWidget);
      }
    });

    expect(tester.takeException(), isNull);
  });

  testWidgets('a Loan sale is blocked until picked, then saves with no change', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    Sale? saved;
    await tester.runAsync(() async {
      await tester.pumpWidget(host());
      await pumpFrames(tester);
      await openDialogWithValues(tester);

      // Step 1 ends with Next; the payment choice lives on the next window.
      await tester.tap(find.text('Next'));
      await pumpFrames(tester);
      expect(find.text('Payment'), findsOneWidget);

      // No selection yet -> Complete is rejected with an inline error.
      await tester.tap(find.text('Complete'));
      await pumpFrames(tester, 3);
      expect(find.text('Select a payment method.'), findsOneWidget);

      // Pick Loan; a reason is still required, so Complete stays blocked.
      await tester.tap(find.text('Loan'));
      await pumpFrames(tester);
      await tester.tap(find.text('Complete'));
      await pumpFrames(tester, 3);
      expect(find.text('Enter a reason for this sale.'), findsOneWidget);

      // Supply the reason and commit.
      await tester.enterText(
        find.widgetWithText(TextField, 'Reason / Reference'),
        'Monthly customer account',
      );
      await tester.pump();
      await tester.tap(find.text('Complete'));

      for (var i = 0; i < 50; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump(const Duration(milliseconds: 20));
        final rows = await SqfliteSaleRepository(db).getSales();
        if (rows.isNotEmpty) {
          saved = rows.single;
          break;
        }
      }
    });

    expect(saved, isNotNull);
    expect(saved!.paymentMethod, 'LOAN');
    // Loan settles for exactly the total: nothing tendered, nothing given back.
    expect(saved!.amountPaidMinorUnits, saved!.totalMinorUnits);
    expect(saved!.changeMinorUnits, 0);
    // The reason rides on the line item's notes, which syncs without a schema
    // change.
    expect(saved!.items.single.notes, 'Monthly customer account');

    expect(tester.takeException(), isNull);
  });
}
