import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:pos_local_engine/pos_local_engine.dart';
import 'package:pos_core/pos_core.dart';
import 'package:pos_contracts/pos_contracts.dart';
import 'package:wholesale_pos_app/core/theme/app_design.dart';
import 'package:wholesale_pos_app/core/theme/app_theme.dart';
import 'package:wholesale_pos_app/features/sales/sales_screen.dart';

// Small-phone guard for both steps of the New Sale window in light and dark
// mode: on a 320x568 device with the soft keyboard open, every field and the
// primary action must stay above the keyboard, and no RenderFlex may overflow.
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
    AppDesign.setMode(Brightness.dark);
    await db.close();
  });

  final owner = User(
    id: 'u-1',
    username: 'owner',
    passwordHash: 'x',
    salt: 'y',
    role: 'OWNER',
  );

  Future<void> pumpFrames(WidgetTester tester, [int n = 10]) async {
    for (var i = 0; i < n; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  for (final brightness in [Brightness.light, Brightness.dark]) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';

    testWidgets('New Sale steps fit a 320px phone with keyboard ($mode)', (
      tester,
    ) async {
      const height = 568.0;
      const keyboard = 260.0;
      const keyboardTop = height - keyboard;

      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1.0;
      tester.view.viewInsets = const FakeViewPadding(bottom: keyboard);
      addTearDown(tester.view.reset);
      AppDesign.setMode(brightness);

      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: brightness == Brightness.dark
                ? AppTheme.dark()
                : AppTheme.light(),
            home: Scaffold(
              body: SalesScreen(
                saleRepository: SqfliteSaleRepository(db),
                shiftRepository: SqfliteShiftRepository(db),
                deviceId: 'test-device',
                currentUser: owner,
                onSaleCompleted: () {},
              ),
            ),
          ),
        );
        await pumpFrames(tester);

        await tester.tap(find.byIcon(CupertinoIcons.plus));
        await pumpFrames(tester);
        await tester.enterText(
          find.widgetWithText(TextField, 'Name'),
          'Super Sugar 1kg Bulk Carton',
        );
        await tester.enterText(
          find.widgetWithText(TextField, 'Quantity'),
          '500',
        );
        await tester.enterText(
          find.widgetWithText(TextField, 'Price (Br)'),
          '4550',
        );
        await tester.pump();

        for (final label in ['Name', 'Quantity', 'Price (Br)']) {
          final rect = tester.getRect(find.widgetWithText(TextField, label));
          expect(
            rect.bottom,
            lessThanOrEqualTo(keyboardTop),
            reason: '$label is behind the keyboard ($mode)',
          );
        }
        expect(
          tester.getRect(find.text('Next')).bottom,
          lessThanOrEqualTo(keyboardTop),
          reason: 'Next is behind the keyboard ($mode)',
        );

        // Step 2: Loan needs the reason field, the tallest payment window.
        await tester.tap(find.text('Next'));
        await pumpFrames(tester);
        await tester.ensureVisible(find.text('Loan'));
        await pumpFrames(tester, 2);
        await tester.tap(find.text('Loan'));
        await pumpFrames(tester);
        await tester.ensureVisible(
          find.widgetWithText(TextField, 'Reason / Reference'),
        );
        await pumpFrames(tester, 2);
        await tester.enterText(
          find.widgetWithText(TextField, 'Reason / Reference'),
          'Monthly customer account',
        );
        await tester.pump();
        expect(
          tester.getRect(find.text('Complete')).bottom,
          lessThanOrEqualTo(keyboardTop),
          reason: 'Complete is behind the keyboard ($mode)',
        );
      });

      expect(tester.takeException(), isNull, reason: 'overflow ($mode)');
    });
  }
}
