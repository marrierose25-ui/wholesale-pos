import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:pos_local_engine/pos_local_engine.dart';
import 'package:pos_core/pos_core.dart';
import 'package:pos_contracts/pos_contracts.dart';
import 'package:wholesale_pos_app/core/theme/app_theme.dart';
import 'package:wholesale_pos_app/features/sales/sales_screen.dart';
import 'package:wholesale_pos_app/features/warehouse/create_picklist_screen.dart';

// The system back button is a second navigation path that no widget test was
// exercising: every guard lived on an AppBar button, and back bypassed it.
// These tests drive the platform's popRoute directly.
void main() {
  late Database db;
  late User owner;

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
    owner = User(
      id: 'u-1',
      username: 'owner',
      passwordHash: 'x',
      salt: 'y',
      role: 'OWNER',
    );
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets('system back does not discard a half-typed sale', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    Future<void> pumpFrames([int n = 10]) async {
      for (var i = 0; i < n; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        await tester.pump(const Duration(milliseconds: 40));
      }
    }

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
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
      await pumpFrames();

      await tester.tap(find.byIcon(CupertinoIcons.plus));
      await pumpFrames();
      expect(find.text('Price (Br)'), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Sugar');
      await tester.enterText(find.widgetWithText(TextField, 'Quantity'), '2');
      await tester.pump();

      // The Android back button used to pop the modal and throw the draft away
      // even though barrierDismissible was false. maybePop() is the exact code
      // path the platform back button runs.
      await tester.state<NavigatorState>(find.byType(Navigator).first).maybePop();
      await pumpFrames(12);

      expect(
        find.text('Price (Br)'),
        findsOneWidget,
        reason: 'system back must not dismiss the New Sale sheet',
      );
      expect(find.text('Sugar'), findsOneWidget);
    });
  });

  testWidgets('system back on step 2 returns to step 1, not out of the flow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    Future<void> pumpFrames([int n = 8]) async {
      for (var i = 0; i < n; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        await tester.pump(const Duration(milliseconds: 40));
      }
    }

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => CreatePicklistScreen(
                        repository: SqflitePicklistRepository(db),
                        currentUser: owner,
                      ),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await pumpFrames(3);

      await tester.tap(find.text('open'));
      await pumpFrames();
      expect(find.text('Step 1 of 2'), findsOneWidget);

      // Step 1 -> step 2.
      await tester.enterText(find.byType(TextField).first, 'Abebe Kebede');
      await tester.pump();
      await tester.tap(find.text('Next'));
      await pumpFrames();
      expect(find.text('Step 2 of 2'), findsOneWidget);

      await tester.state<NavigatorState>(find.byType(Navigator).first).maybePop();
      await pumpFrames(12);

      expect(
        find.text('Step 1 of 2'),
        findsOneWidget,
        reason: 'back on step 2 must return to the customer step',
      );
      expect(find.text('New List'), findsOneWidget);
    });
  });
}
