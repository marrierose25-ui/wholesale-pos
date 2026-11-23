import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:pos_local_engine/pos_local_engine.dart';
import 'package:pos_core/pos_core.dart';
import 'package:pos_contracts/pos_contracts.dart';
import 'package:wholesale_pos_app/core/backend/native_backend.dart';
import 'package:wholesale_pos_app/core/theme/app_design.dart';
import 'package:wholesale_pos_app/core/theme/app_theme.dart';
import 'package:wholesale_pos_app/features/settings/settings_screen.dart';

// The native Settings screen's Change Password window is three stacked
// password fields. On the smallest phone with the keyboard open it must scroll
// inside the dialog rather than overflow. Both themes, normal and enlarged text.
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
  });

  tearDown(() async {
    AppDesign.setMode(Brightness.dark);
    await db.close();
  });

  Future<void> pumpFrames(WidgetTester tester, [int n = 6]) async {
    for (var i = 0; i < n; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  for (final brightness in [Brightness.light, Brightness.dark]) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';

    for (final textScale in [1.0, 1.3]) {
      testWidgets('Settings change password fits 320px with keyboard '
          '($mode, text ${textScale}x)', (tester) async {
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
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(textScale)),
                child: child!,
              ),
              home: SettingsScreen(
                currentUser: owner,
                backend: NativeBackend(
                  db: db,
                  deviceId: 'test-device',
                  users: SqfliteUserRepository(db),
                ),
                onLogout: () {},
                isDarkMode: brightness == Brightness.dark,
                onToggleTheme: () {},
              ),
            ),
          );
          await pumpFrames(tester);

          // The keyboard leaves a short viewport, so the account card may
          // not be built until the list is scrolled.
          await tester.scrollUntilVisible(
            find.text('Change Password'),
            200,
            scrollable: find.byType(Scrollable).first,
          );
          await pumpFrames(tester, 2);
          await tester.tap(find.text('Change Password'));
          await pumpFrames(tester);
          expect(find.text('Current Password'), findsOneWidget);

          await tester.enterText(
            find.widgetWithText(TextField, 'Current Password'),
            'old-password',
          );
          await tester.pump();

          expect(
            tester.getRect(find.text('Save')).bottom,
            lessThanOrEqualTo(keyboardTop),
            reason: 'Save is behind the keyboard ($mode)',
          );

          await tester.ensureVisible(
            find.widgetWithText(TextField, 'Confirm New Password'),
          );
          await pumpFrames(tester, 2);
          expect(
            tester
                .getRect(find.widgetWithText(TextField, 'Confirm New Password'))
                .bottom,
            lessThanOrEqualTo(keyboardTop),
            reason: 'Confirm field unreachable ($mode)',
          );
        });

        expect(tester.takeException(), isNull, reason: 'overflow ($mode)');
      });
    }
  }
}
