import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_contracts/pos_contracts.dart' hide AppBackend;
import 'package:wholesale_pos_app/core/backend/app_backend.dart';
import 'package:wholesale_pos_app/core/theme/app_design.dart';
import 'package:wholesale_pos_app/core/theme/app_theme.dart';
import 'package:wholesale_pos_app/core/backend/web_settings_screen.dart';

// The browser/PWA Settings screen's Change Password window is three stacked
// password fields. On the smallest phone with the keyboard open it must scroll
// inside the dialog rather than overflow. Runs in both themes, with enlarged
// system text, over a storage-agnostic fake backend (no Supabase / dart:io).
void main() {
  final owner = User(
    id: 'u-owner',
    username: 'owner',
    passwordHash: 'x',
    salt: 'y',
    role: 'OWNER',
  );

  Future<void> pumpFrames(WidgetTester tester, [int n = 6]) async {
    for (var i = 0; i < n; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  for (final brightness in [Brightness.light, Brightness.dark]) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';

    for (final textScale in [1.0, 1.3]) {
      testWidgets('Change Password fits a 320px phone with keyboard '
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
              home: WebSettingsScreen(
                backend: _FakeBackend(),
                currentUser: owner,
                onLogout: () {},
                isDarkMode: brightness == Brightness.dark,
                onToggleTheme: () {},
              ),
            ),
          );
          await pumpFrames(tester);

          // With the keyboard open the list viewport is short, so the account
          // section (and its Change Password tile) is not built yet.
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

          // The last field stays reachable by scrolling the dialog body.
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

class _FakeBackend extends AppBackend {
  final _MemorySession _session = _MemorySession();
  final Map<String, String> _settings = {};

  @override
  ProductRepository get products => _StubRepository();
  @override
  SaleRepository get sales => _StubSales();
  @override
  UserRepository get users => _StubUsers();
  @override
  ShiftRepository get shifts => _StubShifts();
  @override
  FinanceRepository get finance => _StubFinance();

  @override
  SessionStore get session => _session;
  @override
  String get deviceId => 'test-device';

  @override
  Future<String?> getSetting(String key) async => _settings[key];
  @override
  Future<void> setSetting(String key, String value) async {
    _settings[key] = value;
  }

  @override
  Widget settingsScreen({
    required User currentUser,
    required VoidCallback onLogout,
    required bool isDarkMode,
    required VoidCallback onToggleTheme,
  }) => const SizedBox.shrink();
}

class _StubRepository implements ProductRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unused in web settings dialog test');
}

class _StubSales implements SaleRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unused in web settings dialog test');
}

class _StubUsers implements UserRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unused in web settings dialog test');
}

class _StubShifts implements ShiftRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unused in web settings dialog test');
}

class _StubFinance implements FinanceRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unused in web settings dialog test');
}

class _MemorySession implements SessionStore {
  SessionData? _data;
  @override
  Future<void> clear() async => _data = null;
  @override
  Future<SessionData?> load() async => _data;
  @override
  Future<void> save(SessionData session) async => _data = session;
}
