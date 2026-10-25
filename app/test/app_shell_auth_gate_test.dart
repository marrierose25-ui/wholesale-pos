import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wholesale_pos_app/app_shell.dart';
import 'package:wholesale_pos_app/core/auth/session_store.dart';
import 'package:wholesale_pos_app/core/backend/app_backend.dart';
import 'package:wholesale_pos_app/core/models/user.dart';
import 'package:wholesale_pos_app/core/repositories/finance_repository.dart';
import 'package:wholesale_pos_app/core/repositories/product_repository.dart';
import 'package:wholesale_pos_app/core/repositories/sale_repository.dart';
import 'package:wholesale_pos_app/core/repositories/shift_repository.dart';
import 'package:wholesale_pos_app/core/repositories/user_repository.dart';

// A storage-agnostic fake over the [AppBackend] seam so the shared shell can be
// exercised in a pure widget test — no Supabase, no dart:io, no localStorage.
// The auth-gate transitions only touch [users] + [session] + settings, so the
// data repositories are reachable-but-unused stubs.
class _FakeBackend extends AppBackend {
  final _FakeUsers _users = _FakeUsers();
  final _MemorySession _session = _MemorySession();
  final Map<String, String> settings = {};
  bool provisioned = true;

  @override
  ProductRepository get products => _StubProducts();
  @override
  SaleRepository get sales => _StubSales();
  @override
  UserRepository get users => _users;
  @override
  ShiftRepository get shifts => _StubShifts();
  @override
  FinanceRepository get finance => _StubFinance();

  @override
  SessionStore get session => _session;
  @override
  String get deviceId => 'test-device';

  @override
  Future<String?> getSetting(String key) async => settings[key];
  @override
  Future<void> setSetting(String key, String value) async {
    settings[key] = value;
  }

  @override
  bool get isProvisioned => provisioned;

  @override
  Widget buildActivationGate({required VoidCallback onReady}) {
    return const Scaffold(body: Center(child: Text('ACTIVATION_GATE')));
  }

  @override
  Widget settingsScreen({
    required User currentUser,
    required VoidCallback onLogout,
    required bool isDarkMode,
    required VoidCallback onToggleTheme,
  }) {
    return const SizedBox.shrink();
  }
}

class _FakeUsers implements UserRepository {
  final Map<String, User> byId = {};

  @override
  Future<bool> hasUsers() async => true;

  @override
  Future<User?> getById(String id) async => byId[id];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unused in auth-gate test');
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

// Reachable-but-unused repository stubs: they throw if the shell ever asks a
// data screen for rows, which is exactly what these auth-gate tests avoid by
// stopping at the gate / login.
class _StubProducts implements ProductRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('data screen reached in auth-gate test');
}

class _StubSales implements SaleRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('data screen reached in auth-gate test');
}

class _StubShifts implements ShiftRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('data screen reached in auth-gate test');
}

class _StubFinance implements FinanceRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('data screen reached in auth-gate test');
}

void main() {
  testWidgets('unprovisioned backend shows the activation gate first', (
    tester,
  ) async {
    final backend = _FakeBackend()..provisioned = false;
    backend.settings[SessionStore.rememberKey] = '0';

    await tester.pumpWidget(PosRoot(backend: backend, initialDarkMode: true));
    await tester.pumpAndSettle();

    expect(find.text('ACTIVATION_GATE'), findsOneWidget);
    expect(find.text('Welcome back'), findsNothing);
  });

  testWidgets(
    'provisioned backend with remember-off lands on the login screen',
    (tester) async {
      final backend = _FakeBackend();
      backend.settings[SessionStore.rememberKey] = '0';

      await tester.pumpWidget(PosRoot(backend: backend, initialDarkMode: true));
      await tester.pumpAndSettle();

      expect(find.text('ACTIVATION_GATE'), findsNothing);
      expect(find.text('Welcome back'), findsOneWidget);
    },
  );
}
