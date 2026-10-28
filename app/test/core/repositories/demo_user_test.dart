import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wholesale_pos_app/core/auth/features.dart';
import 'package:wholesale_pos_app/core/database/local_database.dart';
import 'package:wholesale_pos_app/core/repositories/user_repository.dart';

// Covers the permanent training account: it is created exactly once, always a
// CASHIER, can never be deactivated, cannot be forged through createUser, and
// keeps its feature ticks editable so the owner can retrain different people.
// Its password is a per-install secret — never a value published in the source
// or the docs — so training starts with an owner setting a known one.
void main() {
  late Database db;
  late UserRepository repository;

  setUp(() async {
    db = await LocalDatabase.openInMemory();
    repository = UserRepository(db);
    // An active owner is the actor for the status/permission guards.
    await db.insert('users', {
      'id': 'owner-1',
      'username': 'owner',
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

  test('ensureDemoUser is idempotent and creates one active cashier', () async {
    await repository.ensureDemoUser();
    await repository.ensureDemoUser();

    final users = await repository.getAllUsers();
    final demos = users.where((u) => u.isDemo).toList();

    expect(demos.length, 1);
    expect(demos.single.username, 'demo');
    expect(demos.single.role, 'CASHIER');
    expect(demos.single.isActive, isTrue);
    expect(demos.single.permissions, kDefaultStaffPermissions);
  });

  test('the published default password no longer signs in', () async {
    await repository.ensureDemoUser();

    final user = await repository.authenticate('demo', 'demo1234');

    expect(user, isNull);
  });

  test('the owner sets a known password before training', () async {
    await repository.ensureDemoUser();
    final demo = (await repository.getAllUsers()).firstWhere((u) => u.isDemo);

    await repository.resetPassword(
      targetUserId: demo.id,
      newPassword: 'train-2026',
      actingUserId: 'owner-1',
    );

    final user = await repository.authenticate('demo', 'train-2026');
    expect(user, isNotNull);
    expect(user!.isDemo, isTrue);
    expect(user.role, 'CASHIER');
  });

  test('seeding marks the demo credential version', () async {
    await repository.ensureDemoUser();
    await repository.ensureDemoUser();

    final marker = await db.query(
      'settings',
      where: 'key = ?',
      whereArgs: ['demo_password_version'],
    );
    expect(marker.single['value'], '2');
    // The row keeps a hash and a salt, never the typed password.
    final rows = await db.query('users', where: 'is_demo = 1', limit: 1);
    expect(rows.single['password_hash'], isNot(contains('demo1234')));
    expect(rows.single['salt'], isNotEmpty);
  });

  test('the demo account cannot be deactivated', () async {
    await repository.ensureDemoUser();
    final demo = (await repository.getAllUsers()).firstWhere((u) => u.isDemo);

    await expectLater(
      repository.setUserActive(
        targetUserId: demo.id,
        active: false,
        actingUserId: 'owner-1',
      ),
      throwsA(
        predicate(
          (e) => e.toString().contains('cannot be deactivated'),
          'mentions the demo guard',
        ),
      ),
    );

    // Still active afterwards.
    final after = await repository.getById(demo.id);
    expect(after, isNotNull);
    expect(after!.isActive, isTrue);
  });

  test('createUser rejects the reserved demo username', () async {
    await expectLater(
      repository.createUser('demo', 'password123', 'CASHIER'),
      throwsException,
    );
    // Case-insensitive too.
    await expectLater(
      repository.createUser('DEMO', 'password123', 'CASHIER'),
      throwsException,
    );
  });

  test('the owner can retrain the demo account permissions', () async {
    await repository.ensureDemoUser();
    final demo = (await repository.getAllUsers()).firstWhere((u) => u.isDemo);

    await repository.setUserPermissions(demo.id, const ['pos', 'finance']);

    final updated = await repository.getById(demo.id);
    expect(updated, isNotNull);
    // Money Tracking is owner-only on both backends (audit 2 #3), so a staff
    // tick list can never carry 'finance': the crafted key is dropped rather
    // than stored, and the tab stays hidden.
    expect(updated!.permissions, normalizeFeatureKeys(const ['pos']));
    expect(updated.can('finance'), isFalse);
    expect(updated.can('pos'), isTrue);
    expect(updated.can('reports'), isFalse);
    // Editing permissions never clears the protected flag.
    expect(updated.isDemo, isTrue);
  });
}
