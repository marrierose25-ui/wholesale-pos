import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:pos_local_engine/pos_local_engine.dart';
import 'package:pos_core/pos_core.dart';
import 'package:pos_contracts/pos_contracts.dart';
import 'package:wholesale_pos_app/core/theme/app_design.dart';
import 'package:wholesale_pos_app/core/theme/app_theme.dart';
import 'package:wholesale_pos_app/features/users/user_management_screen.dart';

// Small-phone guard for the Add New User window: it is the tallest dialog in
// the app (three fields plus the permission picker), so it must scroll rather
// than overflow on a 320px phone with the keyboard open, in both themes and
// with enlarged system text.
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
    await db.insert('users', {
      'id': 'u-cashier',
      'username': 'cashier',
      'password_hash': 'x',
      'salt': 'y',
      'role': 'CASHIER',
      'created_at': now,
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

    for (final textScale in [1.0, 1.3]) {
      testWidgets(
        'Add New User fits a 320px phone with keyboard '
        '($mode, text ${textScale}x)',
        (tester) async {
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
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(textScale)),
                  child: child!,
                ),
                home: UserManagementScreen(
                  userRepository: SqfliteUserRepository(db),
                  currentUser: owner,
                ),
              ),
            );
            await pumpFrames(tester);

            await tester.tap(find.text('Add User'));
            await pumpFrames(tester);
            expect(find.text('Add New User'), findsOneWidget);

            await tester.enterText(
              find.widgetWithText(TextField, 'Phone Number'),
              '0911111111',
            );
            await tester.pump();

            // The action row must stay above the keyboard and inside the
            // screen, and the body must scroll instead of overflowing.
            expect(
              tester.getRect(find.text('Create User')).bottom,
              lessThanOrEqualTo(keyboardTop),
              reason: 'Create User is behind the keyboard ($mode)',
            );

            // Every field remains reachable by scrolling the dialog body.
            await tester.ensureVisible(
              find.widgetWithText(TextField, 'Confirm Password'),
            );
            await pumpFrames(tester, 2);
            expect(
              tester.getRect(find.widgetWithText(TextField, 'Confirm Password'))
                  .bottom,
              lessThanOrEqualTo(keyboardTop),
              reason: 'Confirm Password unreachable ($mode)',
            );
          });

          expect(tester.takeException(), isNull, reason: 'overflow ($mode)');
        },
      );
    }
  }
}
