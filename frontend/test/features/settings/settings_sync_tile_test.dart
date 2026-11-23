import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:pos_local_engine/pos_local_engine.dart';
import 'package:pos_contracts/pos_contracts.dart';
import 'package:wholesale_pos_app/core/backend/native_backend.dart';
import 'package:wholesale_pos_app/core/sync/sync_runtime.dart';
import 'package:wholesale_pos_app/core/sync/sync_service.dart';
import 'package:wholesale_pos_app/features/settings/settings_screen.dart';

// The Settings screen is the only place an operator can find out WHY a till is
// not sharing transactions. The case that motivated this: a PC holding a
// pre-Phase-17 license.key signs in and sells normally, while the gateway
// refuses its licence — so "I logged in on another device and saw nothing" was
// invisible. It must now say so and offer the one action that fixes it.

class _RefusedBackend implements SyncBackend {
  @override
  bool get isConfigured => true;

  @override
  Future<Set<String>> push(List<SyncOutboxEntry> entries) async =>
      throw const SyncAuthException('License format not supported by sync.');

  @override
  Future<SyncPullResult> pull({
    Map<String, String>? cursor,
    int limit = 1000,
    List<String>? tables,
  }) async =>
      throw const SyncAuthException('License format not supported by sync.');
}

class _HealthyBackend implements SyncBackend {
  @override
  bool get isConfigured => true;

  @override
  Future<Set<String>> push(List<SyncOutboxEntry> entries) async => const {};

  @override
  Future<SyncPullResult> pull({
    Map<String, String>? cursor,
    int limit = 1000,
    List<String>? tables,
  }) async => const SyncPullResult.empty();
}

void main() {
  late Database db;
  late UserRepository repository;

  final owner = User(
    id: 'owner-1',
    username: '0700000001',
    passwordHash: 'x',
    salt: 'y',
    role: 'OWNER',
  );

  setUp(() async {
    db = await LocalDatabase.openInMemory();
    repository = SqfliteUserRepository(db);
    await db.insert('users', {
      'id': 'owner-1',
      'username': '0700000001',
      'password_hash': 'x',
      'salt': 'y',
      'role': 'OWNER',
      'is_active': 1,
      'created_at': DateTime.now().toIso8601String(),
    });
  });

  tearDown(() async {
    await db.close();
  });

  Future<SyncRuntime> runtimeFor(
    WidgetTester tester,
    SyncBackend backend,
  ) async {
    final service = SyncService(
      SqfliteSyncOutboxRepository(db),
      backend,
      puller: CloudSyncPuller(backend: backend, db: db),
    );
    // Populate the status the way the background loop would. Runs inside
    // runAsync because sqflite uses real timers, which the widget tester's
    // fake clock never advances.
    await tester.runAsync(() => service.syncNow());
    return SyncRuntime(
      service: service,
      puller: CloudSyncPuller(backend: backend, db: db),
    );
  }

  Future<void> pumpSettings(WidgetTester tester, SyncRuntime runtime) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          currentUser: owner,
          backend: NativeBackend(
            db: db,
            deviceId: 'test-device',
            users: repository,
          ),
          onLogout: () {},
          isDarkMode: true,
          onToggleTheme: () {},
          syncRuntime: runtime,
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('a refused licence is shown and offers activation', (
    tester,
  ) async {
    final runtime = await runtimeFor(tester, _RefusedBackend());
    await pumpSettings(tester, runtime);

    expect(find.text('Cloud Sync'), findsWidgets);
    expect(find.textContaining('not activated for cloud sync'), findsOneWidget);
    expect(find.text('Activate this device'), findsOneWidget);

    await tester.tap(find.text('Activate this device'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Activation Code'), findsOneWidget);
  });

  testWidgets('a healthy sync shows no activation prompt', (tester) async {
    final runtime = await runtimeFor(tester, _HealthyBackend());
    await pumpSettings(tester, runtime);

    expect(find.textContaining('up to date with every device'), findsOneWidget);
    expect(find.text('Activate this device'), findsNothing);
  });

  testWidgets('a cashier sees the status but cannot re-activate the shop', (
    tester,
  ) async {
    final runtime = await runtimeFor(tester, _RefusedBackend());
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          currentUser: User(
            id: 'cashier-1',
            username: '0700000002',
            passwordHash: 'x',
            salt: 'y',
            role: 'CASHIER',
          ),
          backend: NativeBackend(
            db: db,
            deviceId: 'test-device',
            users: repository,
          ),
          onLogout: () {},
          isDarkMode: true,
          onToggleTheme: () {},
          syncRuntime: runtime,
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('not activated for cloud sync'), findsOneWidget);
    expect(find.text('Activate this device'), findsNothing);
  });
}
