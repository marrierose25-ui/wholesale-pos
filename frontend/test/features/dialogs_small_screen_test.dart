import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:pos_local_engine/pos_local_engine.dart';
import 'package:pos_core/pos_core.dart';
import 'package:pos_contracts/pos_contracts.dart';
import 'package:wholesale_pos_app/core/theme/app_design.dart';
import 'package:wholesale_pos_app/core/theme/app_theme.dart';
import 'package:wholesale_pos_app/features/finance/finance_person_screen.dart';
import 'package:wholesale_pos_app/features/register/register_screen.dart';

// Small-phone (320x568) dialog guard in both themes: the Money Tracking entry
// wizard and the Register withdrawal window must keep their fields and action
// buttons above the keyboard, and must not overflow.
void main() {
  late Database db;
  final owner = User(
    id: 'u-owner',
    username: 'owner',
    passwordHash: 'x',
    salt: 'y',
    role: 'OWNER',
  );

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
      'status': 'PENDING',
      'entry_date': now,
      'created_at': now,
      'created_by': 'u-owner',
      'updated_at': now,
    });
  });

  tearDown(() async {
    AppDesign.setMode(Brightness.dark);
    await db.close();
  });

  Future<void> pumpFrames(WidgetTester tester, [int n = 10]) async {
    for (var i = 0; i < n; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  for (final brightness in [Brightness.light, Brightness.dark]) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';

    testWidgets('Money Tracking entry fits 320px with keyboard ($mode)', (
      tester,
    ) async {
      const keyboardTop = 568.0 - 260.0;
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1.0;
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      addTearDown(tester.view.reset);
      AppDesign.setMode(brightness);

      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: brightness == Brightness.dark
                ? AppTheme.dark()
                : AppTheme.light(),
            home: FinancePersonScreen(
              financeRepository: SqfliteFinanceRepository(db),
              currentUser: owner,
              categoryId: 'fin-cat-1',
              personName: 'ABC Shipping Company Limited',
            ),
          ),
        );
        await pumpFrames(tester);

        await tester.tap(find.text('Add Entry'));
        await pumpFrames(tester);
        expect(find.text('Add Entry (1/2)'), findsOneWidget);

        await tester.enterText(
          find.widgetWithText(TextField, 'Amount (Br)'),
          '1200',
        );
        await tester.enterText(
          find.widgetWithText(TextField, 'Source (e.g., CBE Bank)'),
          'CBE Head Office Branch',
        );
        await tester.pump();
        expect(
          tester.getRect(find.text('Next')).bottom,
          lessThanOrEqualTo(keyboardTop),
          reason: 'Next is behind the keyboard ($mode)',
        );

        await tester.tap(find.text('Next'));
        await pumpFrames(tester);
        expect(find.text('Select Payment (2/2)'), findsOneWidget);
        expect(
          tester.getRect(find.text('Complete')).bottom,
          lessThanOrEqualTo(keyboardTop),
          reason: 'Complete is behind the keyboard ($mode)',
        );
      });

      expect(tester.takeException(), isNull, reason: 'overflow ($mode)');
    });

    testWidgets('Register withdrawal fits 320px with keyboard ($mode)', (
      tester,
    ) async {
      const keyboardTop = 568.0 - 260.0;
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1.0;
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      addTearDown(tester.view.reset);
      AppDesign.setMode(brightness);

      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: brightness == Brightness.dark
                ? AppTheme.dark()
                : AppTheme.light(),
            home: RegisterScreen(
              currentUser: owner,
              shiftRepository: SqfliteShiftRepository(db),
              saleRepository: SqfliteSaleRepository(db),
              onShiftUpdated: () {},
            ),
          ),
        );
        await pumpFrames(tester);

        // With the keyboard open the body viewport is only the top half of the
        // screen, so scroll the debits card into view before tapping it.
        await tester.ensureVisible(find.text('Today Debits'));
        await pumpFrames(tester, 2);
        await tester.tap(find.text('Today Debits'));
        await pumpFrames(tester);
        expect(find.text('Debit (Withdrawal)'), findsOneWidget);

        await tester.enterText(
          find.widgetWithText(TextField, 'Amount (Br)'),
          '200',
        );
        await tester.enterText(
          find.widgetWithText(TextField, 'Reason / Reference'),
          'Shop rent and utilities',
        );
        await tester.pump();
        expect(
          tester.getRect(find.text('Save')).bottom,
          lessThanOrEqualTo(keyboardTop),
          reason: 'Save is behind the keyboard ($mode)',
        );
      });

      expect(tester.takeException(), isNull, reason: 'overflow ($mode)');
    });
  }
}
