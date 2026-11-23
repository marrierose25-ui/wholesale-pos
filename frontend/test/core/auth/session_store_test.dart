import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';


import 'package:pos_contracts/pos_contracts.dart' hide AppBackend;
import 'package:pos_local_engine/pos_local_engine.dart';

void main() {
  late Database db;
  late SettingsSessionStore store;

  setUp(() async {
    db = await LocalDatabase.openInMemory();
    store = SettingsSessionStore(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('save then load round-trips the user id and token', () async {
    final session = SessionData.create(
      'user-1',
      lifetime: SessionStore.defaultLifetime,
    );
    await store.save(session);

    final loaded = await store.load();
    expect(loaded, isNotNull);
    expect(loaded!.userId, 'user-1');
    expect(loaded.token, session.token);
  });

  test('load returns null when nothing was saved', () async {
    expect(await store.load(), isNull);
  });

  test('an expired session is dropped and returns null', () async {
    final expired = SessionData(
      userId: 'user-1',
      token: 'nonce',
      issuedAt: DateTime.now().subtract(const Duration(hours: 2)),
      expiresAt: DateTime.now().subtract(const Duration(hours: 1)),
    );
    await store.save(expired);

    expect(await store.load(), isNull);
    // The stale row is removed so it can never be resurrected.
    expect(await db.query('settings'), isEmpty);
  });

  test('a tampered record is treated as no session and cleared', () async {
    await db.insert('settings', {'key': 'auth_session', 'value': 'not-json{'});

    expect(await store.load(), isNull);
    expect(await db.query('settings'), isEmpty);
  });

  test('clear removes the stored session', () async {
    await store.save(
      SessionData.create('user-1', lifetime: SessionStore.defaultLifetime),
    );
    await store.clear();
    expect(await store.load(), isNull);
  });

  group('UserRepository.getById', () {
    late UserRepository users;

    setUp(() async {
      users = SqfliteUserRepository(db);
      final now = DateTime.now().toIso8601String();
      await db.insert('users', {
        'id': 'user-1',
        'username': 'owner',
        'password_hash': 'x',
        'salt': 'x',
        'role': 'OWNER',
        'is_active': 1,
        'created_at': now,
      });
      await db.insert('users', {
        'id': 'user-2',
        'username': 'cashier',
        'password_hash': 'x',
        'salt': 'x',
        'role': 'CASHIER',
        'is_active': 0,
        'created_at': now,
      });
    });

    test('returns an active user', () async {
      final user = await users.getById('user-1');
      expect(user, isA<User>());
      expect(user!.username, 'owner');
    });

    test('returns null for a deactivated account', () async {
      expect(await users.getById('user-2'), isNull);
    });

    test('returns null for an unknown id', () async {
      expect(await users.getById('does-not-exist'), isNull);
    });
  });
}
